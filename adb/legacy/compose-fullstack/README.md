# Archived: two-container docker-compose full stack

This is an **earlier, unwired** alternative to how `run-adb-26ai.sh` actually
starts Oracle today. It is kept here for possible future use, not deleted —
but **no script in this repo references it**, and it does not reflect the
current image/config.

## How it differs from the current setup

The live path (`run-adb-26ai.sh`) runs a **single** `adb-free` container with
ORDS and APEX **pre-installed inside it**, on ports `1521`/`1522`/`8443`, driven
entirely by `adb/.env`.

This compose file instead runs **two** containers:
- `oracle-db` — a plain `database/free` image, no APEX pre-installed
- `ords` — a separate ORDS container that installs APEX from a local directory
  on first run, serving HTTP (not HTTPS) on port `8080`

## If you want to revive this

You'd need to:
1. Populate the env vars it expects (`DB_HOSTNAME`, `ORACLE_PWD`, `DB_DATA_DIR`,
   `SERVICE_NAME`, `APEX_DIR` pointing at a downloaded APEX install, `APEX_PORT`,
   `CONTAINER_NAME`, `DOCKER_IMAGE`) — none of these are produced by the current
   `adb/.env`/`.env.sample`.
2. Decide how Ollama integration would work without the single-container image's
   built-in `ollama-proxy` wiring (`run-adb-26ai.sh` sets that up specifically
   for the `adb-free` image).
3. Wire a script to actually invoke `docker compose` — nothing currently does.

Until then, treat this as reference material, not a working path.
