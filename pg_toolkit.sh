#!/usr/bin/env bash
###############################################################################
#  pg_toolkit.sh  -  PostgreSQL backup, restore and database admin toolkit
#
#  Copyright (c) 2023-2026 Tamilselvan Perumal
#  SPDX-License-Identifier: MIT        (see LICENSE)
#  Thanks to Sapthagiri for his support on the first release.
#  Source / updates: https://techstaradmin.blogspot.com
#
#  Version history
#    1.1  2023-08-24  First release (interactive menu)
#    2.0  2026-10-27  Refactor: secure auth via .pgpass, CLI + menu, verify,
#                     checksums, retention, safe restore, bug fixes
#
#  Usage
#    pg_toolkit.sh                       interactive menu
#    pg_toolkit.sh backup  -d appdb -f custom -t nightly
#    pg_toolkit.sh restore --file <backup> --target appdb_copy --create
#    pg_toolkit.sh --help                all commands and options
###############################################################################
set -Eeuo pipefail
umask 077                                   # backups and logs readable by owner only

readonly VERSION="2.0.0"
readonly PROG="${0##*/}"

# ----------------------------------------------------------------- defaults --
CONF_FILE="${PGTK_CONF:-$HOME/.pg_toolkit.conf}"
BACKUP_DIR="$HOME/pg_backups"
COMPRESS_LEVEL=6          # 0-9
DEFAULT_JOBS=2
RETENTION_DAYS=14
ALLOWED_GROUP=""          # e.g. "pgtoolkit" : only members may run the tool
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
ASSUME_YES=false
TMP_PGPASS=""

# ------------------------------------------------------------------ output --
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_R=$'\e[1;31m' C_G=$'\e[1;32m' C_Y=$'\e[1;33m' C_B=$'\e[1;34m' C_C=$'\e[1;36m' C_W=$'\e[1;97m' C_0=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_W="" C_0=""
fi
info() { printf '%s\n' "${C_B}ℹ${C_0}  $*"; }
ok()   { printf '%s\n' "${C_G}✔${C_0}  $*"; }
warn() { printf '%s\n' "${C_Y}⚠${C_0}  $*" >&2; }
err()  { printf '%s\n' "${C_R}✖${C_0}  $*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() { [[ -n "$TMP_PGPASS" && -f "$TMP_PGPASS" ]] && rm -f "$TMP_PGPASS"; return 0; }
trap cleanup EXIT
trap 'err "Unexpected error on line $LINENO (exit $?)"' ERR

# ------------------------------------------------------------------ config --
# Parse key=value lines without "source", so the config file can never run code.
load_config() {
  [[ -f "$CONF_FILE" ]] || return 0
  local perms; perms=$(stat -c '%a' "$CONF_FILE")
  [[ "$perms" =~ ^[0-7]00$ ]] || warn "$CONF_FILE is readable by others (mode $perms). Run: chmod 600 $CONF_FILE"
  local key val
  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key="${key//[[:space:]]/}"; val="${val%\"}"; val="${val#\"}"
    case "$key" in
      BACKUP_DIR|COMPRESS_LEVEL|DEFAULT_JOBS|RETENTION_DAYS|ALLOWED_GROUP|PGHOST|PGPORT|PGUSER)
        printf -v "$key" '%s' "$val" ;;
      *) warn "Ignoring unknown config key: $key" ;;
    esac
  done < "$CONF_FILE"
}

check_access() {
  [[ -z "$ALLOWED_GROUP" ]] && return 0
  id -nG | tr ' ' '\n' | grep -qx "$ALLOWED_GROUP" \
    || die "Access denied: $(id -un) is not a member of OS group '$ALLOWED_GROUP'."
}

require_cmds() {
  local c; for c in psql pg_dump pg_restore gzip sha256sum find; do
    command -v "$c" >/dev/null || die "Required command not found: $c"
  done
}

# -------------------------------------------------------------- connection --
# Prefer ~/.pgpass. If it does not work, ask once and keep the password in a
# private temporary pgpass file (never in PGPASSWORD, never on the command line).
psql_run() { psql -X -w -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" "$@"; }
psql_val() { psql_run -At "$@"; }

ensure_auth() {
  export PGHOST PGPORT PGUSER
  if psql_val -d postgres -c 'SELECT 1' >/dev/null 2>&1; then return 0; fi
  [[ -t 0 ]] || die "Cannot connect as $PGUSER@$PGHOST:$PGPORT. Add an entry to ~/.pgpass (chmod 600)."
  local pw; read -rsp "🔐 Password for $PGUSER@$PGHOST:$PGPORT: " pw; echo
  TMP_PGPASS=$(mktemp "${TMPDIR:-/tmp}/.pgtk.XXXXXX"); chmod 600 "$TMP_PGPASS"
  local esc=${pw//\\/\\\\}; esc=${esc//:/\\:}
  printf '%s:%s:*:%s:%s\n' "$PGHOST" "$PGPORT" "$PGUSER" "$esc" > "$TMP_PGPASS"
  unset pw esc
  export PGPASSFILE="$TMP_PGPASS"
  psql_val -d postgres -c 'SELECT 1' >/dev/null 2>&1 || die "Authentication failed for $PGUSER@$PGHOST:$PGPORT."
  ok "Connected to $PGHOST:$PGPORT as $PGUSER"
}

db_exists() { [[ "$(psql_val -d postgres -v d="$1" <<< "SELECT 1 FROM pg_database WHERE datname = :'d';")" == 1 ]]; }
server_version_num() { psql_val -d postgres -c 'SHOW server_version_num'; }

# ----------------------------------------------------------------- helpers --
valid_name()  { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_$-]{0,62}$ ]]; }
clean_tag()   { local t="${1//[^A-Za-z0-9_-]/}"; printf '%s' "${t:-manual}"; }
now_ts()      { date +%Y%m%d_%H%M%S; }
confirm() {   # confirm "question"
  $ASSUME_YES && return 0
  local a; read -rp "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]
}
ask() {       # ask VAR "prompt" [default]
  local __v="$1" __p="$2" __d="${3:-}" __a
  read -rp "$__p${__d:+ [$__d]}: " __a
  printf -v "$__v" '%s' "${__a:-$__d}"
}
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

history_log() {   # op db format tag status path seconds
  local f="$BACKUP_DIR/history.tsv"
  [[ -f "$f" ]] || printf 'timestamp\tos_user\toperation\tdatabase\tformat\ttag\tstatus\tpath\tseconds\n' > "$f"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$(id -un)" "$@" >> "$f"
}

check_space() {   # db : warn if free space < database size
  local size free
  size=$(psql_val -d postgres -v d="$1" <<< "SELECT pg_database_size(:'d');")
  free=$(df -PB1 "$BACKUP_DIR" | awk 'NR==2{print $4}')
  if (( free < size )); then
    warn "Free space in $BACKUP_DIR ($(human "$free")) is less than the database size ($(human "$size"))."
    confirm "Continue anyway?" || die "Backup cancelled."
  fi
}

# ------------------------------------------------------------------ backup --
backup_db() {   # backup_db DB FORMAT TAG JOBS
  local db="$1" fmt="$2" tag; tag=$(clean_tag "$3"); local jobs="${4:-$DEFAULT_JOBS}"
  valid_name "$db" || die "Invalid database name: $db"
  db_exists "$db" || die "Database '$db' does not exist."
  mkdir -p "$BACKUP_DIR/logs"; check_space "$db"
  local ts base out log start rc=0
  ts=$(now_ts); base="${db}_${fmt}_${tag}_${ts}"; log="$BACKUP_DIR/logs/${base}.log"
  start=$SECONDS
  info "Backing up '$db' ($fmt format, tag '$tag') ..."
  case "$fmt" in
    custom)    out="$BACKUP_DIR/${base}.dump"
               pg_dump -w -d "$db" -Fc -Z "$COMPRESS_LEVEL" -v -f "$out" 2>"$log" || rc=$? ;;
    plain)     out="$BACKUP_DIR/${base}.sql.gz"
               { pg_dump -w -d "$db" -Fp -v 2>"$log" | gzip -"$COMPRESS_LEVEL" > "$out"; } || rc=$? ;;
    directory) out="$BACKUP_DIR/${base}.dir"
               pg_dump -w -d "$db" -Fd -j "$jobs" -Z "$COMPRESS_LEVEL" -v -f "$out" 2>"$log" || rc=$? ;;
    *) die "Unknown format '$fmt' (use custom, plain or directory)." ;;
  esac
  if (( rc != 0 )); then
    history_log backup "$db" "$fmt" "$tag" FAILED "$out" $((SECONDS-start))
    err "pg_dump failed (exit $rc). Last lines of $log:"; tail -n 5 "$log" >&2; return 1
  fi
  write_checksum "$out"
  verify_backup "$out" >/dev/null || { history_log backup "$db" "$fmt" "$tag" CORRUPT "$out" $((SECONDS-start)); die "Backup verification failed: $out"; }
  history_log backup "$db" "$fmt" "$tag" SUCCESS "$out" $((SECONDS-start))
  ok "Backup complete in $((SECONDS-start))s: $out ($(du -sh "$out" | cut -f1))"
}

write_checksum() {   # file or directory
  if [[ -d "$1" ]]; then ( cd "$1" && sha256sum -- * > "../$(basename "$1").sha256" )
  else ( cd "$(dirname "$1")" && sha256sum -- "$(basename "$1")" > "$(basename "$1").sha256" ); fi
}

verify_backup() {    # verify_backup PATH : checksum + readable archive
  local p="${1%/}" sum="${1%/}.sha256"
  [[ -e "$p" ]] || die "Not found: $p"
  if [[ -f "$sum" ]]; then
    if [[ -d "$p" ]]; then ( cd "$p" && sha256sum --quiet -c "$sum" ) || { err "Checksum mismatch: $p"; return 1; }
    else ( cd "$(dirname "$p")" && sha256sum --quiet -c "$sum" ) || { err "Checksum mismatch: $p"; return 1; }; fi
  else warn "No checksum file for $p"; fi
  case "$p" in
    *.sql.gz) gzip -t "$p" || { err "gzip test failed: $p"; return 1; } ;;
    *.dump|*.dir) pg_restore -l "$p" >/dev/null || { err "pg_restore cannot read: $p"; return 1; } ;;
    *) err "Unknown backup type: $p"; return 1 ;;
  esac
  ok "Verified: $p"
}

list_backups() {     # list_backups [DB]  -> numbered list in BACKUPS[]
  local db="${1:-}"; BACKUPS=()
  mapfile -t BACKUPS < <(find "$BACKUP_DIR" -maxdepth 1 \( -name "${db:-*}_*.dump" -o -name "${db:-*}_*.sql.gz" -o -name "${db:-*}_*.dir" \) -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2)
  if (( ${#BACKUPS[@]} == 0 )); then warn "No backups found in $BACKUP_DIR${db:+ for database $db}"; return 1; fi
  printf '%s\n' "${C_W} #  MODIFIED            SIZE    BACKUP${C_0}"
  local i; for i in "${!BACKUPS[@]}"; do
    printf '%3d  %s  %6s  %s\n' "$((i+1))" "$(date -r "${BACKUPS[$i]}" '+%F %H:%M')" "$(du -sh "${BACKUPS[$i]}" | cut -f1)" "$(basename "${BACKUPS[$i]}")"
  done
}

pick_backup() {      # pick_backup [DB] -> PICKED
  list_backups "${1:-}" || return 1
  local n; read -rp "Select backup number: " n
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#BACKUPS[@]} )); then err "Invalid selection."; return 1; fi
  PICKED="${BACKUPS[$((n-1))]}"
}

# ----------------------------------------------------------------- restore --
restore_db() {   # restore_db FILE TARGET CREATE(true/false) CLEAN(true/false) JOBS
  local file="${1%/}" target="$2" create="$3" clean="$4" jobs="${5:-$DEFAULT_JOBS}" start=$SECONDS rc=0
  valid_name "$target" || die "Invalid target database name: $target"
  verify_backup "$file" || die "Refusing to restore an unverified backup."
  mkdir -p "$BACKUP_DIR/logs"
  local log; log="$BACKUP_DIR/logs/restore_${target}_$(now_ts).log"
  if db_exists "$target"; then
    if [[ "$create" == true ]]; then die "Target '$target' already exists; drop it first or restore without --create."; fi
    local objs; objs=$(psql_val -d "$target" -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%'")
    if (( objs > 0 )) && [[ "$clean" != true ]]; then
      warn "Target '$target' already contains $objs objects. Restoring on top will cause errors."
      confirm "Restore into it anyway (consider --clean)?" || die "Restore cancelled."
    fi
  else
    [[ "$create" == true ]] || die "Target '$target' does not exist (use --create)."
    psql_run -d postgres -v d="$target" <<< "SELECT format('CREATE DATABASE %I', :'d') \gexec" >/dev/null
    ok "Created database '$target'"
  fi
  info "Restoring $(basename "$file") into '$target' ..."
  case "$file" in
    *.sql.gz)
      [[ "$clean" == true ]] && warn "--clean has no effect for plain backups (they contain no DROP statements unless dumped with --clean)."
      { gzip -dc "$file" | psql_run -q -d "$target" --single-transaction >"$log" 2>&1; } || rc=$? ;;
    *.dump|*.dir)
      local opts=(-w -d "$target" -j "$jobs" -v)
      [[ "$clean" == true ]] && opts+=(--clean --if-exists)
      pg_restore "${opts[@]}" "$file" >"$log" 2>&1 || rc=$? ;;
  esac
  if (( rc != 0 )); then
    history_log restore "$target" "-" "-" FAILED "$file" $((SECONDS-start))
    err "Restore finished with errors (exit $rc). Review: $log"; grep -m5 -i 'error' "$log" >&2 || true; return 1
  fi
  history_log restore "$target" "-" "-" SUCCESS "$file" $((SECONDS-start))
  ok "Restore complete in $((SECONDS-start))s. Log: $log"
}

# ------------------------------------------------------- database admin ops --
list_dbs() {
  psql_run -d postgres -P border=2 -P footer=off -c "
    SELECT datname AS database, pg_get_userbyid(datdba) AS owner,
           pg_size_pretty(pg_database_size(datname)) AS size,
           (SELECT count(*) FROM pg_stat_activity a WHERE a.datname = d.datname) AS sessions
    FROM pg_database d WHERE NOT datistemplate ORDER BY pg_database_size(datname) DESC;"
}

create_db() {    # create_db DB OWNER [TABLESPACE] [LOCATION]
  local db="$1" owner="$2" ts="${3:-}" loc="${4:-}"
  { valid_name "$db" && valid_name "$owner"; } || die "Names must start with a letter or _ and contain only letters, digits, _ or -."
  db_exists "$db" && die "Database '$db' already exists."
  if [[ "$(psql_val -d postgres -v r="$owner" <<< "SELECT 1 FROM pg_roles WHERE rolname = :'r';")" != 1 ]]; then
    local pw pw2; read -rsp "🔐 New password for role '$owner': " pw; echo; read -rsp "🔐 Repeat password: " pw2; echo
    [[ -n "$pw" && "$pw" == "$pw2" ]] || die "Passwords are empty or do not match."
    psql_run -d postgres -v r="$owner" -v p="$pw" <<< "SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'r', :'p') \gexec" >/dev/null
    unset pw pw2; ok "Created role '$owner'"
  else info "Using existing role '$owner'"; fi
  if [[ -n "$ts" ]]; then
    valid_name "$ts" || die "Invalid tablespace name: $ts"
    if [[ "$(psql_val -d postgres -v t="$ts" <<< "SELECT 1 FROM pg_tablespace WHERE spcname = :'t';")" != 1 ]]; then
      [[ -n "$loc" ]] || die "Tablespace '$ts' does not exist; give its LOCATION (an empty directory owned by the postgres OS user on the DB server)."
      psql_run -d postgres -v t="$ts" -v l="$loc" -v o="$owner" <<< "SELECT format('CREATE TABLESPACE %I OWNER %I LOCATION %L', :'t', :'o', :'l') \gexec" >/dev/null \
        || die "CREATE TABLESPACE failed. The directory must exist, be empty, and be owned by the postgres OS user on $PGHOST."
      ok "Created tablespace '$ts' at $loc"
    fi
  fi
  psql_run -d postgres -v d="$db" -v o="$owner" -v t="${ts:-pg_default}" <<< \
    "SELECT format('CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING %L TABLESPACE %I', :'d', :'o', 'UTF8', :'t') \gexec" >/dev/null
  history_log create "$db" "-" "-" SUCCESS "-" 0
  ok "Created database '$db' (owner $owner, tablespace ${ts:-pg_default})"
}

drop_db() {      # drop_db DB
  local db="$1"
  valid_name "$db" || die "Invalid database name: $db"
  [[ "$db" =~ ^(postgres|template0|template1)$ ]] && die "Refusing to drop system database '$db'."
  db_exists "$db" || die "Database '$db' does not exist."
  psql_run -d postgres -P border=2 -P footer=off -v d="$db" <<< "SELECT datname AS database, pg_size_pretty(pg_database_size(datname)) AS size,
     (SELECT count(*) FROM pg_stat_activity WHERE datname = :'d') AS sessions FROM pg_database WHERE datname = :'d';"
  if list_backups "$db" >/dev/null 2>&1; then info "Latest backup: $(basename "${BACKUPS[0]}")"
  else warn "There is NO backup of '$db' in $BACKUP_DIR."; fi
  if ! $ASSUME_YES; then
    confirm "Take a custom-format backup before dropping?" && backup_db "$db" custom pre_drop "$DEFAULT_JOBS"
    local typed; read -rp "Type the database name to confirm DROP: " typed
    [[ "$typed" == "$db" ]] || die "Name did not match. Nothing dropped."
  fi
  local force=""; (( $(server_version_num) >= 130000 )) && force=" WITH (FORCE)"
  psql_run -d postgres -v d="$db" <<< "SELECT format('DROP DATABASE %I$force', :'d') \gexec" >/dev/null
  history_log drop "$db" "-" "-" SUCCESS "-" 0
  ok "Dropped database '$db'"
}

purge_backups() { # purge_backups DAYS : delete toolkit backups older than DAYS
  local days="${1:-$RETENTION_DAYS}" files=()
  [[ "$days" =~ ^[0-9]+$ ]] || die "Invalid number of days: $days"
  mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 \( -name '*_*.dump' -o -name '*_*.sql.gz' -o -name '*_*.dir' \) -mtime +"$days" 2>/dev/null | sort)
  (( ${#files[@]} )) || { info "No backups older than $days days."; return 0; }
  printf '  %s\n' "${files[@]##*/}"
  confirm "Delete these ${#files[@]} backup(s) older than $days days?" || { info "Nothing deleted."; return 0; }
  local f; for f in "${files[@]}"; do rm -rf -- "$f" "$f.sha256"; history_log purge "-" "-" "-" DELETED "$f" 0; done
  ok "Deleted ${#files[@]} old backup(s)."
}

about() { cat <<EOF
${C_W}Which backup format?${C_0}
  ${C_G}custom${C_0}     pg_dump -Fc   One compressed file. Restore all or selected objects,
                           in parallel with pg_restore -j. Best general choice.
  ${C_G}directory${C_0}  pg_dump -Fd   One compressed file per table. The only format that
                           can BACK UP in parallel (-j). Best for large databases.
  ${C_G}plain${C_0}      pg_dump -Fp   SQL text (gzip). Readable and editable, restored with
                           psql. Single-threaded, slowest for big databases.
  All three are logical backups of one database. For point-in-time recovery use
  pg_basebackup + WAL archiving. Roles and tablespaces: pg_dumpall --globals-only.
EOF
}

# -------------------------------------------------------------------- menu --
banner() {
  local line="════════════════════════════════════════════════════════════"
  printf '%s\n' "${C_C}${line}${C_0}" \
    "  ${C_W}🐘 pg_toolkit ${VERSION}${C_0}   PostgreSQL backup, restore & admin" \
    "  ${PGUSER}@${PGHOST}:${PGPORT}   backups: ${BACKUP_DIR}" \
    "${C_C}${line}${C_0}"
}

menu() {
  local choice db fmt tag jobs target
  while true; do
    echo; banner
    cat <<EOF
  ${C_B}BACKUP${C_0}    1) Backup a database          2) Verify a backup
  ${C_B}RESTORE${C_0}   3) Restore a backup           4) List backups
  ${C_B}DATABASE${C_0}  5) List databases & sizes     6) Create a database
            7) Drop a database
  ${C_B}HOUSEKEEP${C_0} 8) Purge old backups          9) Which format should I use?
            0) Exit
EOF
    read -rp "Choose: " choice || exit 0
    case "$choice" in
      1) list_dbs; ask db "Database"; ask fmt "Format (custom/plain/directory)" custom
         ask tag "Tag" manual; jobs=$DEFAULT_JOBS
         [[ "$fmt" == directory ]] && ask jobs "Parallel jobs (1-$(nproc))" "$DEFAULT_JOBS"
         backup_db "$db" "$fmt" "$tag" "$jobs" || true ;;
      2) pick_backup && verify_backup "$PICKED" || true ;;
      3) if pick_backup; then
           ask target "Target database" "$(basename "$PICKED" | cut -d_ -f1)"
           local c=false k=false
           db_exists "$target" || { confirm "Create '$target'?" && c=true; }
           [[ "$PICKED" == *.sql.gz ]] || { confirm "Drop existing objects first (--clean)?" && k=true; }
           ask jobs "Parallel jobs" "$DEFAULT_JOBS"
           restore_db "$PICKED" "$target" "$c" "$k" "$jobs" || true
         fi ;;
      4) list_backups || true ;;
      5) list_dbs ;;
      6) local o t l; ask db "New database name"; ask o "Owner role"; ask t "Tablespace (empty = pg_default)"
         [[ -n "$t" ]] && ask l "Tablespace location (only if it must be created)"
         create_db "$db" "$o" "$t" "${l:-}" || true ;;
      7) list_dbs; ask db "Database to drop"; drop_db "$db" || true ;;
      8) ask tag "Delete backups older than how many days" "$RETENTION_DAYS"; purge_backups "$tag" ;;
      9) about ;;
      0|q|Q) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

usage() { cat <<EOF
$PROG $VERSION - PostgreSQL backup, restore and admin toolkit

Usage: $PROG [command] [options]
Commands:
  menu                                 interactive menu (default)
  backup     -d DB [-f custom|plain|directory] [-t TAG] [-j JOBS]
  verify     --file PATH
  restore    --file PATH --target DB [--create] [--clean] [-j JOBS]
  list-backups [-d DB]
  list-dbs
  create-db  -d DB --owner ROLE [--tablespace NAME [--location DIR]]
  drop-db    -d DB --yes               (non-interactive drop: use with care)
  purge      [--keep-days N] [--yes]
Connection: -h HOST  -p PORT  -U USER   (or PGHOST/PGPORT/PGUSER, ~/.pgpass)
Config:     $CONF_FILE   (keys: BACKUP_DIR COMPRESS_LEVEL DEFAULT_JOBS
            RETENTION_DAYS ALLOWED_GROUP PGHOST PGPORT PGUSER)
EOF
}

# -------------------------------------------------------------------- main --
main() {
  load_config
  local cmd="${1:-menu}"; [[ $# -gt 0 ]] && shift
  local db="" fmt=custom tag=manual jobs="" file="" target="" create=false clean=false owner="" ts="" loc="" days=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) db="$2"; shift ;;            -f) fmt="$2"; shift ;;
      -t) tag="$2"; shift ;;           -j) jobs="$2"; shift ;;
      -h) PGHOST="$2"; shift ;;        -p) PGPORT="$2"; shift ;;
      -U) PGUSER="$2"; shift ;;        --file) file="$2"; shift ;;
      --target) target="$2"; shift ;;  --create) create=true ;;
      --clean) clean=true ;;           --owner) owner="$2"; shift ;;
      --tablespace) ts="$2"; shift ;;  --location) loc="$2"; shift ;;
      --keep-days) days="$2"; shift ;; --yes|-y) ASSUME_YES=true ;;
      --help) usage; exit 0 ;;         *) die "Unknown option: $1 (see --help)" ;;
    esac; shift
  done
  case "$cmd" in --help|help) usage; exit 0 ;; --version|version) echo "$VERSION"; exit 0 ;; esac
  check_access; require_cmds
  mkdir -p "$BACKUP_DIR/logs"
  case "$cmd" in
    verify) [[ -n "$file" ]] || die "verify needs --file"; verify_backup "$file" || exit 1; exit 0 ;;
    list-backups) list_backups "$db" || exit 1; exit 0 ;;
  esac
  ensure_auth
  case "$cmd" in
    menu)         menu ;;
    backup)       [[ -n "$db" ]] || die "backup needs -d DB"; backup_db "$db" "$fmt" "$tag" "${jobs:-$DEFAULT_JOBS}" || exit 1 ;;
    restore)      [[ -n "$file" && -n "$target" ]] || die "restore needs --file and --target"
                  restore_db "$file" "$target" "$create" "$clean" "${jobs:-$DEFAULT_JOBS}" || exit 1 ;;
    list-dbs)     list_dbs ;;
    create-db)    [[ -n "$db" && -n "$owner" ]] || die "create-db needs -d DB and --owner ROLE"; create_db "$db" "$owner" "$ts" "$loc" ;;
    drop-db)      [[ -n "$db" ]] || die "drop-db needs -d DB"; drop_db "$db" ;;
    purge)        purge_backups "${days:-$RETENTION_DAYS}" ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"
