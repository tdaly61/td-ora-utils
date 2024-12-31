#!/usr/bin/env bash
# run BANE python client most likely against Oracle ADB in a container 
# Tom Daly : Nov 2023 
# see : https://github.com/oracle/adb-free and also 
#       https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/autonomous-docker-container.html?source=%3Aex%3Anc%3A%3A%3Arc_wwmk180119p00044%3Achatbotsinhr#GUID-69850C6E-2E8F-4F2F-A95E-7A2ECDEB067C

function print_db_counts {  
  # eval "$(conda shell.bash hook)"
  # conda activate $CONDA_ENV
  # cd $BANE_DIR 
  python $RUN_DIR/dbstats.py
}

timer() {
  start=$1
  stop=$2
  elapsed=$((stop - start))
  echo $elapsed
}

function print_stats {
  # print out all the elapsed times in the timer_array
  printf "\n********* BANE run stats *******************************\n"


  echo "major processing times :"
  for key in "${!timer_array[@]}"; do
    echo "    $key: ${timer_array[$key]} seconds"
  done
  printf "\n************ BANE run stats ******************************\n"
}

function run_step () { 
  step=$1
  msg=$2
  echo "==============================================="
  echo "   < $2 > " 
  echo "==============================================="
  python -u $RUN_DIR/$step 
  if [[ $? -ne 0  ]]; then 
      printf " [ processing failed at: $step  ] \n"
      exit 1 
  fi
} 

############## main code ################
RUN_DIR=$( cd $(dirname "$0")/.. ; pwd )
echo "RUN_DIR is $RUN_DIR"
CONDA_ENV="BANE"

DB_FILES_DIR=$RUN_DIR/db_files

cd $RUN_DIR 
eval "$(conda shell.bash hook)"
conda activate $CONDA_ENV
# export TNS_ADMIN="/home/ubuntu/myadbwallet/tls_wallet/"  <== local adb 
export TNS_ADMIN="/home/ubuntu/fu40wallet/"

# # only run if not in docker container
if [[ -z ${BANE_TOTAL_CONTAINERS}  ]]; then 
  echo " <  $0 clearing files from $DB_FILES_DIR  > "
  rm -rf $DB_FILES_DIR  
  run_step prepare-db.py " preparing database (assuming no docker) " 
fi 


declare -A timer_array
tstart=$(date +%s)

#run_step Tom01a_ExtractMedia.py "Running Step 1/3" 
run_step Step01_ExtractMedia.py "Running Step 1/3" 
# only run if not in docker container
if [[ -z ${BANE_TOTAL_CONTAINERS}  ]]; then 
  run_step Step02_MatchMedia.py  "Running Step 2/3" 
  run_step Step03_ExportNetwork.py  "Running Step 3/3" 
fi 


tstop=$(date +%s)
telapsed=$(timer $tstart $tstop)
timer_array[bane_single]=$telapsed
if [[ -z ${BANE_TOTAL_CONTAINERS}  ]]; then 
  print_stats
  sleep 5 
  print_db_counts
fi 
###################################################