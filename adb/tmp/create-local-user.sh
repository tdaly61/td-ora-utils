#!/bin/bash
# add a non admin database user to the local ADB instance running in a container 

# Set your Oracle database credentials
export PASSWORD="_Welcome12345"
USER="tomlocal"
CONTAINER_NAME="adb_container"

# SQL script for creating a new user and APEX workspace
SQL_SCRIPT=$(cat <<EOF
SET echo on
SET feedback on
SET heading on
SET serveroutput on

-- Creating a new user
CREATE USER ${USER} IDENTIFIED BY "${PASSWORD}";

-- Granting necessary privileges to the new user
GRANT CONNECT, RESOURCE TO ${USER};

-- Displaying the created user
SELECT * FROM all_users WHERE username = '${USER}';

EXIT;
EOF
)

# Save the SQL script to a file
echo "$SQL_SCRIPT" > /tmp/create_user_workspace.sql

# copy the script into the docker container 
docker cp /tmp/create_user_workspace.sql adb_container:/tmp


# Execute the SQL script using sqlplus inside the docker container 
docker exec $CONTAINER_NAME sqlplus admin/$PASSWORD@localhost:1521/MY_ATP @/tmp/create_user_workspace.sql

