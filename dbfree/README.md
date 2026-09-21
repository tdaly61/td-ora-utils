# dbfree/ — Oracle Database Free + ORDS/APEX

Two-container stack: plain **Oracle Database Free** (official image, OTN
registry login required) plus a **standalone ORDS** container that serves
APEX from a locally downloaded distribution. Unlike Database Free, `../adb/`
runs the single-container **ADB-Free** image, which blocks `ALTER SYSTEM`
(so `PGA_AGGREGATE_LIMIT`/`MAX_STRING_SIZE` can't be adjusted) — this stack
exists for workloads that need those adjustable. `adb/` is untouched by
anything here.

Oracle Database Free ships native arm64 images; Enterprise Edition works too
(point `DOCKER_IMAGE_ARM`/`DOCKER_IMAGE_AMD` at it) but is amd64-only and
loses the adjustable PGA limit.

**Licensing/scope**: Database Free is covered by Oracle's Free Use Terms —
read the terms shown when accepting the licence for `Database -> Free` at
container-registry.oracle.com. This toolkit is demo/POC scope, not
production-hardened (see `../CLAUDE.md`).

## Config

```bash
cp .env.sample .env
```

Edit `.env`: `ORACLE_REGISTRY_USER`/`ORACLE_REGISTRY_PASSWORD` (Oracle SSO
credentials — accept the licence for `Database -> Free` at
container-registry.oracle.com first), `ORACLE_PWD`, `ADMIN_COMPAT_PASSWORD`
(or leave blank to reuse `../adb/.env`'s `DEFAULT_PASSWORD`), and
`DB_HOST_PORT`/`APEX_PORT` if the defaults collide with something already
running.

`.env.sample` is this directory's own config schema — not `../adb/.env`'s.

## Quick start

```bash
./setup-for-dbfree.sh   # docker login, pull images, host dirs, download+extract APEX/ORDS
./run-dbfree.sh          # compose up, install APEX + ORDS + compat ADMIN user, network/AI setup
./test/smoke-dbfree.sh   # verify: connectivity, PGA/session baseline, ORDS, APEX
```

`DB_HOST_PORT`/`APEX_PORT` default to **15216**/**8092** (not 1521/8080) so
they don't collide with a long-running `adb-free` container on the same
host.

## Access

Local:
- APEX: `http://localhost:8092/ords/apex`
- ORDS: `http://localhost:8092/ords/`
- SQL*Net: `localhost:15216/FREEPDB1` (`FREEPDB1` for Database Free,
  `ORCLPDB1` for Enterprise Edition)
- EM Express: `https://localhost:5500/em`

Remote (forward over SSH rather than exposing ports directly):

```bash
ssh -L 15216:localhost:15216 -L 8092:localhost:8092 -L 5500:localhost:5500 \
    -N ubuntu@<host>
```

## Cleanup

```bash
./run-dbfree.sh -c          # stop containers, wipe DB/ORDS state (keeps the extracted APEX zip)
./run-dbfree.sh -c -r       # same, and also remove the pulled Docker images
```

Or, to undo just what `setup-for-dbfree.sh` did (stop containers, optionally
drop the pulled images) without touching DB/ORDS state:

```bash
./cleanup-for-dbfree.sh     # stop all dbfree containers
./cleanup-for-dbfree.sh -r  # same, and also remove the pulled Docker images
```

Unattended clean → deploy → verify cycle:

```bash
./test/full-cycle-test.sh
# tail -f test/reports/full-cycle-<timestamp>.log while it runs
```

## Architecture notes

- No official `ords` container image is used (it needs the same OTN
  registry login as the DB image); `ords` instead runs ORDS standalone,
  downloaded as a plain zip from `download.oracle.com`, inside a generic
  `eclipse-temurin` JRE image. `run-dbfree.sh` generates its entrypoint
  script (`write_ords_entrypoint()`) at each run.
- APEX is installed by `run-dbfree.sh` directly against the DB via
  EZConnect (`apexins.sql`, `apex_rest_config.sql`) — not by the `ords`
  container.
- `run-dbfree.sh` sets `MAX_STRING_SIZE=EXTENDED` and raises
  `PGA_AGGREGATE_LIMIT` (`DB_PGA_AGGREGATE_LIMIT` in `.env`) on first start,
  since plain Database Free defaults to `STANDARD`/2G.
- A compat `ADMIN` database user (`create-admin-compat-user.sql.tpl`) is
  minted with `APEX_ADMINISTRATOR_ROLE` so `../adb/load-apex-app.sh` works
  against this stack unmodified — Database Free has no built-in `ADMIN`
  user the way ADB-Free does.
- Ollama reachability from the DB container: unlike ADB-Free, this stack
  allows plain outbound HTTP, so no TLS proxy is needed. On hardened Linux
  hosts with a default-deny `iptables` INPUT chain, `run-dbfree.sh` detects
  the block and prints the exact rule to add (`ALLOW_FIREWALL_AUTOFIX=true`
  in `.env` to have it apply the rule itself).

## Comparison with `../adb/`

| | `../adb/` (adb-free) | `dbfree/` (this directory) |
|---|---|---|
| Containers | 1 (DB+ORDS+APEX bundled) | 2 (DB, plus ORDS standalone in a plain JRE container) |
| Transport | TCPS/mTLS only | Plain TCP/HTTP |
| Outbound HTTP | `REQUIRE_OUT_HTTPS=Y` forced — needs `ollama-proxy` | Unrestricted — direct `UTL_HTTP` to host Ollama |
| SYS/SYSDBA | Disabled even via `docker exec` | Available |
| `ALTER SYSTEM` | Blocked (`ORA-01031`, even as ADMIN/DBA) | Available |
| Top-level user | `ADMIN` built in | No `ADMIN` — minted by `create-admin-compat-user.sql.tpl` |
| Resource ceiling | 4 ECPU / 30 sessions / 20GB, PGA limit fixed | 2GB PGA+SGA default, DBA-adjustable |
| Host ports | 1521/1522/8443 | 15216 (SQL*Net)/8092 (APEX/ORDS) by default |

## Known limitations

- APEX/ORDS downloads may require an OTN login click-through rather than a
  plain `curl` in some circumstances; `setup-for-dbfree.sh` detects a
  non-zip response and fails with instructions to download manually.
- `ORACLE_PWD` is reused for SYS, the compat `ADMIN` user (unless
  `ADMIN_COMPAT_PASSWORD` is set), `ORDS_PUBLIC_USER`, `APEX_LISTENER`, and
  `APEX_REST_PUBLIC_USER` — fine for a local POC, not for anything shared.
- `DB_HOSTNAME` is baked into the DB's persisted config on first creation
  (`oradata/dbconfig/<SID>/listener.ora`/`tnsnames.ora`) and not re-read
  from `.env` on later restarts — changing it against an existing `oradata/`
  needs a manual edit of those files or a clean `oradata/`.

## Files

- `docker-compose.yml` — the two-container topology
- `.env.sample` — config schema; copy to `.env`
- `lib.sh` — shared helpers (`ini_val`, `resolve_dbfree_path`,
  `enable_extended_string_size`, `set_pga_aggregate_limit`,
  `ensure_host_firewall_allows_ollama`, `run_sql_ezconnect`, ...); reuses
  `../adb/common.sh` read-only
- `setup-for-dbfree.sh` — one-time host prep: registry login, image pulls,
  host dirs, APEX/ORDS download+extract (`download_apex()`/`download_ords()`)
- `run-dbfree.sh` — compose up, install APEX + ORDS + compat ADMIN user,
  network/AI setup, generates `ords-entrypoint.sh`; `-c`/`-c -r` tears the
  stack down
- `cleanup-for-dbfree.sh` — mirrors `setup-for-dbfree.sh`: stops the stack's
  containers and, with `-r`, removes the images it pulled
- `sql-scripts/*.sql.tpl` — compat ADMIN user, network/AI ACLs
- `test/smoke-dbfree.sh` — post-deploy verification
- `test/full-cycle-test.sh` — unattended clean → deploy → verify orchestrator
