#!/bin/bash

set -eu -o pipefail

# size constants
K=1024
# shellcheck disable=SC2034
M=$(( 1024 * K ))
# shellcheck disable=SC2034
G=$(( 1024 * M ))

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

# Make sure that it has to be the strictly specified mountpoint of the
# target device.
mountpoint="${MOUNTPOINT:-/mnt/sda1}"

data_dir="$mountpoint"/rocksdb_data

num_keys="${NUM_KEYS:-$(( 10 * M ))}"
key_size="${KEY_SIZE:-16}"
value_size="${VALUE_SIZE:-$(( 4 * K ))}"

REPO_DIR="$(realpath "$SCRIPT_DIR"/..)"
OUTPUT_BASE="$REPO_DIR"/analysis/data/db_bench

DB_BENCH_LOG="$OUTPUT_BASE"/db_bench.log
BLKSTAT_LOG="$OUTPUT_BASE"/blkstat.dat

BLKSTAT_PIDFILE=blkstat.pid

DISKSTATS_LOG_B="$OUTPUT_BASE"/diskstats_b.log     # log the before stats
DISKSTATS_LOG_A="$OUTPUT_BASE"/diskstats_a.log     # log the after stats

device_fullname="$(findmnt --noheadings --output SOURCE --mountpoint "$mountpoint" || true)"
if [ -n "$device_fullname" ]; then
    device_info="$("$REPO_DIR"/playbooks/roles/run/files/devname2id.sh "$device_fullname")"
    pdevice_fullname="$(echo "$device_info" | head -1)"
    pdevice_id="$(echo "$device_info" | tail -1)"

    notice="$(cat <<-ENDOFNOTICE
Please make sure that the current git repository:
    $REPO_DIR
does NOT reside in any partition of device $pdevice_fullname
ENDOFNOTICE
)"
else
    notice="$(cat <<-ENDOFNOTICE
[Error] Unable to detect the source device of mountpoint '$mountpoint'.

Please make sure '$mountpoint' is the strictly specified mountpoint of the
target device. If not, change it with env MOUNTPOINT.
ENDOFNOTICE
)"
fi

if [ "$#" -lt 1 ]; then
    cat <<-ENDOFMESSAGE
Usage: $0 [--trace_blk_rq] [--backup] BENCHMARK [DB_BENCH_OPTIONS]

This script must be run as root.

BENCHMARK:
    Currently available benchmarks:
        fillseq, readrandom, readrandommergerandom, mergerandom.
    It could also be any of these meta operations on an existing db:
        stats, levelstats, sstables, count_only.

    fillseq:
        Fill num_keys sequential key in async mode with 1 thread.

    readrandom:
        Read operation_keys_ratio% of num_keys from the existing db.

        This workload is similar to the YCSB workloadc. The only difference is
        that the distribution of the selected keys is uniform distribution
        instead of zipfian distribution that used in YCSB.

    readrandommergerandom:
        Read or merge operation_keys_ratio% of num_keys from the existing db
        under merge_read_ratio (default 50/50).

        You can use a different merge operator as opposed to the default 'put'
        by appending db_bench option '-merge_operator' to the command line, but
        be sure to fill a fresh db with this operator first and run the
        benchmark only on this new db.

        This workload is similar to the YCSB workloada or workloadb (by
        changing the merge_read_ratio=5) with two major differences. The first
        one is that the distribution of the selected keys is uniform
        distribution instead of zipfian distribution that used in YCSB. The
        other difference is that the atomic guarantee of the read-modify-write
        is handled by the RocksDB merge operator instead of YCSB by the client.

    mergerandom:
        Similar to readrandommergerandom except that it's all merge.

--trace_blk_rq:
    Trace the ftrace event block_rq_[issue|complete] during benchmarking.

--backup:
    Backup the output files to a time stamped folder under
    $OUTPUT_BASE

DB_BENCH_OPTIONS:
    Any extra options that supported by the db_bench tool, e.g. options that
    overwrite the existing ones.

-------------------------------------------------------------------------------
IMPORTANT NOTICE:
$(sed 's/^/    /' <<< "$notice")

REQUIRED ENVIRONMENT VARIABLES:
    ROCKSDB_DIR=${ROCKSDB_DIR:-undefined}
    MOUNTPOINT=${MOUNTPOINT:-$mountpoint}
ENDOFMESSAGE
    exit
fi

if [[ $EUID -ne 0 ]]; then
    echo "this script must be run as root."
    exit 1
fi

if [[ -z "${ROCKSDB_DIR+"check"}" ]]; then
    echo "please set ROCKSDB_DIR before running."
    exit 1
fi

if [ -z "$device_fullname" ]; then
    echo "$notice"
    exit 1
fi

db_bench_exe="$ROCKSDB_DIR"/db_bench
if [ ! -f "$db_bench_exe" ]; then
    echo "please check if ROCKSDB_DIR ($ROCKSDB_DIR) is correct and also to \
make sure the source code is proper compiled to generate the 'db_bench'
program."
    exit 1
fi

daemon_report_interval_sec="${DAEMON_REPORT_INTERVAL_SEC:-3}"

declare -A daemon_commands=(
    [iostat]="iostat -dktxyzH -g $device_fullname $daemon_report_interval_sec"
    [mpstat]="mpstat -P ALL $daemon_report_interval_sec"
    [pidstat]="pidstat -G db_bench -ult $daemon_report_interval_sec"
)

for daemon in "${!daemon_commands[@]}"; do
    if ! command -v "$daemon" &> /dev/null; then
        echo "program '$daemon' is not available in this bash environment."
        echo "if you are on Ubuntu, you can run 'apt-get install sysstat'."
        exit 1
    fi
done

do_trace_blk_rq=false
if [[ $* == *"--trace_blk_rq "* ]]; then
    do_trace_blk_rq=true
fi

if [ "$do_trace_blk_rq" = true ] && ! command -v trace-cmd &> /dev/null; then
    echo "program 'trace-cmd' is not available in this bash environment."
    exit 1
fi

mkdir --parents "$OUTPUT_BASE"

for (( i=1; i<=$#; i++ )); do
    arg="${!i}"
    if [[ $arg != -* ]]; then
        run_benchmark="$arg"
        db_bench_extra_options=("${@:$(( i + 1 ))}")
        break
    fi
done

if [[ -z "${run_benchmark+"check"}" ]]; then
    echo "which benchmark do you want to run?"
    exit 1
fi

# Check if an item is in a bash array
#   https://unix.stackexchange.com/a/177589
declare -a non_benchmarks=(
    stats levelstats sstables count_only
)
declare -A non_benchmarks_map
for key in "${!non_benchmarks[@]}"; do
    non_benchmarks_map[${non_benchmarks[$key]}]="$key"
done

if [[ -n "${non_benchmarks_map[$run_benchmark]+"check"}" ]]; then
    if [ "$run_benchmark" = "count_only" ]; then
        eval "$ROCKSDB_DIR/ldb --db=$data_dir dump --count_only"
    else
        eval "$db_bench_exe \
                --db=$data_dir \
                --use_existing_db=1 \
                --benchmarks=$run_benchmark"
    fi
    exit 0
fi


num_threads="${NUM_THREADS:-1}"

# The percentage of all keys in the db to be used in the
# operation (read/write/merge)
operation_keys_ratio="${OPERATION_KEYS_RATIO:-100}"

# When 0 it is deterministic.
seed="${SEED:-$( date +%s )}"

vars_to_print=(seed)

if [ "$run_benchmark" = "fillseq" ]; then
    rm -rf "$data_dir" && mkdir --parents "$data_dir"
    num_threads=1
    db_bench_command="--use_existing_db=0 \
        --num=$num_keys \
        --seed=$seed"
elif [ "$run_benchmark" = "readrandom" ]; then
    vars_to_print+=(operation_keys_ratio)
    db_bench_command="--use_existing_db=1 \
        --readonly=1 \
        --num=$num_keys \
        --reads=$(( num_keys * operation_keys_ratio / 100 / num_threads )) \
        --seed=$seed"
elif [ "$run_benchmark" = "readrandommergerandom" ] || \
     [ "$run_benchmark" = "mergerandom" ]; then
    vars_to_print+=(operation_keys_ratio)

    db_bench_command="--use_existing_db=1 \
        --merge_keys=$num_keys \
        --merge_operator='put' \
        --num=$(( num_keys * operation_keys_ratio / 100 / num_threads )) \
        --seed=$seed"

    if [ "$run_benchmark" = "readrandommergerandom" ]; then
        # e.g. 70 means 70% out of all read and merge operations are merges
        merge_read_ratio="${MERGE_READ_RATIO:-50}"

        vars_to_print+=(merge_read_ratio)

        db_bench_command="$db_bench_command \
            --mergereadpercent=$merge_read_ratio"
    fi
else
    echo "benchmark '$run_benchmark' is not found!"
    exit 1
fi

num_vcpus="$(nproc)"

# See RocksDB options files
#   https://github.com/facebook/rocksdb/blob/master/include/rocksdb/options.h
#   https://github.com/facebook/rocksdb/blob/master/options/options.cc
#   https://github.com/facebook/rocksdb/blob/master/include/rocksdb/advanced_options.h
#   https://github.com/facebook/rocksdb/blob/master/tools/db_bench_tool.cc
#
# We didn't use '-options_file' provided by db_bench because it limits the
# change of some options (e.g. '-merge_operator') no matter from within the
# options file or through the command line.
#
# Options are categorized into the follow 2 sections:
#   Part 1: db_bench options;
#   Part 2: options for optimizing level style compaction to make it compatible
#           with the options generated by YCSB.
db_bench_command="( time \
    $db_bench_exe \
    --benchmarks=$run_benchmark \
    --db=$data_dir \
    --key_size=$key_size \
    --value_size=$value_size \
    --threads=$num_threads \
    --disable_wal=0 \
    --stats_per_interval=1 \
    --stats_interval_seconds=60 \
    --histogram=1 \
    \
    --enable_pipelined_write=true \
    --delayed_write_rate=$(( 16 * M )) \
    --wal_dir=$data_dir \
    --table_cache_numshardbits=6 \
    --dump_malloc_stats=true \
    --new_table_reader_for_compaction_inputs=false \
    --compression_type=lz4 \
    --max_write_buffer_number=24 \
    --fifo_compaction_allow_compaction=false \
    --fifo_compaction_max_table_files_size_mb=$(( 1 * K )) \
    --num_levels=7 \
    --block_size=$(( 8 * K )) \
    --bytes_per_sync=$(( 1 * M )) \
    --soft_pending_compaction_bytes_limit=$(( 64 * G )) \
    --hard_pending_compaction_bytes_limit=$(( 256 * G )) \
    --max_background_jobs=$num_vcpus \
    --max_background_flushes=$num_vcpus \
    --max_background_compactions=$num_vcpus \
    --subcompactions=4 \
    --min_level_to_compress=2 \
    --max_bytes_for_level_base=$(( 2 * 2 * 128 * M )) \
    --level0_file_num_compaction_trigger=2 \
    --write_buffer_size=$(( 128 * M )) \
    --min_write_buffer_number_to_merge=2 \
    --max_compaction_bytes=$(( 25 * 64 * M )) \
    --level0_slowdown_writes_trigger=20 \
    --level0_stop_writes_trigger=36 \
    --target_file_size_base=$(( 64 * M )) \
    \
    $db_bench_command \
    ${db_bench_extra_options[*]+"${db_bench_extra_options[*]}"} \
    ) \
    2>&1 | tee -a $DB_BENCH_LOG"


function format_spaces() {
    # replace multiple spaces with one space
    #   https://stackoverflow.com/a/50259880
    echo "$1" | tr --squeeze-repeats ' '
}

function newline_print() {
    local str
    str="$(format_spaces "$1")"
    printf '\n[INFO | %s] %s\n' "$(date +"%F %T,%3N")" "$str" | tee -a "$DB_BENCH_LOG"
}

function print_separator() {
    (for _ in $(seq 80); do printf "="; done; echo) | tee -a "$DB_BENCH_LOG"
}

function print_var() {
    local val
    val="$(format_spaces "${!1}")"
    echo "$1=$val" | tee -a "$DB_BENCH_LOG"
}

# Make room for logging the current benchmark if the "$DB_BENCH_LOG"
# already exists.
if [ -f "$DB_BENCH_LOG" ]; then
    printf '\n\n\n' | tee -a "$DB_BENCH_LOG"
fi

start_date="$(date +%F_%T)"
newline_print "start benchmark $run_benchmark at $start_date"
vars_to_print+=(
    data_dir
    device_fullname
    pdevice_fullname
    daemon_report_interval_sec
    db_bench_command)

print_separator
for v in "${vars_to_print[@]}"; do
    print_var "$v"
done
print_separator

newline_print "configuring scaling governor to performance for online CPUs"
"$REPO_DIR"/playbooks/roles/setup/files/config_cpu.sh performance \
    | tee -a "$DB_BENCH_LOG"

# https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/5/html/tuning_and_optimizing_red_hat_enterprise_linux_for_oracle_9i_and_10g_databases/chap-oracle_9i_and_10g_tuning_guide-setting_shell_limits_for_the_oracle_user
nofile_soft_limit=63536
newline_print "set the nofile soft limit to $nofile_soft_limit"
ulimit -Sn "$nofile_soft_limit"

function cleanup_daemons() {
    for daemon in "${!daemon_commands[@]}"; do
        daemon_pid="$daemon".pid
        if [ -f "$daemon_pid" ]; then
            newline_print "stopping $daemon daemon"

            sig="SIGINT"
            if [ "$daemon" = "iostat" ]; then
                # iostat can only be stopped by SIGTERM
                sig="SIGTERM"
            fi

            # The exit code is not 0 if the PID in pidfile is not found.
            pkill --signal "$sig" --pidfile "$daemon_pid" || true

            rm "$daemon_pid"
        fi
    done

    if [ -f "$BLKSTAT_PIDFILE" ]; then
        newline_print "stopping blkstat daemon"
        pkill -SIGINT --pidfile "$BLKSTAT_PIDFILE" &> /dev/null || true

        newline_print "pause 20 seconds to wait for the tracer to finish..."
        sleep 20

        rm "$BLKSTAT_PIDFILE"
    fi
}
trap cleanup_daemons EXIT

cleanup_daemons

function get_daemon_log() {
    daemon="$1"
    echo "$OUTPUT_BASE"/"$daemon".log
}

for daemon in "${!daemon_commands[@]}"; do
    daemon_cmd="S_TIME_FORMAT=ISO nohup stdbuf -oL -eL \
        ${daemon_commands[$daemon]} \
        < /dev/null > $(get_daemon_log "$daemon") 2>&1 &"
    newline_print "$daemon command: $daemon_cmd"

    eval "$daemon_cmd"
    daemon_pid="$daemon".pid
    echo $! > "$daemon_pid"
    newline_print "$daemon daemon is running (PID=$(cat "$daemon_pid"))"
done

newline_print "freeing the slab objects and pagecache"
sync; echo 3 > /proc/sys/vm/drop_caches

if [ "$do_trace_blk_rq" = true ]; then
    trace-cmd reset

    blk_trace_cmd="nohup trace-cmd record \
        -o $BLKSTAT_LOG \
        --date \
        -e block:block_rq_issue \
        -f 'dev == $pdevice_id' \
        -e block:block_rq_complete \
        -f 'dev == $pdevice_id' \
        < /dev/null > nohup.out 2>&1 &"
    newline_print "block events tracer command: $blk_trace_cmd"

    eval "$blk_trace_cmd"
    echo $! > "$BLKSTAT_PIDFILE"
    newline_print "starting to trace the block events for device $pdevice_fullname (PID=$(cat $BLKSTAT_PIDFILE))"

    newline_print "pause 7 seconds to wait for the tracer to start..."
    sleep 7
fi

pdevice_name="$(basename "$pdevice_fullname")"

newline_print "saving stats for disk $pdevice_fullname (before)"
grep "$pdevice_name" /proc/diskstats > "$DISKSTATS_LOG_B"

echo | tee -a "$DB_BENCH_LOG"
eval "$db_bench_command"

newline_print "saving stats for disk $pdevice_fullname (after)"
sync; grep "$pdevice_name" /proc/diskstats > "$DISKSTATS_LOG_A"

cleanup_daemons

if [ "$do_trace_blk_rq" = true ]; then
    if command -v gzip &> /dev/null; then
        BLKSTAT_LOG_GZ="${BLKSTAT_LOG}".gz
        newline_print "compressing the output from block event tracer to ${BLKSTAT_LOG_GZ}"
        gzip --force --keep --name "${BLKSTAT_LOG}"
    else
        newline_print "did not compress the output from block event tracer \
            because the program 'gzip' is not found."
    fi

    IOSZDIST_LOG="$OUTPUT_BASE"/ioszdist.log
    newline_print "generating I/O size distribution to $IOSZDIST_LOG"
    "$REPO_DIR"/playbooks/roles/run/files/ioszdist.sh "$BLKSTAT_LOG" | tee "$IOSZDIST_LOG"
    rm "$OUTPUT_BASE"/events.dat "$OUTPUT_BASE"/sectors.dat
fi

if [[ $* == *"--backup "* ]]; then
    backup_dir="$OUTPUT_BASE"/"$start_date"
    newline_print "backuping files to dir $backup_dir"
    mkdir "$backup_dir"

    cp "$data_dir"/LOG "$backup_dir"
    cp "$(find "$data_dir" -name "OPTIONS-*" -type f | sort | tail -1)" "$backup_dir"/OPTIONS

    mv "$DB_BENCH_LOG" \
        "$DISKSTATS_LOG_B" \
        "$DISKSTATS_LOG_A" \
        "$backup_dir"

    for daemon in "${!daemon_commands[@]}"; do
        mv "$(get_daemon_log "$daemon")" "$backup_dir"
    done

    if [ "$do_trace_blk_rq" = true ]; then
        mv "$BLKSTAT_LOG" "$IOSZDIST_LOG" "$backup_dir"

        if [[ -n "${BLKSTAT_LOG_GZ+"check"}" ]]; then
            mv "$BLKSTAT_LOG_GZ" "$backup_dir"
        fi
    fi
fi
