#!/usr/bin/env bash

set -eu -o pipefail

if [ "$#" -ne 1 ]; then
    cat <<-ENDOFMESSAGE
This script generates a summary of the distribution of the I/O size.

Usage: $0 BLKPARSE_TXT_FILE

BLKPARSE_TXT_FILE:
    The file is the output (specified by option '--output') from BLKPARSE(1) command.


Note that the "sectors" in result are the standard UNIX 512-byte sectors,
not any device- or filesystem-specific block size. See
https://www.kernel.org/doc/Documentation/block/stat.txt
https://github.com/brendangregg/perf-tools/blob/master/disk/bitesize
ENDOFMESSAGE
    exit
fi

blkparse_txt_file="$1"
blkparse_txt_file_dir="$( cd "$( dirname "$blkparse_txt_file" )" >/dev/null && pwd )"
sectors_file="$blkparse_txt_file_dir"/sectors.dat

echo "Extracting RWBS and sectors to $sectors_file"
sed -nr 's/^.+ +([[:upper:]]+).+\+ +([[:digit:]]+).+$/\1 \2/ p' "$blkparse_txt_file" > "$sectors_file"

echo "Parsing results..."

declare -A buckets_read=()
declare -A buckets_write=()

reads=0
writes=0
read_sectors=0
write_sectors=0

while IFS='' read -r line || [[ -n "$line" ]]; do
    rwbs="${line%% *}"
    sectors="${line#* }"
    if [[ $rwbs == *R* ]]; then
        buckets_read[$sectors]="$(( ${buckets_read[$sectors]:-0} + 1 ))"
        read_sectors="$(( read_sectors + sectors ))"
        (( reads += 1 ))
    else
        buckets_write[$sectors]="$(( ${buckets_write[$sectors]:-0} + 1 ))"
        write_sectors="$(( write_sectors + sectors ))"
        (( writes += 1 ))
    fi

done < "$sectors_file"

function printSeparator() {
    for _ in $(seq 70); do
        printf '-'
    done
    echo
}

printf '\n%-11s   %-2s   %-11s   %-14s   %-15s\n' \
       SECTOR_SIZE \
       RW \
       COUNT \
       "RATIO (in R/W)" \
       "RATIO (Overall)"
printSeparator

total_ios="$(( reads + writes ))"

function printTable() {
    eval "declare -A buckets=${1#*=}"
    rw="$2"

    if [ "$rw" = "R" ]; then
        cat_ios="$reads"
    else
        cat_ios="$writes"
    fi

    # shellcheck disable=SC2154
    for sectors in "${!buckets[@]}"; do
        printf '%-11d   %-2s   %-11d   %13.3f%%   %14.3f%%\n' \
               "$sectors" \
               "$rw" \
               "${buckets[$sectors]}" \
               "$(echo "${buckets[$sectors]}" / "$cat_ios * 100" | bc -l)" \
               "$(echo "${buckets[$sectors]}" / "$total_ios * 100" | bc -l)"
    done
}

# Pass associative array as an argument to a function
#   https://stackoverflow.com/a/8879444
(printTable "$(declare -p buckets_read)" R ; printTable "$(declare -p buckets_write)" W) | sort -rn -k3

printf '\n\n'

echo "SUMMARY (512-byte sectors)"
printSeparator

printf 'Total read I/Os : %-14d [%7.3f%%]' \
       "$reads" \
       "$(echo "$reads" / "$total_ios * 100" | bc -l)"
echo
printf 'Total write I/Os: %-14d [%7.3f%%]' \
       "$writes" \
       "$(echo "$writes" / "$total_ios * 100" | bc -l)"
echo

total_sectors="$(( read_sectors + write_sectors ))"
printf 'Total read sectors : %-11d [%7.3f%%, %11.3fMB]' \
       "$read_sectors" \
       "$(echo "$read_sectors" / "$total_sectors * 100" | bc -l)" \
       "$(echo "$read_sectors" / 2 / 1024 | bc -l)"
echo
printf 'Total write sectors: %-11d [%7.3f%%, %11.3fMB]' \
       "$write_sectors" \
       "$(echo "$write_sectors" / "$total_sectors * 100" | bc -l)" \
       "$(echo "$write_sectors" / 2 / 1024 | bc -l)"
echo
