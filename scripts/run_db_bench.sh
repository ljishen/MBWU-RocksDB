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
device_fullname="$(findmnt --noheadings --output SOURCE --mountpoint "$mountpoint")"

num_keys="${NUM_KEYS:-$(( 1 * M ))}"
key_size="${KEY_SIZE:-16}"
value_size="${VALUE_SIZE:-$(( 8 * K ))}"

REPO_DIR="$(realpath "$SCRIPT_DIR"/..)"
OUTPUT_BASE="$REPO_DIR"/analysis/data/db_bench

DB_BENCH_LOG="$OUTPUT_BASE"/db_bench.log
IOSTAT_LOG="$OUTPUT_BASE"/iostat.log
MPSTAT_LOG="$OUTPUT_BASE"/mpstat.log
BLKSTAT_LOG="$OUTPUT_BASE"/blkstat.dat

IOSTAT_PIDFILE=iostat.pid
MPSTAT_PIDFILE=mpstat.pid
BLKSTAT_PIDFILE=blkstat.pid

DISKSTATS_LOG_B="$OUTPUT_BASE"/diskstats_b.log     # log the before stats
DISKSTATS_LOG_A="$OUTPUT_BASE"/diskstats_a.log     # log the after stats

device_info="$("$REPO_DIR"/playbooks/roles/run/files/devname2id.sh "$device_fullname")"
pdevice_name="$(echo "$device_info" | head -1)"
pdevice_id="$(echo "$device_info" | tail -1)"

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

        This workload is similar to the YCSB workloada. The first difference is
        that the distribution of the selected keys is uniform distribution
        instead of zipfian distribution that used in YCSB. Another difference
        is that the atomic guarantee of the read-modify-write is handled by the
        RocksDB merge operator instead of YCSB by the client.

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
    Please make sure that the current git repository:
        $REPO_DIR
    does NOT reside in any partition of device $pdevice_name

REQUIRED ENVIRONMENT VARIABLE:
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

db_bench_exe="$ROCKSDB_DIR"/db_bench
if [ ! -f "$db_bench_exe" ]; then
    echo "please check if ROCKSDB_DIR ($ROCKSDB_DIR) is correct and also to \
make sure the source code is proper compiled to generate the 'db_bench'
program."
    exit 1
fi

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
operation_keys_ratio="${OPERATION_KEYS_RATIO:-75}"

vars_to_print=()

if [ "$run_benchmark" = "fillseq" ]; then
    rm -rf "$data_dir" && mkdir --parents "$data_dir"
    num_threads=1
    db_bench_command="--use_existing_db=0 \
        --num=$num_keys \
        --seed=$( date +%s )"
elif [ "$run_benchmark" = "readrandom" ]; then
    vars_to_print+=(operation_keys_ratio)
    db_bench_command="--use_existing_db=1 \
        --readonly=1 \
        --num=$num_keys \
        --reads=$(( num_keys * operation_keys_ratio / 100 / num_threads )) \
        --seed=$( date +%s )"
elif [ "$run_benchmark" = "readrandommergerandom" ] || \
     [ "$run_benchmark" = "mergerandom" ]; then
    vars_to_print+=(operation_keys_ratio)

    db_bench_command="--use_existing_db=1 \
        --merge_keys=$num_keys \
        --merge_operator='put' \
        --num=$(( num_keys * operation_keys_ratio / 100 / num_threads )) \
        --seed=$( date +%s )"

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
db_bench_command="$db_bench_exe \
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
    --enable_pipelined_write=false \
    --delayed_write_rate=$(( 16 * M )) \
    --wal_dir=$data_dir \
    --table_cache_numshardbits=6 \
    --max_background_compactions=$num_vcpus \
    --max_background_jobs=$num_vcpus \
    --dump_malloc_stats=true \
    --new_table_reader_for_compaction_inputs=false \
    --compression_type=snappy \
    --max_write_buffer_number=6 \
    --hard_pending_compaction_bytes_limit=$(( 256 * G )) \
    --fifo_compaction_allow_compaction=false \
    --fifo_compaction_max_table_files_size_mb=$(( 1 * K )) \
    --num_levels=7 \
    --block_size=$(( 8 * K )) \
    $db_bench_command \
    ${db_bench_extra_options[*]+"${db_bench_extra_options[*]}"} \
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

newline_print "start benchmark $run_benchmark at $(date)" | tee "$DB_BENCH_LOG"
vars_to_print+=(
    data_dir
    device_fullname
    pdevice_name
    db_bench_command)

print_separator
for v in "${vars_to_print[@]}"; do
    print_var "$v"
done
print_separator

pkill -SIGTERM --pidfile "$IOSTAT_PIDFILE" &> /dev/null || true
rm --force "$IOSTAT_PIDFILE"
nohup stdbuf -oL -eL iostat -dktxyzH -g "$device_fullname" 3 < /dev/null > "$IOSTAT_LOG" 2>&1 &
echo $! > "$IOSTAT_PIDFILE"
newline_print "iostat daemon is running (PID=$(cat $IOSTAT_PIDFILE))"

pkill -SIGTERM --pidfile "$MPSTAT_PIDFILE" &> /dev/null || true
rm --force "$MPSTAT_PIDFILE"
nohup stdbuf -oL -eL mpstat -P ALL 3 < /dev/null > "$MPSTAT_LOG" 2>&1 &
echo $! > "$MPSTAT_PIDFILE"
newline_print "mpstat daemon is running (PID=$(cat $MPSTAT_PIDFILE))"

newline_print "freeing the slab objects and pagecache"
sync; echo 3 > /proc/sys/vm/drop_caches

if [ "$do_trace_blk_rq" = true ]; then
    trace-cmd reset

    blk_trace_command="nohup trace-cmd record \
        -o $BLKSTAT_LOG \
        --date \
        -e block:block_rq_issue \
        -f 'dev == $pdevice_id' \
        -e block:block_rq_complete \
        -f 'dev == $pdevice_id' \
        < /dev/null > nohup.out 2>&1 &"
    newline_print "$blk_trace_command" | tee -a "$DB_BENCH_LOG"

    eval "$blk_trace_command"
    echo $! > "$BLKSTAT_PIDFILE"
    newline_print "starting the block events for device $pdevice_name (PID=$(cat $BLKSTAT_PIDFILE))"

    newline_print "pause 7 seconds to wait for the tracer to start..."
    sleep 7
fi

device_name="$(basename "$device_fullname")"

newline_print "saving stats for disk $device_fullname (before)"
grep "$device_name" /proc/diskstats > "$DISKSTATS_LOG_B"

echo | tee -a "$DB_BENCH_LOG"
eval "$db_bench_command"

newline_print "saving stats for disk $device_fullname (after)"
sync; grep "$device_name" /proc/diskstats > "$DISKSTATS_LOG_A"

newline_print "stopping iostat daemon"
pkill -SIGTERM --pidfile "$IOSTAT_PIDFILE" || true
rm --force "$IOSTAT_PIDFILE"

newline_print "stopping mpstat daemon"
pkill -SIGINT --pidfile "$MPSTAT_PIDFILE" || true
rm --force "$MPSTAT_PIDFILE"

if [ "$do_trace_blk_rq" = true ]; then
    newline_print "stopping blkstat daemon"
    pkill -SIGINT --pidfile "$BLKSTAT_PIDFILE" &> /dev/null || true

    newline_print "pause 20 seconds to wait for the tracer to finish..."
    sleep 20

    rm --force "$BLKSTAT_PIDFILE"

    if command -v gzip &> /dev/null; then
        BLKSTAT_LOG_GZ="${BLKSTAT_LOG}".gz
        newline_print "compressing the output from block event tracer to ${BLKSTAT_LOG_GZ}"
        gzip --force --keep --name "${BLKSTAT_LOG}"
    else
        newline_print "did not compress the output from block event tracer \
            because program 'gzip' is not found."
    fi

    IOSZDIST_LOG="$OUTPUT_BASE"/ioszdist.log
    newline_print "generating I/O size distribution to $IOSZDIST_LOG"
    "$SCRIPT_DIR"/ioszdist.sh "$BLKSTAT_LOG" | tee "$IOSZDIST_LOG"
    rm "$OUTPUT_BASE"/events.dat "$OUTPUT_BASE"/sectors.dat
fi

if [[ $* == *"--backup "* ]]; then
    backup_dir="$OUTPUT_BASE/$(date +%F_%T)"
    newline_print "backuping files to dir $backup_dir"
    mkdir "$backup_dir"
    mv "$DB_BENCH_LOG" \
        "$IOSTAT_LOG" \
        "$MPSTAT_LOG" \
        "$DISKSTATS_LOG_B" \
        "$DISKSTATS_LOG_A" \
        "$backup_dir"

    if [ "$do_trace_blk_rq" = true ]; then
        mv "$BLKSTAT_LOG" "$IOSZDIST_LOG" "$backup_dir"

        if [[ -n "${BLKSTAT_LOG_GZ+"check"}" ]]; then
            mv "$BLKSTAT_LOG_GZ" "$backup_dir"
        fi
    fi
fi
