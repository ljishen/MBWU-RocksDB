#!/usr/bin/env bash

set -eu -o pipefail

if [ "$#" -ne 1 ]; then
    cat <<-ENDOFMESSAGE
Usage: ./config_cpu.sh SCALING_GOVERNOR

Set the scaling governor specified by SCALING_GOVERNOR for all online CPUs.

This script must be run as root!

To see more detail:
https://www.kernel.org/doc/Documentation/cpu-freq/user-guide.txt
https://www.kernel.org/doc/Documentation/cpu-freq/governors.txt
ENDOFMESSAGE
    exit
fi

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root!"
    exit 1
fi

BASE_DIR="/sys/devices/system/cpu"

# convert the content in file /sys/devices/system/cpu/online to an array
online_line="$(cat "$BASE_DIR"/online)"

TIFS=","

IFS="$TIFS" read -ra online <<< "$online_line"
online_cpus=()
for c in "${online[@]}"; do
    if [[ "$c" == *-* ]]; then
        start="${c%-*}"
        end="${c#*-}"
        IFS="$TIFS" read -ra seq_cpus <<< "$(seq -s "$TIFS" "$start" "$end")"
    else
        seq_cpus=("$c")
    fi

    online_cpus+=("${seq_cpus[@]}")
done

# check if an element in the input array
function contains() {
    local array="$1[@]"
    local seek="$2"
    for element in "${!array}"; do
        if [[ "$element" == "$seek" ]]; then
            return 0
        fi
    done
    return 1
}

gov="$1"

for c in "${online_cpus[@]}"; do
    # shellcheck disable=SC2034
    IFS=" " read -ra available_govs <<< "$(cat "$BASE_DIR"/cpu"$c"/cpufreq/scaling_available_governors)"
    if ! contains available_govs "$gov"; then
        echo "The scaling governor '$gov' is not available for cpu$c!"
        exit 1
    fi

    echo "$gov" > "$BASE_DIR"/cpu"$c"/cpufreq/scaling_governor
done

echo "Successfully updated scaling governor for CPUs [$online_line]."
