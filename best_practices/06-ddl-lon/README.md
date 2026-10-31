# Kịch bản 6: Thay đổi schema lớn (DDL)

**Script:** [rsu_ddl.sh](rsu_ddl.sh) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

Chạy `ALTER TABLE` (thêm cột, thêm index, đổi kiểu cột...) trên bảng lớn mà **không làm cả cụm đứng ghi**. Đây là kịch bản dễ gây sự cố nhất trên Galera, vì một lệnh `ALTER` tưởng như vô hại có thể chặn toàn cụm trong nhiều phút.

## 2. Kiến thức nền

### 2.1 DDL trong Galera khác DML như thế nào

Giao dịch DML (`INSERT/UPDATE/DELETE`) được nhân bản bằng **writeset** và áp dụng song song (nhiều luồng `wsrep_slave_threads`) nếu không xung đột. DDL không có "dòng thay đổi" để nhân bản, nên Galera có hai cách xử lý, chọn bằng `wsrep_OSC_method`:

| Cách | Mặc định? | Cơ chế | Ảnh hưởng |
|---|---|---|---|
| **TOI** (Total Order Isolation) | Có | Câu lệnh DDL được gửi tới **mọi node** theo thứ tự toàn cục, chạy **đồng thời trên tất cả**, và trong lúc đó việc áp dụng các giao dịch khác bị chặn để giữ đúng thứ tự | `ALTER` mất 10 phút nghĩa là **cả cụm không commit được giao dịch mới khoảng 10 phút** (đọc vẫn được) |
| **RSU** (Rolling Schema Upgrade) | Không | DDL **chỉ chạy trên node bạn gõ lệnh**, không nhân bản. Node đó tạm tách khỏi luồng đồng bộ trong lúc chạy, writeset từ node khác xếp hàng chờ, và áp dụng sau khi DDL xong | Cụm vẫn nhận ghi qua các node khác. Phải chạy **lần lượt từng node** |

### 2.2 Điều kiện của RSU: thay đổi phải tương thích ngược

Trong lúc DDL chạy trên node A, các node khác vẫn ghi dữ liệu theo schema **cũ**, và các writeset đó sẽ được node A áp dụng **sau khi** schema A đã đổi. Nếu schema mới không còn khớp writeset cũ thì apply thất bại và node bị hỏng đồng bộ. Do đó chỉ dùng RSU cho thay đổi tương thích ngược: **thêm index, thêm cột cho phép NULL hoặc có default**. Không dùng khi đổi nghĩa hoặc kiểu dữ liệu mà ứng dụng đang ghi.

### 2.3 Thuật toán DDL của InnoDB: INSTANT, INPLACE, COPY

Độc lập với TOI/RSU, bản thân `ALTER` của InnoDB có ba mức:

| `ALGORITHM` | Làm gì | Chặn DML trên bảng? |
|---|---|---|
| `INSTANT` | Chỉ sửa **siêu dữ liệu**, không đụng dữ liệu | Không, tức thì (áp dụng cho thêm cột cuối, đổi default...) |
| `INPLACE` | Xây lại index hoặc bảng **tại chỗ**, không tạo bản sao đầy đủ; với `LOCK=NONE` vẫn cho DML trên bảng đó | Không (với `LOCK=NONE`) nhưng tốn thời gian và I/O |
| `COPY` | Tạo bảng mới, chép từng dòng, đổi tên | **Có**, chặn ghi suốt quá trình |

Chỉ định `ALGORITHM` rõ ràng là **bảo hiểm**: nếu thay đổi không hỗ trợ mức đó, MariaDB báo **lỗi** thay vì âm thầm chạy `COPY` chậm. Lưu ý: dưới **TOI**, dù thuật toán là `INPLACE`, cụm vẫn bị giữ theo thứ tự toàn cục trong lúc chạy, nên `INPLACE` thường chỉ nên dùng cho bảng vừa phải.

### 2.4 DML lớn cũng gây vấn đề tương tự

Một giao dịch rất lớn (xóa hàng triệu dòng một lần) tạo **writeset khổng lồ**: giới hạn bởi `wsrep_max_ws_size` (mặc định khoảng 2GB), làm chậm certification, tăng xung đột và giữ khóa lâu. Cách xử lý chuẩn là **chia nhỏ theo lô** (và MariaDB còn có *streaming replication* với `wsrep_trx_fragment_size` cho trường hợp đặc biệt).

## 3. Cách 1: Chạy script (RSU)

```bash
cd ~/learn_mariadb/best_practices/06-ddl-lon
./rsu_ddl.sh vn_provinces "ALTER TABLE wards ADD INDEX idx_wards_name (name)"
ORDER="mariadb-node3 mariadb-node1 mariadb-node2" ./rsu_ddl.sh vn_provinces "ALTER TABLE ..."   # Master để cuối
DRY_RUN=1 ./rsu_ddl.sh vn_provinces "ALTER TABLE wards ADD INDEX idx_wards_name (name)"
```

Với **từng node** theo thứ tự (mặc định ngược inventory), script:

1. Hỏi xác nhận (thay đổi **phải** tương thích ngược).
2. `maxctrl set server server_N drain` trên **mọi** MaxScale, chờ `DRAIN_WAIT` giây.
3. Chạy `SET SESSION wsrep_OSC_method='RSU'; <DDL>;` trong **cùng một phiên** (hai lệnh gộp một lần gọi `mariadb`, vì `SET SESSION` chỉ có hiệu lực trong phiên của nó).
4. Đợi node `Synced`, rồi `clear drain`.
5. Nếu DDL lỗi trên một node thì dừng ngay: các node đã chạy trước **đã có** thay đổi, node chưa chạy thì chưa; script nhắc gỡ `drain`.

## 4. Cách 2: Các bước thủ công và lý do

### Bước 1. Đo trước

```sql
SELECT table_name, ROUND((data_length+index_length)/1024/1024) AS size_mb, table_rows
FROM information_schema.tables WHERE table_schema='vn_provinces' ORDER BY size_mb DESC;
```

**Tại sao:** thời gian DDL tỉ lệ với kích thước bảng. Bảng vài MB thì TOI chấp nhận được, bảng hàng chục GB thì không. Kết quả này quyết định chọn cách nào ở bước 3.

### Bước 2. Thử trên bản sao

Khôi phục một backup vào instance tạm ([kịch bản 7](../07-backup-pitr/README.md)) và chạy DDL ở đó để đo thời gian thật.

**Tại sao:** ước lượng lý thuyết thường lệch nhiều so với thực tế (phụ thuộc đĩa, index, kích thước dòng). Không bao giờ thử lần đầu trên production.

### Bước 3. Chọn cách chạy

| Thay đổi | Cách | Lý do |
|---|---|---|
| Thêm cột cuối bảng, đổi default | `ALGORITHM=INSTANT` | Chỉ sửa siêu dữ liệu nên tức thì, kể cả khi TOI |
| Thêm hoặc xóa index, bảng vừa | `ALGORITHM=INPLACE, LOCK=NONE` | Không chặn DML bảng đó, chấp nhận TOI vì ngắn |
| Đổi kiểu cột, đổi khóa chính, bảng rất lớn | **RSU** (bước 4) hoặc công cụ ngoài `pt-online-schema-change`, `gh-ost` | TOI sẽ chặn cụm quá lâu. Công cụ ngoài không nằm trong bộ cài, tự chuẩn bị |

```sql
ALTER TABLE wards ADD COLUMN note VARCHAR(100) NULL, ALGORITHM=INSTANT;
ALTER TABLE wards ADD INDEX idx_wards_name (name), ALGORITHM=INPLACE, LOCK=NONE;
```

**Tại sao ghi rõ `ALGORITHM`:** mục 2.3, nếu không hỗ trợ sẽ báo lỗi chứ không âm thầm `COPY`.

### Bước 4. RSU từng node (cho thay đổi nặng)

Lặp cho từng node, **Master làm cuối**:

```bash
maxctrl -u admin -p mariadb set server server_3 drain
mariadb -u root -p -S /u01/data/database/mariadb.sock vn_provinces -e "SET SESSION wsrep_OSC_method='RSU'; ALTER TABLE wards ADD INDEX idx_wards_name (name);"
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
maxctrl -u admin -p mariadb clear server server_3 drain
```

**Tại sao từng dòng:**

1. `drain` (làm trên mọi MaxScale nếu muốn chính xác): ngừng gửi kết nối mới tới node sắp bị tách khỏi đồng bộ, để ứng dụng không đọc phải dữ liệu chậm/lệch trên node đó.
2. `SET SESSION wsrep_OSC_method='RSU'` và `ALTER` **trong cùng một lệnh `mariadb -e`**: biến phiên chỉ tồn tại trong phiên hiện tại nên hai câu phải chung một phiên. Trong lúc `ALTER` chạy, node này tách khỏi luồng đồng bộ (RSU), các node khác vẫn ghi.
3. Đợi `Synced`: sau DDL node phải **áp dụng nốt** các writeset đã xếp hàng. Chưa `Synced` mà sang node kế thì cụm có thể thiếu node nhận ghi.
4. `clear drain`: đưa node trở lại định tuyến.

Sau khi cả 3 node xong, schema đồng nhất; kiểm tra bằng `SHOW CREATE TABLE wards\G` trên từng node.

### Bước 5. DML lớn: chia lô

```sql
-- chạy lặp đến khi không còn dòng nào bị ảnh hưởng
DELETE FROM big_table WHERE created_at < '2026-01-01' LIMIT 10000;
```

**Tại sao:** mỗi lô là một giao dịch nhỏ, writeset nhỏ, giữ khóa ngắn và dễ thắng certification; các node apply kịp nên hàng đợi không phình lên.

### Bước 6. Theo dõi trong lúc chạy

```sql
SHOW FULL PROCESSLIST;
SHOW STATUS LIKE 'wsrep_local_recv_queue_avg';
SHOW STATUS LIKE 'wsrep_flow_control_paused';
```

**Tại sao:** `PROCESSLIST` cho thấy DDL đang ở giai đoạn nào. Hàng đợi và flow control cho thấy cụm có đang bị kẹt vì DDL không. Muốn hủy: `KILL <id>` trên node đang chạy DDL. Mọi DDL đều được ghi vào audit log `/u01/logs/mariadb/database_audit.log` (`QUERY_DDL`), dùng để truy vết ai đã chạy gì.

## 5. Kiểm tra kết quả

- Schema giống nhau trên mọi node: `SHOW CREATE TABLE wards\G`.
- `../01-healthcheck/healthcheck.sh` đạt; `wsrep_flow_control_paused` và hàng đợi về mức bình thường.

## 6. Lỗi thường gặp

| Triệu chứng | Nguyên nhân khả dĩ |
|---|---|
| Cả cụm đứng ghi khi `ALTER` | Đang dùng TOI cho thay đổi nặng, đổi sang RSU hoặc công cụ ngoài |
| `ALGORITHM=... is not supported` | Thay đổi không hỗ trợ mức đó; đó là bảo vệ, chọn mức khác hoặc RSU |
| Node lỗi apply sau RSU | Thay đổi không tương thích ngược; xem mục 2.2 |
| Writeset quá lớn | DML không chia lô; xem bước 5 |

## 7. Điểm cốt lõi cần nhớ

- **TOI chặn cả cụm** trong lúc `ALTER` chạy; **RSU** chạy từng node nhưng đòi hỏi thay đổi **tương thích ngược**.
- Luôn ghi rõ **`ALGORITHM`** để MariaDB báo lỗi thay vì âm thầm `COPY`.
- Biến `SET SESSION` chỉ sống trong **một phiên**: gộp chung một lần gọi.
- **Chia lô** mọi DML lớn.
- Luôn **thử trên bản sao** trước khi làm thật.
