#!/usr/bin/env bash
# run BANE against Oracle ADB in a container 
# Tom Daly : Nov 2023 
# see : https://github.com/oracle/adb-free and also 
#       https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/autonomous-docker-container.html?source=%3Aex%3Anc%3A%3A%3Arc_wwmk180119p00044%3Achatbotsinhr#GUID-69850C6E-2E8F-4F2F-A95E-7A2ECDEB067C


####### main code #######
RUN_DIR=$HOME/tom/bane/AdelVidMatcher
CONDA_ENV="BANE"


cd $RUN_DIR 
eval "$(conda shell.bash hook)"
conda activate $CONDA_ENV
export TNS_ADMIN="/home/ubuntu/myadbwallet/tls_wallet/"


echo "===================================================="
echo "   < Running Python Web Client in foreground  > " 
echo "===================================================="
python webserver.py 



