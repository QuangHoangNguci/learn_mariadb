# Kịch bản 9: Chẩn đoán hiệu năng

**Script:** [performance_report.sh](performance_report.sh) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

Khi ứng dụng báo **chậm**, tìm ra chậm ở **tầng nào** và **do truy vấn nào**, theo thứ tự từ ngoài vào trong, thay vì đoán mò hay vội tăng cấu hình. Kịch bản này chỉ **đọc**, không thay đổi gì trên cụm, nên an toàn chạy bất cứ lúc nào.

## 2. Kiến thức nền: chẩn đoán theo tầng

Chậm có thể nằm ở bốn tầng khác nhau; hỏi theo thứ tự để loại trừ nhanh:

| Tầng | Câu hỏi | Công cụ |
|---|---|---|
| 1. Hệ thống | CPU, RAM, đĩa có bão hòa không? | `top`, `vmstat`, `iostat`, `free` |
| 2. Galera | Cụm có bị kéo chậm bởi một node hoặc xung đột? | `wsrep_flow_control_*`, `wsrep_local_recv_queue_avg`, `wsrep_local_cert_failures` |
| 3. MariaDB | Có khóa, hết kết nối, bộ đệm nhỏ? | `PROCESSLIST`, `INNODB_TRX`, buffer pool hit |
| 4. Truy vấn | Câu lệnh nào chậm và vì sao? | slow log, `performance_schema`, `EXPLAIN`/`ANALYZE` |

Chẩn đoán theo tầng tránh sai lầm kinh điển: tối ưu truy vấn khi nút cổ chai là đĩa, hay thêm RAM khi thủ phạm là một truy vấn thiếu index.

### 2.1 Slow log

MariaDB ghi mọi câu lệnh chạy **lâu hơn `long_query_time`** vào slow log. Role đặt `slow_query_log=1` và `long_query_time=1` (1 giây). Nó **chỉ ghi sau khi lệnh chạy xong**, nên lệnh đang treo chưa thấy ở đây (xem `PROCESSLIST`). `mariadb-dumpslow` tóm tắt slow log: gom các lệnh giống nhau (thay hằng số bằng `N`/`S`) rồi xếp theo tổng thời gian, giúp thấy **nhóm** lệnh tốn nhiều nhất chứ không chỉ lệnh chậm nhất.

### 2.2 performance_schema digest

`events_statements_summary_by_digest` gom thống kê theo **mẫu câu lệnh chuẩn hóa** (digest): số lần gọi, tổng/trung bình thời gian, số dòng quét, số lần không dùng index. Khác slow log: nó tính cả lệnh **nhanh nhưng gọi rất nhiều**, thường mới là thủ phạm thật. Cột `SUM_NO_INDEX_USED` lớn là gợi ý thiếu index.

### 2.3 userstat

Role bật `userstat=1`, MariaDB tự thống kê theo bảng, index, user vào `information_schema.TABLE_STATISTICS`, `INDEX_STATISTICS`, `USER_STATISTICS`. Dùng để biết **bảng nào đọc nhiều nhất**, index nào hữu ích (và index **không bao giờ được đọc** là ứng viên để xóa vì chỉ làm chậm ghi).

### 2.4 EXPLAIN và ANALYZE

- `EXPLAIN` cho kế hoạch **dự kiến** mà không chạy lệnh.
- `ANALYZE` (MariaDB) **chạy thật** và so sánh dòng ước tính với dòng **thực tế** cùng thời gian từng bước. Chênh lệch lớn nghĩa là thống kê lệch hoặc kế hoạch sai.

Dấu hiệu xấu: `type: ALL` (quét toàn bảng), `rows` lớn, `Using filesort`, `Using temporary`.

### 2.5 Khóa và giao dịch mở lâu

InnoDB khóa ở **mức dòng**. Một giao dịch mở lâu giữ khóa làm các giao dịch khác phải chờ (`Waiting for ... lock`). Role đặt `innodb_lock_wait_timeout=120` (chờ tối đa 2 phút) và `innodb_print_all_deadlocks=1` (ghi mọi deadlock vào error log). Trên Galera còn có **BF abort** (giao dịch cục bộ bị hủy vì writeset từ node khác tới sau xung đột) và `cert.log_conflicts=ON` ghi các xung đột đó vào error log.

### 2.6 Cổng quản trị `extra_port`

Khi `Threads_connected` đã chạm `max_connections`, kết nối mới vào cổng 3306 bị từ chối, kể cả của DBA. MariaDB cung cấp `extra_port` (role đặt **1301**, tối đa `extra_max_connections=15`) chạy theo mô hình khác (một luồng mỗi kết nối) và có giới hạn riêng, để DBA luôn đăng nhập được lúc quá tải.

## 3. Cách 1: Chạy script

```bash
cd ~/learn_mariadb/best_practices/09-chan-doan-hieu-nang
./performance_report.sh                           # mọi node
LIMIT=mariadb-node1 ./performance_report.sh       # một node
DRY_RUN=1 ./performance_report.sh
```

Báo cáo gồm (mỗi node một khối, chỉ đọc): hệ thống (tải, RAM, đĩa); kết nối, InnoDB và **tỉ lệ cache buffer pool**; chỉ số Galera (flow control, hàng đợi, xung đột); truy vấn đang chạy (không tính `Sleep`); giao dịch InnoDB mở lâu; **top 10 câu lệnh** theo `performance_schema`; bảng và index đọc nhiều (`userstat`); **top 5 slow log** bằng `mariadb-dumpslow`; và các dòng xung đột, `[ERROR]` gần đây trong error log. Mẹo: chạy khi **đang chậm** và so với bản chụp lúc **bình thường** (lưu bằng `./performance_report.sh > baseline.txt`).

## 4. Cách 2: Các bước thủ công và lý do

### Bước 1. Tầng hệ thống

```bash
top -b -n 1 | head -15
vmstat 1 5
iostat -x 1 3
free -m
```

**Tại sao:** `top` cho biết tiến trình nào ngốn CPU. `vmstat`: cột `wa` (chờ I/O) cao nghĩa là đĩa là nút cổ chai; cột `si/so` khác 0 nghĩa là đang dùng swap (rất chậm). `iostat -x` (gói `sysstat`) cho `%util` (đĩa bão hòa gần 100%) và `await` (độ trễ mỗi I/O). `free` xem RAM và swap; swap bị dùng nhiều là dấu hiệu `innodb_buffer_pool_size` quá lớn so với RAM thật.

### Bước 2. Tầng MariaDB: kết nối và khóa

```sql
SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_running','Threads_connected','Max_used_connections','Innodb_row_lock_waits','Innodb_row_lock_time_avg','Created_tmp_disk_tables','Slow_queries');
SHOW FULL PROCESSLIST;
```

**Tại sao:** `Threads_running` (số luồng **đang chạy**, khác `Threads_connected`) cao kéo dài là tải CPU hoặc khóa. `Innodb_row_lock_waits` và `row_lock_time_avg` cho biết có tranh chấp khóa không. `Created_tmp_disk_tables` nhiều nghĩa là có truy vấn tạo bảng tạm trên đĩa (chậm). `PROCESSLIST` cho thấy từng lệnh đang chạy, thời gian và trạng thái: trạng thái `Waiting for ... lock` chỉ thẳng vào khóa.

### Bước 3. Tầng Galera

```sql
SHOW STATUS LIKE 'wsrep_flow_control_paused';
SHOW STATUS LIKE 'wsrep_flow_control_sent';
SHOW STATUS LIKE 'wsrep_local_recv_queue_avg';
SHOW STATUS LIKE 'wsrep_local_cert_failures';
SHOW STATUS LIKE 'wsrep_local_bf_aborts';
```

```bash
grep -i "conflict" /u01/logs/mariadb/mariadb.error.log | tail -20
```

**Tại sao:** nếu **cả cụm** chậm cùng lúc, nghi Galera trước. `flow_control_paused` trên 0.1 nghĩa là cụm hay bị tạm dừng; `flow_control_sent` cho biết **node nào đang phát tín hiệu dừng** (node đó là nút cổ chai, thường do đĩa hoặc CPU yếu hơn). `recv_queue_avg` trên 1 liên tục là node apply không kịp. `cert_failures` và `bf_aborts` tăng nhanh là ứng dụng ghi **đụng nhau** giữa các node; error log (nhờ `cert.log_conflicts=ON`) cho biết bảng và dòng nào gây xung đột. Đây cũng là lý do MaxScale dồn ghi về một node.

### Bước 4. Tìm truy vấn chậm

```bash
/usr/local/mariadb/bin/mariadb-dumpslow -s t -t 10 /u01/logs/mariadb/mariadb.slow.log
tail -f /u01/logs/mariadb/mariadb.slow.log
```

```sql
SET GLOBAL long_query_time = 0.2;
```

**Tại sao:** `-s t -t 10` xếp theo **tổng thời gian** và lấy 10 nhóm đầu (`-s c` theo số lần gọi). Hạ `long_query_time` tạm xuống 0.2 giây để bắt được lệnh vừa phải (mặc định 1 giây bỏ sót lệnh 0.5 giây gọi triệu lần). Đổi động không cần restart; **nhớ trả về 1** để slow log không phình quá nhanh.

```sql
SELECT DIGEST_TEXT, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e12,2) AS total_sec,
       ROUND(AVG_TIMER_WAIT/1e12,4) AS avg_sec, SUM_ROWS_EXAMINED, SUM_NO_INDEX_USED
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC LIMIT 10;
```

**Tại sao:** `SUM_TIMER_WAIT` tính bằng **picosecond** nên chia `1e12` ra giây. Sắp theo tổng thời gian cho thấy lệnh tốn tài nguyên nhất **tính cả cụm lệnh nhanh gọi nhiều**. So `SUM_ROWS_EXAMINED` với số dòng trả về để biết lệnh quét thừa bao nhiêu.

### Bước 5. Phân tích một truy vấn

```sql
EXPLAIN SELECT * FROM wards WHERE name LIKE '%Hà%';
ANALYZE SELECT * FROM wards WHERE province_code = '01';
ANALYZE FORMAT=JSON SELECT w.name FROM wards w JOIN provinces p ON p.code = w.province_code WHERE p.code = '01';
```

**Tại sao:** `EXPLAIN` an toàn (không chạy). `ANALYZE` chạy thật nên có dòng **thực tế** và thời gian từng bước; hữu ích khi `EXPLAIN` trông ổn mà lệnh vẫn chậm. `LIKE '%...%'` (dấu `%` ở đầu) không dùng được index thường nên sẽ `type: ALL`. Khi thấy `ALL` hoặc `rows` lớn, cân nhắc thêm index theo [kịch bản 6](../06-ddl-lon/README.md) rồi `ANALYZE` lại để so sánh.

### Bước 6. Bảng, index, user (nhờ `userstat`)

```sql
SELECT * FROM information_schema.TABLE_STATISTICS ORDER BY ROWS_READ DESC LIMIT 10;
SELECT * FROM information_schema.INDEX_STATISTICS ORDER BY ROWS_READ DESC LIMIT 10;
SELECT * FROM information_schema.USER_STATISTICS ORDER BY BUSY_TIME DESC;
```

**Tại sao:** biết **bảng nào bị đọc nhiều nhất** để ưu tiên tối ưu; `USER_STATISTICS` sắp theo `BUSY_TIME` cho biết **user (ứng dụng) nào** tốn tài nguyên nhất. Index không bao giờ xuất hiện trong `INDEX_STATISTICS` kể từ lúc bật `userstat` là ứng viên để xóa:

```sql
SELECT s.table_schema, s.table_name, s.index_name
FROM information_schema.statistics s
LEFT JOIN information_schema.INDEX_STATISTICS i
  ON i.TABLE_SCHEMA=s.table_schema AND i.TABLE_NAME=s.table_name AND i.INDEX_NAME=s.index_name
WHERE i.INDEX_NAME IS NULL AND s.table_schema NOT IN ('mysql','information_schema','performance_schema') AND s.index_name <> 'PRIMARY';
```

**Tại sao:** index không dùng vẫn phải cập nhật mỗi lần ghi nên chỉ tốn chi phí. Nhưng cần quan sát **đủ lâu** (qua một chu kỳ nghiệp vụ, ví dụ cuối tháng) trước khi kết luận.

### Bước 7. Khóa và deadlock

```sql
SELECT * FROM information_schema.INNODB_TRX\G
SELECT * FROM information_schema.INNODB_LOCK_WAITS;
SHOW ENGINE INNODB STATUS\G
KILL QUERY <id>;
```

**Tại sao:** `INNODB_TRX` liệt kê giao dịch đang mở và thời điểm bắt đầu: giao dịch mở hàng chục phút thường giữ khóa và là thủ phạm. `INNODB_LOCK_WAITS` (nếu có ở phiên bản này) cho biết ai chờ ai. `SHOW ENGINE INNODB STATUS` có mục `LATEST DETECTED DEADLOCK`. `KILL QUERY` hủy **lệnh** đang chạy nhưng giữ kết nối; `KILL <id>` cắt luôn kết nối và rollback giao dịch.

### Bước 8. MaxScale và kết nối

```bash
maxctrl -u admin -p mariadb list services
maxctrl -u admin -p mariadb list sessions
maxctrl -u admin -p mariadb show server server_1
```

**Tại sao:** biết số kết nối mỗi dịch vụ và mỗi server, phát hiện **mất cân bằng** (một node nhận quá nhiều kết nối). Khi `Threads_connected` chạm `max_connections`, vào bằng cổng quản trị (mục 2.6):

```bash
mariadb -h <ip-node> -P 1301 -u root -p
```

## 5. Quy trình chẩn đoán tóm tắt

1. Chạy `performance_report.sh`, xem **tầng nào** bất thường.
2. Hệ thống bão hòa: xử lý tài nguyên (đĩa, RAM, swap).
3. Galera: tìm node chậm (`flow_control_sent`) hoặc xung đột (`cert_failures`).
4. MariaDB: tìm khóa và giao dịch mở lâu.
5. Truy vấn: top digest, `EXPLAIN`/`ANALYZE`, thêm index.
6. Đo lại sau khi sửa để chắc đã cải thiện.

## 6. Lỗi thường gặp

| Triệu chứng | Nguyên nhân khả dĩ |
|---|---|
| Slow log trống nhưng ứng dụng vẫn chậm | `long_query_time=1` quá cao, hạ tạm; hoặc chậm do khóa (chưa ra khỏi lệnh) |
| `INNODB_LOCK_WAITS` không tồn tại | Phiên bản không có bảng này; dùng `SHOW ENGINE INNODB STATUS` |
| Báo cáo trống ở phần `performance_schema` | `performance_schema` tắt trên node |

## 7. Điểm cốt lõi cần nhớ

- Chẩn đoán **từ ngoài vào trong**: hệ thống, Galera, MariaDB, truy vấn.
- **Cả cụm chậm cùng lúc** thì nghi Galera: tìm node phát `flow_control_sent`.
- Slow log chỉ ghi lệnh **đã xong** và vượt ngưỡng; digest bắt được lệnh **nhanh nhưng gọi nhiều**.
- `ANALYZE` chạy thật và cho số liệu **thực tế**, `EXPLAIN` chỉ là dự kiến.
- Lưu **mốc bình thường** để so sánh khi có sự cố.
