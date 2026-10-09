# dbfree/ — Oracle Database Free + ORDS/APEX

Fully standalone toolkit: two-container stack (plain **Oracle Database
Free**, official image, OTN registry login required, plus a **standalone
ORDS** container serving APEX from a locally downloaded distribution) and
everything needed to deploy any APEX app into it. `ALTER SYSTEM` works, so
`PGA_AGGREGATE_LIMIT` and `MAX_STRING_SIZE` are adjustable — `run-dbfree.sh`
sets both on first start.

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
container-registry.oracle.com first), `ORACLE_PWD`, `DEFAULT_PASSWORD` (the
one password used both for the compat `ADMIN` user and by
`load-apex-app.sh`'s own admin connection — see the `.env.sample` comment for
why this is deliberately a single key), and `DB_HOST_PORT`/`APEX_PORT` if the
defaults collide with something already running.

## Quick start

```bash
./setup-for-dbfree.sh   # preflight checks, Instant Client install, docker login,
                         # pull images, host dirs, download+extract APEX/ORDS
./run-dbfree.sh          # compose up, install APEX + ORDS + compat ADMIN user,
                          # network/AI setup
./test/smoke-dbfree.sh   # verify: connectivity, PGA/session baseline, ORDS, APEX
```

`setup-for-dbfree.sh` runs a `preflight` check first — Docker daemon up,
`docker compose` wired, disk space, `grealpath` on macOS, registry
credentials not left as placeholders, and whether `DB_HOST_PORT`/`APEX_PORT`/
`EM_EXPRESS_HOST_PORT` are already bound — and reports every problem it
finds in one pass rather than failing on the first one. It also installs the
Oracle Instant Client (to `~/oraclient/<INSTANT_CLIENT>`) if not already
present, so this script alone is enough to go from a brand-new machine to a
running stack.

`DB_HOST_PORT`/`APEX_PORT` default to **15216**/**8092** (not 1521/8080) so
they don't collide with other services on the same host — and because a host port held by a long-running prior container can
develop a stuck macOS-side NAT state even after that container stops and
after a full Colima restart (confirmed empirically — raw TCP connects, no
payload ever crosses). If SQL*Net/HTTP mysteriously hangs on whatever ports
you pick instead, suspect this and move off whatever port a long-running
prior container held.

## Deploying an APEX app

```bash
./load-apex-app.sh -f /path/to/your_app_export.sql
```

Generic — not specific to any one app. Auto-detects the schema/workspace
from the export's `p_default_owner`, creates the schema + APEX workspace +
admin user if they don't exist, imports the app (Supporting Objects install
the schema), grants the `ADMINISTRATOR` ACL role, grants network ACL for
`UTL_HTTP`, and configures any `LLM_<STATIC_ID>` remote-server/credential
entries from `.env` (overridable per-import with `-r STATIC_ID=URL`). Run
`./load-apex-app.sh -h` for the full flag list.

## Deploying CaseWeave

From the sibling `caseweave` repo (after `./run-dbfree.sh` has finished):

```bash
cd ../../caseweave && ./deploy-caseweave-to-dbfree.sh
```

It reads this directory's `.env`, imports the app via `load-apex-app.sh`,
and serves the ONNX embedding model from `onnx-models/` (downloaded from
`ONNX_MODEL_URLS` (checksum-verified) on first use).

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
  minted with `APEX_ADMINISTRATOR_ROLE` so `load-apex-app.sh` works —
  Database Free has no built-in `ADMIN` user. The
  role grant has to wait until APEX itself is installed, so `run-dbfree.sh`
  bootstraps this user twice (once early to create it, once more after APEX
  installs to apply the role).
- Ollama reachability from the DB container: this stack allows plain
  outbound HTTP, so no TLS proxy is needed. On hardened Linux
  hosts with a default-deny `iptables` INPUT chain, `run-dbfree.sh` detects
  the block and prints the exact rule to add (`ALLOW_FIREWALL_AUTOFIX=true`
  in `.env` to have it apply the rule itself).
- **The native APEX Generative AI feature (`apex_ai.generate`, used by an
  app's own "Execute Server-Side Code" processes) needs network ACL on the
  APEX owning schema itself** (e.g. `APEX_260100`), not on the calling
  workspace schema, `ADMIN`, or `SYSTEM` — it runs its `UTL_HTTP` call from
  inside a definer-rights package owned by APEX. Without this grant it
  fails with `ORA-29273` wrapping `ORA-24247` ("network access denied by
  access control list (ACL)"), which reads like a generic HTTP/connectivity
  problem and is easy to misdiagnose as a bad URL — confirmed empirically
  (caseweave's "ISet Analyser RAG+" page). `setup-dbfree-network-ai.sql.tpl`
  now grants this automatically (detecting the APEX schema name rather than
  hardcoding a version-specific one). `DBMS_VECTOR_CHAIN` calls don't need
  this grant — only the newer AI Config feature does.
- An app export from another deployment may have a
  Generative AI credential whose actual static ID doesn't match
  `load-apex-app.sh`'s `<LLM_ID>_CRED` convention (APEX Builder sometimes
  auto-generates an opaque name like `credentials_for_<id>_5_` instead).
  This is **not** cosmetic: confirmed empirically that `apex_ai.generate()`
  against a credential left with no value set returns `HTTP-400` from
  Ollama (Ollama itself ignores the `Authorization` header entirely, but
  APEX's own request construction behaves differently with an unset
  credential). `load-apex-app.sh`'s Step 5 handles this automatically now —
  after trying the `<LLM_ID>_CRED` naming guess, it also looks up any
  credential in the workspace whose `VALID_FOR_URLS` contains the remote
  server's base URL (Builder sets this to the linked remote server's URL
  at creation time, which makes it a reliable match independent of naming)
  and sets that one too. `VALID_FOR_URLS` is newline-delimited even for a
  single entry, so the match uses `INSTR`, not exact equality.
- **`apexins.sql` (Oracle's own file) has no trailing `EXIT`** — it chains
  into `apexins_cdb.sql`/`apexins_nocdb.sql` via `@@` and simply ends.
  Every sqlplus call in this toolkit that invokes a script via a bare
  command-line `"@script"` argument (not a heredoc) now redirects
  `< /dev/null`, because without it sqlplus drops into interactive mode
  once the script runs out of input and hangs waiting on whatever stdin
  the call inherited — confirmed empirically (hangs indefinitely without
  the redirect, returns in well under a second with it). This stayed
  hidden during development because backgrounded runs
  (`./run-dbfree.sh > log 2>&1 &`) happen to get a non-interactive stdin
  already; running the same command in the foreground of a real terminal
  is what triggers it.

## Known limitations

- APEX/ORDS downloads may require an OTN login click-through rather than a
  plain `curl` in some circumstances; `setup-for-dbfree.sh` detects a
  non-zip response and fails with instructions to download manually.
- `ORACLE_PWD` is reused for SYS, `ORDS_PUBLIC_USER`, `APEX_LISTENER`, and
  `APEX_REST_PUBLIC_USER` — fine for a local POC, not for anything shared.
- `DB_HOSTNAME` is baked into the DB's persisted config on first creation
  (`oradata/dbconfig/<SID>/listener.ora`/`tnsnames.ora`) and not re-read
  from `.env` on later restarts — changing it against an existing `oradata/`
  needs a manual edit of those files or a clean `oradata/`.

## Files

- `docker-compose.yml` — the two-container topology
- `.env.sample` — config schema; copy to `.env`
- `common.sh` — generic shell helpers (`ini_val`, `platform_val`,
  `detect_platform`, `select_docker_image`, `ok`/`fail`/`warn`/`hdr`/`die`)
- `lib.sh` — dbfree-specific helpers (`resolve_dbfree_path`,
  `enable_extended_string_size`, `set_pga_aggregate_limit`,
  `ensure_host_firewall_allows_ollama`, `run_sql_ezconnect`, ...); sources
  `common.sh`
- `install-instant-client.sh` — one-time Oracle Instant Client install
  (macOS DMG / Linux ZIP), called by `setup-for-dbfree.sh`
- `setup-for-dbfree.sh` — preflight checks, Instant Client install,
  registry login, image pulls, host dirs, APEX/ORDS download+extract
  (`download_apex()`/`download_ords()`)
- `load-apex-app.sh` — import any APEX app export into this stack
- `run-dbfree.sh` — compose up, install APEX + ORDS + compat ADMIN user,
  network/AI setup, generates `ords-entrypoint.sh`; `-c`/`-c -r` tears the
  stack down
- `cleanup-for-dbfree.sh` — mirrors `setup-for-dbfree.sh`: stops the stack's
  containers and, with `-r`, removes the images it pulled
- `onnx-models/` — ONNX embedding model served to the DB (gitignored)
- `sql-scripts/*.sql.tpl` — compat ADMIN user, network/AI ACLs
- `test/smoke-dbfree.sh` — post-deploy verification
- `test/full-cycle-test.sh` — unattended clean → deploy → verify orchestrator
