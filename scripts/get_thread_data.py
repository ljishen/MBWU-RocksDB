#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# MIT License
#
# Copyright (c) 2020 Jianshen Liu<jliu120@ucsc.edu>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
"""Extract thread data points from a data folder.

The input data folder should include data only from a thread number.

Do NOT use this script on a folder that contains results from different
numbers of threads.

Example:
   $ ./get_thread_data.py ../data/ycsb/myworkloada/THNSNJ128G8NU/MBWU/2_threads

"""

import argparse
import datetime
import json
import re
import os
import statistics


def __get_round_idx(filename):
    return int(re.search(r"(?<=_round)\d+", filename).group(0))


DATE_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}:\d{3}")
THROUGHPUT_PATTERN = re.compile(r"Throughput\(ops/sec\), ([.\d]+)")

KEY_START_TIME = "start_time"
KEY_END_TIME = "end_time"
KEY_DEVICE_IOS = "device_ios"
KEY_DEVICE_SECTORS = "device_sectors"
KEY_DEVICE_MBS = "device_mbs"
KEY_YCSB_THROUGHPUT = "ycsb_throughput"


def __extract_from_files(folder, round_data, filename_prefix, func):
    found = False

    for root, _, files in os.walk(folder):
        for filename in files:
            if filename.startswith(filename_prefix):
                found = True

                round_idx = __get_round_idx(filename)
                if round_idx not in round_data:
                    round_data[round_idx] = {}

                with open(os.path.join(root, filename), "r") as stats_file:
                    file_content = stats_file.read()

                func(round_data[round_idx], file_content, root, filename)

    if not found:
        raise RuntimeWarning(
            "No file found in this folder with the prefix of \"{}\"".format(
                filename_prefix))


def __process_ycsb_log(round_data_at_idx, file_content, *_):
    # populate start_time and end_time
    timestamps = [
        datetime.datetime.strptime(string, "%Y-%m-%d %H:%M:%S:%f")
        for string in DATE_PATTERN.findall(file_content)
    ]

    if KEY_START_TIME not in round_data_at_idx:
        round_data_at_idx[KEY_START_TIME] = timestamps[0]
        round_data_at_idx[KEY_END_TIME] = timestamps[-1]
    else:
        round_data_at_idx[KEY_START_TIME] = min(
            [timestamps[0], round_data_at_idx[KEY_START_TIME]])
        round_data_at_idx[KEY_END_TIME] = max(
            [timestamps[-1], round_data_at_idx[KEY_END_TIME]])

    # populate YCSB throughput
    throughput = float(THROUGHPUT_PATTERN.search(file_content).group(1))
    round_data_at_idx[KEY_YCSB_THROUGHPUT] = round_data_at_idx.get(
        KEY_YCSB_THROUGHPUT, 0) + throughput


def __process_device_stats_log(round_data_at_idx, file_content, root,
                               filename):
    # see the description of fields on
    # https://www.kernel.org/doc/Documentation/ABI/testing/procfs-diskstats
    fields = file_content.split()
    ios = int(fields[3]) + int(fields[7])
    sectors = int(fields[5]) + int(fields[9])

    # populate device ios and sectors
    if filename.endswith("_b.log"):
        round_data_at_idx[KEY_DEVICE_IOS] = round_data_at_idx.get(
            KEY_DEVICE_IOS, 0) - ios
        round_data_at_idx[KEY_DEVICE_SECTORS] = round_data_at_idx.get(
            KEY_DEVICE_SECTORS, 0) - sectors
    elif filename.endswith("_a.log"):
        round_data_at_idx[KEY_DEVICE_IOS] = round_data_at_idx.get(
            KEY_DEVICE_IOS, 0) + ios
        round_data_at_idx[KEY_DEVICE_SECTORS] = round_data_at_idx.get(
            KEY_DEVICE_SECTORS, 0) + sectors
    else:
        raise RuntimeError("Unknow file {} found in dir {}".format(
            filename, root))


def __check_path(string):
    if not os.path.isdir(string):
        raise argparse.ArgumentTypeError(
            "Folder path {} does not exist.".format(string))
    return string


STEADY_STATE_WINDOW_SIZE = 3


def main():
    """Extract data points."""
    parser = argparse.ArgumentParser(
        description='''Extract thread data points from a folder of files
        generated by the ycsb-rocksdb ansible playbook.
        ''',
        epilog='See https://github.com/ljishen/ycsb-rocksdb')
    parser.add_argument("folder",
                        type=__check_path,
                        help="the path of the data folder")
    args = parser.parse_args()

    round_data = {}
    __extract_from_files(args.folder, round_data, "ycsb_transactions@",
                         __process_ycsb_log)
    __extract_from_files(args.folder, round_data, "device_stats_",
                         __process_device_stats_log)

    steady_state_round_idxes = sorted(
        round_data.keys())[-STEADY_STATE_WINDOW_SIZE:]
    if len(steady_state_round_idxes) < STEADY_STATE_WINDOW_SIZE:
        raise RuntimeError(("Found total {:d} rounds of data, "
                            "but need {:d} to evaluate steady state.").format(
                                len(steady_state_round_idxes),
                                STEADY_STATE_WINDOW_SIZE))

    list_ycsb_throughputs = []
    list_device_ios = []
    list_device_mbs = []  # throughputs in MiB/s

    for round_idx in steady_state_round_idxes:
        round_data_at_idx = round_data[round_idx]

        list_ycsb_throughputs.append(round_data_at_idx[KEY_YCSB_THROUGHPUT])

        duration_in_seconds = (
            round_data_at_idx[KEY_END_TIME] -
            round_data_at_idx[KEY_START_TIME]).total_seconds()

        list_device_ios.append(round_data_at_idx[KEY_DEVICE_IOS] /
                               duration_in_seconds)
        list_device_mbs.append(round_data_at_idx[KEY_DEVICE_SECTORS] * 512 /
                               1024 / 1024 / duration_in_seconds)

    print(json.dumps(
        {
            KEY_YCSB_THROUGHPUT: {
                'mean': statistics.mean(list_ycsb_throughputs),
                'stdev': statistics.pstdev(list_ycsb_throughputs)
            },
            KEY_DEVICE_IOS: {
                'mean': statistics.mean(list_device_ios),
                'stdev': statistics.pstdev(list_device_ios)
            },
            KEY_DEVICE_MBS: {
                'mean': statistics.mean(list_device_mbs),
                'stdev': statistics.pstdev(list_device_mbs)
            }
        },
        sort_keys=True,
        indent=2))


if __name__ == "__main__":
    main()
