# ee/ — Oracle Database Enterprise Edition POC

Two-container Oracle stack (plain DB + separate ORDS container) as an
alternative to the single bundled `adb-free` container in `../adb/`.
**`adb/` is untouched by anything here** — cars1 and other apps keep using it
as-is.

## Why this exists

`../adb/` runs the ADB-Free container, which — like plain Oracle Database
Free — has hard, vendor-imposed resource ceilings (see the project's
[CLAUDE.md](../CLAUDE.md)). caseweave's vector-embedding worker daemons have
hit `ORA-04036` (PGA_AGGREGATE_LIMIT exceeded) against ADB-Free, and Database
Free's own combined SGA+PGA cap (2GB) hits the same wall. This toolkit stands
up the two-container topology (DB + ORDS + APEX 26.1) directly against
**Oracle Database Enterprise Edition** — no vendor-imposed PGA ceiling —
pulled straight from Oracle's own registry
(`container-registry.oracle.com/database/enterprise`, OTN registry
credentials required — see `.env.sample`).

**Licensing**: this runs under the free **OTN Developer License Terms** —
developing/testing/prototyping/demonstrating only; no production/business/
commercial data processing; single developer/single workstation; no
redistribution to third parties. That fits a personal demo/POC exactly — it
stops applying the moment this instance is shared with a team or used to
process real data.

A generic, `adb/`-equivalent script library (`load-apex-app.sh`,
`export-apex-app.sh`, OCI bundle/deploy) for this topology doesn't exist yet
— this POC deliberately reuses `../adb/load-apex-app.sh` directly (see
below) as a proof that the generic-library pattern already works here,
rather than duplicating it early.

## Quick start

```bash
cp .env.sample .env
# edit .env: ORACLE_REGISTRY_USER/PASSWORD (your Oracle SSO credentials —
# accept the licence for Database -> Enterprise Edition at
# container-registry.oracle.com first), ORACLE_PWD, ADMIN_COMPAT_PASSWORD
# (or leave blank to reuse ../adb/.env's DEFAULT_PASSWORD), and DB_HOST_PORT
# if 1521 isn't free

./setup-for-ee.sh      # docker login, pull images, host dirs
./download-apex.sh     # fetch + extract APEX (see note below if this fails)
./download-ords.sh     # fetch + extract ORDS (same caveat)
./run-ee.sh            # compose up, install APEX + ORDS + compat ADMIN user, network/AI setup
./test/smoke-ee.sh     # verify: connectivity, PGA/session baseline, ORDS, APEX
```

Note: `DB_HOST_PORT` defaults to **1521** — the same port `../adb/`'s
adb-free container normally holds. Only one of the two can bind 1521 at a
time; stop adb-free first (`docker stop adb-free` — reversible, doesn't
touch anything in `adb/`), or set `DB_HOST_PORT` to something else (e.g.
`1523`) in `.env` if you need both running side by side. Check `docker ps`
if you're unsure what's currently bound.

## Access from your laptop

If this is running on a remote host, forward the ports over SSH rather than
exposing them directly:

```bash
ssh -L 1521:localhost:1521 -L 8080:localhost:8080 -L 5500:localhost:5500 \
    -N ubuntu@<host>
```

Then, from your laptop:
- APEX: `http://localhost:8080/ords/apex` (plain HTTP — ee has no self-signed
  cert to accept, unlike adb-free's `https://localhost:8443`)
- ORDS: `http://localhost:8080/ords/`
- SQL*Net (sqlplus/DB tools): `localhost:1521/ORCLPDB1` (or whatever
  `ORACLE_PDB` is set to)
- EM Express: `https://localhost:5500/em`

(Same pattern `../adb/load-apex-app.sh` already uses for its own printed
"SSH tunnel (if remote)" note — just with ee's ports instead of adb-free's.)

To tear down and start over from nothing:

```bash
./run-ee.sh -c          # stop containers, wipe DB/ORDS state (keeps the extracted APEX zip)
./run-ee.sh -c -r       # same, and also remove the pulled Docker images
```

Or run the whole clean → deploy → verify cycle unattended in one shot
(this is the "walk away and check the report" path):

```bash
./test/full-cycle-test.sh
# tail -f test/reports/full-cycle-<timestamp>.log while it runs, or just
# check the exit code / summary at the end.
```

## No official ORDS container image either

`container-registry.oracle.com/database/ords` needs the same OTN registry
login as the official DB images — so like the DB image, it's avoided here.
Instead, `ords` runs **standalone** from the plain zip distribution
(`download-ords.sh`, a real unauthenticated `download.oracle.com` URL, same
idea as the APEX zip) inside a generic, unauthenticated JRE base image
(`eclipse-temurin`). See `ords-entrypoint.sh` for the non-interactive
`ords install --password-stdin` + `ords serve --apex-images ...` sequence.

APEX itself is **not** installed by the ords container at all (that
convenience is specific to Oracle's official ords image, which isn't in use
here) — `run-ee.sh` installs it directly via password-based EZConnect
(`sys/$ORACLE_PWD@//localhost:$DB_HOST_PORT/$ORACLE_PDB as sysdba`, landing
straight in the PDB — no CDB$ROOT/`ALTER SESSION` dance needed), running
`apexins.sql` then `apex_rest_config.sql` from the official APEX
distribution.

**Status**: the topology (DB + ORDS + APEX 26.1 coming up clean from nothing,
including a from-scratch run with `apex-install/`/`ords-install/` deleted
entirely) was verified end to end with `./test/full-cycle-test.sh` passing
all 6 steps (clean, setup, download APEX, download ORDS, deploy, verify),
deploy taking ~7-8 minutes end to end (`apexins.sql` is the bulk of it), while
this `.env` was pointed at Database Free during earlier development. Not yet
re-verified against Enterprise Edition since the `DOCKER_IMAGE`/`ORACLE_PDB`
switch — re-run `./test/full-cycle-test.sh` (or `./run-ee.sh` +
`./test/smoke-ee.sh`) to confirm before relying on it.

### Real gotchas hit while getting this working (kept here so a future generic library doesn't re-discover them)

- **`apexins.sql`'s nested `@@core/scripts/*.sql` references only resolve
  when sqlplus's actual OS working directory is set to apexins.sql's own
  directory** and it's invoked via a bare relative filename (`@apexins.sql`).
  A full-path `@script args` invocation from a different cwd — which matches
  Oracle's own documented `@@` semantics and *should* work — empirically does
  not. `run-ee.sh` works around this with `cd "$APEX_INSTALL_DIR" && ...
  "@apexins.sql" ...`; the `apex_rest_config.sql` docker-exec call uses
  `docker exec -w /tmp/apex` for the same reason.
- **`apex_rest_config.sql` needs a real `$ORACLE_HOME`** (it can shell out to
  `catcon.pl` on a CDB) — only exists inside the DB container, not on the
  host's thin Instant Client, so this one script specifically runs via
  `docker exec`, while `apexins.sql` and everything else runs from the host.
- **`ords serve` does not accept `--log-folder`** (only `ords install` does)
  — passing it is a hard error, not a warning.
- **`docker cp`'d files aren't readable by the container's `oracle` user**
  (uid 54321) if the host file was created with a restrictive mode (e.g.
  `mktemp`'s default 600, owned by a different host uid) — avoided entirely
  by piping SQL via stdin instead of copying files in.
- **`SET FEEDBACK OFF` must precede `ALTER SESSION`**, not follow it, when
  capturing a query result into a shell variable — otherwise "Session
  altered." text leaks into the captured value ahead of the real result.
- **`docker exec`-created container state (DB datafiles etc.) can't be `rm
  -rf`'d by the host user** even from a chmod-777 parent directory — the
  container creates its own subdirectories as uid 54321 with restrictive
  perms. `run-ee.sh -c` deletes via a throwaway root `alpine` container
  instead of a host-side `rm -rf`.
- **`/ords/apex` (no trailing slash) is the real APEX entry point** — it
  302s through a session-establishing redirect chain that requires a cookie
  jar to follow correctly (each hop otherwise creates a brand new session
  and redirects again, looking like an infinite loop / empty body to a
  cookie-less `curl -L`). `/ords/apex/` (WITH a trailing slash) is a
  different, unmapped path that 404s — easy to mistake for "APEX isn't
  installed" when it's actually just the wrong URL.
- **Ollama connectivity check in `setup-ee-network-ai.sql.tpl` fails
  (expectedly) if no Ollama is running on the host** — this is logged as a
  non-fatal warning by design, not a deploy blocker.
- **`DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT`'s JSON `"host"` field is not
  where the endpoint goes** — for a self-hosted Ollama it must literally be
  the string `"local"`; the actual URL (including the `/api/generate` path)
  goes in a separate `"url"` key. Passing the real URL as `"host"` raises
  `ORA-20003: invalid HOST value`, which reads like a connectivity problem
  but is purely a JSON-shape mistake.
- **LINUX HOSTS ONLY (not macOS/Colima)**: a hardened host with a
  default-deny iptables INPUT chain will reject the DB container's calls to
  Ollama (`ORA-29273: HTTP request failed`) even once the JSON above is
  fixed and Ollama is confirmed running — the container's traffic to
  `host.docker.internal:11434` needs an explicit ACCEPT rule for the `ee/`
  compose project's docker network subnet. `run-ee.sh` now detects this
  (`ensure_host_firewall_allows_ollama` in `lib.sh`, ported from
  `adb/run-adb-26ai.sh`'s equivalent) and prints the exact `sudo iptables`
  command to run by hand — it does **not** modify the host firewall
  automatically unless `ALLOW_FIREWALL_AUTOFIX=true` is explicitly set in
  `.env` (host firewall changes are persistent and host-level, so this
  requires an intentional opt-in, not a silent default). `iptables -L`
  itself typically needs root too, not just `-I`/`-C` — a plain unprivileged
  read fails silently and can look identical to "no firewall issue here".
- **`MAX_STRING_SIZE` is `STANDARD` (4000-byte VARCHAR2 limit) by default on
  plain Oracle Database (Enterprise Edition here)** — ADB-Free has it
  pre-set to `EXTENDED`, which masked this until a real app (caseweave) was
  deployed
  here: any schema with a VARCHAR2 column over 4000 bytes fails `CREATE
  TABLE` with `ORA-00910`, silently leaving that table (and everything that
  depends on it) missing — which then surfaces much later as `ORA-00942`
  ("table or view does not exist") in whatever application code queries it,
  far from the real cause. `run-ee.sh` now runs
  `enable_extended_string_size` (`lib.sh`, ported from
  `adb/run-adb-26ai.sh`'s equivalent) right after the DB is healthy, before
  installing anything — idempotent, but genuinely invasive: it cycles the
  database through `SHUTDOWN IMMEDIATE` / `STARTUP UPGRADE` / normal
  `STARTUP`, adding a couple of minutes to a fresh deploy.
- **Deploying a real app surfaced two more APEX-specific gaps**, both now
  fixed in `create-admin-compat-user.sql.tpl` / documented for app deploy
  scripts to handle themselves:
  - The compat `ADMIN` user needs `APEX_ADMINISTRATOR_ROLE` granted
    explicitly — plain `DBA` is not enough for
    `apex_instance_admin.add_workspace` (used by `adb/load-apex-app.sh` for
    every app import), which fails with `ORA-20987: User ADMIN requires
    ADMIN privilege` without it.
  - `apxchpwd.sql` (Oracle's own script for creating an APEX instance
    administrator) does **not** correctly read piped/non-TTY stdin for its
    `ACCEPT ... HIDE` password prompt on this SQL*Plus version — it silently
    returns an empty string, which both raises `ORA-20001` (blank password
    rejected) and misaligns every subsequent piped input line. Turned out to
    be unnecessary here anyway once the role grant above was in place (this
    finding is kept for reference in case another SQL*Plus/APEX version
    combination still needs an instance-admin identity created this way —
    call `wwv_flow_instance_admin.create_or_update_admin_user` directly with
    a literal password instead of running `apxchpwd.sql`).

## Known open risks going forward (not glossed over)

- **APEX/ORDS downloads**: both may require an OTN login click-through in
  some circumstances rather than a plain `curl` (verified working
  unauthenticated as of this POC, but Oracle could change that). Both
  download scripts detect a non-zip response and fail loudly with
  instructions to download manually and drop the file into the cache dir.
- **Shared passwords for POC simplicity**: `ORACLE_PWD` is reused for SYS,
  the compat ADMIN user (unless `ADMIN_COMPAT_PASSWORD` is set), ORDS_PUBLIC_USER,
  APEX_LISTENER, and APEX_REST_PUBLIC_USER. Fine for a local POC; not a
  pattern to carry into any shared/hosted environment.
- **OTN Developer License Terms scope**: single developer/single workstation,
  no production/business/commercial data processing, no redistribution to
  third parties. This stops being a licence-compliant setup the moment it's
  turned into a shared team resource or used to process real data — see
  "Why this exists" above.

## How this differs from `../adb/`

| | `../adb/` (adb-free) | `ee/` (this directory) |
|---|---|---|
| Containers | 1 (DB+ORDS+APEX bundled) | 2 (DB, plus ORDS standalone in a plain JRE container) |
| Transport | TCPS/mTLS only, no plain listener | Plain TCP/HTTP |
| Outbound HTTP | `REQUIRE_OUT_HTTPS=Y` forced — needs `ollama-proxy` | Unrestricted — direct `UTL_HTTP` to host Ollama |
| SYS/SYSDBA | Disabled even via `docker exec` | Available |
| Top-level user | `ADMIN` built in | No `ADMIN` — minted by `create-admin-compat-user.sql.tpl` so `../adb/load-apex-app.sh` works unmodified |
| Resource ceiling | ADB-Free: 4 ECPU / 30 sessions / 20GB | Enterprise Edition: no vendor-imposed ceiling (subject to host resources) |
| Host ports | 1521/1522/8443 | 1521 (SQL*Net, configurable)/8080 (APEX/ORDS, HTTP) — same SQL*Net port as adb/ by default, so only one of the two can be up at a time unless `DB_HOST_PORT` is changed |

## Files

- `docker-compose.yml` — the two-container topology: `oracle-db` (Oracle
  Database Enterprise Edition, official image) + `ords` (plain JRE +
  standalone ORDS zip, not an official image — see above)
- `.env.sample` — fresh config schema (not `../adb/.env`'s — see comments)
- `lib.sh` — shared helpers, sourced by every script here; reuses
  `../adb/common.sh`'s `ini_val`/`platform_val`/colour helpers read-only
- `setup-for-ee.sh` / `download-apex.sh` / `download-ords.sh` / `run-ee.sh` — bring-up pipeline
- `ords-entrypoint.sh` — non-interactive ORDS install + serve, run inside the `ords` container
- `sql-scripts/*.sql.tpl` — compat ADMIN user, network/AI ACLs, optional PGA tuning
- `test/smoke-ee.sh` — post-deploy verification
- `test/full-cycle-test.sh` — unattended clean → deploy → verify orchestrator
