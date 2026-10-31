# Best practices: kịch bản vận hành cụm MariaDB Galera + MaxScale

Bộ tài liệu và script mô phỏng công việc của DBA trên cụm do role [ansible-mariadb](../ansible-mariadb) dựng ra (3 node Galera, MaxScale trên mỗi node). **Mỗi kịch bản là một thư mục riêng** gồm: một file `README.md` (cơ chế, nguyên lý, các bước thủ công kèm lý do, cách chạy script, kiểm tra, lỗi thường gặp) và các script chạy sẵn cho kịch bản đó. Kiến trúc cụm xem [architecture.md](../architecture.md), cách cài xem [README.md](../README.md).

> **Đọc trước khi dùng.** Các lệnh và script được viết từ cấu hình thực của role (đường dẫn, cổng, tham số `my.cnf`, cách `expand`/`fresh` hoạt động). Đã kiểm tra cú pháp bash, chạy thử toàn bộ luồng phía bastion ở chế độ `DRY_RUN=1` và thử các hàm phân tích dữ liệu trên dữ liệu giả, nhưng **chưa chạy trên cụm thật**. Hãy tập trên cụm lab, đừng chạy thẳng lên production. Những chỗ chưa chắc về cú pháp công cụ ngoài role được ghi chú trong từng kịch bản.

## Các kịch bản

| # | Thư mục | Kịch bản | Script | Downtime | Rủi ro |
|---|---|---|---|---|---|
| 1 | [01-healthcheck](01-healthcheck/README.md) | Kiểm tra sức khỏe hằng ngày | `healthcheck.sh` | Không | Thấp |
| 2 | [02-them-xoa-node](02-them-xoa-node/README.md) | Thêm và xóa node | `maxscale_server.sh` | Không | Trung bình |
| 3 | [03-node-crash-rejoin](03-node-crash-rejoin/README.md) | Một node crash và rejoin | `simulate_crash.sh` | Không | Thấp |
| 4 | [04-mat-toan-bo-cum-bootstrap](04-mat-toan-bo-cum-bootstrap/README.md) | Mất toàn bộ cụm, bootstrap lại | `bootstrap_cluster.sh` | **Có** | Cao |
| 5 | [05-rolling-restart-nang-cap](05-rolling-restart-nang-cap/README.md) | Rolling restart và nâng cấp | `rolling_restart.sh` | Không | Trung bình |
| 6 | [06-ddl-lon](06-ddl-lon/README.md) | Thay đổi schema lớn (DDL) | `rsu_ddl.sh` | Tùy cách | Cao |
| 7 | [07-backup-pitr](07-backup-pitr/README.md) | Backup và point-in-time recovery | `backup_full.sh`, `pitr_restore.sh` | Không | Trung bình |
| 8 | [08-mat-quorum-split-brain](08-mat-quorum-split-brain/README.md) | Mất quorum và split-brain | `simulate_partition.sh` | **Có** (phía thiểu số) | Cao |
| 9 | [09-chan-doan-hieu-nang](09-chan-doan-hieu-nang/README.md) | Chẩn đoán hiệu năng | `performance_report.sh` | Không | Thấp |
| 10 | [10-day-dia-binlog](10-day-dia-binlog/README.md) | Đầy đĩa và dọn binlog | (không) | Có thể | Trung bình |
| 11 | [11-doi-mat-khau](11-doi-mat-khau/README.md) | Đổi mật khẩu user | (không) | Không | Thấp |

Kịch bản 10 và 11 không có script vì thao tác cần quyết định của con người từng bước (xóa file nào, đổi mật khẩu theo thứ tự nào).

**Gợi ý thứ tự học:** 1 (đọc chỉ số) rồi 3 (node chết và hồi phục) rồi 8 (quorum) rồi 4 (mất cả cụm) rồi 5 (rolling restart) rồi 7 (backup), sau đó các kịch bản còn lại. Kịch bản 1 và 8 chứa phần lớn khái niệm nền mà các kịch bản khác dựa vào.

## Services mô phỏng tải

Thư mục [services](services/README.md) chứa hai service backend Python (writer ghi liên tục, reader cung cấp API đọc, kết nối theo chuỗi 3 node qua MaxScale, chạy trên bastion) và một Frontend chạy trên máy local. Dùng chúng để tạo tải thật rồi thử các kịch bản ở trên (node chết, rolling restart, mất quorum, backup) và quan sát tác động.

## Cách dùng: pull về và chạy trên bastion

```bash
cd ~/learn_mariadb && git pull
cd best_practices/01-healthcheck
./healthcheck.sh
```

Mỗi script nằm trong thư mục kịch bản của nó, **chạy trong thư mục nào cũng được** (chúng tự tìm [lib.sh](lib.sh) và [ansible-mariadb](../ansible-mariadb) để lấy inventory và `ansible.cfg`). Bastion cần có Ansible và SSH được tới các node như khi cài.

**Cách các script hoạt động.** Mỗi script chạy trên bastion, dùng module `script` của Ansible để copy **chính file đó** lên node và chạy bằng quyền root với tham số `--node`. Vì vậy không cần cài gì thêm trên node.

**Biến môi trường chung** (đặt trước lệnh hoặc `export`):

| Biến | Ý nghĩa | Mặc định |
|---|---|---|
| `MARIADB_ROOT_PASSWORD` | Mật khẩu `root` của MariaDB | Đọc `mariadb_admin_pass` trong [group_vars/mariadb.yml](../ansible-mariadb/projects/inventory/group_vars/mariadb.yml). Nếu mật khẩu bị mã hóa vault thì bắt buộc đặt biến này |
| `MAXCTRL_PASSWORD` | Mật khẩu user REST `admin` của MaxScale | `mariadb` |
| `LIMIT` | Chỉ chạy trên một host (với script có hỗ trợ) | cả nhóm `mariadb` |
| `DRY_RUN=1` | Chỉ in các lệnh `ansible` sẽ chạy, không thực thi | tắt |
| `YES=1` | Bỏ qua bước hỏi xác nhận | hỏi xác nhận |
| `ANSIBLE_DIR` | Thư mục ansible-mariadb | `../ansible-mariadb` |

Mật khẩu được truyền cho node dưới dạng tham số của script nên có thể thấy tạm thời trong danh sách tiến trình (`ps`) trên bastion và node. Chấp nhận được cho lab; với production hãy dùng cách quản lý bí mật phù hợp.

## Cấu trúc thư mục

```
best_practices/
├── README.md                          # trang này
├── lib.sh                             # hàm dùng chung cho các script (được source, không chạy trực tiếp)
├── 01-healthcheck/                    # README.md + healthcheck.sh
├── 02-them-xoa-node/                  # README.md + maxscale_server.sh
├── 03-node-crash-rejoin/              # README.md + simulate_crash.sh
├── 04-mat-toan-bo-cum-bootstrap/      # README.md + bootstrap_cluster.sh
├── 05-rolling-restart-nang-cap/       # README.md + rolling_restart.sh
├── 06-ddl-lon/                        # README.md + rsu_ddl.sh
├── 07-backup-pitr/                    # README.md + backup_full.sh + pitr_restore.sh
├── 08-mat-quorum-split-brain/         # README.md + simulate_partition.sh
├── 09-chan-doan-hieu-nang/            # README.md + performance_report.sh
├── 10-day-dia-binlog/                 # README.md
├── 11-doi-mat-khau/                   # README.md
└── services/                          # writer + reader (bastion) và frontend (máy local) mô phỏng tải
```

Các script gọi lẫn nhau theo đường dẫn tương đối trong thư mục này (ví dụ `rolling_restart.sh` gọi `01-healthcheck/healthcheck.sh`); đừng di chuyển riêng một thư mục ra khỏi `best_practices/`.

## Thông số của project này

| Mục | Giá trị |
|---|---|
| Service | `mariadb`, `maxscale` (systemd) |
| Binary | `/usr/local/mariadb/bin/` (`mariadb`, `mariabackup`, `mariadb-binlog`, `mariadb-dump`, `mariadb-admin`, `mariadb-upgrade`, `mariadb-dumpslow`, `galera_recovery`, `garbd`) |
| Socket | `/u01/data/database/mariadb.sock` |
| Datadir / tmp | `/u01/data/database`, `/u01/data/database_tmp` |
| Log | `/u01/logs/mariadb/mariadb.error.log`, `mariadb.slow.log` (`long_query_time=1`), `database_audit.log` |
| Binlog | `/u01/logs/mariadb/binlog/binlog.NNNNNN`, ROW, giữ `expire_logs_days=3`, mỗi file tối đa 512M |
| Cấu hình | `/etc/my.cnf` (do role sinh), `/etc/systemd/system/mariadb.service` |
| Galera | `wsrep_sst_method=mariabackup`, cổng 1031 SST / 1032 group / 1033 IST, `cert.log_conflicts=ON` |
| MaxScale | RW `4006`, RO `4016`, monitor `Galera-Monitor`, REST `127.0.0.1:8990`, cấu hình `/etc/maxscale.cnf`, log `/var/log/maxscale/maxscale.log` |
| Chẩn đoán đã bật | `performance_schema=1`, `userstat=1`, slow log, audit (`QUERY_DDL,QUERY_DCL,CONNECT`) |

**Quy ước trong các lệnh thủ công.** Chạy trên node với quyền root (`sudo -i`). Đăng nhập MariaDB đầy đủ (sẽ hỏi mật khẩu `root`, là `mariadb_admin_pass`):

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock
```

Lệnh `maxctrl` dùng user REST `admin`, mật khẩu `mariadb`:

```bash
maxctrl -u admin -p mariadb list servers
```

Tên server trong MaxScale theo thứ tự inventory: `server_1`, `server_2`, `server_3`. `<ip-node1>`, `<ip-node2>`... là giá trị bạn thay vào.

## Thuật ngữ nền tảng (dùng chung cho mọi kịch bản)

Mỗi kịch bản giải thích lại phần liên quan; đây là bản tóm tắt để tra nhanh.

| Thuật ngữ | Ý nghĩa ngắn gọn | Giải thích kỹ ở |
|---|---|---|
| **Writeset** | Gói thay đổi của một giao dịch, gửi tới mọi node khi `COMMIT` | [Kịch bản 1](01-healthcheck/README.md) |
| **Certification** | Mỗi node tự kiểm tra writeset có xung đột với giao dịch khác không; kết quả giống nhau trên mọi node | [Kịch bản 1](01-healthcheck/README.md), [9](09-chan-doan-hieu-nang/README.md) |
| **`seqno` và `uuid`** | Số thứ tự toàn cục của giao dịch đã commit và mã lịch sử của cụm | [Kịch bản 4](04-mat-toan-bo-cum-bootstrap/README.md) |
| **SST** | Chép toàn bộ dữ liệu từ donor sang node (dùng `mariabackup`), cho node mới hoặc quá lệch | [Kịch bản 2](02-them-xoa-node/README.md), [3](03-node-crash-rejoin/README.md) |
| **IST** | Chỉ gửi phần thay đổi bị lỡ, lấy từ `gcache` của donor | [Kịch bản 3](03-node-crash-rejoin/README.md) |
| **`gcache`** | File vòng giữ các writeset gần đây trên mỗi node, quyết định node tắt bao lâu thì còn IST | [Kịch bản 3](03-node-crash-rejoin/README.md) |
| **Quorum / Primary** | Nhóm node chiếm hơn nửa mới được hoạt động; `non-Primary` tự ngừng để chống split-brain | [Kịch bản 8](08-mat-quorum-split-brain/README.md) |
| **Flow control** | Một node chậm phát tín hiệu dừng, kéo cả cụm chậm theo | [Kịch bản 1](01-healthcheck/README.md), [9](09-chan-doan-hieu-nang/README.md) |
| **Bootstrap** | Tạo cụm mới (`--wsrep-new-cluster`) từ dữ liệu của một node | [Kịch bản 4](04-mat-toan-bo-cum-bootstrap/README.md) |
| **TOI / RSU** | Hai cách chạy DDL: đồng thời trên mọi node (chặn cụm) hoặc từng node một | [Kịch bản 6](06-ddl-lon/README.md) |
| **Drain** | MaxScale ngừng nhận kết nối mới cho một server | [Kịch bản 2](02-them-xoa-node/README.md), [5](05-rolling-restart-nang-cap/README.md) |
| **PITR** | Khôi phục về thời điểm = backup + phát lại binlog | [Kịch bản 7](07-backup-pitr/README.md) |

## Checklist vận hành nhanh

| Tần suất | Việc | Kịch bản |
|---|---|---|
| Hằng ngày | `healthcheck.sh`; xem `df -h /u01`; xem `[ERROR]` mới trong error log | [1](01-healthcheck/README.md) |
| Hằng tuần | `performance_report.sh`, xem top slow query; khôi phục thử backup mới nhất | [9](09-chan-doan-hieu-nang/README.md), [7](07-backup-pitr/README.md) |
| Hằng tháng | `rolling_restart.sh` để kiểm tra khả năng chịu lỗi; xoay mật khẩu | [5](05-rolling-restart-nang-cap/README.md), [11](11-doi-mat-khau/README.md) |
| Trước mọi thay đổi | `backup_full.sh`, `healthcheck.sh`, đọc lại kịch bản tương ứng, thử trên lab | [7](07-backup-pitr/README.md), [1](01-healthcheck/README.md) |
| Sau mọi thay đổi | `healthcheck.sh`, ghi thử qua cổng 4006 | [1](01-healthcheck/README.md) |
