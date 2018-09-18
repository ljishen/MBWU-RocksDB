# ycsb-rocksdb

Ansible Playbook for Running the YCSB RocksDB binding on the Latest RocksDB.


## Requirements on Control Machine

- `ansible >= 2.5`


## Usage

```bash
git clone https://github.com/ljishen/ycsb-rocksdb.git

# command is required to run within this dir so that ansible-playbook can see ansible.cfg
cd ycsb-rocksdb

# Modify the hosts and the corresponding device mountpoint
vim hosts`

# run tests
ansible-playbook playbooks/main.yml --tags WORKLOADS [-v]

# TESTS can be any combinations of workloads separated by comma.
# Besides all the 6 YCSB core workloads, you can create your own
# workload and put it in dir `playbooks/roles/run/templates/`.
#
# WORKLOADS:
#   The YCSB core workloads (workload[a-f]) and user-defined workloads
#
# E.g. ansible-playbook playbooks/main.yml --tags "workloada,workloadb"
#
# Options:
#   --extra-vars "rocksdb_options_file=/path/to/your/optionsfile"
#   -v  Show debug messages while running playbook
```
