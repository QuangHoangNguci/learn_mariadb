# Kịch bản 1: Healthcheck hằng ngày

**Script:** [healthcheck.sh](healthcheck.sh) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

Biết cụm có khỏe không **trước khi** người dùng báo lỗi. Healthcheck là kịch bản nền: chạy nó **trước và sau** mọi thao tác thay đổi (thêm node, restart, DDL, backup...) để biết thao tác đó có làm cụm xấu đi không. Nếu chỉ chạy khi có sự cố thì bạn không có mốc để so sánh "bình thường" là như thế nào.

## 2. Kiến thức nền: một cụm Galera khỏe trông như thế nào

Một cụm Galera không chỉ là "các node đang chạy". Cụm khỏe khi cùng lúc thỏa **bốn tầng**:

| Tầng | Câu hỏi | Chỉ số |
|---|---|---|
| Tiến trình | Dịch vụ có chạy không? | `systemctl is-active mariadb` |
| Thành viên cụm | Node có thuộc về cụm đủ quorum không, cụm có đủ node không? | `wsrep_cluster_status`, `wsrep_cluster_size`, `wsrep_connected` |
| Đồng bộ dữ liệu | Node đã bắt kịp dữ liệu và nhận truy vấn được chưa? | `wsrep_local_state_comment`, `wsrep_ready`, hàng đợi, flow control |
| Tài nguyên | Có sắp hết đĩa, hết kết nối, đầy lỗi không? | đĩa, `Threads_connected`/`max_connections`, error log |

Phía trước cụm còn **MaxScale**: nó phải thấy đủ server và đăng nhập được vào từng server.

### Ý nghĩa từng chỉ số Galera

- **`wsrep_cluster_status`**: `Primary` nghĩa là node này đang ở thành phần (component) có **đa số phiếu** (quorum). `non-Primary` nghĩa là node bị tách khỏi đa số, nó **tự từ chối đọc/ghi** để không tạo dữ liệu lệch. Đây là cơ chế bảo vệ, xem kịch bản 8.
- **`wsrep_cluster_size`**: số node node này đang thấy trong cụm. Nhỏ hơn số node thiết kế nghĩa là có node đã rời hoặc bị cô lập.
- **`wsrep_local_state_comment`**: vòng đời của node: `Joining` (đang nhận dữ liệu), `Joined` (nhận xong, đang bắt kịp), **`Synced`** (đã bắt kịp, bình thường), `Donor/Desynced` (đang gửi dữ liệu cho node khác hoặc bị tách khỏi flow control). Chỉ `Synced` mới là trạng thái phục vụ bình thường.
- **`wsrep_ready` / `wsrep_connected`**: `wsrep_connected = ON` là node đã nối vào cụm; `wsrep_ready = ON` là node sẵn sàng nhận truy vấn ứng dụng. Có thể `connected` nhưng chưa `ready`.
- **`wsrep_local_recv_queue_avg`**: số writeset trung bình đang **chờ được áp dụng (apply)** trên node này. Mỗi giao dịch commit ở node khác sinh ra một writeset gửi tới mọi node; node nào apply chậm thì hàng đợi này dài lên.
- **`wsrep_flow_control_paused`**: tỉ lệ thời gian (0 đến 1) cụm bị **tạm dừng** vì flow control. Cơ chế: khi hàng đợi apply của một node vượt ngưỡng `gcs.fc_limit`, node đó gửi tín hiệu "dừng" cho **cả cụm** cho đến khi nó bắt kịp. Một node chậm có thể kéo **toàn bộ cụm** chậm theo, vì Galera ưu tiên các node nhất quán hơn là tốc độ. Giá trị gần 0 là tốt, gần 1 là cụm gần như đứng.
- **`wsrep_local_cert_failures`** và **`wsrep_local_bf_aborts`**: đếm các giao dịch bị hủy do **xung đột** khi hai node cùng sửa một dòng. `cert_failures`: giao dịch cục bộ không qua kiểm tra certification. `bf_aborts` ("brute force abort"): giao dịch cục bộ đang chạy bị hủy vì một writeset nhân bản từ node khác tới sau xung đột với nó và được ưu tiên. Hai số này tăng nhanh nghĩa là ứng dụng đang ghi đụng nhau giữa các node.

### Vì sao còn kiểm tra đĩa, kết nối, log

- **Đĩa:** hết chỗ thì InnoDB, binlog hoặc `gcache` không ghi được, node gặp lỗi và có thể dừng. Cảnh báo sớm ở 80% vì dọn dẹp cần thời gian.
- **Kết nối:** `Threads_connected` chạm `max_connections` thì ứng dụng mới không vào được. Role còn mở một cổng quản trị dự phòng (`extra_port` 1301) để DBA vẫn đăng nhập được lúc đó.
- **Error log (`[ERROR]`):** nhiều lỗi nhỏ lặp lại thường báo trước sự cố lớn.

### Trạng thái MaxScale

`maxctrl list servers` cho mỗi server một trạng thái. Với `galeramon`: **`Master, Synced, Running`** là node nhận ghi, **`Slave, Synced, Running`** là node đọc, `Down` là MaxScale không kết nối được, **`Auth Error`** là kết nối được nhưng user `maxscale` bị từ chối (thường do host của user không khớp IP nguồn).

## 3. Cách 1: Chạy script

```bash
cd ~/learn_mariadb/best_practices/01-healthcheck
./healthcheck.sh                                  # cả cụm
LIMIT=mariadb-node2 ./healthcheck.sh              # một node
EXPECTED=4 ./healthcheck.sh                       # khi cụm có 4 node
DRY_RUN=1 ./healthcheck.sh                        # chỉ in lệnh ansible
```

Script copy chính nó lên từng node (module `script` của Ansible) và kiểm tra tại chỗ. Mỗi dòng báo `[ OK ]` hoặc `[FAIL]`:

| Kiểm tra | Điều kiện đạt |
|---|---|
| service `mariadb` | `active` |
| `wsrep_cluster_status` | `Primary` |
| `wsrep_local_state_comment` | `Synced` |
| `wsrep_cluster_size` | bằng `EXPECTED` (mặc định: số host trong inventory) |
| `wsrep_ready`, `wsrep_connected` | `ON` |
| `wsrep_flow_control_paused` | dưới 0.1 |
| `wsrep_local_recv_queue_avg` | dưới 1 |
| Kết nối đang dùng | dưới 80% `max_connections` |
| Đĩa datadir | dưới 80% |
| MaxScale | `maxctrl list servers` không có `Down` hoặc `Auth Error` |

Script cũng in số dòng `[ERROR]` trong error log và 3 dòng gần nhất. Mã thoát khác 0 nếu **bất kỳ** node nào có `[FAIL]`, nên dùng được trong cron hoặc công cụ giám sát. Ngưỡng 0.1, 1 và 80% là ngưỡng tham khảo, sửa trong script nếu hệ thống của bạn khác.

## 4. Cách 2: Các bước thủ công và lý do

Chạy trên từng node (quyền root). Đăng nhập MariaDB đầy đủ: `mariadb -u root -p -S /u01/data/database/mariadb.sock` (sẽ hỏi mật khẩu `root`).

### Bước 1. Xem trạng thái Galera

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready','wsrep_connected','wsrep_flow_control_paused','wsrep_local_recv_queue_avg','wsrep_local_cert_failures','wsrep_local_bf_aborts');"
```

**Tại sao:** các biến `wsrep_*` do thư viện Galera cập nhật liên tục, đây là nguồn sự thật về **vai trò của node trong cụm**. `SHOW GLOBAL STATUS` (không phải `SESSION`) vì ta quan tâm số liệu của cả máy chủ. Hãy chạy trên **mọi node**, vì mỗi node có góc nhìn riêng: một node bị cô lập vẫn tưởng mình bình thường nếu bạn chỉ hỏi node khác.

| Chỉ số | Khỏe | Báo động |
|---|---|---|
| `wsrep_cluster_size` | bằng số node (3) | nhỏ hơn 3: có node rời cụm |
| `wsrep_cluster_status` | `Primary` | `non-Primary`: mất quorum (kịch bản 8) |
| `wsrep_local_state_comment` | `Synced` | `Donor/Desynced`, `Joining`: đang SST hoặc IST |
| `wsrep_flow_control_paused` | gần 0 | gần 1: một node chậm kéo cả cụm |
| `wsrep_local_recv_queue_avg` | dưới 1 | lớn liên tục: node này apply chậm |

### Bước 2. Xem MaxScale nhìn các node như thế nào

```bash
maxctrl -u admin -p mariadb list servers
```

**Tại sao:** ứng dụng đi qua MaxScale, không đi thẳng vào MariaDB. Một node có thể khỏe với `mariadb` nhưng `Down` hoặc `Auth Error` ở MaxScale (sai user hoặc mạng), khi đó ứng dụng vẫn lỗi. Kết quả mong đợi: một `Master` và hai `Slave`, đều `Synced, Running`. Mỗi node có một MaxScale độc lập, nên với kiểm tra kỹ hãy chạy lệnh này trên cả 3 node.

### Bước 3. Xem tài nguyên

```bash
df -h /u01
du -sh /u01/data/database /u01/logs/mariadb /u01/logs/mariadb/binlog
free -m
uptime
```

**Tại sao:** `df` cho biết còn bao nhiêu chỗ; `du` cho biết cái gì đang chiếm chỗ (dữ liệu, log hay binlog) để biết cần dọn gì (kịch bản 10). `free` và `uptime` cho thấy RAM và tải; swap bị dùng nhiều là dấu hiệu `innodb_buffer_pool_size` quá lớn so với RAM.

### Bước 4. Đọc log lỗi gần đây

```bash
grep -E "\[ERROR\]|\[Warning\] WSREP" /u01/logs/mariadb/mariadb.error.log | tail -20
systemctl status mariadb maxscale --no-pager
```

**Tại sao:** nhiều sự cố Galera (mất kết nối giữa node, xung đột, SST lỗi) hiện trong error log trước khi hiện ở các chỉ số. Lọc `[Warning] WSREP` để thấy cảnh báo của Galera, không chỉ lỗi cứng.

### Bước 5. Kiểm tra kết nối và hiệu quả cache

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Max_used_connections','Aborted_connects','Created_tmp_disk_tables','Slow_queries'); SELECT @@max_connections;"
```

**Tại sao:** `Max_used_connections` gần `max_connections` là dấu hiệu sắp hết kết nối; `Threads_running` cao kéo dài là tải CPU/khóa; `Created_tmp_disk_tables` nhiều là truy vấn tạo bảng tạm trên đĩa (chậm).

Tỉ lệ cache InnoDB:

```sql
SELECT ROUND(100 * (1 - r.v / q.v), 2) AS buffer_pool_hit_pct
FROM (SELECT VARIABLE_VALUE+0 v FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Innodb_buffer_pool_reads') r,
     (SELECT VARIABLE_VALUE+0 v FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests') q;
```

**Tại sao:** `Innodb_buffer_pool_read_requests` là số lần đọc trang logic, `Innodb_buffer_pool_reads` là số lần phải đọc từ **đĩa** vì trang không có trong bộ nhớ. Tỉ lệ cache = 1 trừ tỉ lệ trượt. Trên cụm đã chạy ổn định nên trên 99%; thấp nghĩa là buffer pool nhỏ hơn dữ liệu nóng hoặc có truy vấn quét toàn bảng.

## 5. Kiểm tra kết quả

Healthcheck đạt khi script thoát mã 0 và mọi dòng là `[ OK ]`. Lưu kết quả lúc bình thường để so sánh về sau.

## 6. Lỗi thường gặp

| Triệu chứng | Nguyên nhân khả dĩ |
|---|---|
| `[FAIL] maxctrl list servers lỗi` | Sai mật khẩu REST `admin` (đặt `MAXCTRL_PASSWORD`), hoặc MaxScale chưa chạy |
| `[FAIL] MaxScale báo ... Auth Error` | User `maxscale` không có host khớp IP node (xem [users.sql](../../setup/mariadb/Install_Mariadb/users.sql)) |
| `[FAIL]` ở mọi chỉ số Galera, `mariadb` vẫn `active` | Sai mật khẩu `root` (đặt `MARIADB_ROOT_PASSWORD`) nên script không đọc được số liệu |
| `wsrep_cluster_size` nhỏ hơn mong đợi | Có node rời cụm, xem kịch bản 3 hoặc 8 |

## 7. Điểm cốt lõi cần nhớ

- "Node chạy" khác "cụm khỏe": phải xét cả quorum, đồng bộ, tài nguyên và MaxScale.
- Chạy healthcheck trên **mọi node**, mỗi node tự báo vai trò của nó.
- `flow_control_paused` cao là dấu hiệu **một node chậm kéo cả cụm**, đừng chỉ nhìn node bị ảnh hưởng.
- Luôn có mốc "bình thường" để so sánh trước khi thay đổi.
