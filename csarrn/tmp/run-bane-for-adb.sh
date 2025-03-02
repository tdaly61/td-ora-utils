#!/usr/bin/env bash
# run BANE python client most likely against Oracle ADB in a container 
# Tom Daly : Nov 2023 
# see : https://github.com/oracle/adb-free and also 
#       https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/autonomous-docker-container.html?source=%3Aex%3Anc%3A%3A%3Arc_wwmk180119p00044%3Achatbotsinhr#GUID-69850C6E-2E8F-4F2F-A95E-7A2ECDEB067C


####### main code #######
RUN_DIR=$( cd $(dirname "$0")/.. ; pwd )
echo "RUN_DIR is $RUN_DIR"
CONDA_ENV="BANE"

DB_FILES_DIR=$RUN_DIR/db_files

cd $RUN_DIR 
eval "$(conda shell.bash hook)"
conda activate $CONDA_ENV
# export TNS_ADMIN="/home/ubuntu/myadbwallet/tls_wallet/"  <== local adb 
export TNS_ADMIN="/home/ubuntu/fu30wallet/"

echo " <  clearing files from $DB_FILES_DIR  > "
rm -rf $DB_FILES_DIR 

echo "==============================================="
echo "   < Running Step 1/3 > " 
echo "==============================================="
python -u StepTom01_ExtractMedia.py
if [[ $? -ne 0  ]]; then 
    printf " [ ******* Step 1 failed ********* ] \n"
    exit 1 
fi 

echo "==============================================="
echo "   < Running Step 2/3 > " 
echo "==============================================="
python -u Step02_MatchMedia.py 
if [[ $? -ne 0  ]]; then 
    printf " [ Step 2 failed ] \n"
    exit 1 
fi

echo "==============================================="
echo "   < Running Step 3/3 > " 
echo "==============================================="
python -u Step03_ExportNetwork.py
if [[ $? -ne 0  ]]; then 
    printf " [ Step 3 failed ] \n"
    exit 1 
fi