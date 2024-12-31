#!/usr/bin/env bash
# run the Oracle ADB in a container 
# Tom Daly : Nov 2023 
# see : https://github.com/oracle/adb-free and also 
#       https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/autonomous-docker-container.html?source=%3Aex%3Anc%3A%3A%3Arc_wwmk180119p00044%3Achatbotsinhr#GUID-69850C6E-2E8F-4F2F-A95E-7A2ECDEB067C

create_docker_volume() {
    local VOL_NAME=$1
    if docker volume inspect "$VOL_NAME" >/dev/null 2>&1; then
        echo "Error: Volume '$VOL_NAME' already exists."
        echo "       you can remove with docker volume rm $VOL_NAME" before trying again
        exit 1
    else
        # create a local volume
        docker volume create $VOL_NAME
    fi
}

####### main code #######
HOSTNAME="fu6.local"  # I think it requires a hostname before self-signed certs are generated add fu6.local to /etc/hosts 127.0.01
VOL_NAME="adb_container_vol" 

# create a local volume
create_docker_volume $VOL_NAME

# now run ADB with the volume mounted as /u01/data
echo "Running ADB" 
docker run -d \
-p 1521:1522 \
-p 1522:1522 \
-p 8443:8443 \
-p 27017:27017 \
--hostname $HOSTNAME \
--cap-add SYS_ADMIN \
--device /dev/fuse \
--name adb_container \
--volume $VOL_NAME:/u01/data \
--restart unless-stopped \
container-registry.oracle.com/database/adb-free:latest-23ai
