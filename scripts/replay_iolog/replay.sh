#!/bin/bash

set -eu -o pipefail

if [ "$#" -lt 1 ]; then
    cat <<-ENDOFMESSAGE
Usage: $0 FOLDER DEVICE

FOLDER:
    This is the workload folder that contains all the iolog files that are
    used to replay.

DEVICE:
    This is the device that all IOP in the iolog will be redirected to.
    See replay_redirect [https://fio.readthedocs.io/en/latest/fio_man.html#cmdoption-arg-replay-redirect]
ENDOFMESSAGE
    exit
fi

if [[ $EUID -ne 0 ]]; then
    echo "this script must be run as root."
    exit 1
fi

# by default it uses the version of fio that the system has installed.
fio_bin="${FIO_BIN:-fio}"

if ! command -v "$fio_bin"; then
    echo "fio not found. Use env the FIO_BIN to specify the path of it."
    exit 2
fi

workload_folder="$1"

# the device in fullname, e.g. /dev/sdb
redirected_device="$2"

if [ ! -d "$workload_folder" ]; then
    echo "folder $workload_folder does not exist!"
    exit 2
fi

if [ ! -b "$redirected_device" ]; then
    echo "device $redirected_device does not exist!"
    exit 2
fi

purge_script=/tmp/blkerasediscard.sh
curl -o "$purge_script" -fsSL https://raw.githubusercontent.com/ljishen/SSSPT/master/playbooks/roles/common/files/blkerasediscard.sh
chmod +x "$purge_script"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

output_dir="${OUTPUT_DIR:-"$SCRIPT_DIR"/output}"
mkdir --parents "$output_dir"
echo "Output directory: $output_dir"

# get the number of rounds that have record in the folder
num_rounds="$(find "$workload_folder" -name 'blkstat_load_round*_issue.bin' | wc -l)"

# get the first round number in the steady state window
MEASUREMENT_WINDOW_SIZE=5
start_round="$(( num_rounds - MEASUREMENT_WINDOW_SIZE + 1 ))"

function kill_iostat() {
    echo "$cur_round: clean remnant iostat process"
    pkill -SIGTERM iostat
}

function do_replay() {
    phase="$1"

    job_file="$output_dir"/"$phase"_round"$r".fio
    iolog="$workload_folder"/blkstat_"$phase"_round"$r"_issue.bin

    echo "$cur_round: generate fio job file for $phase phase"
    sed -e "s#{{ redirected_device }}#$redirected_device#" -e "s#{{ iolog }}#$iolog#" "$SCRIPT_DIR"/job.fio > "$job_file"

    echo "$cur_round: replay $phase I/O patterns ..."
    "$fio_bin" "$job_file" --output-format=json+ --output "$output_dir"/"$phase"_round"$r".json
}

iostat_interval_secs="${IOSTAT_INTERVAL_SECS:-3}"

for r in $(seq "$start_round" "$num_rounds"); do
    cur_round="round $r"

    kill_iostat

    echo "$cur_round: purge device $redirected_device ..."
    "$purge_script" "$redirected_device"

    echo "$cur_round: run workload independent pre-conditioning on $redirected_device ..."
    "$fio_bin" "$workload_folder"/wipc.fio --output-format=json+ --output "$output_dir"/wipc_round"$r".json

    echo "$cur_round: start iostat log"
    nohup stdbuf -oL -eL iostat -dktxyzH -g "$redirected_device" "$redirected_device" "$iostat_interval_secs" < /dev/null > iostat_round"$r".log 2>&1 &

    do_replay load
    do_replay transactions
done

kill_iostat

echo "done!"