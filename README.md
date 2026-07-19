# Oracle Utilities

Some oracle utilities that enhance or simplify the use of freely available Oracle technologies.

---

## Setup Order

Run the scripts in this order. Each step is idempotent — safe to re-run.

```
Step 0 (GPU only)    sudo ./nvidia/nvidia-gpu-setup.sh   # NVIDIA drivers (reboot after)
Step 1 (AI tools)    sudo ./nvidia/ai-tools-setup.sh     # Ollama + models + Claude Code
Step 2 (DB prep)     sudo ./adb/setup-for-adb-26ai.sh    # Docker/Colima, Oracle Instant Client
Step 3 (DB + APEX)        ./adb/run-adb-26ai.sh          # Start DB (APEX/ORDS pre-installed), Ollama AI
```

### Minimal example (no GPU)

```bash
cd td-ora-utils

# Install Ollama (skip GPU-specific models if no GPU)
sudo ./nvidia/ai-tools-setup.sh --skip-models
ollama pull llama3                          # pull a small model

# Prepare the host (Docker/Colima, Oracle Instant Client)
sudo ./adb/setup-for-adb-26ai.sh

# Start everything — DB, APEX, Ollama AI integration
./adb/run-adb-26ai.sh
```

### Full example (NVIDIA GPU)

```bash
cd td-ora-utils

# Install NVIDIA drivers (reboot required)
sudo ./nvidia/nvidia-gpu-setup.sh

# Install Ollama, Claude Code, OpenCode + pull recommended models
sudo ./nvidia/ai-tools-setup.sh

# Prepare the host
sudo ./adb/setup-for-adb-26ai.sh

# Start everything
./adb/run-adb-26ai.sh
```

### What you get

| Service | URL / Port |
|---------|-----------|
| APEX | `https://localhost:8443/ords/apex` |
| Database Actions | `https://localhost:8443/ords/sql-developer` |
| sqlplus | `TNS_ADMIN=~/auth/tls_wallet sqlplus admin/<password>@myatp_high` |
| Ollama API | `http://localhost:11434` |

(Self-signed cert on `:8443` — accept it in the browser on first visit.)

The DB can call Ollama directly from SQL:
```sql
SELECT DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT(
  'Tell me a joke',
  JSON('{"provider":"ollama","host":"https://ollama-proxy:443","model":"llama3.2:3b"}')
) FROM dual;
```

### Deploy your own APEX app (optional)

After `run-adb-26ai.sh`, import any APEX application export:
```bash
cd adb
./load-apex-app.sh -f path/to/your-app.sql
# No app of your own yet? Try the generic demo:
./examples/sample-app/load-sample-app.sh
```

Later, export it back out and hand it to someone deploying to Oracle ADB on OCI:
```bash
./export-apex-app.sh -u <schema_user>
./bundle-apex-for-oci.sh -f apex-exports/app_<timestamp>.sql   # -> a tarball with
                                                               # step-by-step README-OCI.md
```

The AI/vision models are the single source of truth in `adb/.env`
(`OLLAMA_VISION_MODEL`, `OLLAMA_TEXT_MODEL`, and `LLM_*`; add `_MAC` variants for
smaller models on Apple Silicon). `ai-tools-setup.sh` pulls exactly those tags via
`adb/pull-ollama-models.sh`.

---

## Cleanup

Tear down in reverse order.

```bash
# Stop DB containers, prompt to remove data
./adb/run-adb-26ai.sh -c            # add -r to also remove Docker images

# WARNING: this does NOT scope itself to what this repo installed. On Linux it
# runs `docker system prune -a -f --volumes` (wipes ALL local Docker containers,
# images and volumes, not just this project's), then uninstalls docker.io itself
# and deletes the docker OS group/user. Only run it if you want Docker gone
# entirely from this host.
sudo ./adb/setup-for-adb-26ai.sh -c

# Remove Ollama + all models, Claude Code, OpenCode
sudo ./nvidia/ai-tools-setup.sh --cleanup

# Remove NVIDIA drivers (reboot required)
sudo ./nvidia/nvidia-gpu-setup.sh --cleanup
```

---

## Directory Layout

| Directory | What |
|-----------|------|
| `adb/` | Oracle Database Free 26ai + APEX + ORDS container setup. See [adb/README.md](adb/README.md) (macOS/Colima-focused) and [adb/LINUX-SETUP.md](adb/LINUX-SETUP.md) (Ubuntu) |
| `nvidia/` | NVIDIA GPU driver setup and AI tools (Ollama, Claude Code, OpenCode) |
