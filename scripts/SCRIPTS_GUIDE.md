# Giải thích các script trong `scripts/`

Bộ script cài MariaDB (single / DR / Galera cluster) **offline**, chạy tuần tự `01 → 09`. Cấu hình lấy từ `configs/cluster.env`, gói cài nằm trong `package/`.

## Thứ tự chạy

| Script | Việc chính |
|---|---|
| `01_prepare_system.sh` | Chuẩn bị hệ điều hành |
| `02_install_mariadb_binary.sh` | Giải nén binary MariaDB, tạo user/thư mục |
| `03_configure_mariadb.sh` | Sinh file `my.cnf` cho từng instance |
| `04_enable_mariadb_service.sh` | Sinh unit systemd |
| `05_prepare_database.sh` | Khởi tạo datadir rỗng |
| `06_initialize_database.sh` | Import schema, user, đặt mật khẩu root (chạy tay) |
| `07_maxscale_install.sh` | Cài và cấu hình MaxScale (proxy/load balancer) |
| `08_install_db_jobs.sh` | Cài job cron vận hành (backup, analyze, partition, rotate log) |
| `09_install_vector.sh` | Cài Vector thu log MariaDB |
| `common.sh` | Hàm dùng chung (được `source` bởi các script) |
| `lib/render_mycnf.sh` | Hàm sinh `my.cnf` từ template |
| `show_config.sh` | In bản xem trước cấu hình tính toán, không sửa gì |
| `test.sh` | Kiểm tra nhanh parser và các ràng buộc bảo mật |

---

## 01_prepare_system.sh — Chuẩn bị hệ thống

- Phát hiện OS (Ubuntu / CentOS-RHEL).
- Chế độ `fresh`: hỏi xác nhận rồi dừng/gỡ MariaDB/MySQL của OS để tránh xung đột.
- Gỡ `ufw`, cài các gói `.deb` offline từ `package/os/`.
- Mở iptables cho syslog/NTP/DNS, node quản trị, node primary (DR) và các node Galera.
- Tinh chỉnh kernel (`vm.swappiness`, `fs.file-max`, `vm.min_free_kbytes`), tăng giới hạn `nofile`, tắt THP, tắt NUMA zone reclaim (nếu bật trong env).

**Thư viện/gói được cài (`package/os/`):**

| Gói | Công dụng |
|---|---|
| `libjemalloc2` | Bộ cấp phát bộ nhớ jemalloc, MariaDB nạp qua `LD_PRELOAD` để ít phân mảnh RAM (**bắt buộc**) |
| `numactl` (`os-jammy/`), `libnuma1` | Chạy MariaDB với `--interleave=all` trên máy NUMA (**bắt buộc**) |
| `iptables`, `iptables-persistent`, `netfilter-persistent` | Tường lửa và lưu rule sau khi reboot (**bắt buộc**: `iptables`) |
| `keepalived` | VIP / failover giữa các node |
| `rsync`, `socat` | Công cụ SST (đồng bộ dữ liệu) cho Galera |
| `libmariadb3`, `mariadb-common`, `mysql-common` | Thư viện client chung (hai gói `common` và `libmariadb3` bị bỏ qua khi cài để tránh xung đột) |
| `libmicrohttpd12t64`, `libprotobuf32t64`, `libsnmp40t64`, `libsnmp-base`, `libicu74`, `libatomic1`, `liburing2`, `libltdl7`, `gcc-14-base` | Thư viện phụ thuộc của MaxScale / MariaDB / keepalived |
| `unixodbc`, `unixodbc-common`, `libodbc2`, `libodbcinst2` | Thư viện ODBC (phụ thuộc của MaxScale) |
| `libconfig-inifiles-perl`, `gnupg` | Phụ thuộc Perl/GPG cho các gói MariaDB |
| `net-tools`, `psmisc`, `traceroute`, `inetutils-telnet`, `unzip` | Công cụ mạng, quản lý tiến trình, kiểm tra kết nối, giải nén |
| `os-el7/jemalloc` (`.rpm`) | jemalloc cho CentOS 7 |

> Chỉ jemalloc, numactl, iptables là *critical*; các gói khác lỗi chỉ cảnh báo.

## 02_install_mariadb_binary.sh — Cài binary MariaDB

- Giải nén tarball `mariadb-*.tar.gz` (từ `package/mariadb/`) cho từng instance vào `/usr/local/mariadb[_ID]`.
- Tạo user hệ thống riêng cho từng instance, tạo thư mục data/tmp/log/binlog và phân quyền.
- Vá password policy trong `enterprise.cnf`, thêm PATH vào `/etc/profile.d`, tạo wrapper lệnh `mariadb[ID]`.
- Kiểm tra port không bị chiếm. Chỉ cảnh báo nếu thiếu jemalloc/numactl.

## 03_configure_mariadb.sh — Sinh `my.cnf`

- Bắt buộc có jemalloc và numactl.
- Tự tính thông số theo RAM, CPU, loại đĩa (buffer pool, log file, IO capacity, thread pool).
- Tạo nhóm `mariadb_log_readers` để các dịch vụ khác (Vector) đọc log.
- Backup file config cũ, render `my.cnf` mới (dùng `lib/render_mycnf.sh`).
- Chế độ `expand`: nếu buffer pool đổi thì ghi file `.new` và cảnh báo cần rolling restart.

## 04_enable_mariadb_service.sh — Service systemd

- Sinh `/etc/systemd/system/mariadb_<ID>.service` (không tự enable/start, người dùng làm sau bước 05).
- Unit có `LD_PRELOAD` jemalloc, `ExecStart` bọc qua `numactl`, `LimitNOFILE`, `Restart=on-failure`; Galera có `ExecStartPre` chạy `galera_recovery`.
- Chế độ `fresh`: dừng/disable service MariaDB mặc định của OS.
- Galera: sửa đường dẫn trong các script helper wsrep (`wsrep_sst_*`) cho đúng thư mục cài.

## 05_prepare_database.sh — Khởi tạo datadir

- Chạy `mariadb-install-db` tạo datadir rỗng và system table cho từng instance.
- Bỏ qua instance thiếu binary/config, đang chạy, hoặc đã có datadir; `fresh` dọn file rác trong datadir.
- Không đặt mật khẩu root, không import schema.

## 06_initialize_database.sh — Import schema và đặt mật khẩu (chạy tay)

- Chỉ chạy trên node bootstrap hoặc standalone (joiner bị chặn); DR cần xác nhận.
- Bật `mariadbd` tạm (`--skip-networking`) qua socket, import `vsystem.sql`, sinh và import `users.sql` (thay placeholder mật khẩu), đặt mật khẩu root, rồi tắt.
- `EMPTY_CLUSTER=true`: chỉ đặt mật khẩu root (dùng khi data lấy từ backup/`mariabackup`).
- In gợi ý bước tiếp: `galera_new_cluster` (bootstrap) hoặc `systemctl start`.

## 07_maxscale_install.sh — MaxScale

- Tạo user `maxscale`, cài NodeJS offline (`package/nodejs/node-*.tar.xz`, cần cho giao diện MaxGUI).
- Cài MaxScale từ `.deb` (`dpkg -i`) hoặc `.tar.gz` trong `package/maxscale/` (tự nhận dạng, hoặc ép bằng `MAXSCALE_PACKAGE_TYPE`).
- Sinh cấu hình và service cho từng instance, mở cổng R/W và R/O theo `INSTANCE_<ID>`, tạo wrapper `maxctrl[ID]` điều khiển qua REST.

| Thành phần | Công dụng |
|---|---|
| MaxScale | Proxy/load balancer: tách đọc/ghi, tự chuyển hướng khi node lỗi |
| NodeJS (v18) | Cần cho `maxctrl` / giao diện MaxGUI |
| `maxctrl` | Công cụ dòng lệnh quản trị MaxScale qua REST |
| `libmicrohttpd12t64` | HTTP server cho REST API của MaxScale |
| `libtbb12`, `libboost-serialization`, `libmemcached11t64`, `librdkafka++1` | Thư viện phụ thuộc của MaxScale (song song, serialize, cache, Kafka); cần để cùng `.deb`, thiếu thì `dpkg` lỗi |

> Chỉ chạy khi `ENABLE_MAXSCALE=true` và `ENABLE_GALERA=true`.

## 08_install_db_jobs.sh — Job vận hành (cron)

- Tạo user `mariadb_jobs` (không phải root) và nhóm `mariadb_log_readers`.
- Sinh script: `auto_add_partition`, `auto_analyze` (chạy trên node bootstrap), `innodb_stat`, `backup_database`, `rotate_mariadb_log` cho từng instance.
- Chọn job qua tham số, biến `JOBS` hoặc menu; cài vào `/etc/cron.d/` (backup dùng `flock` để không chạy chồng).
- Gỡ cron cũ của root và kiểm tra không còn job nào chạy bằng root.
- Script này **không cài gói**, chỉ cần các công cụ sau có sẵn:

| Công cụ | Công dụng |
|---|---|
| `mariadb` client | Chạy SQL |
| `mariadb-backup` / `mariabackup` | Backup vật lý cho Galera |
| `qpress` | Nén/giải nén file backup, binlog (`.qp`) |
| `openssl` | Mã hóa backup AES-256-CBC |
| `mc` (MinIO client) | Đẩy backup và checksum lên MinIO |
| `flock` (util-linux) | Chống chạy backup đồng thời |
| `cron` | Lập lịch |
| `sha256sum`, `xargs`, `tar`, `gzip` | Checksum song song, xoay log |

## 09_install_vector.sh — Vector (thu log)

- Tạo user/group `vector_mariadb` (không đăng nhập, không phải root) và thư mục `/u01/apps/vector_mariadb`.
- Cấp quyền đọc log MariaDB qua nhóm `mariadb_log_readers`.
- Copy binary `vector` và `vector.yaml`, dùng `python3` vá đường dẫn log từng instance và IP local.
- Validate config, sinh unit `vector_mariadb.service`, enable và restart.

| Thành phần | Công dụng |
|---|---|
| `vector` | Thu thập log MariaDB, biến đổi và đẩy đi nơi khác |
| `python3` | Vá file `vector.yaml` |
| `runuser` (util-linux) | Kiểm tra quyền đọc log bằng user vector |

## common.sh — Hàm dùng chung

- **Log**: `log`, `warn`, `error`, `die`, `step` (ghi vào `/var/log/mariadb_cluster/cluster.log`).
- **Kiểm tra**: `check_root`, `require_cmd`, `require_file`, `confirm` (hỏi y/N, hỗ trợ `ASSUME_YES`).
- **Instance**: `parse_instances_table` đọc `INSTANCE_<ID>`; các hàm `get_install_dir`, `get_data_dir`, `get_conf_file`... thay `{ID}` trong pattern đường dẫn.
- **Topology**: `derive_topology` (`single | dr | cluster | dr-cluster` → `ENABLE_GALERA`, `REPLICA_MODE`), `compute_wsrep_ports`, `detect_node_index`.
- **Tune**: `detect_disk_type`, `compute_tune_for_id` tính buffer pool, log file, IO, thread pool.
- **Validate**: `validate_cluster_env`, `validate_passwords_for_init`, `preflight_check` (RAM/disk).

## lib/render_mycnf.sh

Cung cấp `render_mycnf <ID> <out_file>`: tính giá trị (đường dẫn, auto-tune, server-id, GTID, wsrep, `libgalera_smm.so`) rồi ghép các template trong `configs/templates/` (`my.cnf.base.tmpl`, `block.galera.tmpl`, `block.dr.tmpl`) bằng `awk`/`sed`.

## show_config.sh và test.sh

- `show_config.sh`: in bảng auto-tune, cổng wsrep/SST/IST và đường dẫn theo từng ID để xem trước; không sửa file.
- `test.sh`: kiểm tra parser `INSTANCE_<n>`, tên cluster/mật khẩu theo instance, và đảm bảo script 08/09 không chạy bằng root.
