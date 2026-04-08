# Oracle Database Free 26ai — Container Setup Guide

This guide covers how to set up and run Oracle Database Free (version 23.26.x, also referred to as 26ai) as a Docker container on Ubuntu. It also configures the database with an ONNX embedding model for vector search, creates a demo user, and explains how to access the database from a remote machine.

> **For demo and POC use only. This setup is not hardened for production.**

---

## Contents

- [Prerequisites](#prerequisites)
- [One-Time Oracle Registry Setup](#one-time-oracle-registry-setup)
- [Configuration](#configuration)
- [Step 0 — Install Ollama](#step-0--install-ollama)
- [Step 1 — OS and Docker Setup](#step-1--os-and-docker-setup)
- [Step 2 — Run the Database Container](#step-2--run-the-database-container)
- [Accessing the Database](#accessing-the-database)
- [Remote Access via SSH Port Forwarding](#remote-access-via-ssh-port-forwarding)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Requirement | Details |
|---|---|
| **OS** | Ubuntu 22.04 or 24.04 (x86_64 or ARM64) |
| **RAM** | 8 GB minimum, 16 GB recommended |
| **Disk** | 20 GB free for container image and database files |
| **Docker** | Installed and running (script installs if missing) |
| **sudo** | Required — run setup script as root/sudo |
| **Internet** | Required to pull the container image and Oracle Instant Client |
| **Oracle account** | Free account at [container-registry.oracle.com](https://container-registry.oracle.com) |
| **Ollama** | Running on host with `OLLAMA_HOST=0.0.0.0`. Install via `sudo ../nvidia/ai-tools-setup.sh` |

---

## One-Time Oracle Registry Setup

The Oracle Container Registry requires a free account and license acceptance before you can pull the image.

1. Create a free account at [container-registry.oracle.com](https://container-registry.oracle.com)
2. Sign in, search for **Oracle Database Free**, and click **Continue** to accept the license agreement
3. Add your credentials to `config.ini`:

```ini
ORACLE_REGISTRY_USER=your.email@example.com
ORACLE_REGISTRY_PASSWORD=your_oracle_password
```

The `setup-for-adb-26ai.sh` script will log in and pull the image automatically using these credentials. You only need to do this once per machine — Docker caches the login token.

---

## Configuration

All settings are in `config.ini` in the same directory as the scripts. Defaults work out of the box once registry credentials are added.

| Setting | Default | Description |
|---|---|---|
| `HOSTNAME` | `fu8.local` | Hostname for the container. Must be in `/etc/hosts` for remote TLS access. |
| `DOCKER_IMAGE` | `container-registry.oracle.com/database/free:latest` | Container image. Pin to `23.26.1.0-amd64` or `23.26.1.0-arm64` for a fixed version. |
| `CONTAINER_NAME` | `oracle-db` | Docker container name |
| `SERVICE_NAME` | `FREEPDB1` | Oracle PDB service name used for connections |
| `DEFAULT_PASSWORD` | `Welcome_MY_ATP_123` | Password for `system`, `sys`, and the `TRACKER1` demo user |
| `ORACLE_REGISTRY_USER` | *(empty)* | Your Oracle account email |
| `ORACLE_REGISTRY_PASSWORD` | *(empty)* | Your Oracle account password |
| `ONNX_MODEL_URL` | *(OCI URL)* | Source URL for the `all-MiniLM-L12-v2` ONNX embedding model |
| `INSTANT_CLIENT` | `instantclient_23_6` | Oracle Instant Client version directory name |

To use a specific architecture tag instead of `latest`, update `DOCKER_IMAGE`:

```ini
# AMD64 (Intel/AMD)
DOCKER_IMAGE=container-registry.oracle.com/database/free:23.26.1.0-amd64

# ARM64 (Apple Silicon, Ampere, etc.)
DOCKER_IMAGE=container-registry.oracle.com/database/free:23.26.1.0-arm64
```

---

## Step 0 — Install Ollama

Ollama must be running on the host before `run-adb-26ai.sh` can configure generative AI. The simplest way:

```bash
sudo ../nvidia/ai-tools-setup.sh     # installs Ollama, sets OLLAMA_HOST=0.0.0.0
ollama pull llama3                    # pull the default model (or change OLLAMA_MODEL in config.ini)
```

Verify it's listening on all interfaces:
```bash
ss -tlnp | grep 11434
# Should show *:11434 or 0.0.0.0:11434
```

---

## Step 1 — OS and Docker Setup

Run once on a new machine to install Docker, Oracle OS groups, and Oracle Instant Client.

```bash
sudo ./setup-for-adb-26ai.sh
```

This script:
- Verifies Ubuntu 22 or 24
- Installs Docker if not present and ensures it is running
- Creates Oracle OS user and groups (`oracle`, `oinstall`, `dba`, etc.)
- Downloads and installs Oracle Instant Client 23.6 (sqlplus) to `~/oraclient/`
- Fixes the `libaio.so.1` symlink for the correct Ubuntu version
- Logs in to the Oracle Container Registry and pulls the image
- Adds `ORACLE_HOME`, `LD_LIBRARY_PATH`, and `PATH` to `~/.bashrc`

**Expected output (success):**
```
Docker is running.
Oracle Instant Client is already installed at /home/ubuntu/oraclient/instantclient_23_6.
Logging in to Oracle Container Registry as you@example.com...
Login Succeeded
Pulling image container-registry.oracle.com/database/free:latest...
Oracle Container Registry login and image pull successful.

OS and Docker Setup for ADB 26ai completed
```

---

## Step 2 — Run the Database Container

Start the container and configure the database. Run as your normal user (no sudo needed).

```bash
./run-adb-26ai.sh
```

This script:
1. Checks no container named `oracle-db` already exists
2. Creates `~/db_data_dir` for persistent database storage
3. Pulls the image if not already cached locally
4. Starts the container on ports **1521** (listener) and **5500** (EM Express)
5. Waits up to 30 minutes for the container to report healthy (typically ~3.5 minutes)
6. Downloads the `all-MiniLM-L12-v2` ONNX model to `~/model.onnx` if not already present
7. Creates a `tnsnames.ora` in `~/auth/tns/` for local sqlplus connections
8. Queries and copies the ONNX model into the container's `DATA_PUMP_DIR`
9. Creates the `TRACKER1` demo user with developer grants
10. Loads the ONNX model into the database as `ALL_MINILM` for vector search

**Expected output (success):**
```
Running Oracle Database Free using image ...
Container oracle-db is running and healthy.
Total time taken: 00:03:30
TNS configuration written to /home/ubuntu/auth/tns/tnsnames.ora
DATA_PUMP_DIR is /opt/oracle/admin/FREE/dpdump/...
SQL file create-users.sql executed successfully.
SQL file vector-setup.sql executed successfully.
Notes ...
1. to see database status use docker logs -f oracle-db
2. this deployment is NOT secure it is intended for Demo and POC use only
3. Access Enterprise Manager Express https://localhost:5500/em
4. SQLplus Login via .../sqlplus system/Welcome_MY_ATP_123@FREEPDB1
```

---

## Accessing the Database

### Ports

| Port | Protocol | Service |
|---|---|---|
| **1521** | TCP | Oracle SQL*Net listener (connect with sqlplus, SQL Developer, etc.) |
| **5500** | HTTPS | Oracle Enterprise Manager Express (web UI) |

### SQLplus (command line)

Source your environment first (or open a new shell after running the setup script):

```bash
source ~/.bashrc
```

Connect as **system** to the pluggable database:
```bash
sqlplus system/Welcome_MY_ATP_123@FREEPDB1
```

Connect as **sys** (DBA):
```bash
sqlplus sys/Welcome_MY_ATP_123@FREE as sysdba
```

Connect as the demo user **TRACKER1**:
```bash
sqlplus TRACKER1/Welcome_MY_ATP_123@FREEPDB1
```

### Enterprise Manager Express (web UI)

Open in a browser on the **database host**:

```
https://localhost:5500/em
```

Login with `system` / `Welcome_MY_ATP_123`. Accept the self-signed certificate warning.

### SQL Developer / Other Tools

Use these JDBC or connection parameters:

| Parameter | Value |
|---|---|
| Hostname | `localhost` (or forwarded host — see below) |
| Port | `1521` |
| Service name | `FREEPDB1` |
| Username | `system` |
| Password | `Welcome_MY_ATP_123` |

---

## Remote Access via SSH Port Forwarding

If the database host is a remote server (cloud VM, remote workstation, etc.), use SSH local port forwarding to tunnel both ports to your laptop.

### Single command — forward both ports

```bash
ssh -L 1521:localhost:1521 \
    -L 5500:localhost:5500 \
    user@your-server-hostname-or-ip
```

Keep this terminal open while you work. Then on your **local machine**:

- **SQLplus:** `sqlplus system/Welcome_MY_ATP_123@localhost:1521/FREEPDB1`
- **EM Express:** `https://localhost:5500/em`
- **SQL Developer:** host `localhost`, port `1521`, service `FREEPDB1`

### Background (non-blocking) tunnel

Add `-fN` to run the tunnel in the background without opening a shell:

```bash
ssh -fN \
    -L 1521:localhost:1521 \
    -L 5500:localhost:5500 \
    user@your-server-hostname-or-ip
```

To kill a background tunnel:
```bash
# Find the PID
ps aux | grep "ssh -fN"
kill <pid>
```

### VS Code / Cursor remote port forwarding

If you are connected to the server via VS Code Remote SSH or Cursor, use the **Ports** panel (bottom status bar → Ports tab) to forward ports `1521` and `5500`. They will then be available on `localhost` on your local machine automatically.

### Cloud firewall note

SSH tunnels work through the SSH port (22) only — you do **not** need to open ports 1521 or 5500 in your cloud firewall/security group. Only port 22 needs to be open for remote access.

---

## Cleanup

### Stop the container (data preserved)

```bash
docker stop oracle-db
docker rm oracle-db
```

Restart later with `./run-adb-26ai.sh` — the database files in `~/db_data_dir` are retained.

### Full cleanup (remove container and data)

```bash
./run-adb-26ai.sh -c
```

You will be prompted whether to also delete `~/db_data_dir`. Deleting it means the database is recreated from scratch on the next run.

---

## Troubleshooting

### Container stays in `starting` state

The database initialises on first run and can take up to 5 minutes. Check the container logs:

```bash
docker logs -f oracle-db
```

Look for `DATABASE IS READY TO USE!` near the end.

### `libaio.so.1: cannot open shared object file`

The `libaio` symlink is broken. Re-run the setup script to fix it:

```bash
sudo ./setup-for-adb-26ai.sh
```

### `ORA-12154: TNS:could not resolve the connect identifier`

`TNS_ADMIN` is not set. Either source `.bashrc` or export it manually:

```bash
export TNS_ADMIN=$HOME/auth/tns
export LD_LIBRARY_PATH=$HOME/oraclient/instantclient_23_6
```

### `manifest unknown` when pulling image

The tag does not exist or you are not logged in. Check:
1. `ORACLE_REGISTRY_USER` and `ORACLE_REGISTRY_PASSWORD` are set in `config.ini`
2. You have accepted the Oracle Database Free license at [container-registry.oracle.com](https://container-registry.oracle.com)

### Container already exists error

A previous container was not cleaned up:

```bash
docker stop oracle-db && docker rm oracle-db
```

Then re-run `./run-adb-26ai.sh`.

### Port 1521 already in use

Another Oracle process or the old container is still occupying the port:

```bash
sudo ss -tlnp | grep 1521
```

Stop whatever process is listed, then retry.

---

## File Reference

| File | Purpose |
|---|---|
| `config.ini` | All configurable settings — edit this before running |
| `setup-for-adb-26ai.sh` | One-time host setup (Docker, Instant Client, registry login) |
| `run-adb-26ai.sh` | Start the container, configure TNS, load model, run SQL setup, configure Ollama AI |
| `sql-scripts/create-users.sql.tpl` | Template for user + APEX workspace SQL |
| `sql-scripts/vector-setup.sql` | Loads ONNX model into Oracle as `ALL_MINILM` |
| `sql-scripts/setup-ollama-ai.sql.tpl` | Template for network ACL + Ollama generative AI setup |
| `../nvidia/ai-tools-setup.sh` | Installs Ollama + AI tools (run before database setup) |

---

## Contact

For questions or issues please contact [tdaly61@gmail.com](mailto:tdaly61@gmail.com) or open an issue in the repository.
