#!/usr/bin/env bash

set -eu -o pipefail

if [ "$#" -lt 2 ]; then
    cat <<-ENDOFMESSAGE
This script gets the energy usage from TP-Link HS110 by polling the energy API.

Usage: $0 tplink_smartplug_repo_path ip [log_file_path] [poll_interval_in_secs]

tplink_smartplug_repo_path:
    Required. This is the path of git clone repo
        https://github.com/softScheck/tplink-smartplug

ip:
    Required. The IP address of the TP-Link HS110 device.

log_file_path:
    Optional. The file path that the energy log will be appended to.
    The default file is energy.log in the current dir.

poll_interval_in_secs:
    Optional. The frequency in seconds that the energy API will be polled.
    The default polling interval is 5 seconds.
ENDOFMESSAGE
    exit
fi

# See how to remove the trailing "/" characters
#   https://stackoverflow.com/a/3352015
tplink_smartplug_script="${1%"${1##*[!/]}"}"/tplink_smartplug.py

if [ ! -f "$tplink_smartplug_script" ]; then
    printf "[Error] script %s is not found!\\n\\n" "$tplink_smartplug_script"
    printf "Please double check if tplink_smartplug_repo_path points to the root\\n\
of repo tplink-smartplug (https://github.com/softScheck/tplink-smartplug).\\n"
    exit 1
fi

ip="$2"
echo "check if IP $ip is reachable ..."
if ! ping -c 1 "$ip" &> /dev/null; then
    printf "[Error] IP address %s is not reachable!\\n\\n" "$ip"
    exit 2
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
log_file_path="$SCRIPT_DIR"/energy.log
if [ "$#" -gt 2 ]; then
    log_file_path="$3"
fi
echo "[log_file_path] $log_file_path"

poll_interval_in_secs=5
if [ "$#" -gt 3 ]; then
    poll_interval_in_secs="$4"
    if [[ $poll_interval_in_secs == -* ]]; then
        printf "[Error] the poll_interval_in_secs cannot be negative!\\n\\n"
        exit 3
    fi
fi

echo
printf "Start polling the energy usage from TP-Link HS110 (%s) every %d seconds ... \
Hit Ctrl-C to end.\\n\\n" "$ip" "$poll_interval_in_secs" | tee "$log_file_path"

function pre_exit() {
    printf "\\npolling has stopped.\\n"
}
trap pre_exit EXIT

while true; do
    output="$( ("$tplink_smartplug_script" -t "$ip" -c energy | tail -1) 2>&1 )"
    exit_status="$?"
    if [[ "$exit_status" != 0 ]]; then
        printf "[Error] unable to poll from $ip: %s\\n\\n" "$output"
        exit 4
    fi
    echo "[$(date --iso-8601=seconds)] ${output##* }" | tee --append "$log_file_path"
    sleep "$poll_interval_in_secs"
done
