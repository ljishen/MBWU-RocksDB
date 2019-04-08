# ycsb-rocksdb

Ansible Playbook for Running the YCSB RocksDB binding on the Latest RocksDB.


## Requirements on Control Machine

- `ansible >= 2.7.9`


## Usage

```bash
git clone https://github.com/ljishen/ycsb-rocksdb.git

# command is required to run within this dir so that ansible-playbook can see ansible.cfg
cd ycsb-rocksdb

# Modify the hosts and the corresponding device mountpoint
vim hosts

# run tests
ansible-playbook playbooks/main.yml [-v]

# Extra Variables:
#   - rocksdb_options_file:
#       This is the path of the RockDB options file. By default, it is the
#       {{ playbook_dir }}/roles/run/templates/OPTIONS
#   - ycsb_run_workloads:
#       This is the paths of a list of the YCSB workload parameter files
#       separated by comma. Each of them could be any of the YCSB core
#       workload[a-f], or the absolute path of a user-defined workload
#       parameter file. By default, it is the
#       {{ playbook_dir }}/roles/run/templates/myworkloada
#
# Options:
#   -v  Show debug messages while running playbook
#
# For example:
# $ ansible-playbook playbooks/main.yml -v \
#       --extra-vars "ycsb_run_workloads=workloadc,/path/to/workload1,/path/to/workload2 rocksdb_options_file=/path/to/optionsfile"
#
```
