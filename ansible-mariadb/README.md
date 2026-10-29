# ansible-mariadb

Cài MariaDB offline bằng Ansible: `single`, `dr`, `cluster` (Galera), `dr-cluster`. Tùy chọn thêm MaxScale và Vector.
Thay cho `deploy.sh` và `scripts/01..06`.

## Chạy nhanh

Chạy trong thư mục `ansible-mariadb/`.

**1. Chuẩn bị trên máy chạy Ansible**

- `../package/mariadb/mariadb-*.tar.gz`: binary MariaDB.
- `../package/os/*.deb` (hoặc `os-jammy`, `os-el7`): gói jemalloc, numactl, iptables. Chỉ cần khi node còn thiếu.
- `../setup/mariadb/Install_Mariadb/vsystem.sql` và `users.sql`: chỉ cần khi `mariadb_empty_cluster: false`.
- Để ở chỗ khác thì đặt `mariadb_package_dir` và `mariadb_setup_sql_dir` (đường dẫn tuyệt đối) trong group_vars.

**2. Khai báo node** trong [projects/inventory/databases.yaml](projects/inventory/databases.yaml). Tên host phải là IP của node. Node đầu tiên là bootstrap, các node sau là joiner.

**3. Sửa cấu hình** trong [projects/inventory/group_vars/mariadb.yml](projects/inventory/group_vars/mariadb.yml). Bắt buộc đổi:

| Biến | Ý nghĩa |
|---|---|
| `mariadb_topology` | `single` / `dr` / `cluster` / `dr-cluster` |
| `mariadb_admin_pass`, `mariadb_common_pass`, `mariadb_galera_pass`, `mariadb_maxscale_pass` | Mật khẩu. Còn `CHANGE_ME` thì role dừng ngay |
| `mariadb_primary_nodes` | IP primary, bắt buộc với `dr` / `dr-cluster` |
| `mariadb_mgmt_nodes` | IP được vào SSH và port MariaDB qua firewall |
| `mariadb_data_dir`, `mariadb_log_dir`... | Đường dẫn dữ liệu và log |

Các biến còn lại và giá trị mặc định xem [roles/mariadb/defaults/main.yml](roles/mariadb/defaults/main.yml).

**4. Chạy**

```bash
ansible-playbook projects/install_mariadb.yml --syntax-check
ansible-playbook projects/install_mariadb.yml                          # cài toàn bộ
```

Các cách chạy khác:

```bash
ansible-playbook projects/install_mariadb.yml --tags os,install        # chỉ một số giai đoạn
ansible-playbook projects/install_mariadb.yml --limit 10.211.60.103 -e mariadb_expected_cluster_size=3
ansible-playbook projects/install_mariadb.yml -e mariadb_install_mode=expand   # chạy lại trên cluster đang chạy
ansible-playbook projects/install_mariadb.yml -e mariadb_install_maxscale=true -e mariadb_install_vector=true
```

Tags: `os`, `install`, `config`, `service`, `datadir`, `init`, `start`, `maxscale`, `vector`.

## Luồng chạy

```
Play 1  Chuẩn bị + cài         tất cả node song song, dừng cả playbook nếu 1 node lỗi (any_errors_fatal)
 │
 ├─ common      [always]   kiểm tra biến, RAM tối thiểu, mật khẩu khác CHANGE_ME
 │                         tính buffer pool / max_connections / port / server_id -> dict `inst`
 │                         phát hiện jemalloc/numactl/iptables, trạng thái service (1 lần)
 ├─ preflight   [os,install,init]  kiểm tra tarball + file SQL trên máy controller (1 lần)
 ├─ os                     gói offline (chỉ khi thiếu) -> iptables -> sysctl, limits -> tắt THP
 ├─ install                backup bản cũ -> giải nén tarball vào thư mục cài -> user, thư mục, wrapper `mariadb`
 ├─ config                 render /etc/my.cnf (base + Galera + DR)
 ├─ service                vá script galera_* -> ghi unit systemd
 ├─ datadir                mariadb-install-db (bỏ qua trên joiner)
 └─ init                   mariadbd tạm -> import vsystem.sql, users.sql -> đặt mật khẩu root (bỏ qua trên joiner)

Play 2  Phân nhóm              group_by node_role -> mariadb_bootstrap / mariadb_joiner
Play 3  Start bootstrap        ghi cờ wsrep-new-cluster -> start -> xóa cờ -> chờ Synced
Play 4  Start joiner           từng node một (serial: 1): chờ bootstrap mở port Galera
                               -> start (SST, async) -> chờ Synced và cluster >= 2 node
Play 5  Xác nhận cluster       chờ cluster đủ mariadb_expected_cluster_size node, đều Synced
Play 6  MaxScale               chỉ khi mariadb_install_maxscale=true
Play 7  Vector                 chỉ khi mariadb_install_vector=true
```

`single` và `dr` không có Galera nên play 3 gọi `start_standalone` (enable + start), play 4 và 5 không có việc.

### Hai chế độ cài

| `mariadb_install_mode` | Dùng khi | Hành vi |
|---|---|---|
| `fresh` (mặc định) | Cài mới | Cài lại binary, init lại datadir. **Từ chối** chạy nếu service đang chạy |
| `expand` | Chạy lại, thêm node | Giữ instance đang chạy. Nếu buffer pool đổi, config mới ghi vào `my.cnf.new` để restart thủ công |

Sau khi cluster đã chạy, muốn chạy lại playbook thì dùng `expand`.

### Chạy lại có an toàn không

- `datadir` và `init` dùng file đánh dấu (`<datadir>/mysql`, `.ansible_init_done`, `grastate.dat`), không init lại dữ liệu đã có.
- Gói OS chỉ copy và cài khi node còn thiếu (ép bằng `mariadb_os_packages_force: true`).
- Backup (thư mục cài, `my.cnf`, unit systemd) chỉ tạo khi nội dung đổi và chỉ giữ `mariadb_backup_keep` bản mới nhất (mặc định 2).
- Cờ bootstrap Galera nằm ở `/run/<service>/wsrep-new-cluster` (tmpfs, chỉ user MariaDB vào được) và bị xóa ngay sau khi start.

## Cấu trúc

```
ansible-mariadb/
├── ansible.cfg                          # forks, SSH pipelining, ControlPersist
├── projects/
│   ├── install_mariadb.yml              # playbook (7 play như trên)
│   └── inventory/
│       ├── databases.yaml               # danh sách node (tên host = IP)
│       └── group_vars/mariadb.yml       # cấu hình
└── roles/mariadb/
    ├── defaults/main.yml                # biến mặc định mariadb_*
    ├── handlers/main.yml                # reload sysctl, reload systemd
    ├── files/, templates/               # disable-thp.service, my.cnf, unit systemd, sysctl, limits
    └── tasks/
        ├── main.yml                     # gọi lần lượt các giai đoạn theo tags
        ├── common.yml                   # kiểm tra + tính thông số `inst`
        ├── preflight.yml                # kiểm tra file trên controller
        ├── libs.yml                     # phát hiện jemalloc/numactl/iptables
        ├── os_*.yml                     # gói offline, firewall, sysctl/limits/THP
        ├── install.yml  config.yml  service.yml  datadir.yml  init.yml
        ├── start*.yml                   # standalone / bootstrap / joiner
        ├── wait_synced.yml  verify_cluster.yml
        ├── backup_cleanup.yml           # giữ N bản backup
        ├── maxscale.yml  vector.yml
```

## Lưu ý

- Mỗi server cài đúng 1 instance. Ghi đè vai trò bằng host var `mariadb_node_role` (`bootstrap` / `joiner`).
- Role tính `innodb_buffer_pool_size` = 75% RAM (`mariadb_reserved_ram_pct: 25`). `max_connections` mặc định `auto` theo RAM, `innodb_flush_log_at_trx_commit` mặc định 2 với Galera và 1 với single/dr. Node dưới `mariadb_min_ram_mb` (2048) bị từ chối.
- Mặc định **không** gỡ MariaDB của OS. Đặt `mariadb_remove_os_mariadb: true` để gỡ (chỉ áp dụng khi `fresh`).
- Mật khẩu đang nằm plaintext trong group_vars (chưa dùng ansible-vault). Đừng commit file thật lên repo công khai.
- Chưa chuyển 08 (job cron/backup); script vẫn chạy được trong `scripts/`.
