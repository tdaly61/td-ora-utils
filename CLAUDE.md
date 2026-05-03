# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

**td-ora-utils** automates the deployment of Oracle Database Free (26ai) with APEX/ORDS in Docker containers, plus local AI integration via Ollama. Intended for demo and POC use only — not production-hardened.

## Setup Workflow

The canonical setup order (from `README.md`):

```bash
# Optional: NVIDIA GPU driver (requires reboot)
sudo ./nvidia/nvidia-gpu-setup.sh

# Install AI tools (Ollama, Claude Code, OpenCode)
sudo ./nvidia/ai-tools-setup.sh
ollama pull llama3.2:3b          # or whichever model set in config.ini

# One-time OS/Docker prep (requires sudo)
sudo ./adb/setup-for-adb-26ai.sh

# Start Oracle DB + ORDS/APEX + configure Ollama integration
./adb/run-adb-26ai.sh
```

Cleanup: `./adb/run-adb-26ai.sh -c` (add `-r` to also remove Docker images).

## Configuration

All user-editable settings live in `adb/config.ini`. The main script generates `adb/.env` from it — never edit `.env` directly. Key settings:

- Oracle Container Registry credentials (required to pull images)
- DB image, container name, service name, passwords
- APEX/ORDS port and credentials
- Ollama endpoint (`OLLAMA_BASE_URL`) and model (`OLLAMA_MODEL`)
- Docker runtime selection (macOS: Rancher, Docker Desktop, OrbStack)

## Architecture

### Core Scripts

| Script | Role |
|--------|------|
| `adb/setup-for-adb-26ai.sh` | One-time OS prep: installs Docker, Oracle Instant Client, downloads APEX, creates OS users/groups |
| `adb/run-adb-26ai.sh` | Main orchestrator: starts DB container, waits for health, runs SQL setup, starts ORDS, configures Ollama AI integration |
| `nvidia/nvidia-gpu-setup.sh` | NVIDIA driver installation for Ubuntu 24.04 |
| `nvidia/ai-tools-setup.sh` | Installs Ollama, Claude Code, OpenCode; pulls LLM models |

### SQL Templating

SQL files ending in `.sql.tpl` are templates with `__TOKEN__` placeholders substituted at runtime:
- `__APEX_USER__`, `__APEX_PASSWORD__` — from config.ini
- `__OLLAMA_BASE_URL__`, `__OLLAMA_MODEL__` — from config.ini

The generated (non-template) `.sql` files in `adb/sql-scripts/` are the runtime-ready versions.

### Docker Services (`adb/docker-compose.yml`)

Two services started in sequence:
1. **oracle-db** — Oracle Database Free on port 1521 (SQL*Net) and 5500 (EM Express). Healthcheck polls every 30s up to 75 minutes.
2. **ords** — ORDS/APEX on `APEX_PORT` (default 8080). Depends on oracle-db health; auto-installs APEX 24.2 on first run.

The `host.docker.internal` extra host entry allows containers to reach Ollama running on the host.

### Ollama Integration Pattern

Ollama runs on the **host** at `0.0.0.0:11434`. The DB container reaches it via `http://host.docker.internal:11434`. The setup SQL grants `UTL_HTTP` network ACLs and `DBMS_VECTOR_CHAIN` privileges, then registers Ollama as an APEX AI service using its OpenAI-compatible `/v1` endpoint.

### Platform Handling

Scripts detect `PLATFORM` (linux/darwin) and `ARCH` (x86_64/arm64) and branch accordingly:
- **Linux**: Instant Client via ZIP, Docker from `docker.io`, NVIDIA GPU support
- **macOS**: Instant Client via DMG, Docker context resolution for Rancher/Docker Desktop/OrbStack, API version pinning for compatibility

### Python Utility

`aiutils/summarise_conversations.py` — standalone Reddit conversation summarizer using Ollama. Requires `ollama` and `tqdm` packages. Supports incremental processing and resume via `--resume` flag.

## Service URLs (after successful run)

- APEX: `http://localhost:8080/ords/apex`
- EM Express: `https://localhost:5500/em`
- SQLPlus: `localhost:1521/FREEPDB1`
- Ollama API: `http://localhost:11434`

## Key Conventions

- Scripts use `set -euo pipefail` and an `ini_val()` function to parse `config.ini`
- All scripts are designed to be idempotent (safe to re-run)
- Documentation lives in `adb/ORACLE-ADB-UTILS.md` (setup guide) and `adb/ORACLE-26ai.md` (reference)
- The `26ai-mac-v1` branch is the active development branch targeting macOS M4
