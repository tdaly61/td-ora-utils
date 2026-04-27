# Oracle Autonomous Database (ADB) 26ai Container Setup

Scripts and configuration to run Oracle Database Free 23ai with APEX and ORDS locally using Docker Compose. Includes an ONNX embedding model for vector search. Intended for **demo and POC use only** — not hardened for production.

> Reference: [Oracle ADB Container Free docs](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-database-container-free.html#GUID-B2E52334-2171-47F0-B951-B8007DD1B63C)

---

## Architecture

Two containers managed by Docker Compose, with Ollama running on the host:

```
                                  ┌─────────────────────────┐
                                  │  Host                   │
                                  │  Ollama :11434          │
                                  │  (OLLAMA_HOST=0.0.0.0)  │
                                  └────────▲────────────────┘
                                           │ host.docker.internal
┌─────────────────────────────┐     ┌──────┴───────────────────────┐
│  oracle-db                  │     │  ords                        │
│  database/free:latest       │◄────│  database/ords:latest        │
│                             │     │                              │
│  port 1521  SQL*Net         │     │  port 8080  APEX / REST      │
│  port 5500  EM Express      │     │                              │
│  ~/db_data_dir  (data)      │     │  auto-installs APEX 24.2     │
│  ./apex      (APEX files)   │     │  ./ords_config  (config)     │
│                             │     │                              │
│  UTL_HTTP / DBMS_VECTOR_CHAIN    │                              │
│  → Ollama via host.docker.internal                              │
└─────────────────────────────┘     └──────────────────────────────┘
```

`run-adb-26ai.sh` starts `oracle-db` first, waits for it to be healthy, runs SQL setup (users, ONNX model), then starts `ords` which auto-installs APEX 24.2 into the database on first run. Finally, it configures network ACLs and connects the database to Ollama for generative AI.

---

## Repository Contents

| File | Purpose |
|------|---------|
| `config.ini` | All environment-specific settings — edit before running |
| `docker-compose.yml` | Defines the oracle-db and ords services |
| `setup-for-adb-26ai.sh` | One-time OS/Docker/Instant Client + APEX prep (run as sudo) |
| `run-adb-26ai.sh` | Starts containers, loads ONNX model, runs SQL setup |
| `sql-scripts/create-users.sql.tpl` | Template for user + APEX workspace SQL (edit this, not the generated file) |
| `sql-scripts/vector-setup.sql` | Loads the `ALL_MINILM` ONNX model into the database |
| `sql-scripts/setup-ollama-ai.sql.tpl` | Template for network ACL + Ollama AI service configuration |
| `apex/` | APEX 24.2 install files (created by setup script) |
| `ords_config/` | ORDS runtime config — written by ORDS on first start |

---

## Prerequisites

### Hardware & OS
- **Ubuntu 22.04 or 24.04** (x86_64 or ARM64)
- **Minimum 16 GB RAM** (8 GB minimum; Oracle DB needs ~4 GB, ORDS/APEX needs ~2 GB)
- **Minimum 30 GB free disk** (DB data dir ~10 GB, APEX install files ~1 GB, images ~8 GB)
- Internet access to download Docker images, Instant Client, APEX zip, and the ONNX model

### Ollama (required for generative AI features)

Ollama must be installed and running on the host **before** running `run-adb-26ai.sh`. The easiest way is to run the AI tools setup script from the `nvidia/` directory:

```bash
sudo ../nvidia/ai-tools-setup.sh     # installs Ollama, configures OLLAMA_HOST=0.0.0.0
ollama pull llama3                    # or whichever model you set in config.ini
```

This installs Ollama, sets it to listen on all interfaces (`0.0.0.0:11434`), and optionally pulls recommended models. See the [top-level README](../README.md) for the full setup order.

### Software installed automatically by `setup-for-adb-26ai.sh`
- `curl`, `unzip`, `git`
- Docker (`docker.io`)
- Docker Compose v2 plugin (`docker-compose-v2`)
- Oracle Instant Client 23.6 (SQLPlus)

### Oracle Container Registry accounts (required for both images)

Both images are gated behind separate license agreements at [container-registry.oracle.com](https://container-registry.oracle.com):

1. Create a free account
2. Accept the **Database → free** license (for `database/free`)
3. Accept the **Database → ords** license (for `database/ords`)
4. Add your credentials to `config.ini`:
   ```ini
   ORACLE_REGISTRY_USER=your@email.com
   ORACLE_REGISTRY_PASSWORD=your_password
   ```

> If credentials are left blank, `docker compose pull` will fail unless you have previously run `docker login container-registry.oracle.com` manually.

---

## Configuration

Edit `config.ini` before running any scripts. `run-adb-26ai.sh` generates `.env` from these values automatically — do not edit `.env` by hand.

### Oracle Container Registry

| Key | Default | Notes |
|-----|---------|-------|
| `ORACLE_REGISTRY_USER` | _(empty)_ | Your Oracle Container Registry login email |
| `ORACLE_REGISTRY_PASSWORD` | _(empty)_ | Your Oracle Container Registry password |

### Database

| Key | Default | Notes |
|-----|---------|-------|
| `DOCKER_IMAGE` | `container-registry.oracle.com/database/free:latest` | Pin to `-amd64` or `-arm64` tag if needed |
| `CONTAINER_NAME` | `oracle-db` | Name for the Oracle DB Docker container |
| `SERVICE_NAME` | `FREEPDB1` | Pluggable database service name — used by SQLPlus, ORDS, and TNS |
| `DEFAULT_PASSWORD` | `Welcome_MY_ATP_123` | Password for `SYS` and `SYSTEM` — **change for shared environments** |
| `HOSTNAME` | `fu8.local` | Must resolve locally — added to `/etc/hosts` by the setup script |

### APEX / ORDS

| Key | Default | Notes |
|-----|---------|-------|
| `APEX_PORT` | `8080` | Host port for ORDS/APEX HTTP. Change if 8080 is already in use. |
| `APEX_DIR` | _(empty → `$HOME/apex`)_ | Path to unzipped APEX install files. Leave empty to use the default. |
| `APEX_USER` | `TRACKER1` | Created as both the Oracle DB schema and the APEX workspace/admin username |
| `APEX_PASSWORD` | _(empty → `DEFAULT_PASSWORD`)_ | APEX admin password. Leave empty to use `DEFAULT_PASSWORD`. |

### Oracle Instant Client (SQLPlus on host)

| Key | Default | Notes |
|-----|---------|-------|
| `INSTANT_CLIENT` | `instantclient_23_6` | Must match the Instant Client ZIP filenames |
| `BASIC_URL` / `SQLPLUS_URL` | Oracle download URLs | Update only when a newer Instant Client is released |

### ONNX Vector Model

| Key | Default | Notes |
|-----|---------|-------|
| `ONNX_MODEL_URL` | OCI Object Storage URL | `all_MiniLM_L12_v2.onnx` — the vector embedding model. Only change to use a different model. |

### Ollama (Local LLM)

| Key | Default | Notes |
|-----|---------|-------|
| `OLLAMA_BASE_URL` | `http://host.docker.internal:11434` | Ollama endpoint as seen from inside the Docker container |
| `OLLAMA_MODEL` | `llama3` | Default model for generative AI. Must be pulled in Ollama first. |

---

## Quick Setup

### Step 1 — Clone the repository

```bash
git clone https://github.com/tdaly61/td-ora-utils.git
cd td-ora-utils/adb
```

### Step 2 — Install Ollama (once per machine)

```bash
sudo ../nvidia/ai-tools-setup.sh     # installs Ollama with OLLAMA_HOST=0.0.0.0
ollama pull llama3                    # pull the model set in config.ini
```

Or if Ollama is already installed, just ensure it listens on all interfaces:

```bash
sudo systemctl edit ollama
# Add:  [Service]
#       Environment="OLLAMA_HOST=0.0.0.0"
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

### Step 3 — Edit `config.ini`

At minimum set `ORACLE_REGISTRY_USER` and `ORACLE_REGISTRY_PASSWORD`. Set `OLLAMA_MODEL` to whichever model you pulled. Review and adjust other values for your environment.

### Step 4 — Run the OS setup script (once per machine, requires sudo)

```bash
cd td-ora-utils/adb
sudo ./setup-for-adb-26ai.sh
```

This script:
- Verifies Ubuntu 22 or 24
- Installs `curl`, `unzip`, `git` if missing
- Adds the configured `HOSTNAME` to `/etc/hosts`
- Installs and starts Docker if not present; adds the invoking user to the `docker` group
- Installs the Docker Compose v2 plugin (`docker-compose-v2`)
- Creates Oracle OS user and groups (`oracle`, `oinstall`, `dba`, etc.)
- Downloads and installs Oracle Instant Client 23.6 under `~/oraclient/`
- Appends `ORACLE_HOME`, `LD_LIBRARY_PATH`, and `PATH` to `~/.bashrc`
- Logs in to Oracle Container Registry and pre-pulls the DB image
- Downloads APEX 24.2 zip (~290 MB) and unzips it to `./apex/`
- Creates the `./ords_config/` directory (with world-write permissions for the ORDS container)

> **After setup completes:** log out and back in (or run `newgrp docker`) so Docker group membership is active.

### Step 5 — Start the database, APEX, and Ollama AI

```bash
./run-adb-26ai.sh
```

This script runs in three phases:

**Phase 1 — Oracle Database**
- Generates `.env` from `config.ini`
- Pulls both Docker images (`database/free` and `database/ords`)
- Starts the `oracle-db` container via `docker compose`
- Waits up to 30 minutes for the DB to be healthy
- Downloads the ONNX model to `~/model.onnx` if not already present
- Writes TNS config to `~/auth/tns/tnsnames.ora`
- Copies the ONNX model into the container's `DATA_PUMP_DIR`
- Generates `create-users.sql` from `create-users.sql.tpl` (substitutes `APEX_USER` / `APEX_PASSWORD`)
- Runs `create-users.sql` (creates the `APEX_USER` DB schema)
- Runs `vector-setup.sql` (loads `ALL_MINILM` ONNX model)

**Phase 2 — ORDS and APEX**
- Starts the `ords` container via `docker compose`
- ORDS auto-installs itself and APEX 24.2 into the database from `./apex/`
- Waits up to 60 minutes for APEX to be available on port `APEX_PORT`
- **First-run APEX install typically takes 5–15 minutes**
- Re-runs `create-users.sql` to create the APEX workspace for `APEX_USER` (now that APEX is installed)

**Phase 3 — Ollama Generative AI**
- Generates `setup-ollama-ai.sql` from template (substitutes `APEX_USER`, `OLLAMA_BASE_URL`, `OLLAMA_MODEL`)
- Grants network ACL (`DBMS_NETWORK_ACL_ADMIN`) so the DB can make outbound HTTP calls
- Grants `UTL_HTTP` and `DBMS_VECTOR_CHAIN` execute privileges to the application user
- Creates an `OLLAMA_CRED` credential (dummy — Ollama has no auth)
- Tests HTTP connectivity from inside the DB to the Ollama API
- Runs an end-to-end generative AI test via `DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT`

---

## Accessing the Services

After `run-adb-26ai.sh` completes:

### From a remote desktop (SSH tunnel)

Run this on your **laptop** — keep the terminal open while you work:

```bash
ssh -L 8080:localhost:8080 -L 5500:localhost:5500 -N ubuntu@<server-ip>
```

If you changed `APEX_PORT` in `config.ini` (e.g. to `18080`), adjust accordingly:

```bash
ssh -L 18080:localhost:18080 -L 5500:localhost:5500 -N ubuntu@<server-ip>
```

### URLs

| URL | What |
|-----|------|
| `http://localhost:8080/ords/apex` | APEX 24.2 |
| `http://localhost:8080/ords/` | ORDS REST endpoint |
| `https://localhost:5500/em` | Enterprise Manager Express |

### APEX Login

- **URL:** `http://localhost:<APEX_PORT>/ords/apex`
- **Workspace:** value of `APEX_USER` in `config.ini` (default: `TRACKER1`)
- **Username:** value of `APEX_USER` in `config.ini` (default: `TRACKER1`)
- **Password:** value of `APEX_PASSWORD` in `config.ini` (defaults to `DEFAULT_PASSWORD` if empty)

### SQLPlus

```bash
export TNS_ADMIN=~/auth/tns
export LD_LIBRARY_PATH=~/oraclient/instantclient_23_6

# Connect as SYSTEM
~/oraclient/instantclient_23_6/sqlplus system/Welcome_MY_ATP_123@FREEPDB1

# Connect as SYS
~/oraclient/instantclient_23_6/sqlplus sys/Welcome_MY_ATP_123@FREEPDB1 as sysdba
```

### Monitoring

```bash
docker logs -f oracle-db   # database logs
docker logs -f ords        # ORDS / APEX install and runtime logs
docker ps                  # container status
```

### TNS Aliases (in `~/auth/tns/tnsnames.ora`)

| Alias | Service |
|-------|---------|
| `FREEPDB1` | Pluggable database — use for application connections |
| `FREE` | Root container database |

### Calling Ollama from SQL

After setup, any user with network ACL and `DBMS_VECTOR_CHAIN` grants can call Ollama:

```sql
-- Generate text
SELECT DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT(
  'Explain Oracle APEX in one sentence',
  JSON('{"provider":"ollama","host":"http://host.docker.internal:11434","model":"llama3"}')
) FROM dual;

-- Test raw HTTP connectivity
DECLARE
  v_req  UTL_HTTP.REQ;
  v_resp UTL_HTTP.RESP;
BEGIN
  v_req  := UTL_HTTP.BEGIN_REQUEST('http://host.docker.internal:11434/api/tags', 'GET');
  v_resp := UTL_HTTP.GET_RESPONSE(v_req);
  DBMS_OUTPUT.PUT_LINE('HTTP ' || v_resp.status_code);
  UTL_HTTP.END_RESPONSE(v_resp);
END;
/
```

---

## Database Users

| User | Password | Notes |
|------|----------|-------|
| `SYS` | `DEFAULT_PASSWORD` | SYSDBA — admin use only |
| `SYSTEM` | `DEFAULT_PASSWORD` | DBA — used by setup scripts |
| `APEX_USER` | `APEX_PASSWORD` | Application user; `DB_DEVELOPER_ROLE`, `CREATE MINING MODEL`, DATA_PUMP_DIR read/write |

`APEX_USER` and `APEX_PASSWORD` are set in `config.ini` (defaults: `TRACKER1` and `DEFAULT_PASSWORD`). An APEX workspace with the same name as `APEX_USER` is created automatically once ORDS has finished installing APEX.

---

## ONNX Vector Search Model

The `ALL_MINILM` model (`all_MiniLM_L12_v2`, ~127 MB) is loaded into the database via `DBMS_VECTOR.LOAD_ONNX_MODEL`. Verify it is loaded:

```sql
SELECT model_name, mining_function, algorithm,
       ROUND(model_size/1024/1024, 1) AS model_size_mb
FROM   user_mining_models
ORDER BY model_name;
```

---

## Cleanup

Stop both containers (prompts whether to delete `~/db_data_dir`):

```bash
./run-adb-26ai.sh -c            # stop containers, prompt to remove data dir
./run-adb-26ai.sh -c -r         # also remove Docker images
```

Remove Oracle Instant Client, APEX files, container images, and generated configs (Docker itself is **not** removed):

```bash
sudo ./setup-for-adb-26ai.sh -c
```

Remove Ollama and all AI tools:

```bash
sudo ../nvidia/ai-tools-setup.sh --cleanup
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `docker compose` not found | Compose v2 plugin not installed | Run `sudo apt-get install -y docker-compose-v2` |
| ORDS exits immediately with "not writable" | `ords_config/` permissions | Run `chmod 777 ords_config` |
| `docker compose pull` fails with auth error | Registry credentials missing or ORDS license not accepted | Accept both **Database → free** and **Database → ords** licenses at container-registry.oracle.com |
| APEX install slow | Normal — first-run install | Check progress: `docker logs -f ords` |
| `http://localhost:8080/apex` returns 404 | Wrong path | Use `/ords/apex` not `/apex` |
| Ollama test FAILED: `ORA-24247` | Network ACL not granted | Re-run `./run-adb-26ai.sh` or manually run `setup-ollama-ai.sql` as SYSTEM |
| Ollama test FAILED: `ORA-29273` (HTTP request failed) | Ollama not listening on `0.0.0.0` | Run `sudo systemctl edit ollama`, add `Environment="OLLAMA_HOST=0.0.0.0"`, then `sudo systemctl daemon-reload && sudo systemctl restart ollama` |
| DBMS_VECTOR_CHAIN returns ORA error | Model not pulled or wrong name | Check `ollama list` on host, ensure `OLLAMA_MODEL` in `config.ini` matches |

---

## Security Notice

- The default password is stored in plaintext in `config.ini` and written to `.env`.
- Ports `1521`, `5500`, and `8080` are bound to all interfaces (`0.0.0.0`).
- **Do not expose this setup to a shared network or use in production without additional hardening.**

---

## License

MIT License. See `LICENSE` for details.

## Contributing

Issues and pull requests welcome at [github.com/tdaly61/td-ora-utils](https://github.com/tdaly61/td-ora-utils).

## Contact

[tdaly61@gmail.com](mailto:tdaly61@gmail.com)
