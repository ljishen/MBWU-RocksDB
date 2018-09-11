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
```
