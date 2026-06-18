# Oracle Database Free 26ai — Linux/Ubuntu Setup

Run Oracle Database Free (26ai/23.x) on Ubuntu with an ONNX embedding model for vector search and Ollama for generative AI. Two variants are covered:

- **Database only** — single container, SQLplus + EM Express, no APEX
- **Full stack** — Docker Compose, two containers, includes APEX 24.2 and ORDS

> **Demo and POC use only — not hardened for production.**

---

## Prerequisites

| Requirement | Details |
|---|---|
| **OS** | Ubuntu 22.04 or 24.04 (x86_64 or ARM64) |
| **RAM** | 8 GB minimum, 16 GB recommended |
| **Disk** | 20 GB free (database only); 30 GB (full stack) |
| **Docker** | Installed and running (setup script installs if missing) |
| **sudo** | Required — run setup script as root/sudo |
| **Internet** | Required to pull images, Instant Client, and ONNX model |
| **Oracle account** | Free account at [container-registry.oracle.com](https://container-registry.oracle.com) |
| **Ollama** | Running on host with `OLLAMA_HOST=0.0.0.0` — see below |

---

## Oracle Container Registry

Both images are gated behind license agreements.

1. Create a free account at [container-registry.oracle.com](https://container-registry.oracle.com)
2. Accept the **Database → free** license (required for both variants)
3. For the full stack, also accept the **Database → ords** license
4. Add your credentials to `config.ini`:

```ini
ORACLE_REGISTRY_USER=your@email.com
ORACLE_REGISTRY_PASSWORD=your_password
```

---

## Configuration (`config.ini`)

All settings live in `config.ini`. Scripts read this file — do not edit generated `.env` files directly.

| Setting | Default | Notes |
|---|---|---|
| `ORACLE_REGISTRY_USER` | *(empty)* | Oracle account email |
| `ORACLE_REGISTRY_PASSWORD` | *(empty)* | Oracle account password |
| `DOCKER_IMAGE` | `container-registry.oracle.com/database/free:latest` | Pin to `-amd64` or `-arm64` tag if needed |
| `CONTAINER_NAME` | `oracle-db` | Docker container name |
| `SERVICE_NAME` | `FREEPDB1` | Oracle PDB service name |
| `DEFAULT_PASSWORD` | `Welcome_MY_ATP_123` | Password for SYS, SYSTEM, and demo user |
| `HOSTNAME` | `fu8.local` | Must resolve locally (added to `/etc/hosts` by setup) |
| `APEX_PORT` | `8080` | Host port for ORDS/APEX (full stack only) |
| `APEX_USER` | `TRACKER1` | DB schema and APEX workspace username |
| `APEX_PASSWORD` | *(→ DEFAULT_PASSWORD)* | APEX admin password |
| `OLLAMA_BASE_URL` | `http://host.docker.internal:11434` | Ollama endpoint from inside Docker |
| `OLLAMA_MODEL` | `llama3` | Model name (must be pulled in Ollama first) |
| `ONNX_MODEL_URL` | *(OCI URL)* | Source for `all-MiniLM-L12-v2` ONNX model |
| `INSTANT_CLIENT` | `instantclient_23_6` | Oracle Instant Client version directory name |

---

## Step 0 — Install Ollama

Ollama must be running before `run-adb-26ai.sh` can configure generative AI:

```bash
sudo ../nvidia/ai-tools-setup.sh     # installs Ollama, sets OLLAMA_HOST=0.0.0.0
ollama pull llama3                    # pull the model set in config.ini
```

Verify it's listening on all interfaces:

```bash
ss -tlnp | grep 11434
# Should show *:11434 or 0.0.0.0:11434
```

If Ollama is already installed but only on localhost:

```bash
sudo systemctl edit ollama
# Add:  [Service]
#       Environment="OLLAMA_HOST=0.0.0.0"
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

---

## Step 1 — OS Setup (once per machine)

```bash
sudo ./setup-for-adb-26ai.sh
```

This script:
- Verifies Ubuntu 22 or 24
- Installs `curl`, `unzip`, `git`, and Docker if missing
- Creates Oracle OS user and groups (`oracle`, `oinstall`, `dba`, etc.)
- Downloads and installs Oracle Instant Client 23.6 to `~/oraclient/`
- Fixes the `libaio.so.1` symlink for the correct Ubuntu version
- Logs in to Oracle Container Registry and pulls the DB image
- Appends `ORACLE_HOME`, `LD_LIBRARY_PATH`, and `PATH` to `~/.bashrc`
- **(Full stack only)** installs Docker Compose v2, downloads APEX 24.2 (~290 MB), creates `./ords_config/`

After the script completes, log out and back in (or run `newgrp docker`) so Docker group membership is active.

---

## Step 2 — Start the Database

### Database only

Starts a single `oracle-db` container on ports 1521 and 5500:

```bash
./run-adb-26ai.sh
```

The script:
1. Starts `oracle-db` (waits up to 30 min for healthy — typically ~3.5 min)
2. Downloads the ONNX model to `~/model.onnx` if missing
3. Writes `~/auth/tns/tnsnames.ora` for sqlplus
4. Copies the ONNX model into the container's `DATA_PUMP_DIR`
5. Creates the `TRACKER1` demo user with developer grants
6. Loads the `ALL_MINILM` ONNX model for vector search
7. Configures network ACL and connects the database to Ollama

### Full stack (APEX + ORDS via Docker Compose)

Same command — the `docker-compose.yml` orchestrates both containers:

```bash
./run-adb-26ai.sh
```

**Phase 1 — Oracle Database** (same steps as above)

**Phase 2 — ORDS and APEX**
- Starts the `ords` container; ORDS auto-installs APEX 24.2 from `./apex/`
- First-run APEX install takes 5–15 minutes — check progress with `docker logs -f ords`
- Waits for APEX to be available on `APEX_PORT`, then creates the APEX workspace

**Phase 3 — Ollama Generative AI**
- Grants network ACL so the DB can make outbound HTTP calls
- Grants `UTL_HTTP` and `DBMS_VECTOR_CHAIN` execute privileges to the application user
- Creates a dummy `OLLAMA_CRED` credential (Ollama requires no auth)
- Tests HTTP connectivity and runs an end-to-end generative AI test

---

## Accessing the Services

### Ports

| Port | Service |
|---|---|
| `1521` | Oracle SQL*Net listener |
| `5500` | Enterprise Manager Express (HTTPS) |
| `8080` | APEX / ORDS REST (full stack only) |

### SQLplus

```bash
source ~/.bashrc    # or open a new shell after running setup

sqlplus system/Welcome_MY_ATP_123@FREEPDB1
sqlplus sys/Welcome_MY_ATP_123@FREE as sysdba
sqlplus TRACKER1/Welcome_MY_ATP_123@FREEPDB1
```

### Enterprise Manager Express

```
https://localhost:5500/em
```

Log in as `system` / `Welcome_MY_ATP_123`. Accept the self-signed certificate warning.

### APEX (full stack only)

```
http://localhost:8080/ords/apex
```

- **Workspace / Username:** value of `APEX_USER` in `config.ini` (default: `TRACKER1`)
- **Password:** value of `APEX_PASSWORD` (defaults to `DEFAULT_PASSWORD`)

### Calling Ollama from SQL

```sql
SELECT DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT(
  'Explain Oracle APEX in one sentence',
  JSON('{"provider":"ollama","host":"http://host.docker.internal:11434","model":"llama3"}')
) FROM dual;
```

### Remote Access (SSH Port Forwarding)

Run on your laptop and keep the terminal open:

```bash
# Database only
ssh -L 1521:localhost:1521 -L 5500:localhost:5500 -N user@server

# Full stack (add APEX port)
ssh -L 1521:localhost:1521 -L 5500:localhost:5500 -L 8080:localhost:8080 -N user@server
```

Then connect as if the database were local. VS Code / Cursor Remote SSH users can use the **Ports** panel instead.

> SSH tunnels work through port 22 only — you do not need to open 1521, 5500, or 8080 in your cloud firewall.

---

## Database Users

| User | Password | Notes |
|---|---|---|
| `SYS` | `DEFAULT_PASSWORD` | SYSDBA — admin use only |
| `SYSTEM` | `DEFAULT_PASSWORD` | DBA — used by setup scripts |
| `TRACKER1` / `APEX_USER` | `APEX_PASSWORD` | Application user; developer grants, DATA_PUMP_DIR access |

---

## ONNX Vector Search Model

`all_MiniLM_L12_v2` (~127 MB) is loaded as `ALL_MINILM` via `DBMS_VECTOR.LOAD_ONNX_MODEL`. Verify it loaded:

```sql
SELECT model_name, mining_function, algorithm,
       ROUND(model_size/1024/1024, 1) AS model_size_mb
FROM   user_mining_models
ORDER BY model_name;
```

---

## Cleanup

```bash
./run-adb-26ai.sh -c                      # stop containers, prompt to remove data dir
./run-adb-26ai.sh -c -r                   # also remove Docker images
sudo ./setup-for-adb-26ai.sh -c           # remove Instant Client, APEX files, configs
sudo ../nvidia/ai-tools-setup.sh --cleanup  # remove Ollama and AI tools
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Container stays in `starting` | Normal — DB init on first run | `docker logs -f oracle-db` — wait for `DATABASE IS READY TO USE!` |
| `libaio.so.1: cannot open shared object file` | Broken symlink | Re-run `sudo ./setup-for-adb-26ai.sh` |
| `ORA-12154: TNS:could not resolve` | `TNS_ADMIN` not set | `source ~/.bashrc` or export `TNS_ADMIN=$HOME/auth/tns` manually |
| `manifest unknown` when pulling image | Not logged in or license not accepted | Check credentials in `config.ini`; accept license at container-registry.oracle.com |
| Container already exists error | Old container not removed | `docker stop oracle-db && docker rm oracle-db` |
| Port 1521 already in use | Old container or another Oracle process | `sudo ss -tlnp \| grep 1521`, stop the listed process |
| `docker compose` not found | Compose v2 plugin not installed | `sudo apt-get install -y docker-compose-v2` |
| ORDS exits with "not writable" | `ords_config/` permissions | `chmod 777 ords_config` |
| `docker compose pull` auth error | ORDS license not accepted | Accept **Database → ords** license at container-registry.oracle.com |
| `http://localhost:8080/apex` → 404 | Wrong path | Use `/ords/apex` not `/apex` |
| Ollama test FAILED: `ORA-24247` | Network ACL not granted | Re-run `./run-adb-26ai.sh` or manually run `setup-ollama-ai.sql` as SYSTEM |
| Ollama test FAILED: `ORA-29273` | Ollama not listening on `0.0.0.0` | `sudo systemctl edit ollama`, add `Environment="OLLAMA_HOST=0.0.0.0"`, restart |
| `DBMS_VECTOR_CHAIN` returns ORA error | Model not pulled or wrong name | `ollama list` on host; ensure `OLLAMA_MODEL` in `config.ini` matches |

---

## File Reference

| File | Purpose |
|---|---|
| `config.ini` | All configurable settings — edit before running |
| `docker-compose.yml` | Defines oracle-db and ords services (full stack) |
| `setup-for-adb-26ai.sh` | One-time OS/Docker/Instant Client setup (requires sudo) |
| `run-adb-26ai.sh` | Start containers, load ONNX model, run SQL setup, configure Ollama AI |
| `sql-scripts/create-users.sql.tpl` | Template for user + APEX workspace SQL |
| `sql-scripts/vector-setup.sql` | Loads `ALL_MINILM` ONNX model into the database |
| `sql-scripts/setup-ollama-ai.sql.tpl` | Template for network ACL + Ollama AI configuration |
| `apex/` | APEX 24.2 install files (created by setup script, full stack only) |
| `ords_config/` | ORDS runtime config (full stack only) |
| `../nvidia/ai-tools-setup.sh` | Installs Ollama + AI tools (run before database setup) |

---

## Security Notice

- Passwords are stored in plaintext in `config.ini` and `.env`.
- Ports `1521`, `5500`, and `8080` bind to all interfaces (`0.0.0.0`).
- **Do not expose to a shared network or use in production without additional hardening.**

---

Issues and pull requests welcome at [github.com/tdaly61/td-ora-utils](https://github.com/tdaly61/td-ora-utils) · [tdaly61@gmail.com](mailto:tdaly61@gmail.com)
