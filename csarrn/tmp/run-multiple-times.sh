#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <script_to_run> <number_of_runs> <sleep_interval_seconds>"
    exit 1
fi

# Extract the arguments
script_to_run="$1"
number_of_runs="$2"
sleep_interval="$3"

# Run the script multiple times with a sleep interval
for ((i = 1; i <= number_of_runs; i++)); do
    echo " ========== start iteration $1 ====================="
    echo "Running $script_to_run (Iteration $i)"
    bash "$script_to_run"

    # Sleep for the specified interval
    sleep "$sleep_interval"
    echo " ========== end iteration $i  ====================="
done

echo "Script execution completed."
