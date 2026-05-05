#!/usr/bin/env bash

#brew install docker-credential-helper

docker run -d \
-p 1521:1522 \
-p 1522:1522 \
-p 8443:8443 \
-p 27017:27017 \
-e WORKLOAD_TYPE=ATP \
-e WALLET_PASSWORD=Welcome_MY_ATP_123 \
-e ADMIN_PASSWORD=Welcome_MY_ATP_123 \
--cap-add SYS_ADMIN \
--device /dev/fuse \
--name adb-free \
container-registry.oracle.com/database/adb-free:latest-26ai
