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
ollama pull llama3.2:3b          # or whichever model set in adb/.env

# One-time OS/Docker prep (requires sudo)
sudo ./adb/setup-for-adb-26ai.sh

# Start Oracle DB (APEX/ORDS pre-installed in the image) + configure Ollama integration
./adb/run-adb-26ai.sh
```

Cleanup: `./adb/run-adb-26ai.sh -c` (add `-r` to also remove Docker images). Separately,
`sudo ./adb/setup-for-adb-26ai.sh -c` is **not scoped to this repo** — on Linux it runs
`docker system prune -a -f --volumes` and uninstalls Docker itself from the host.

## Configuration

All user-editable settings live in `adb/.env.sample` — copy it to `adb/.env` and edit
(this is what every script actually reads; `config.ini` was the old name and is only
read as a fallback for pre-existing checkouts). Key settings:

- Oracle Container Registry credentials (only needed for the `container-registry.oracle.com`
  fallback image — the default `ghcr.io` images pull unauthenticated)
- DB image (`DOCKER_IMAGE_ARM`/`DOCKER_IMAGE_AMD`, arch-selected automatically), container
  name, service name, passwords
- APEX port (`8443`, HTTPS) and workspace credentials
- Ollama models and the `LLM_<STATIC_ID>=url|model|type` remote-server entries
- Docker runtime selection (macOS: Colima only — Docker Desktop/Rancher/OrbStack are
  detected and the scripts ask you to shut them down)

**Model config is the single source of truth** (`adb/.env`): `OLLAMA_VISION_MODEL`,
`OLLAMA_TEXT_MODEL`, and `LLM_<STATIC_ID>=url|model|type` entries. Any key may have a
`_MAC` variant used on Apple Silicon (`common.sh` `platform_val` resolves it) — e.g.
smaller models than `llama3.3:70b` for an M4. `adb/pull-ollama-models.sh` reads these
and pulls exactly those tags; `nvidia/ai-tools-setup.sh` delegates its pipeline-model
pulls to it (so there is no hardcoded-tag drift).

## Architecture

### Core Scripts

Everything in `adb/` is generic — it works with any APEX application, not any one app
in particular. App-specific deployment logic lives entirely in
that app's own repo and calls into these as a library.

| Script | Role |
|--------|------|
| `adb/setup-for-adb-26ai.sh` | One-time OS prep: installs Docker/Colima, Oracle Instant Client, creates OS users/groups |
| `adb/run-adb-26ai.sh` | Main orchestrator: starts the DB container, waits for health, starts the Ollama HTTPS proxy, runs SQL setup |
| `adb/load-apex-app.sh` | Import an APEX app export into a running ADB — local or, given a cloud wallet, remote |
| `adb/export-apex-app.sh` | Export a live APEX app to a versioned SQL file + manifest |
| `adb/bundle-apex-for-oci.sh` | Package an app export (+ optional post-import SQL / payload) into a manual-handover tarball for OCI ADB |
| `adb/deploy-apex-to-oci.sh` | Optional: automate that handover via the `oci` CLI (wallet download + grants + import) |
| `adb/examples/sample-app/` | Generic worked example (Notes + vector search) proving the toolkit needs no app-specific knowledge |
| `adb/legacy/compose-fullstack/` | Archived two-container docker-compose alternative — not wired to any script, kept for reference |
| `nvidia/nvidia-gpu-setup.sh` | NVIDIA driver installation for Ubuntu 24.04 |
| `nvidia/ai-tools-setup.sh` | Installs Ollama, Claude Code, OpenCode; pulls LLM models |

### SQL Templating

SQL files ending in `.sql.tpl` are templates with `__TOKEN__` placeholders substituted at runtime:
- `sql-scripts/create-users.sql.tpl` — `__APEX_USER__`, `__APEX_PASSWORD__`
- `sql-scripts/setup-ollama-ai.sql.tpl` — `__APEX_USER__`, `__APEX_PASSWORD__`, `__OLLAMA_BASE_URL__`, `__OLLAMA_MODEL__`
- `sql-scripts/load-onnx-model.sql.tpl` — `__MODEL_NAME__`, `__ONNX_URL__` (generic embedding-model loader, rendered by whichever app needs a named model)
- `sql-scripts/oci-admin-grants.sql.tpl` — `__SCHEMA__`, `__LLM_HOST__` (generic OCI handover grants)

The generated (non-template) `.sql` files in `adb/sql-scripts/` are the runtime-ready versions of the first two; the latter two are rendered on demand by `bundle-apex-for-oci.sh`/`deploy-apex-to-oci.sh` or by an app's own wrapper.

### Container Architecture

`run-adb-26ai.sh` starts a **single** `adb-free` container (ORDS and APEX pre-installed),
mapping `1521`/`1522` (SQL*Net), `8443` (APEX/ORDS, HTTPS), `27017` (MongoDB API). It also
starts a second, small `ollama-proxy` container (nginx) on a shared Docker network
(`oracle-ai-net`) that TLS-terminates calls to Ollama on the host — required because
ADB-Free enforces outbound-HTTPS-only. `adb/legacy/compose-fullstack/` documents an older,
unwired two-container alternative (plain DB image + separate ORDS container) kept for
reference only.

### Ollama Integration Pattern

Ollama runs on the **host** at `0.0.0.0:11434`. The DB container reaches it via the
`ollama-proxy` container (`https://ollama-proxy:443`), which terminates TLS and forwards
to `http://host.docker.internal:11434` — ADB-Free hardcodes `REQUIRE_OUT_HTTPS=Y`, so a
direct plain-HTTP call from `UTL_HTTP` is rejected. The setup SQL grants network ACLs and
`DBMS_VECTOR_CHAIN` privileges, then registers Ollama as an APEX AI service using its
OpenAI-compatible `/v1` endpoint. See `adb/README.md` for the full constraint list.

### Platform Handling

Scripts source `adb/common.sh` and call `detect_platform` to set `PLATFORM` (linux/darwin)
and `ARCH` (x86_64/arm64), then branch accordingly:
- **Linux**: Instant Client via ZIP, Docker from `docker.io`, NVIDIA GPU support
- **macOS**: Instant Client via DMG, Colima only as the container runtime (Docker Desktop/Rancher/OrbStack are rejected), `COLIMA_ARCH` can override the host arch for x86_64 emulation

`select_docker_image` and `resolve_instant_client` (also in `common.sh`) centralise the
arch-to-image and `_MAC`-fallback logic so `setup-for-adb-26ai.sh` and `run-adb-26ai.sh`
agree on which image/client to use.

### Python Utility

`aiutils/summarise_conversations.py` — standalone Reddit conversation summarizer using Ollama. Requires `ollama` and `tqdm` packages. Supports incremental processing and resume via `--resume` flag.

## Service URLs (after successful run)

- APEX: `https://localhost:8443/ords/apex` (self-signed cert — accept it on first visit)
- Database Actions: `https://localhost:8443/ords/sql-developer`
- sqlplus: `TNS_ADMIN=~/auth/tls_wallet sqlplus admin/<password>@myatp_high`
- Ollama API (host): `http://localhost:11434`
- Ollama proxy (Docker network only): `https://ollama-proxy:443`

## Key Conventions

- Scripts use `set -euo pipefail` and an `ini_val()`/`platform_val()` function (in
  `adb/common.sh`) to parse `adb/.env`
- All scripts are designed to be idempotent (safe to re-run)
- Documentation lives in `adb/README.md` (macOS/Colima-focused setup + architecture
  reference) and `adb/LINUX-SETUP.md` (Ubuntu)
- `adb/` contains **no app-specific logic or references** — app repos
  call into `load-apex-app.sh`/`export-apex-app.sh`/`bundle-apex-for-oci.sh` as a library
  and keep their own schema/model/user names entirely in their own repo
