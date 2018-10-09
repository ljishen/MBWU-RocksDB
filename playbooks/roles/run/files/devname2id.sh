#!/usr/bin/env bash

set -eu -o pipefail

if [ "$#" -ne 1 ]; then
    cat <<-ENDOFMESSAGE
Usage: $0 DEVICE_NAME

This script converts the device name of a partition to the device ID of its
parent held by the type dev_t, which can be then used to filter the device in
the block:* events in ftrace.

DEVICE_NAME:
    Note that this is the device name of a partition.

For example:
    $0 /dev/sda1

See
https://linux.die.net/man/3/minor
ENDOFMESSAGE
    exit
fi

device_name="$1"

pdevice_name=/dev/"$(lsblk --noheadings --output pkname "$device_name" | tail -1)"
major="$(stat --format '%t' "$pdevice_name")"
minor="$(stat --format '%T' "$pdevice_name")"

echo "$pdevice_name"

# See how to convert the major and minor numbers to the device ID:
#   https://github.com/brendangregg/perf-tools/blob/master/iolatency
echo "$(( (major << 20) + minor ))"
