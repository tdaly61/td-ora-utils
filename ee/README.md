# ee/ — Database Free / Enterprise Edition POC (Phase 1)

Two-container Oracle stack (plain DB + separate ORDS container) as an
alternative to the single bundled `adb-free` container in `../adb/`.
**`adb/` is untouched by anything here** — cars1 and other apps keep using it
as-is.

## Why this exists

`../adb/` runs the ADB-Free container, which — like plain Oracle Database
Free — has hard, vendor-imposed resource ceilings (see the project's
[CLAUDE.md](../CLAUDE.md) and the POC plan this was built from). caseweave's
vector-embedding worker daemons have hit `ORA-04036` (PGA_AGGREGATE_LIMIT
exceeded) against ADB-Free. This toolkit stages a path off that ceiling:

1. **Phase 1 (this directory, current scope)**: stand up the two-container
   topology on plain Oracle Database Free first — cheap, no Enterprise
   licence friction. Prove the topology works (DB + ORDS + APEX 26.1 come up
   clean from nothing, repeatably, unattended) before touching caseweave.
   The default image is **`gvenzl/oracle-free`** (Docker Hub) rather than
   `container-registry.oracle.com/database/free` — a widely-used repackaging
   of the same official Oracle Database Free binaries, chosen specifically
   because it needs no OTN registry login or licence click-through, which is
   what makes `test/full-cycle-test.sh` runnable fully unattended with zero
   credentials. The official image is documented as a swap-in in
   `.env.sample` for whenever OTN registry auth is set up.
2. **Swap-ready to Enterprise Edition**: if load testing later shows Free's
   own 2GB combined SGA+PGA cap is still a wall, switch to
   `container-registry.oracle.com/database/enterprise` (requires OTN
   registry credentials — see `.env.sample`; also requires updating
   `ORACLE_PDB` and `docker-compose.yml`'s env var mapping together with the
   image, since the official images use different names than `gvenzl`'s —
   this is **not** a pure one-line change, see `.env.sample` for the exact
   list of what moves together).
3. **Phase 2 (not built yet)**: a generic, `adb/`-equivalent script library
   (`load-apex-app.sh`, `export-apex-app.sh`, OCI bundle/deploy) for this
   topology, plus wiring caseweave's own deploy scripts to target it. Phase 1
   deliberately reuses `../adb/load-apex-app.sh` directly (see below) as a
   proof that the generic-library pattern already works here, rather than
   duplicating it early.

## Quick start

```bash
cp .env.sample .env
# edit .env: ORACLE_PWD, ADMIN_COMPAT_PASSWORD (or leave blank to reuse
# ../adb/.env's DEFAULT_PASSWORD), and DB_HOST_PORT if 1523 isn't free either

./setup-for-ee.sh      # pull images, host dirs
./download-apex.sh     # fetch + extract APEX (see note below if this fails)
./download-ords.sh     # fetch + extract ORDS (same caveat)
./run-ee.sh            # compose up, install APEX + ORDS + compat ADMIN user, network/AI setup
./test/smoke-ee.sh     # verify: connectivity, PGA/session baseline, ORDS, APEX
```

Note: `DB_HOST_PORT` defaults to **1523**, not 1521 — `../adb/`'s adb-free
container commonly already holds 1521/1522 on the same host, and adb/ is
never touched to free them. Check `docker ps` if you're unsure what's
already bound.

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
login as the official DB images — so like the DB image, it's avoided for
Phase 1. Instead, `ords` runs **standalone** from the plain zip distribution
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

**Status: verified working end to end**, including a from-scratch run with
`apex-install/`/`ords-install/` deleted entirely (only the cached zips kept)
— `./test/full-cycle-test.sh` passes all 6 steps (clean, setup, download
APEX, download ORDS, deploy, verify) unattended, deploy taking ~7-8 minutes
end to end (`apexins.sql` is the bulk of it). `./test/smoke-ee.sh` confirms
`pga_aggregate_limit = 2G` on Database Free — the exact ceiling this whole
toolkit exists to get past (see Context above).

### Real gotchas hit while getting this working (kept here so Phase 2 doesn't re-discover them)

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

## Known open risks going forward (not glossed over)

- **APEX/ORDS downloads**: both may require an OTN login click-through in
  some circumstances rather than a plain `curl` (verified working
  unauthenticated as of this POC, but Oracle could change that). Both
  download scripts detect a non-zip response and fail loudly with
  instructions to download manually and drop the file into the cache dir.
- **Database Free's cap confirmed**: `pga_aggregate_limit = 2G`, verified via
  `smoke-ee.sh`'s baseline dump. Whether this is actually tighter than what
  caused caseweave's original ADB-Free crashes still needs real load testing
  (see the plan's Validation section) — the fallback is the one-line
  `DOCKER_IMAGE` swap to Enterprise Edition.
- **Shared passwords for POC simplicity**: `ORACLE_PWD` is reused for SYS,
  the compat ADMIN user (unless `ADMIN_COMPAT_PASSWORD` is set), ORDS_PUBLIC_USER,
  APEX_LISTENER, and APEX_REST_PUBLIC_USER. Fine for a local POC; not a
  pattern to carry into Phase 2 or any shared/hosted environment.

## How this differs from `../adb/`

| | `../adb/` (adb-free) | `ee/` (this directory) |
|---|---|---|
| Containers | 1 (DB+ORDS+APEX bundled) | 2 (DB, plus ORDS standalone in a plain JRE container) |
| Transport | TCPS/mTLS only, no plain listener | Plain TCP/HTTP |
| Outbound HTTP | `REQUIRE_OUT_HTTPS=Y` forced — needs `ollama-proxy` | Unrestricted — direct `UTL_HTTP` to host Ollama |
| SYS/SYSDBA | Disabled even via `docker exec` | Available |
| Top-level user | `ADMIN` built in | No `ADMIN` — minted by `create-admin-compat-user.sql.tpl` so `../adb/load-apex-app.sh` works unmodified |
| Resource ceiling | ADB-Free: 4 ECPU / 30 sessions / 20GB | Free: 2 CPU / 2GB SGA+PGA / 12GB — or none, on Enterprise Edition |
| Host ports | 1521/1522/8443 | 1523 (SQL*Net, configurable)/8080 (APEX/ORDS, HTTP) — different from adb/ on purpose, so both can run side by side |

## Files

- `docker-compose.yml` — the two-container topology: `oracle-db` (Database
  Free by default, swap-ready to Enterprise Edition) + `ords` (plain JRE +
  standalone ORDS zip, not an official image — see above)
- `.env.sample` — fresh config schema (not `../adb/.env`'s — see comments)
- `lib.sh` — shared helpers, sourced by every script here; reuses
  `../adb/common.sh`'s `ini_val`/`platform_val`/colour helpers read-only
- `setup-for-ee.sh` / `download-apex.sh` / `download-ords.sh` / `run-ee.sh` — bring-up pipeline
- `ords-entrypoint.sh` — non-interactive ORDS install + serve, run inside the `ords` container
- `sql-scripts/*.sql.tpl` — compat ADMIN user, network/AI ACLs, optional PGA tuning
- `test/smoke-ee.sh` — post-deploy verification
- `test/full-cycle-test.sh` — unattended clean → deploy → verify orchestrator
