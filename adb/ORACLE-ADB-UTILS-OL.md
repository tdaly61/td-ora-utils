# Oracle Autonomous 23ai Database Container Setup for Oracle Linux

## Overview

This repository provides a streamlined setup for the Oracle Autonomous 23ai Database container on Oracle Linux. It includes scripts and configurations that simplify the official Oracle ADB container deployment, with additional configuration for ONNX language model integration.

> **IMPORTANT**: These scripts are intended for development and testing purposes only. They prioritize ease of deployment over security considerations and should NOT be used in production environments without appropriate security hardening.

This project simplifies the official Oracle ADB container instructions found at [Oracle's documentation](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-database-container-free.html#GUID-B2E52334-2171-47F0-B951-B8007DD1B63C).

## Repository Contents

| File | Description |
|------|-------------|
| `setup-for-adb-23ai.sh` | Main setup script that prepares the environment and installs dependencies |
| `config.ini` | Configuration file for environment-specific settings |
| `vector-setup.sql` | SQL script for loading and configuring the ONNX model |
| `run-adb-23ai.sh` | Script to launch the Oracle Autonomous 23ai database container |

## System Requirements

- Oracle Linux 8.9 or 8.10
- Minimum 8GB RAM (16GB+ recommended)
- At least 50GB free disk space
- Internet connection for downloading components
- Sudo access

## Installation Guide

### 1. Install Git

```bash
sudo dnf install -y git
```

### 2. Clone the Repository

```bash
git clone -b oracle-linux https://github.com/tdaly61/td-ora-utils.git
cd td-ora-utils/adb/
```

### 3. Configure Environment Settings

Edit the configuration file to customize your installation:

```bash
# Open the file in your preferred editor
vi config.ini

# Update hostname and passwords as needed
```

### 4. Ensure Docker Access

Docker commands must be executable without sudo. You have two options:

```bash
# Option 1: Temporarily switch to the docker group
newgrp docker
docker ps  # Verify docker access works

# Option 2: Log out and log back in (preferred for persistence)
exit
# Log back in to your system
```

### 5. Run the Setup Script

```bash
sudo ./setup-for-adb-23ai.sh
```

The setup script performs the following actions:
- Validates root/sudo privileges
- Confirms compatible OS version
- Installs and configures Docker if needed
- Creates and configures the Oracle OS user
- Installs Oracle Instant Client
- Prepares the environment for container deployment

### 6. Launch the Database Container

```bash
./run-adb-23ai.sh
```

This script:
- Pulls the Oracle Autonomous 23ai database container image
- Launches the container with appropriate parameters
- Configures database integration with the ONNX language model
- Provides connection information upon successful startup

### 7. Accessing ADB from your laptop / (remote) desktop using localhost"
Add the HOSTNAME (i.e. the value from config.ini ) to your hosts file on the laptop/desktop system where your web browser is running where <IP> (without the angle brackets) is the IP of the server or VM where ADB has been deployed. If your browser is running on Linux or MacOS then all hosts entries go on one line , if your browser is running on Windows then you need a separate line for each entry. If you are deploying and running to the same system then <IP> will be localhost i.e. 127.0.0.1.

#### If you have specified a FQDN in the config.ini then you can skip this setup

```bash
# Linux/MacOS using a remote OCI VM (/etc/hosts) 
<IP> myadb.local

# Linux/MacOS running on the system where ADB is deployed  (/etc/hosts) 
<IP> myadb.local

# Windows remote (C:\Windows\System32\drivers\etc\hosts)
127.0.0.1 
<IP> myadb.local
```
#### Access ADB
```
    https://myadb.local:9443/ords/_/landing
```
or 
```
    https://<your FQDN>:9443/ords/_/landing
```
login using the users and passwords set in the config.ini

## Configuration Options

The `config.ini` file allows customization of various parameters:

- `HOSTNAME`: Server hostname
- `ORACLE_USER`: Database admin username
- `ORACLE_PASSWORD`: Database admin password
- `CONTAINER_NAME`: Name for the Docker container
- `DOCKER_IMAGE`: Oracle container image reference
- `ORACLE_INSTANT_CLIENT_URL`: Download URL for Oracle client
- `ONNX_MODEL_URL`: URL for the ONNX language model

## Troubleshooting

Common issues and their solutions:

1. **Docker access denied**: Ensure your user is in the docker group and you've either used `newgrp docker` or logged out and back in.

2. **Insufficient memory/disk space**: The container requires significant resources. Check system requirements with:
   ```bash
   free -h
   df -h
   ```

3. **Container fails to start**: Check Docker logs:
   ```bash
   docker logs <container_name>
   ```
4. **Can't access apex  

## Using port forward to access ADB from an OCI VM
assuming port 443 is open and you have set HOSTNAME in the config.ini to myadb.local (for example)

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to:
- Open issues for bugs or feature requests
- Submit pull requests with improvements
- Suggest documentation enhancements

## Contact

For questions, support, or feedback:
- Email: [tdaly61@gmail.com](mailto:tdaly61@gmail.com)
- GitHub Issues: [Report an issue](https://github.com/tdaly61/td-ora-utils/issues)