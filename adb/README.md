# Oracle ADB-Free 26ai — Local Container with Ollama AI

Run Oracle Autonomous Database Free (26ai) locally with APEX, ORDS, vector search, and a local Ollama LLM — on macOS (Apple Silicon via Colima) or Linux.

> **Demo and POC use only — not hardened for production.**

Reference: [Oracle ADB Container Free docs](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-database-container-free.html)

---

## Architecture

```
macOS host
  Ollama :11434 (HTTP)
       │
       │ host.docker.internal:11434
       │
  ┌────▼──────────────────────────────────────────────────┐
  │  Docker network: oracle-ai-net                        │
  │                                                       │
  │  ┌───────────────────┐    ┌──────────────────────┐   │
  │  │  ollama-proxy     │    │  adb-free            │   │
  │  │  nginx:alpine     │    │  26ai container      │   │
  │  │  :443 (HTTPS)     │◄───│                      │   │
  │  │                   │    │  :8443  APEX/ORDS    │   │
  │  │  TLS terminates   │    │  :1521  SQL*Net      │   │
  │  │  → Ollama HTTP    │    │                      │   │
  │  └───────────────────┘    │  UTL_HTTP            │   │
  │                           │  APEX AI service     │   │
  │                           │  DBMS_VECTOR_CHAIN   │   │
  └───────────────────────────┴──────────────────────┘   │
```

**Why the nginx proxy?** ADB-Free enforces `REQUIRE_OUT_HTTPS=Y` as a hardcoded, non-configurable policy. Every outbound call from APEX and `UTL_HTTP` must use HTTPS. Ollama speaks plain HTTP, so an HTTPS-terminating proxy is required.

**Why copy to DBFS path?** ADB-Free's Oracle database process runs in an internal DBFS namespace separate from the container's regular filesystem. Docker volume mounts (e.g. `~/db_data_dir → /u01/data`) are visible to shell processes but NOT to `DBMS_VECTOR.LOAD_ONNX_MODEL`. After creating the `ONNX_STAGING` Oracle directory object, `run-adb-26ai.sh` queries `dba_directories` to resolve the DBFS path (e.g. `/u01/dbfs/<GUID>/data/u01/data`) and copies the model there via `docker cp`.

---

## Quick Start

```bash
# 1. First run: install Oracle Instant Client, configure Docker/Colima
./setup-for-adb-26ai.sh

# 2. Start everything (ADB container + nginx proxy + ONNX model + APEX users)
#    Add -k if mifos-gazelle Kubernetes pods are running (see "mifos-gazelle co-existence" below)
./run-adb-26ai.sh

# 3. Load your APEX application (uses APEX_EXPORT_FILE from .env by default)
./load-apex-app.sh
# Or override with: ./load-apex-app.sh -f path/to/your-app.sql
# No app to load yet? Try the generic demo: ./examples/sample-app/load-sample-app.sh

# 4. Open APEX
open https://localhost:8443/ords/apex
# Workspace: TRACKER1  User: TRACKER1  Password: Welcome_MY_ATP_123

# 5. Later — export your app and hand it to someone deploying to OCI ADB:
./export-apex-app.sh -u TRACKER1
./bundle-apex-for-oci.sh -f apex-exports/app_<timestamp>.sql

# 6. Clean up (stop containers; prompts before deleting data)
./run-adb-26ai.sh -c
```

---

## Files

| File | Purpose |
|------|---------|
| `.env` | All settings — edit `.env.sample` → copy to `.env` before running |
| `run-adb-26ai.sh` | Main script: start containers, load model, configure AI |
| `setup-for-adb-26ai.sh` | One-time install: Instant Client, Docker/Colima, registry login |
| `load-apex-app.sh` | Import an APEX app export + wire up AI remote servers (local or cloud) |
| `export-apex-app.sh` | Export a live APEX app to a versioned SQL file + manifest |
| `bundle-apex-for-oci.sh` | Package an app for manual handover to an Oracle ADB on OCI |
| `deploy-apex-to-oci.sh` | Optional: automate that handover via the `oci` CLI |
| `examples/sample-app/` | Generic worked example — Notes app + vector search |
| `legacy/compose-fullstack/` | Archived two-container alternative (not wired to any script) |
| `ollama-proxy/nginx.conf` | nginx HTTPS→HTTP proxy config |
| `ollama-proxy.crt` / `ollama-proxy.key` | Self-signed cert for the proxy (gitignored) |
| `sql-scripts/create-users.sql.tpl` | User + APEX workspace template |
| `sql-scripts/load-onnx-model.sql.tpl` | Generic ONNX embedding-model loader (any model name/URL) |
| `sql-scripts/oci-admin-grants.sql.tpl` | Generic ADMIN grants for an OCI ADB handover |
| `sql-scripts/setup-ollama-ai.sql.tpl` | Network ACL + APEX AI remote server template |

---

## Configuration (`.env`)

Copy `.env.sample` to `.env` and edit. Key settings most likely to need changing:

```ini
DOCKER_IMAGE_ARM=ghcr.io/oracle/adb-free:26.5.4.2-26ai-arm64   # arch-specific image tags —
DOCKER_IMAGE_AMD=ghcr.io/oracle/adb-free:26.5.4.2-26ai-amd64   # run-adb-26ai.sh picks the right one
CONTAINER_NAME=adb-free
DEFAULT_PASSWORD=Welcome_MY_ATP_123          # ADMIN, wallet, and demo user password
APEX_USER=TRACKER1

# LLM endpoint — "local" type: run-adb-26ai.sh starts the nginx proxy automatically
LLM_OLLAMA_LOCAL=https://ollama-proxy:443|llama3.2:3b|local

# macOS / Colima
CONTAINER_RUNTIME=colima
COLIMA_ARCH=x86_64      # x86_64 emulation for amd64 Oracle image on Apple Silicon
COLIMA_DISK=100         # GB — needs ~35 GB for mifos + ~20 GB for Oracle
```

---

## What `run-adb-26ai.sh` Does

On each run (idempotent — safe to re-run against a live stack):

1. Starts Colima with the configured VM sizing (skipped if already running)
2. Starts the `adb-free` Docker container (skipped if healthy)
3. Waits for the healthcheck to pass (~2–5 min on first start)
4. Downloads the `all-MiniLM-L12-v2` ONNX model to `~/model.onnx` if missing
5. Copies the model into the container data volume (`/u01/data/`)
6. Configures sqlplus access via the tls_wallet (copies to `~/auth/tls_wallet/`)
7. **Starts the nginx HTTPS proxy** (`start_ollama_proxy`)
8. **Trusts the proxy cert in Oracle's ssl_wallet** (`trust_proxy_cert`)
9. Generates SQL from templates and runs setup scripts (users, ONNX, Ollama AI)

---

## ADB-Free Security Constraints (Important for AI Assistants)

These are **hardcoded** ADB-Free behaviours that cannot be changed by any Oracle parameter, SQL command, or `APEX_INSTANCE_ADMIN` call. Understanding them is essential when working on this codebase.

### 1. `REQUIRE_OUT_HTTPS=Y` — outbound HTTP is blocked

All outbound calls from `UTL_HTTP`, `APEX_WEB_SERVICE`, and `DBMS_VECTOR_CHAIN` must use `https://` URLs. Plain `http://` requests fail with `ORA-20987: The requested URL has been prohibited.`

**Solution:** The `ollama-proxy` nginx container terminates TLS and forwards to Ollama over plain HTTP.

### 2. `UTL_HTTP.set_wallet()` is silently ignored

In ADB-Free, `UTL_HTTP.set_wallet('file:/any/path')` always returns success but has no effect. The database always uses its internal **ssl_wallet** (`/u01/app/oracle/wallets/ssl_wallet/`) for all outbound HTTPS certificate validation. This means:

- Logon triggers that call `set_wallet()` do nothing
- Custom wallets pointed to by `set_wallet()` are never used
- `SQLNET.WALLET_OVERRIDE` does not affect UTL_HTTP's wallet choice

**Discovery evidence:** `set_wallet('file:/nonexistent/path')` succeeds without error and still produces ORA-29024, same as a real wallet path that lacks the cert.

### 3. `ssl_wallet` password is not `WALLET_PASSWORD`

The `ssl_wallet` contains ~117 public CA certificates (DigiCert, GlobalSign, Amazon, etc.). Its `ewallet.p12` was created during Docker image build with an unknown password — **not** the `WALLET_PASSWORD` you supply at container startup (which is used only for `tls_wallet`). Common passwords (`Welcome_MY_ATP_123`, `oracle`, etc.) all fail with `PKI-02003: Invalid padding string`.

### 4. `/ as sysdba` OS authentication is disabled

ADB-Free blocks OS authentication even from inside the container via `docker exec`. All DBA operations must use `ADMIN` user credentials over TCPS. This affects logon trigger creation (must be in `ADMIN` schema, not `SYS`).

### 5. TCPS (mTLS) required for all client connections

ADB-Free does not expose a plain TCP listener. All external connections (sqlplus, Python oracledb, JDBC) must use mTLS via the `tls_wallet`. The wallet is copied to `~/auth/tls_wallet/` by `run-adb-26ai.sh`.

---

## How the Proxy Cert Trust Works

Oracle's `ssl_wallet` is an auto-login wallet (`cwallet.sso`). The `cwallet.sso` is read by Oracle at runtime without a password — Oracle doesn't use `ewallet.p12` for runtime SSL validation, only for administrative wallet operations.

`trust_proxy_cert()` in `run-adb-26ai.sh` rebuilds `cwallet.sso` to include the proxy cert:

1. **Export** all 117 existing CA certs from `ssl_wallet` without a password (auto-login wallet allows this)
2. **Create** a fresh wallet with `-with_trust_flags` support (required for `SERVER_AUTH` trust flag)
3. **Re-add** all original CA certs with `SERVER_AUTH`; end-entity certs without flag
4. **Add** the nginx proxy cert with `SERVER_AUTH`
5. **Replace** `ssl_wallet/cwallet.sso` with the new one (`ewallet.p12` is left untouched)

This survives `docker restart` (container writable layer is preserved). It is **lost** on `docker rm` (full cleanup with `-c`), so `run-adb-26ai.sh` re-runs `trust_proxy_cert()` on every start.

---

## Python Connection to ADB-Free

ADB-Free requires TCPS (mTLS) for all Python connections. Configure `oracledb` with wallet parameters:

```ini
# your-app/.credentials (or .env — format is up to your app)
[db]
user = TRACKER1
password = Welcome_MY_ATP_123
dsn = myatp_high
wallet_location = /Users/you/auth/tls_wallet
wallet_password = Welcome_MY_ATP_123
```

```python
import oracledb
conn = oracledb.connect(
    user=creds['user'],
    password=creds['password'],
    dsn=creds['dsn'],           # TNS alias from tls_wallet/tnsnames.ora
    config_dir=wallet_loc,      # directory containing tnsnames.ora + cwallet.sso
    wallet_location=wallet_loc,
    wallet_password=wallet_pass or None
)
```

Plain TCP (`dsn = localhost:1521/FREEPDB1`) will fail — ADB-Free does not expose a plain listener.

---

## Connection Details

| Service | URL / Command |
|---------|---------------|
| APEX | `https://localhost:8443/ords/apex` |
| Database Actions | `https://localhost:8443/ords/sql-developer` |
| sqlplus | `TNS_ADMIN=~/auth/tls_wallet sqlplus admin/Welcome_MY_ATP_123@myatp_high` |
| Ollama proxy (HTTPS) | `https://ollama-proxy:443` (Docker network only) |
| Ollama direct (HTTP) | `http://localhost:11434` (macOS host) |

Default credentials: **Workspace** `TRACKER1` · **User** `TRACKER1` · **Password** `Welcome_MY_ATP_123`

---

## Export an app and deploy it to OCI Autonomous Database

Two ways to move an app from this local instance to a real Oracle ADB on OCI —
both start with an export:

```bash
./export-apex-app.sh -u TRACKER1        # -> apex-exports/app_<timestamp>.sql + manifest
```

**Manual handover (works today, no OCI CLI setup needed):**

```bash
./bundle-apex-for-oci.sh -f apex-exports/app_<timestamp>.sql \
    --onnx-model MY_EMBED_MODEL --post-sql app_users.sql --payload-dir ./workers
# -> dist/apex-oci-<schema>-<timestamp>.tar.gz
```

Hand the tarball to whoever has access to the target ADB. They follow the
generated `README-OCI.md`: run the ADMIN grants in Database Actions, import the
app in APEX Builder with Supporting Objects checked, run the numbered post-import
SQL, then `./check-prereqs.sh` before starting any payload.

**Automated push (optional — needs the `oci` CLI configured):**

```bash
./deploy-apex-to-oci.sh -f apex-exports/app_<timestamp>.sql \
    --db-ocid ocid1.autonomousdatabase.oc1..xxxx --llm-host api.x.ai
```

Downloads the instance wallet, runs the ADMIN grants, and imports the app —
`load-apex-app.sh` is target-agnostic, so the same importer used locally works
against a cloud wallet. If the `oci` CLI isn't installed/configured, this script
tells you and exits; the manual bundle above always works as a fallback.

Neither of these scripts ever runs `git commit` or `git push`.

---

## mifos-gazelle co-existence

Both this project and mifos-gazelle share the **same Colima VM** (the default profile). mifos-gazelle starts that VM with `--kubernetes`, so k3s and its system pods occupy 6–8 GB of the VM's RAM. When Oracle ADB is also running, the two compete for memory.

### Check whether k3s is running

```bash
./run-adb-26ai.sh      # prints a WARNING and the k3s pod count if k3s is active
```

Or check directly:

```bash
docker ps --filter "label=io.kubernetes.pod.namespace" --format "table {{.Names}}\t{{.Status}}"
```

### Stop k3s before starting Oracle ADB

```bash
# Stops k3s inside the Colima VM; Colima and Docker keep running.
./run-adb-26ai.sh -k
```

`-k` disables and stops k3s via `systemctl`, then runs `k3s-killall.sh` to release
containers and network interfaces. Colima continues running so Oracle ADB starts
without a VM restart.

### Restore k3s when you switch back to mifos-gazelle

```bash
colima ssh -- sudo systemctl enable k3s && colima ssh -- sudo systemctl start k3s
# Then redeploy mifos-gazelle if needed:
# sudo ./run.sh -u $USER -m deploy -a all
```

Or use the helper directly from the project root:

```bash
source adb/mac_helpers.sh && start_k3s_mac
```

### Tips

- `COLIMA_DISK=100` in `.env` covers both projects (~35 GB mifos + ~20 GB Oracle).
- You do not need to resize or recreate the Colima VM when switching between projects.
- Stopping k3s does **not** delete Kubernetes workloads; they resume when k3s restarts.

---

## Troubleshooting

### `ORA-29024: Certificate validation failure` from UTL_HTTP

The proxy cert is not in Oracle's `ssl_wallet`. Re-run `trust_proxy_cert()`:

```bash
./run-adb-26ai.sh    # runs trust_proxy_cert() automatically on every start
```

If the cert has been regenerated (`.crt` / `.key` deleted and recreated), the old cert is no longer trusted. Run `./run-adb-26ai.sh -c` then `./run-adb-26ai.sh` to reset everything cleanly.

### `ORA-20987: The requested URL has been prohibited`

The URL passed to `UTL_HTTP` or `APEX_WEB_SERVICE` uses `http://` instead of `https://`. ADB-Free blocks plain HTTP outbound. Fix: ensure `LLM_OLLAMA_LOCAL` in `.env` starts with `https://`.

### HTTP 403 Forbidden from Ollama via proxy

nginx is sending a `Host:` header that Ollama rejects. Ensure `nginx.conf` has:
```nginx
proxy_set_header Host "localhost";
```
Ollama on macOS only accepts requests that appear to come from localhost.

### `DPY-6000` or `ORA-12170` from Python

Plain TCP connection attempted. Switch to TCPS: add `wallet_location` and `wallet_password` to `.credentials` and use a TNS alias (`myatp_high`) not a host:port DSN.

### Container not reachable after `docker restart`

The `adb-free` container may have lost its `oracle-ai-net` network membership. `run-adb-26ai.sh` reconnects it automatically. Manual fix:

```bash
docker network connect oracle-ai-net adb-free
```

### Colima VM already running with wrong sizing

Colima VM disk cannot be resized without full delete. If the VM exists with insufficient disk:

```bash
colima delete     # deletes the VM (data in ~/db_data_dir is on macOS, so it's safe)
colima start --arch x86_64 --vm-type vz --vz-rosetta --memory 8 --disk 100
```

---

## Related Docs

- [LINUX-SETUP.md](LINUX-SETUP.md) — Linux/Ubuntu setup guide (database only or full stack with APEX/ORDS)
