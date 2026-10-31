# Kịch bản 10: Đầy đĩa và dọn binlog

**Script:** không có (các thao tác dọn dẹp cần quyết định của con người, không nên tự động) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

Xử lý khi phân vùng `/u01` sắp hoặc đã đầy mà **không làm hỏng dữ liệu**. Đĩa đầy là một trong các sự cố gây downtime phổ biến nhất vì khi đầy: InnoDB không ghi được, binlog và `gcache` không mở rộng được, node gặp lỗi và có thể tự dừng, và nếu nhiều node đầy cùng lúc thì cả cụm dừng.

**Tác động:** thao tác dọn dẹp bản thân không gây downtime; nhưng nếu đĩa đã đầy 100% có thể phải xử lý trong tình trạng node đã dừng.

## 2. Kiến thức nền

### 2.1 Cái gì chiếm đĩa trong cấu hình của role

| Thành phần | Vị trí | Đặc điểm tăng trưởng |
|---|---|---|
| Dữ liệu và redo log InnoDB | `/u01/data/database` | Tăng theo dữ liệu thật; redo log kích thước cố định |
| **Binlog** | `/u01/logs/mariadb/binlog/` | Tăng theo mức ghi; mỗi file tối đa 512M; xóa theo `expire_logs_days=3` |
| **`galera.cache` (gcache)** | trong datadir | **Kích thước cố định** `gcache.size`, ghi vòng, không tự phình thêm |
| Slow log | `/u01/logs/mariadb/mariadb.slow.log` | Tăng theo lệnh chậm |
| Audit log | `/u01/logs/mariadb/database_audit.log` | Role xoay ở 100MB, giữ 99 bản (có thể đến cỡ 10GB) |
| Error log | `/u01/logs/mariadb/mariadb.error.log` | Thường nhỏ, có thể lớn khi lỗi lặp |
| Thư mục tạm | `/u01/data/database_tmp` | Bảng tạm và sắp xếp lớn |
| Backup (nếu để cùng đĩa) | ví dụ `/backup` | Mỗi bản bằng cỡ dữ liệu |

### 2.2 Cơ chế xóa binlog

Binlog được **đánh chỉ mục** trong file `binlog.index`. MariaDB tự xóa file cũ hơn `expire_logs_days` (3 ngày) khi **xoay file mới** hoặc lúc khởi động. Lệnh `PURGE BINARY LOGS` xóa file **và cập nhật `binlog.index`** một cách nhất quán. Nếu `rm` file bằng tay khi MariaDB đang chạy, chỉ mục vẫn trỏ tới file không còn: lệnh như `SHOW BINARY LOGS` lỗi và có thể gây rắc rối khi khởi động. Vì vậy **luôn dùng `PURGE`**.

### 2.3 Đánh đổi khi xóa binlog

Binlog là nguyên liệu của **PITR** ([kịch bản 7](../07-backup-pitr/README.md)): xóa sớm làm **thu hẹp cửa sổ khôi phục**. Cần cân bằng: nếu cần giữ lâu hơn 3 ngày thì tăng `mariadb_expire_logs_days` và dành đĩa tương ứng, hoặc **sao chép binlog sang nơi khác** trước khi xóa.

### 2.4 Slow log và `FLUSH SLOW LOGS`

MariaDB giữ file slow log **đang mở**. Nếu bạn đổi tên (`mv`) file, MariaDB vẫn ghi vào file đã đổi tên (cùng inode). `FLUSH SLOW LOGS` bảo MariaDB **đóng và mở lại** file theo tên gốc, tạo file mới. Vì vậy quy trình đúng là: đổi tên file, rồi `FLUSH SLOW LOGS`.

### 2.5 gcache không phải thủ phạm "phình"

`galera.cache` có kích thước **cố định** theo `gcache.size`; nó chiếm đĩa ngay từ đầu nhưng không tăng. Nếu thấy nó lớn, đó là do cấu hình (mặc định 2048M, ở lab đã đặt 512M), không phải rò rỉ.

## 3. Cách 1: Script

Không có script cho kịch bản này, vì xóa dữ liệu cần con người quyết định (file nào, giữ bao lâu, có cần sao chép đi trước không). Dùng `./01-healthcheck/healthcheck.sh` để **cảnh báo sớm**: nó báo `[FAIL]` khi đĩa datadir vượt 80%.

## 4. Cách 2: Các bước thủ công và lý do

### Bước 1. Xác định cái gì đang chiếm chỗ

```bash
df -h /u01
du -sh /u01/data/database/* /u01/logs/mariadb/* 2>/dev/null | sort -h | tail
```

**Tại sao:** `df` cho biết còn bao nhiêu; `du` ... `sort -h | tail` liệt kê thư mục/file **lớn nhất** để biết dọn đúng chỗ. Đừng đoán: xóa nhầm file không phải thủ phạm thì mất dữ liệu mà không giải quyết vấn đề.

### Bước 2. Dọn theo thủ phạm

| Thủ phạm | Cách xử lý |
|---|---|
| Binlog | Sao chép đi nơi khác nếu cần PITR rồi `PURGE` (bước 3) |
| Slow log hoặc audit log | Đổi tên file rồi `FLUSH SLOW LOGS` (slow log); audit log role đã tự xoay |
| `galera.cache` | Cố định, giảm `mariadb_gcache_size` nếu cần (cần restart) |
| Backup cùng đĩa | Chuyển sang đĩa hoặc máy khác |
| Dữ liệu thật tăng | Mở rộng đĩa, hoặc lưu trữ và xóa dữ liệu cũ **theo lô** ([kịch bản 6](../06-ddl-lon/README.md), mục DML lớn) |

### Bước 3. Dọn binlog đúng cách

```sql
SHOW BINARY LOGS;
PURGE BINARY LOGS TO 'binlog.000010';
-- hoặc theo thời điểm
PURGE BINARY LOGS BEFORE NOW() - INTERVAL 1 DAY;
```

**Tại sao:** `SHOW BINARY LOGS` xem danh sách và kích thước để chọn mốc. `PURGE ... TO` xóa mọi file **trước** file được nêu (không xóa chính nó); `PURGE ... BEFORE` xóa theo thời điểm. Cả hai cập nhật `binlog.index` đúng (mục 2.2). Trước khi purge hãy chắc backup gần nhất đã có và binlog bị xóa không còn cần cho PITR.

### Bước 4. Dọn slow log

```bash
mv /u01/logs/mariadb/mariadb.slow.log /u01/logs/mariadb/mariadb.slow.log.$(date +%F)
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "FLUSH SLOW LOGS;"
```

**Tại sao:** mục 2.4. Chỉ `mv` mà không `FLUSH` thì MariaDB vẫn ghi vào file đã đổi tên và đĩa không giải phóng khi bạn xóa file đó (file đã xóa nhưng vẫn mở, chiếm chỗ). Sau `FLUSH`, nén hoặc xóa bản đã đổi tên.

### Bước 5. Nếu đĩa đã đầy 100% và MariaDB không start

Giải phóng chỗ bằng các file **không thuộc dữ liệu** trước (log cũ, backup, file tạm), rồi mới `systemctl start mariadb`.

**Tại sao:** MariaDB cần chỗ trống để khởi động (ghi error log, tạo file tạm, recovery redo log). Không `rm` binlog bằng tay khi MariaDB đang chạy. Nếu MariaDB đã dừng, dọn binlog bằng tay cần chỉnh cả `binlog.index`, nên ưu tiên các nguồn khác trước rồi dùng `PURGE` sau khi node đã lên.

### Bước 6. Phòng ngừa tái diễn

- Cảnh báo ở **80%** (healthcheck đã có).
- Đặt backup và binlog đã sao chép **sang đĩa khác**.
- Tính dung lượng cho binlog: `mức ghi trung bình mỗi ngày × expire_logs_days`.
- Dành sẵn đường mở rộng đĩa (LVM hoặc đĩa ảo mở rộng được).

## 5. Kiểm tra kết quả

```bash
df -h /u01
../01-healthcheck/healthcheck.sh
```

Đĩa dưới 80% và healthcheck đạt. Nếu đã `PURGE` binlog, ghi nhận mốc binlog cũ nhất còn lại để biết cửa sổ PITR mới.

## 6. Lỗi thường gặp

| Triệu chứng | Nguyên nhân khả dĩ |
|---|---|
| Xóa file log xong mà `df` vẫn đầy | File đã xóa còn **đang mở** bởi mariadbd; `FLUSH SLOW LOGS` hoặc restart để nhả |
| `SHOW BINARY LOGS` lỗi sau khi `rm` binlog | Chỉ mục `binlog.index` còn trỏ file đã xóa; tránh bằng cách luôn dùng `PURGE` |
| Hết chỗ lại sau vài ngày | Nguyên nhân gốc chưa xử lý (binlog giữ quá lâu so với đĩa, backup cùng đĩa) |

## 7. Điểm cốt lõi cần nhớ

- Dọn **đúng thủ phạm**: xem `du` trước.
- Binlog dùng **`PURGE`**, không bao giờ `rm` khi MariaDB đang chạy.
- Xóa binlog **thu hẹp cửa sổ PITR**: sao chép đi trước nếu cần.
- File log đã `mv` phải **`FLUSH`** để MariaDB nhả file cũ.
- `gcache` có kích thước **cố định**, không phải thủ phạm "phình".
