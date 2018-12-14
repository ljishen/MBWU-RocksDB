#!/usr/bin/env bash

set -eu -o pipefail

if [ "$#" -ne 3 ]; then
    cat <<-ENDOFMESSAGE
This script appends IO accounting information for a specific process to file.

Usage: $0 PID_FILE OUTPUT_FILE INTERVAL_IN_SECS

PID_FILE:
    The file contains the identification number of the task to be monitored.

OUTPUT_FILE:
    The file the IO accounting information to be printed to.

INTERVAL_IN_SECS:
    The interval between each append.

1. This script may require privilege escalation on some systems.
2. The exit status is 1 if the PID does not exist and 0 otherwise.

See section 3.3 /proc/<pid>/io - Display the IO accounting fields
from https://www.kernel.org/doc/Documentation/filesystems/proc.txt
ENDOFMESSAGE
    exit 1
fi

PID_FILE="$1"
PID="$(cat "$PID_FILE")"
OUTPUT_FILE="$2"
INTERVAL_IN_SECS="$3"

if [ ! -f /proc/"$PID"/io ]; then
    printf "PID %s does not exist!\\n" "$PID"
    exit 1
fi

rm --force "$OUTPUT_FILE"
printf "Recording IO accounting information for PID %s ... Hit Ctrl-C to end.\\n" "$PID"

while [ -f /proc/"$PID"/io ]; do
    info=["$(date --iso-8601=seconds)"]$'\n'"$(cat /proc/"$PID"/io)"$'\n'
    echo "$info" >> "$OUTPUT_FILE"
    sleep "$INTERVAL_IN_SECS"
done || true
