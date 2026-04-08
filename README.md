# Oracle Utilities

Some oracle utilities that enhance or simplify the use of freely available Oracle technologies.

---

## Setup Order

Run the scripts in this order. Each step is idempotent — safe to re-run.

```
Step 0 (GPU only)    sudo ./nvidia/nvidia-gpu-setup.sh   # NVIDIA drivers (reboot after)
Step 1 (AI tools)    sudo ./nvidia/ai-tools-setup.sh     # Ollama + models + Claude Code
Step 2 (DB prep)     sudo ./adb/setup-for-adb-26ai.sh    # Docker, Instant Client, APEX
Step 3 (DB + APEX)        ./adb/run-adb-26ai.sh          # Start DB, ORDS/APEX, Ollama AI
```

### Minimal example (no GPU)

```bash
cd td-ora-utils

# Install Ollama (skip GPU-specific models if no GPU)
sudo ./nvidia/ai-tools-setup.sh --skip-models
ollama pull llama3                          # pull a small model

# Prepare the host (Docker, Instant Client, APEX download)
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
| APEX | `http://localhost:8080/ords/apex` |
| EM Express | `https://localhost:5500/em` |
| SQLPlus | `localhost:1521/FREEPDB1` |
| Ollama API | `http://localhost:11434` |

The DB can call Ollama directly from SQL:
```sql
SELECT DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT(
  'Tell me a joke',
  JSON('{"provider":"ollama","host":"http://host.docker.internal:11434","model":"llama3"}')
) FROM dual;
```

---

## Cleanup

Tear down in reverse order. Each `--cleanup` / `-c` only removes what that script installed.

```bash
# Stop DB containers, prompt to remove data
./adb/run-adb-26ai.sh -c            # add -r to also remove Docker images

# Remove Instant Client, APEX files, Oracle container images
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
| `adb/` | Oracle Database Free 26ai + APEX + ORDS container setup. See [ORACLE-ADB-UTILS.md](adb/ORACLE-ADB-UTILS.md) |
| `nvidia/` | NVIDIA GPU driver setup and AI tools (Ollama, Claude Code, OpenCode) |
