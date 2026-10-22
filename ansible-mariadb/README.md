# ansible-mariadb

Cài MariaDB (single / dr / Galera cluster) offline bằng Ansible, thay cho `deploy.sh` và `scripts/01..06`.

```
ansible-mariadb/
├── ansible.cfg
├── projects/
│   ├── install_mariadb.yml              # playbook
│   └── inventory/
│       ├── databases.yaml               # khai báo host (tên host = IP node)
│       └── group_vars/mariadb.yml       # cấu hình (thay configs/cluster.env)
└── roles/
    └── mariadb                          # role duy nhất, mỗi giai đoạn là một file trong tasks/
        ├── defaults/main.yml            # biến mặc định (mariadb_*)
        ├── handlers/main.yml            # reload sysctl
        ├── files/, templates/           # disable-thp.service, my.cnf, unit systemd, sysctl, limits
        └── tasks/
            ├── main.yml                 # gọi lần lượt các giai đoạn bên dưới (theo tags)
            ├── common*.yml              # kiểm tra biến, tính auto-tune / port / đường dẫn (common.sh)
            ├── os_*.yml                 # 01: gói offline, iptables, sysctl, limits, THP
            ├── install*.yml             # 02: giải nén binary, user, thư mục, wrapper
            ├── config*.yml              # 03: my.cnf (template gộp base + Galera + DR)
            ├── service*.yml             # 04: unit systemd, vá script helper Galera
            ├── datadir*.yml             # 05: mariadb-install-db (bỏ qua trên joiner)
            ├── init*.yml                # 06: import vsystem.sql/users.sql, đặt mật khẩu root
            ├── start*.yml               # start: bootstrap -> joiner (SST), hoặc standalone
            ├── maxscale.yml             # 07: MaxScale (chỉ khi mariadb_install_maxscale=true)
            └── vector.yml               # 09: Vector (chỉ khi mariadb_install_vector=true)
```

## Chạy

Chạy trong thư mục `ansible-mariadb/`:

```bash
# 1. Sửa projects/inventory/group_vars/mariadb.yml (topology, instances, mật khẩu - nên dùng ansible-vault)
# 2. Cần có package/mariadb/mariadb-*.tar.gz và package/os/*.deb trên máy chạy Ansible
ansible-playbook projects/install_mariadb.yml --syntax-check
ansible-playbook projects/install_mariadb.yml                         # cài toàn bộ
ansible-playbook projects/install_mariadb.yml --tags os,install       # chỉ một số bước
ansible-playbook projects/install_mariadb.yml -e mariadb_install_mode=expand
ansible-playbook projects/install_mariadb.yml --limit 10.254.150.6    # một node
```

Tags: `os`, `install`, `config`, `service`, `datadir`, `init`, `start`, `maxscale`, `vector`.

Mỗi server cài đúng 1 instance. Node đầu tiên trong inventory là bootstrap, các node sau là joiner.
MaxScale và Vector mặc định tắt, bật bằng biến trong playbook hoặc `-e mariadb_install_maxscale=true -e mariadb_install_vector=true`.

## Lưu ý

- Node **đầu tiên** của nhóm `mariadb` là bootstrap, các node còn lại là joiner (ghi đè bằng host var `mariadb_node_role`).
- Joiner được start lần lượt từng node (`serial: 1`) và chờ trạng thái `Synced`.
- Cờ bootstrap dùng file `/tmp/wsrep-new-cluster_<ID>` mà unit systemd đã đọc qua `EnvironmentFile`, rồi xóa sau khi start.
- Mặc định **không** gỡ MariaDB của OS; đặt `mariadb_remove_os_mariadb: true` nếu muốn (chỉ áp dụng khi `fresh`).
- Chưa chuyển 07 (MaxScale), 08 (job cron/backup), 09 (Vector); các script này vẫn chạy được trong `scripts/`.
