# ansible-mariadb

Cài MariaDB offline bằng Ansible: `single`, `dr`, `cluster` (Galera), `dr-cluster`. Tùy chọn thêm MaxScale và Vector.
Thay cho `deploy.sh` và `scripts/01..06`.

Kiến trúc cụm (Galera, MaxScale, đồng bộ, đọc/ghi): xem [architecture.md](architecture.md).

```
 bastion (chạy Ansible, có package/ + setup/)
    │  SSH: copy tarball, gói OS, render config, start service
    ├──► node1  bootstrap (node đầu trong inventory)
    ├──► node2  joiner (SST từ node1)
    └──► node3  joiner
```

Mục lục: [Chuẩn bị](#1-chuẩn-bị-chung-lab-và-thực-tế) · [Lab](#2-cài-lab-3-node-2-vcpu--4gb) · [Thực tế](#3-cài-môi-trường-thực-tế) · [Kiểm tra và dùng DB](#4-kiểm-tra-sau-khi-cài) · [Gỡ cài đặt](#5-gỡ-cài-đặt-để-cài-lại) · [Chạy lại / các lệnh khác](#6-chạy-lại-và-các-lệnh-khác) · [Sự cố thường gặp](#7-sự-cố-thường-gặp)

## 1. Chuẩn bị chung (lab và thực tế)

Làm trên **bastion**, trong thư mục `ansible-mariadb/`. Bastion cần Ansible (ansible-core), SSH được tới các node, và (để tải bản cài) ra được github.com.

### 1.1 Tải bản cài về bastion

Tarball MariaDB và MaxScale không nằm trong git mà ở GitHub Release `packages-v1`. Các file còn lại (`nodejs/`, `os/`, `os-jammy/`, `os-el7/`) đã có sẵn khi clone.

```bash
git clone https://github.com/QuangHoangNguci/learn_mariadb.git
cd learn_mariadb
./download_packages.sh                 # tải mariadb + maxscale vào package/mariadb, package/maxscale
./download_packages.sh maxscale        # hoặc chỉ tải một gói
ls -lh package/mariadb package/maxscale
cd ansible-mariadb
```

Các file role cần trên bastion:

| Đường dẫn | Dùng khi |
|---|---|
| `../package/mariadb/mariadb-*.tar.gz` | Luôn cần (binary MariaDB) |
| `../package/os/*.deb` (và `os-jammy`, `os-el7`) | Node còn thiếu jemalloc / numactl / iptables |
| `../package/os-jammy/libssl1.1_*.deb` | Galera trên Ubuntu 22.04/24.04 (thiếu `libssl.so.1.1` thì mariadbd không nạp được Galera). Role tự cài khi node thiếu |
| `../setup/mariadb/Install_Mariadb/vsystem.sql`, `users.sql` | Khi `mariadb_empty_cluster: false` |

Để ở chỗ khác thì đặt `mariadb_package_dir` và `mariadb_setup_sql_dir` (đường dẫn tuyệt đối) trong group_vars.

### 1.2 Khai báo node và SSH

Sửa [projects/inventory/databases.yaml](projects/inventory/databases.yaml). Node **đầu tiên** là bootstrap, các node sau là joiner.

```yaml
all:
  children:
    new__databases:
      children:
        mariadb:
          vars:
            ansible_user: ubuntu
            ansible_ssh_private_key_file: /home/ubuntu/key.pem
          hosts:
            mariadb-node1: { ansible_host: 172.24.220.161 }
            mariadb-node2: { ansible_host: 172.24.220.244 }
            mariadb-node3: { ansible_host: 172.24.220.65 }
```

- Role lấy IP của node theo thứ tự: `ansible_host` → IP mặc định (`default_ipv4`) từ facts → tên host. Hãy khai báo `ansible_host` (hoặc đặt luôn tên host là IP) để chắc chắn đúng mạng dùng cho Galera. Chạy `--limit` một node bắt buộc phải có `ansible_host`, vì node còn lại không được thu thập facts.
- Khi `ansible_host` là IP, SSH không dùng mục `Host` trong `~/.ssh/config`. Vì vậy phải khai báo `ansible_user` và `ansible_ssh_private_key_file` như trên.

Kiểm tra SSH và quyền sudo:

```bash
chmod 600 /home/ubuntu/key.pem
ansible mariadb -m ping                # cả 3 node phải trả "pong"
ansible mariadb -b -m command -a "id"  # uid=0(root) nghĩa là sudo ổn
```

### 1.3 Mở mạng giữa các node

Giữa các node (và firewall/security group của nền tảng ảo hóa) cần thông:

| Cổng | Dùng cho |
|---|---|
| 22 | SSH từ bastion |
| 3306 | MariaDB client |
| 1301 | `mariadb_mgnt_port` (extra_port) |
| 1031 / 1032 / 1033 | Galera SST / group communication / IST (`mariadb_wsrep_base_port` 1030 + 1/2/3) |
| 4006 / 4016, 8990 | MaxScale rw / ro, REST (chỉ khi cài MaxScale) |

Role tự thêm rule iptables ACCEPT giữa các node trong cluster, nhưng không điều khiển được security group bên ngoài. Nếu thiếu cổng 1032, task "Chờ node cluster sẵn sàng nhận kết nối Galera" sẽ timeout.

### 1.4 Cấu hình dùng chung

Sửa [projects/inventory/group_vars/mariadb.yml](projects/inventory/group_vars/mariadb.yml). Bắt buộc xem lại:

| Biến | Ý nghĩa |
|---|---|
| `mariadb_topology` | `single` / `dr` / `cluster` / `dr-cluster` |
| `mariadb_admin_pass`, `mariadb_common_pass`, `mariadb_galera_pass`, `mariadb_maxscale_pass` | Mật khẩu. Còn `CHANGE_ME` thì role dừng ngay |
| `mariadb_primary_nodes` | IP primary, bắt buộc với `dr` / `dr-cluster` |
| `mariadb_mgmt_nodes` | IP được vào SSH và port MariaDB qua firewall (nên gồm IP bastion) |
| `mariadb_data_dir`, `mariadb_log_dir`... | Đường dẫn dữ liệu và log |

Các biến còn lại và giá trị mặc định xem [roles/mariadb/defaults/main.yml](roles/mariadb/defaults/main.yml).

## 2. Cài lab (3 node, 2 vCPU / 4GB)

Cấu hình mặc định nhắm vào server lớn (buffer pool = 75% RAM, `max_connections` theo RAM, gcache 2GB). Trên node 4GB RAM mặc định để chừa quá ít cho OS, connection và Galera, nên truyền thêm [projects/lab.yml](projects/lab.yml) để ghi đè (extra-vars ưu tiên hơn group_vars, cấu hình production không bị đổi):

| Biến | Giá trị lab | Mặc định (tính theo RAM) |
|---|---|---|
| `mariadb_buf_mb` | 2048 | ~2900MB (75% RAM) |
| `mariadb_max_connections` | 200 | ~487 |
| `mariadb_gcache_size` | 512M | 2048M |
| `mariadb_size_gb`, `mariadb_max_open_files` | 20, 65535 | 100, 1000000 |

Các bước (sau khi làm xong mục 1):

```bash
# Kiểm tra cú pháp
ansible-playbook projects/install_mariadb.yml -e @projects/lab.yml --syntax-check

# Cài
ansible-playbook projects/install_mariadb.yml -e @projects/lab.yml

# Kèm MaxScale (RAM chung node nên giảm buffer pool)
ansible-playbook projects/install_mariadb.yml -e @projects/lab.yml \
  -e mariadb_install_maxscale=true -e mariadb_buf_mb=1536
```

Playbook chạy thành công khi qua play 5 "Xác nhận cluster" (đủ node, đều `Synced`). Kiểm tra lại ở [mục 4](#4-kiểm-tra-sau-khi-cài).

Lưu ý cho lab:
- Mỗi node nên có 1–2GB swap để tránh OOM-killer khi SST.
- Dư vài GB đĩa dưới `/u01` (gcache + redo log + binlog + dữ liệu).
- Muốn cài lại để test: dùng [playbook gỡ cài đặt](#5-gỡ-cài-đặt-để-cài-lại), rồi chạy lại lệnh cài ở trên.

## 3. Cài môi trường thực tế

Cùng quy trình, khác ở cấu hình và an toàn. Không dùng `lab.yml`.

### 3.1 Các bước

1. Làm hết [mục 1](#1-chuẩn-bị-chung-lab-và-thực-tế) với IP thật. Nên đặt `ansible_host` là IP mạng dành cho Galera.
2. Đặt mật khẩu mạnh, không để plaintext. Dùng ansible-vault:
   ```bash
   ansible-vault encrypt_string '<mật khẩu>' --name mariadb_admin_pass   # dán kết quả vào group_vars/mariadb.yml
   ```
   Lúc chạy thêm `--ask-vault-pass`. Đừng commit file mật khẩu thật lên repo công khai.
3. Điền `mariadb_mgmt_nodes` (IP quản trị được vào SSH/port MariaDB), `mariadb_primary_nodes` (nếu `dr` / `dr-cluster`), đường dẫn `mariadb_data_dir`, `mariadb_log_dir`, `mariadb_binlog_dir` trên đĩa phù hợp (thường là đĩa dữ liệu riêng).
4. Xem trước giá trị tuning sẽ được tính (bảng 3.2) và ghi đè nếu cần (ví dụ `mariadb_gcache_size`, `mariadb_buf_mb`).
5. Chạy:
   ```bash
   ansible-playbook projects/install_mariadb.yml --syntax-check
   ansible-playbook projects/install_mariadb.yml --ask-vault-pass
   ```
6. Kiểm tra theo [mục 4](#4-kiểm-tra-sau-khi-cài), và đối chiếu `/etc/my.cnf` với bảng tính bên dưới.

### 3.2 Cấu hình động được tính thế nào

Mỗi node tự tính từ RAM, CPU và loại đĩa **của chính node đó** (facts thu thập lúc chạy), kết quả đưa vào `/etc/my.cnf`. Node có cấu hình khác nhau sẽ ra giá trị khác nhau. Công thức nằm ở [common.yml](roles/mariadb/tasks/common.yml):

| Thông số | Công thức | Ghi đè bằng |
|---|---|---|
| `innodb_buffer_pool_size` | `RAM_MB × (100 − reserved_pct) / 100`, tối thiểu 128MB. `reserved_pct` mặc định 25 → 75% RAM | `mariadb_buf_mb` (số MB) hoặc `mariadb_reserved_ram_pct` |
| `max_connections` | `min(max(RAM_MB / 8, 200), 4000)` | `mariadb_max_connections` |
| `innodb_log_file_size` | `buffer_pool / 4`, kẹp trong 256MB – 2048MB | (theo buffer pool) |
| `innodb_buffer_pool_instances` | `min(max(buffer_pool_GB, 1), 8)` | (theo buffer pool) |
| `thread_pool_size`, `wsrep_slave_threads` | `min(max(2 × CPU, 4), 64)` | (theo CPU) |
| `innodb_io_capacity` / `_max` | SSD/NVMe: 4000 / 10000. HDD: 200 / 2000 (tự phát hiện qua `rotational`) | `mariadb_disk_type: ssd\|hdd` |
| `innodb_flush_neighbors` | SSD 0, HDD 1 | `mariadb_disk_type` |
| `innodb_flush_log_at_trx_commit` | 2 với Galera, 1 với single/dr | `mariadb_flush_log_at_trx_commit` |
| `server_id` | Galera: `mariadb_server_id`. Còn lại: octet cuối của IP × 100 | `mariadb_server_id` |
| Cổng Galera | SST = base+1, group = base+2, IST = base+3 (base mặc định 1030) | `mariadb_wsrep_base_port` |
| `wsrep_node_name` | `<mariadb_node_name_prefix>_<thứ tự node trong inventory>`, ví dụ `db_1` | `mariadb_node_name_prefix` |
| `gcache.size` | **Không động**, cố định 2048M | `mariadb_gcache_size` |

Node có RAM dưới `mariadb_min_ram_mb` (2048) bị từ chối ngay.

**Ví dụ minh họa.** Node 16GB RAM (16384MB), 8 vCPU, SSD, Galera:

```
buffer_pool            = 16384 × 75% = 12288MB
max_connections        = min(max(16384/8, 200), 4000) = 2048
innodb_log_file_size   = clamp(12288/4 = 3072, 256, 2048) = 2048MB
buffer_pool_instances  = min(12, 8) = 8
thread_pool_size       = min(max(2×8, 4), 64) = 16   (wsrep_slave_threads = 16)
io_capacity / max      = 4000 / 10000
flush_log_at_trx_commit= 2
```

Node 4GB RAM, 2 vCPU, SSD (RAM thực khoảng 3900MB) với mặc định: buffer pool ~2925MB, `max_connections` 487, redo log ~731MB, `thread_pool_size` 4. Vì vậy lab dùng `lab.yml` để hạ xuống.

Xem giá trị thực tế đã ghi trên từng node:

```bash
ansible mariadb -b -m shell -a "grep -E '^(innodb_buffer_pool_size|max_connections|innodb_log_file_size|thread_pool_size|wsrep_slave_threads|innodb_flush_log_at_trx_commit|server_id|wsrep_node_name|wsrep_cluster_address)' /etc/my.cnf"
```

### 3.3 Lưu ý riêng cho thực tế

- Mặc định `flush_log_at_trx_commit = 2` với Galera (OS crash có thể mất tối đa ~1s giao dịch trên node đó, cluster còn bản sao). Đặt `1` nếu cần bền tuyệt đối.
- Đặt `mariadb_gcache_size` đủ lớn để IST được nếu node tắt lâu, nhưng phải còn đủ đĩa.
- Không để `mariadb_remove_os_mariadb: true` trừ khi chắc chắn (chỉ áp dụng khi `fresh`, gỡ MariaDB của OS).
- Đừng chạy `uninstall` trên production. Playbook đó xóa toàn bộ dữ liệu.

## 4. Kiểm tra sau khi cài

Playbook báo OK khi play "Xác nhận cluster" qua, tức là cluster đủ `mariadb_expected_cluster_size` node và đều `Synced`. Kiểm tra độc lập thêm như sau.

**Trên một node (ví dụ node1).** Lưu ý: gõ `mariadb` trong phiên SSH có thể chạy binary thật (PATH ưu tiên `/usr/local/mariadb/bin`) và tìm `/tmp/mysql.sock`, nên truyền socket rõ ràng:

```bash
sudo -i
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS WHERE Variable_name IN
  ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment',
   'wsrep_ready','wsrep_connected','wsrep_incoming_addresses','wsrep_cluster_conf_id');"
```

Kỳ vọng với cluster 3 node:

| Biến | Giá trị đúng |
|---|---|
| `wsrep_cluster_size` | `3` |
| `wsrep_cluster_status` | `Primary` |
| `wsrep_local_state_comment` | `Synced` |
| `wsrep_ready` / `wsrep_connected` | `ON` |
| `wsrep_incoming_addresses` | liệt kê địa chỉ cả 3 node |

**Từ bastion, kiểm tra cả cụm một lệnh** (thay `<mật khẩu>` bằng `mariadb_admin_pass`):

```bash
ansible mariadb -b -m shell -a "systemctl is-active mariadb"
ansible mariadb -b -m shell -a "MYSQL_PWD='<mật khẩu>' /usr/local/mariadb/bin/mariadb -u root -S /u01/data/database/mariadb.sock -Nse \"SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_local_state_comment','wsrep_ready')\""
```

Mỗi node phải in `active`, `wsrep_cluster_size 3`, `Synced`, `ON`.

**Cổng đang lắng nghe** (trên mỗi node): `sudo ss -lntp | grep -E '3306|1031|1032|1033'`.

**Thử ghi/đọc đồng bộ:**

```bash
# node1: tạo
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "CREATE DATABASE IF NOT EXISTS t_lab; CREATE TABLE t_lab.t (id INT PRIMARY KEY); INSERT INTO t_lab.t VALUES (1);"
# node2/node3: phải thấy dữ liệu
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SELECT * FROM t_lab.t;"
# dọn
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "DROP DATABASE t_lab;"
```

### Đăng nhập và thao tác với database

Binary client nằm ở `/usr/local/mariadb/bin/` (`mariadb`, `mariadb-dump`, `mariadb-admin`, `mariabackup`). Socket của instance: `/u01/data/database/mariadb.sock` (đổi theo `mariadb_data_dir`). Mật khẩu root là `mariadb_admin_pass`.

**Đăng nhập trên node (qua socket):**

```bash
sudo -i
mariadb -u root -p -S /u01/data/database/mariadb.sock        # vào console, hỏi mật khẩu
# hoặc gọi wrapper do role tạo (tự thêm --defaults-file=/etc/my.cnf)
/usr/local/bin/mariadb -u root -p
```

Muốn gõ ngắn `mariadb` mà không phải nhập socket và mật khẩu, tạo `~/.my.cnf` của user root (chỉ dùng cho lab, mật khẩu nằm plaintext):

```bash
cat > /root/.my.cnf <<'EOF'
[client]
user=root
password=<mật khẩu root>
socket=/u01/data/database/mariadb.sock
EOF
chmod 600 /root/.my.cnf
mariadb                                  # vào thẳng
```

**Đăng nhập qua mạng (TCP):**

```bash
mariadb -h 172.24.220.161 -P 3306 -u tdht -p     # trực tiếp vào một node
mariadb -h <ip-maxscale> -P 4006 -u tdht -p      # qua MaxScale: 4006 read-write, 4016 read-only
mariadb -h 172.24.220.161 -P 1301 -u root -p     # extra_port 1301: vào được khi đã hết max_connections
```

User do `users.sql` tạo: `root@localhost` và `tdht` (mật khẩu `mariadb_admin_pass`), `monitor` (`mariadb_common_pass`), user SST của Galera và `maxscale`. `tdht`, `monitor` và `maxscale` được tạo cho `localhost`, `127.0.0.1`, `10.%`, `192.168.%` và `172.%`. Các user còn lại (`galera`, `mbackup`, `mysqlexp`, `auto_add_partition`) chỉ cho `localhost` / `127.0.0.1`. Với mạng khác các dải trên (hoặc cluster đã cài bằng `users.sql` cũ) không đăng nhập từ xa được. Dùng root qua socket, hoặc tạo user mới:

```sql
CREATE USER 'app'@'172.24.%' IDENTIFIED BY 'MatKhau#123';
GRANT ALL PRIVILEGES ON appdb.* TO 'app'@'172.24.%';
```

**Chạy một lệnh không cần vào console:**

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SELECT VERSION();"
mariadb -u root -p -S /u01/data/database/mariadb.sock -Nse "SHOW DATABASES"      # -N bỏ tên cột, -s gọn
mariadb -u root -p -S /u01/data/database/mariadb.sock -E -e "SHOW SLAVE STATUS"  # -E in dọc
mariadb -u root -p -S /u01/data/database/mariadb.sock appdb < file.sql           # chạy file SQL
```

**SQL thường dùng trong console:**

```sql
SELECT VERSION(), @@hostname, @@port;
SHOW DATABASES;
USE appdb;
SHOW TABLES;
DESCRIBE t;

CREATE DATABASE appdb CHARACTER SET utf8mb4;
CREATE TABLE t (id INT PRIMARY KEY, name VARCHAR(50));      -- Galera yêu cầu bảng có PRIMARY KEY
INSERT INTO t VALUES (1, 'a');
SELECT * FROM t;
DROP DATABASE appdb;

SELECT user, host FROM mysql.user;                           -- danh sách user
SHOW GRANTS FOR 'tdht'@'localhost';
ALTER USER 'root'@'localhost' IDENTIFIED BY 'MatKhauMoi#1';  -- đổi mật khẩu
FLUSH PRIVILEGES;

SHOW PROCESSLIST;                                            -- kết nối đang chạy
SHOW GLOBAL VARIABLES LIKE 'innodb_buffer_pool_size';
SHOW GLOBAL VARIABLES LIKE 'max_connections';
SHOW GLOBAL STATUS LIKE 'Threads_connected';
```

Trong Galera, DDL và ghi đều đồng bộ sang các node, ghi trên node nào cũng được. Bảng thiếu `PRIMARY KEY` hoặc engine không phải InnoDB có thể gây lỗi hoặc không replicate đầy đủ.

**Trạng thái Galera (trong console):**

```sql
SHOW STATUS LIKE 'wsrep_cluster_size';           -- số node trong cluster
SHOW STATUS LIKE 'wsrep_local_state_comment';    -- Synced / Donor/Desynced / Joining
SHOW STATUS LIKE 'wsrep_cluster_status';         -- Primary
SHOW STATUS LIKE 'wsrep_ready';                  -- ON
SHOW STATUS LIKE 'wsrep_local_recv_queue_avg';   -- gần 0 là ổn, lớn nghĩa là node ghi chậm hơn các node khác
SHOW STATUS LIKE 'wsrep_flow_control_paused';    -- gần 0 là ổn
SHOW GLOBAL VARIABLES LIKE 'wsrep_node_name';
SHOW GLOBAL VARIABLES LIKE 'wsrep_cluster_address';
```

**Sao lưu và khôi phục logic:**

```bash
/usr/local/mariadb/bin/mariadb-dump -u root -p -S /u01/data/database/mariadb.sock \
  --single-transaction --routines --triggers --events --databases appdb > appdb.sql
mariadb -u root -p -S /u01/data/database/mariadb.sock < appdb.sql                  # khôi phục
```

`mariabackup` (cùng thư mục bin) là công cụ SST dùng khi node join. Nếu muốn sao lưu vật lý thì tự chạy riêng, role không cấu hình sẵn.

**Quản trị nhanh:**

```bash
/usr/local/mariadb/bin/mariadb-admin -u root -p -S /u01/data/database/mariadb.sock ping      # mysqld is alive
/usr/local/mariadb/bin/mariadb-admin -u root -p -S /u01/data/database/mariadb.sock status
/usr/local/mariadb/bin/mariadb-admin -u root -p -S /u01/data/database/mariadb.sock processlist
```

**Điều khiển service trên node:**

```bash
sudo systemctl status mariadb --no-pager
sudo systemctl restart mariadb           # restart từng node một, đợi Synced rồi mới sang node kế
sudo systemctl stop mariadb
sudo journalctl -u mariadb --no-pager | tail -50
sudo tail -n 80 /u01/logs/mariadb/mariadb.error.log
```

**Khởi động lại cả cụm sau khi tắt hết node.** Không start đồng loạt. Chọn node có dữ liệu mới nhất, thường là node tắt cuối cùng, xem `safe_to_bootstrap` ở file `grastate.dat`:

```bash
sudo cat /u01/data/database/grastate.dat                     # node nào có safe_to_bootstrap: 1 thì bootstrap từ node đó
# trên node được chọn: bootstrap
echo '_WSREP_NEW_CLUSTER=--wsrep-new-cluster' | sudo tee /run/mariadb/wsrep-new-cluster
sudo systemctl start mariadb
sudo rm -f /run/mariadb/wsrep-new-cluster                    # xóa cờ ngay để lần restart sau không bootstrap lại
# các node còn lại: start bình thường, mỗi lần một node
sudo systemctl start mariadb
```

Chỉ làm khi hiểu rõ trạng thái cluster. Bootstrap nhầm node cũ sẽ làm mất giao dịch mới nhất. Nếu cluster còn ít nhất một node chạy thì chỉ cần `systemctl start mariadb` trên node đã tắt.

### Tương tác với cụm qua MaxScale

Áp dụng khi đã cài MaxScale (`-e mariadb_install_maxscale=true`, cổng `mariadb_max_rw_port` / `mariadb_max_ro_port`, mặc định trong group_vars là 4006 / 4016). Role cài MaxScale trên **mỗi node**, nên dùng IP của bất kỳ node nào làm `<ip-maxscale>`. Tên các thành phần trong `/etc/maxscale.cnf`: server `server_1..3` (theo thứ tự trong inventory), monitor `Galera-Monitor`, dịch vụ `Read-Write-Service` / `Read-Only-Service`, listener `Read-Write-Listener` / `Read-Only-Listener`.

**Kết nối dữ liệu qua MaxScale** (user phải được phép đăng nhập từ IP của máy client, xem mục user ở trên):

```bash
mariadb -h <ip-maxscale> -P 4006 -u tdht -p      # đọc/ghi, MaxScale tự tách đọc và ghi
mariadb -h <ip-maxscale> -P 4016 -u tdht -p      # chỉ đọc, chia kết nối giữa các node Synced
```

Kiểm tra truy vấn đang vào node nào:

```bash
# Cổng ghi: lệnh ghi luôn về node Master
mariadb -h <ip-maxscale> -P 4006 -u tdht -p -e "SELECT @@hostname, @@server_id, @@wsrep_node_name;"

# Cổng đọc: mỗi kết nối mới có thể sang node khác, chạy nhiều lần để thấy chia đều
for i in 1 2 3 4 5 6; do
  mariadb -h <ip-maxscale> -P 4016 -u tdht -p'<mật khẩu>' -Nse "SELECT @@hostname"
done
```

**Quản trị MaxScale bằng `maxctrl`** (chạy trên node). Role tạo wrapper `/usr/local/bin/maxctrl` tự trỏ vào REST API `127.0.0.1:8990` (`mariadb_maxscale_rest_port`). User REST **chỉ có `admin`** (không dùng được user MariaDB như `tdht`). Role đổi mật khẩu `admin` từ mặc định `mariadb` thành `mariadb_maxscale_pass` khi cài. Nếu cài bằng bản role cũ thì mật khẩu vẫn là `mariadb`, đổi bằng: `maxctrl -u admin -p mariadb alter user admin '<mariadb_maxscale_pass>'`.

```bash
maxctrl -u admin -p '<mật khẩu>' list servers        # trạng thái từng node: Master/Slave, Synced, Running
maxctrl -u admin -p '<mật khẩu>' list services       # dịch vụ, số kết nối
maxctrl -u admin -p '<mật khẩu>' list listeners      # cổng 4006 / 4016
maxctrl -u admin -p '<mật khẩu>' list monitors       # Galera-Monitor đang theo dõi những node nào
maxctrl -u admin -p '<mật khẩu>' list sessions       # kết nối client đang mở
maxctrl -u admin -p '<mật khẩu>' show server server_1
maxctrl -u admin -p '<mật khẩu>' show monitor Galera-Monitor
maxctrl -u admin -p '<mật khẩu>' show service Read-Write-Service
maxctrl -u admin -p '<mật khẩu>' show maxscale       # phiên bản, uptime, cấu hình chung
```

Cột `State` trong `list servers` thường gặp: `Master, Synced, Running` (node nhận ghi), `Slave, Synced, Running` (node đọc), `Running` hoặc `Down` (node không dùng được). Dùng `watch -n1 "maxctrl -u admin -p '<mật khẩu>' list servers"` để theo dõi khi test failover.

**Đưa node ra khỏi tuyến (bảo trì)**

```bash
maxctrl -u admin -p '<mật khẩu>' set server server_2 drain          # ngừng nhận kết nối mới, kết nối cũ chạy xong thì thôi
maxctrl -u admin -p '<mật khẩu>' set server server_2 maintenance    # ngừng định tuyến tới node này
maxctrl -u admin -p '<mật khẩu>' clear server server_2 maintenance  # đưa node trở lại
```

Chế độ bảo trì chỉ đổi định tuyến của MaxScale trên node đang gọi lệnh, không dừng MariaDB. Vì mỗi node có một MaxScale độc lập, muốn áp dụng toàn cụm thì chạy lệnh trên cả 3 node (có thể dùng `ansible mariadb -b -m shell -a "maxctrl -u admin -p '<mật khẩu>' set server server_2 maintenance"`).

**Thử failover**

```bash
# 1. Xem node nào đang là Master
maxctrl -u admin -p '<mật khẩu>' list servers
# 2. Dừng MariaDB trên node Master đó
sudo systemctl stop mariadb
# 3. Sau khoảng 2 giây, trên node khác: Master mới được chọn, node cũ báo Down
maxctrl -u admin -p '<mật khẩu>' list servers
# 4. Bật lại node cũ: nó rejoin làm Slave, không giành lại Master
sudo systemctl start mariadb
```

**Service, log, cấu hình MaxScale**

```bash
sudo systemctl status maxscale --no-pager
sudo systemctl restart maxscale
sudo tail -n 80 /var/log/maxscale/maxscale.log
cat /etc/maxscale.cnf                                # cấu hình do role sinh ra
```

Nếu `list servers` hiện `Down` mà MariaDB vẫn chạy, thường do user `maxscale` không đăng nhập được từ IP của node (users.sql chỉ tạo cho `10.%`, `192.168.%` và `172.%`; cluster cài từ bản `users.sql` cũ chưa có `172.%`, cần `CREATE USER` bổ sung), hoặc thiếu cổng 3306 giữa các node. Xem `maxscale.log` để biết lỗi xác thực.

## 5. Gỡ cài đặt (để cài lại)

Playbook riêng [projects/uninstall_mariadb.yml](projects/uninstall_mariadb.yml), **không** nằm trong `main.yml` và không chạy khi cài. **Xóa toàn bộ dữ liệu**, chỉ dùng cho lab/test.

```bash
ansible-playbook projects/uninstall_mariadb.yml -e @projects/lab.yml     # gõ 'yes' để xác nhận
ansible-playbook projects/uninstall_mariadb.yml -e @projects/lab.yml -e mariadb_assume_yes=true   # bỏ hỏi
ansible-playbook projects/uninstall_mariadb.yml -e @projects/lab.yml --limit mariadb-node3        # một node
```

Truyền cùng `-e` như lúc cài để đường dẫn khớp. Sau đó cài lại bằng lệnh ở [mục 2](#2-cài-lab-3-node-2-vcpu--4gb) (chế độ `fresh`).

Playbook xóa trên mỗi node: dừng service và kill tiến trình của user `mariadb`; thư mục cài (`/usr/local/mariadb` + `.bak.*`); dữ liệu, tmp, log, binlog, `/run/mariadb`; `/etc/my.cnf` và unit `mariadb.service` cùng backup; `/etc/profile.d/mariadb.sh`, `/usr/local/bin/mariadb`, `/tmp/mariadb_os_pkgs`; tuning OS (sysctl, limits, disable-thp); user `mariadb` và group `mariadb_log_readers`.

Tùy chọn: `-e mariadb_uninstall_os_tuning=false` (giữ sysctl/limits/THP), `-e mariadb_uninstall_users=false` (giữ user/group).

Không gỡ: gói OS đã cài (`libssl1.1`, jemalloc, numactl...), rule iptables, MaxScale, Vector. Giá trị sysctl đã nạp trong kernel chỉ mất sau reboot. Role chặn xóa khi đường dẫn rỗng hoặc trỏ vào thư mục hệ thống (`/`, `/usr`, `/etc`, `/u01`...).

## 6. Chạy lại và các lệnh khác

```bash
ansible-playbook projects/install_mariadb.yml --tags os,install        # chỉ một số giai đoạn
ansible-playbook projects/install_mariadb.yml --limit <host> -e mariadb_expected_cluster_size=3   # một node (cần ansible_host)
ansible-playbook projects/install_mariadb.yml -e mariadb_install_mode=expand   # chạy lại trên cluster đang chạy
ansible-playbook projects/install_mariadb.yml -e mariadb_install_maxscale=true -e mariadb_install_vector=true
```

Tags: `os`, `install`, `config`, `service`, `datadir`, `init`, `start`, `maxscale`, `vector`.

### Hai chế độ cài

| `mariadb_install_mode` | Dùng khi | Hành vi |
|---|---|---|
| `fresh` (mặc định) | Cài mới | Cài lại binary, init lại datadir. **Từ chối** chạy nếu service đang chạy. Mỗi lần chạy backup thư mục cài cũ thành `.bak.<epoch>` rồi giải nén lại |
| `expand` | Chạy lại, thêm node | Giữ instance đang chạy, bỏ qua bước cài binary nếu thư mục cài đã có. Nếu buffer pool đổi, config mới ghi vào `my.cnf.new` để restart thủ công |

Sau khi cluster đã chạy, muốn chạy lại playbook thì dùng `expand`.

### Chạy lại có an toàn không

- `datadir` và `init` dùng file đánh dấu (`<datadir>/mysql`, `.ansible_init_done`, `grastate.dat`), không init lại dữ liệu đã có.
- Gói OS chỉ copy và cài khi node còn thiếu (ép bằng `mariadb_os_packages_force: true`).
- Backup (thư mục cài, `my.cnf`, unit systemd) chỉ tạo khi nội dung đổi và chỉ giữ `mariadb_backup_keep` bản mới nhất (mặc định 2).
- Cờ bootstrap Galera nằm ở `/run/<service>/wsrep-new-cluster` (tmpfs, chỉ user MariaDB vào được) và bị xóa ngay sau khi start.

## 7. Sự cố thường gặp

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| `Permission denied (publickey,password)` ngay Gathering Facts | `ansible_host` là IP nên SSH không dùng `~/.ssh/config`. Đặt `ansible_user` và `ansible_ssh_private_key_file` trong inventory |
| `iptables ... host/network 'mariadb-node1' not found` | Role dùng tên host thay vì IP. Khai báo `ansible_host` (IP) cho từng node |
| `Timeout when waiting for <ip>:1032` | Cổng Galera bị chặn. Mở 1030–1033 và 3306 giữa các node (cả security group). Xem `iptables -L INPUT -n --line-numbers` trên node đích |
| `mariadb` báo `Can't connect ... /tmp/mysql.sock` | Đang chạy binary thật, không biết socket. Thêm `-S /u01/data/database/mariadb.sock` hoặc gọi `/usr/local/bin/mariadb` |
| Node joiner kẹt "Chờ node Synced", error.log có `libssl.so.1.1: cannot open shared object file` | Thiếu OpenSSL 1.1 cho Galera. Role tự cài `package/os-jammy/libssl1.1_*.deb`; kiểm tra file này có trên bastion rồi chạy lại với `-e mariadb_install_mode=expand` |
| `Service mariadb đang chạy! Dừng trước khi cài fresh` | Chế độ `fresh` từ chối cài đè. Dùng `-e mariadb_install_mode=expand`, hoặc gỡ bằng [uninstall](#5-gỡ-cài-đặt-để-cài-lại) rồi cài lại |
| `Node chỉ có N MB RAM, yêu cầu tối thiểu 2048 MB` | Node dưới `mariadb_min_ram_mb`. Tăng RAM hoặc hạ biến này (chỉ cho lab) |
| Còn `CHANGE_ME` | Đổi mật khẩu trong group_vars |

Để xem lỗi mariadbd trên node: `sudo tail -n 80 /u01/logs/mariadb/mariadb.error.log` và `sudo journalctl -u mariadb --no-pager | tail -50`.

## Luồng chạy

```
Play 1  Chuẩn bị + cài         tất cả node song song, dừng cả playbook nếu 1 node lỗi (any_errors_fatal)
 │
 ├─ common      [always]   kiểm tra biến, RAM tối thiểu, mật khẩu khác CHANGE_ME
 │                         tính buffer pool / max_connections / port / server_id -> dict `inst`
 │                         phát hiện jemalloc/numactl/iptables/libssl1.1, trạng thái service (1 lần)
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

## Cấu trúc

```
ansible-mariadb/
├── ansible.cfg                          # forks, SSH pipelining, ControlPersist
├── projects/
│   ├── install_mariadb.yml              # playbook cài (7 play như trên)
│   ├── uninstall_mariadb.yml            # playbook gỡ sạch để cài lại (lab/test)
│   ├── lab.yml                          # ghi đè cấu hình cho lab 2 vCPU / 4GB
│   └── inventory/
│       ├── databases.yaml               # danh sách node (+ ansible_host, user, key SSH)
│       └── group_vars/mariadb.yml       # cấu hình
└── roles/mariadb/
    ├── defaults/main.yml                # biến mặc định mariadb_*
    ├── handlers/main.yml                # reload sysctl, reload systemd
    ├── files/, templates/               # disable-thp.service, my.cnf, unit systemd, sysctl, limits
    └── tasks/
        ├── main.yml                     # gọi lần lượt các giai đoạn theo tags
        ├── common.yml                   # kiểm tra + tính thông số `inst`
        ├── preflight.yml                # kiểm tra file trên controller
        ├── libs.yml                     # phát hiện jemalloc/numactl/iptables/libssl1.1
        ├── os_*.yml                     # gói offline, firewall, sysctl/limits/THP
        ├── install.yml  config.yml  service.yml  datadir.yml  init.yml
        ├── start*.yml                   # standalone / bootstrap / joiner
        ├── wait_synced.yml  verify_cluster.yml
        ├── backup_cleanup.yml           # giữ N bản backup
        ├── uninstall.yml                # chỉ chạy qua uninstall_mariadb.yml, không nằm trong main
        ├── maxscale.yml  vector.yml
```

## Lưu ý

- Mỗi server cài đúng 1 instance. Ghi đè vai trò bằng host var `mariadb_node_role` (`bootstrap` / `joiner`).
- Mặc định **không** gỡ MariaDB của OS. Đặt `mariadb_remove_os_mariadb: true` để gỡ (chỉ áp dụng khi `fresh`).
- Mật khẩu đang nằm plaintext trong group_vars (chưa dùng ansible-vault). Đừng commit file thật lên repo công khai.
- Chưa chuyển 08 (job cron/backup); script vẫn chạy được trong `scripts/`.
