#!/usr/bin/env bash

set -eu -o pipefail

if [ "$#" -ne 3 ]; then
    cat <<-ENDOFMESSAGE
This script appends IO accounting information for a specific process to file.

Usage: $0 PID OUTPUT_FILE INTERVAL_IN_SECS

PID:
    The identification number of the task to be monitored.

OUTPUT_FILE:
    The file the IO accounting information to be printed to.

INTERVAL_IN_SECS:
    The interval between each append.

This script may require privilege escalation on some system.

See section 3.3 /proc/<pid>/io - Display the IO accounting fields
from https://www.kernel.org/doc/Documentation/filesystems/proc.txt
ENDOFMESSAGE
    exit
fi

PID="$1"
OUTPUT_FILE="$2"
INTERVAL_IN_SECS="$3"

rm --force "$OUTPUT_FILE"
printf "Recording IO accounting information for PID %s ... Hit Ctrl-C to end.\\n" "$PID"

while true; do
    info=["$(date --iso-8601=seconds)"]$'\n'"$(cat /proc/"$PID"/io)"$'\n'
    echo "$info" >> "$OUTPUT_FILE"
    sleep "$INTERVAL_IN_SECS"
done
