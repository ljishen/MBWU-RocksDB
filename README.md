# MBWU-RocksDB

A playbook to Evaluate RocksDB Performance with MBWU-based methodology.


## Requirements

- Control Node
  - ansible >= 2.7.9
  - python-apt or python3-apt or aptitude

- Managed Nodes ([rocksdb, storage])
  - python-apt or python3-apt or aptitude


## Usage

```bash
git clone https://github.com/ljishen/MBWU-RocksDB.git

# run within this dir so that ansible-playbook can see ansible.cfg
cd MBWU-RocksDB

# Add hosts to groups of rocksdb and storage
vim hosts.yml

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
