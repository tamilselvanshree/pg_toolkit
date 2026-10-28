# Code review: PostgreSQL Backup & Restore tool v1.1 → pg_toolkit 2.0

Reviewed: the original v1.1 script (24 Aug 2023). Tested on PostgreSQL 16.15 / Ubuntu 24.04 / bash 5.2, shellcheck clean.
Items marked **(proved)** were reproduced on a test system before being fixed.

## 1. Critical: security and login

| # | Problem in v1.1 | Impact | Fix in 2.0 |
|---|---|---|---|
| 1 | `initialize_config` writes `authorized_users` but never writes `user_passwords`. | **No one can ever log in** on a fresh install. **(proved)** | Script login removed (see #4). |
| 2 | `prompt_and_validate_input` runs `eval "$input_var=\"$input\""`. | Anything typed at a prompt, e.g. `$(rm -rf ~)`, is **executed**. **(proved)** | No `eval`. Uses `printf -v` and strict name validation. |
| 3 | `.config.cfg` is loaded with `source`. | Anyone who can edit the file can run code as the DBA. | Config is parsed as `key=value`; only known keys are accepted. Warns if not `chmod 600`. |
| 4 | Passwords stored in plain text in `.config.cfg`. Lockout kept in `.login_attempts.log` (just delete it to reset). A failed login offers to add a new user. `admin_password` is empty if an env var is unset. | The login gives no real protection, only a feeling of it. | Real controls: OS file permissions, optional `ALLOWED_GROUP` (OS group membership), and PostgreSQL's own authentication. |
| 5 | `export PGPASSWORD=...`. | Password visible to child processes and in `/proc/<pid>/environ`. | Uses `~/.pgpass`. If missing, asks once and writes a `mktemp` pgpass (mode 600) that a `trap` deletes on exit. |
| 6 | `create_remote_database` builds SQL by string interpolation (`CREATE DATABASE $db ...`). | SQL injection through a database/role name. | psql variables + `format('%I','%L')` + `\gexec`, plus name validation. |

## 2. Backup and restore bugs

| # | Problem | Fix |
|---|---|---|
| 7 | Custom-format (`-Fc`) dump is gzipped again. It is already compressed, so this wastes CPU, and restore needs a temporary full unzip copy. | `pg_dump -Fc -Z <level>`, no extra gzip. |
| 8 | Plain restore runs `psql` without `ON_ERROR_STOP`. psql exits 0 even when statements fail, so a broken restore is reported as **success**. | `psql -v ON_ERROR_STOP=1 --single-transaction`: any error rolls the whole restore back. Tested. |
| 9 | Restore follows the log with `tail -f` and waits for a "failed" marker that is never written. On failure the script **hangs forever**. | Exit code checked directly; first errors printed from the log. |
| 10 | `exit 1` inside functions runs before `log_history`. Failures are never recorded. | Every outcome (SUCCESS / FAILED / CORRUPT) goes to `history.tsv`. |
| 11 | Housekeeping searches `directory-*` and `plain-*.backup.gz`, but backups are named `Directory-*` and `plain-*.sql.gz`. **It never deletes anything.** **(proved)** | One naming scheme `<db>_<format>_<tag>_<YYYYmmdd_HHMMSS>` and `find -mtime` retention. |
| 12 | Timestamps `dd-mm-YYYY` do not sort in time order. | `YYYYmmdd_HHMMSS`. |
| 13 | Custom restore has no `-j`, `--clean` or create option. | `--create`, `--clean --if-exists`, `-j N`. |
| 14 | No check that a backup is readable before you need it. | SHA-256 checksum written after every backup; `verify` runs checksum + `pg_restore -l` / `gzip -t`. Restore refuses unverified files. |
| 15 | Backups are picked with unquoted `ls` globs (breaks on spaces, `ls` parsing). | `find` + `mapfile`, numbered chooser. |
| 16 | "localhost / 5432" shown as defaults but not applied when Enter is pressed. | Defaults really apply (`ask VAR "prompt" default`). |
| 17 | No free-space check. | Warns when free space < database size. |

## 3. Admin operations

| # | Problem | Fix |
|---|---|---|
| 18 | `psql -W password` – `-W` only forces a prompt, it does not take a value; combined with `-w` it is contradictory. | Removed; auth via pgpass. |
| 19 | `createuser -P` gets one line from a pipe, so the "enter it again" confirmation fails. | Role created with SQL; password asked twice and compared. |
| 20 | Tablespace directory must exist, be empty and be owned by the **postgres OS user on the DB server**; not mentioned. | Checked and explained in the error message. |
| 21 | Menu option 1 passes unset variables and asks for the database name twice. | Rewritten menu. |
| 22 | `drop_database` has no backup offer and fails if anyone is connected. | Shows size/sessions/latest backup, offers a backup, requires typing the name, refuses `postgres`/`template*`, uses `WITH (FORCE)` on PG 13+. |
| 23 | `list_database_sizes` uses an unset `superuser_password`. | Uses the shared connection. |

## 4. Shell quality

* No `set -Eeuo pipefail`, no traps → 2.0 has both, plus `umask 077` so backups are owner-only.
* shellcheck: 9 warnings in v1.1 → 0 in 2.0.
* `chmod` at the end of the script was unreachable (after the menu's `exit`).
* New: CLI sub-commands for cron, `NO_COLOR` support, `--help`, `--version`.

## 5. Corrections to the "About" text

| v1.1 said | Correct |
|---|---|
| Custom format: no parallel restore | Custom format **does** support parallel restore (`pg_restore -j`). Only the *dump* is single-threaded. |
| Plain format needs only psql | Plain needs `pg_dump` to create and `psql` to restore. |
| Directory format: not compressed, toc.dat human-readable | Directory format **is** compressed per table; `toc.dat` is binary (read it with `pg_restore -l`). |
| "Michael Stonebreaker" | Michael **Stonebraker**. |

Also worth stating: all three are **logical** backups of one database. They do not include roles or tablespaces (use `pg_dumpall --globals-only`) and cannot do point-in-time recovery (use `pg_basebackup` + WAL archiving or pgBackRest).
