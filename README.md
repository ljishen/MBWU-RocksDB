# ycsb-rocksdb

Ansible Playbook for Running YCSB on RocksDB RMI Server over Disaggregated Storage Devices.


## Requirements

- Control Node
  - ansible >= 2.7.9
  - python-apt or python3-apt or aptitude

- Managed Nodes ([rocksdb, storage])
  - python-apt or python3-apt or aptitude


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
#       This is the path of the RockDB options file.
#       The default value is:
#       {{ playbook_dir }}/templates/OPTIONS
#   - ycsb_workload:
#       This variable accepts the name of a YCSB core workload
#       ("workloada" to "workloadf") or an user-defined workload.
#       The default value is:
#       {{ playbook_dir }}/templates/myworkloada
#
# Options:
#   -v  Show debug messages while running playbook
#
# For example:
# $ ansible-playbook playbooks/main.yml -v \
#       --extra-vars "ycsb_workload=/path/to/your/ycsb/workload rocksdb_options_file=/path/to/your/optionsfile"
#
```
