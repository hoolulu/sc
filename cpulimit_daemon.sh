#!/bin/bash
# ==============================================================
# CPU limit daemon - set PID's max. percentage CPU consumptions
# ==============================================================
# Variables
CPU_LIMIT=25        # Maximum percentage CPU consumption by each PID
DAEMON_INTERVAL=3   # Daemon check interval in seconds
BLACK_PROCESSES_LIST="server_linux_am" # Limit only processes defined in this variable. If variable is empty (default) all violating processes are limited.
WHITE_PROCESSES_LIST=   # Limit all processes except processes defined in this variable. If variable is empty (default) all violating processes are limited.
# Check if one of the variables BLACK_PROCESSES_LIST or WHITE_PROCESSES_LIST is defined.
if [[ -n "$BLACK_PROCESSES_LIST" && -n "$WHITE_PROCESSES_LIST" ]] ; then    # If both variables are defined then error is produced.
   echo "At least one or both of the variables BLACK_PROCESSES_LIST or WHITE_PROCESSES_LIST must be empty."
   exit 1
elif [[ -n "$BLACK_PROCESSES_LIST" ]] ; then                                 # If this variable is non-empty then set NEW_PIDS_COMMAND variable to below command
   NEW_PIDS_COMMAND="ps -eo pid,comm | awk -v limit=$CPU_LIMIT '\$2 ~ BLACK_PROCESSES_LIST {print \$1}' BLACK_PROCESSES_LIST=$BLACK_PROCESSES_LIST CPU_LIMIT=$CPU_LIMIT"
elif [[ -n "$WHITE_PROCESSES_LIST" ]] ; then                                 # If this variable is non-empty then set NEW_PIDS_COMMAND variable to below command
   NEW_PIDS_COMMAND="ps -eo pid,comm | awk -v limit=$CPU_LIMIT '\$2 !~ WHITE_PROCESSES_LIST {print \$1}' WHITE_PROCESSES_LIST=$WHITE_PROCESSES_LIST CPU_LIMIT=$CPU_LIMIT"
else
   NEW_PIDS_COMMAND="ps -eo pid,comm | awk -v limit=$CPU_LIMIT '\$2 ~ /.*/ {print \$1}' CPU_LIMIT=$CPU_LIMIT"
fi
# Search and limit violating PIDs
while sleep $DAEMON_INTERVAL
do
   NEW_PIDS=$(eval "$NEW_PIDS_COMMAND")                                                                    # Violating PIDs
   LIMITED_PIDS=$(ps -eo args | awk '$1=="cpulimit" {print $3}')                                          # Already limited PIDs
   QUEUE_PIDS=$(comm -23 <(echo "$NEW_PIDS" | sort -u) <(echo "$LIMITED_PIDS" | sort -u) | grep -v '^$')   # PIDs in queue
   for i in $QUEUE_PIDS
   do
       cpulimit -p $i -l $CPU_LIMIT -z &   # Limit new violating processes
   done
done
