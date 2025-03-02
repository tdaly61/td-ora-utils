# Oracle Autonomous 23ai Database Container Setup

This repository contains scripts and configuration files to set up and run the Oracle Autonomous 23ai database container. It also configures the database to work with the ONNX language model. The scripts here are intended for demonstration purposes and for testing but are not deploying Oracle in a very secure fashion and so should NOT be used *as is* for any sort of production environment. These utilities are aimed at simplifying the Oracle ADB container instructions at https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-database-container-free.html#GUID-B2E52334-2171-47F0-B951-B8007DD1B63C 

## Repository Contents

- `setup-for-adb-23ai.sh`: Bash script to set up the environment and install necessary dependencies.
- `config.ini`: Configuration file containing environment-specific settings.
- `vector-setup.sql`: SQL script to load the ONNX model into the database.
- `run-adb-23ai.sh`: Bash script to run the Oracle Autonomous 23ai database container.

### Prerequisites

- A running Ubuntu 24.04 OS with sufficient memory and disk for Oracle ADB 
- Internet connection to download necessary files.
- Access to sudo 

### Quick Setup

1. **Clone the repository:**

    ```bash
    git clone https://github.com/tdaly61/td-ora-utils.git
    edit the 
    cd td-ora-utils/adb
    ```

2. **Run the setup script:**

    ```bash
    sudo ./setup-for-adb-23ai.sh
    ```

    This script will:
    - Check for root user privileges.
    - Verify the operating system.
    - ensure docker is installed.
    - Set up the Oracle OS user.
    - Install the Oracle Instant Client.
    - Perform other necessary setup tasks.

### Running the Database Container
3. **Run the database container:**

    ```bash
         ./run-adb-23ai.sh
    ```

    This script will:
    - Pull the Oracle Autonomous 23ai database container image.
    - Start the container.
    - Configure the database to work with the ONNX language model.

## Configuration

The scripts should run out of the box and start the Oracle ADB however you can customize the setup by modifying the [config.ini](http://_vscodecontentref_/1) file. This file contains various settings such as the hostname, Oracle Instant Client URLs, ONNX model URL, container name, and Docker image.

## License

This project is licensed under the MIT License. See the [LICENSE](http://_vscodecontentref_/2) file for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request for any improvements or bug fixes.

## Contact

For any questions or support, please contact [tdaly61@gmail.com](mailto:tdaly61@gmail.com).