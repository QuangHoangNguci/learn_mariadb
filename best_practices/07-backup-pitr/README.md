# Kịch bản 7: Backup và point-in-time recovery (PITR)

**Script:** [backup_full.sh](backup_full.sh), [pitr_restore.sh](pitr_restore.sh) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

Có bản sao lưu để **khôi phục về một thời điểm bất kỳ** khi xảy ra sự cố dữ liệu (xóa nhầm bảng, cập nhật sai hàng loạt, lỗi ứng dụng). Cụm Galera **không thay thế được backup**: nó nhân bản mọi thứ, kể cả lệnh `DROP TABLE` sai, sang mọi node trong vài mili giây. Chỉ backup mới cứu được dữ liệu trong trường hợp này.

## 2. Kiến thức nền

### 2.1 Backup vật lý bằng mariabackup

`mariabackup` là **backup nóng** (khi MariaDB vẫn chạy, không khóa bảng lâu):

1. Chép các file dữ liệu InnoDB trong khi hệ thống vẫn ghi. Các file này **không nhất quán** vì chúng bị thay đổi trong lúc chép.
2. Đồng thời theo dõi **redo log** (nhật ký ghi trước) để ghi lại mọi thay đổi xảy ra trong lúc chép (đánh dấu bằng LSN).
3. Ở cuối, lấy một khóa rất ngắn để ghi vị trí binlog và GTID.

Vì bản chép chưa nhất quán, **bắt buộc phải `--prepare`**: bước này áp lại redo log lên bản chép (giống crash recovery nhưng chạy offline) để đưa nó về trạng thái nhất quán tại thời điểm kết thúc backup. Backup chưa prepare **không dùng được**.

File `xtrabackup_binlog_info` ghi **tên file binlog, vị trí và GTID** tại thời điểm backup, đây là **điểm xuất phát** để phát lại binlog trong PITR.

### 2.2 Vì sao backup trên một node và `wsrep_desync`

Backup tốn nhiều I/O và có thể làm node apply chậm. Nhớ lại [kịch bản 1](../01-healthcheck/README.md): node có hàng đợi apply dài sẽ kích hoạt **flow control** và kéo **cả cụm** chậm. `SET GLOBAL wsrep_desync=ON` báo cụm: "node này tạm thời không tính vào flow control". Node vẫn nhận writeset nhưng cụm không dừng vì nó. Phải trả về `OFF` sau backup để node tham gia flow control bình thường trở lại; nếu quên, node đó có thể tụt lại mà không ai phanh. Script dùng `trap` để **luôn** trả `OFF`, kể cả khi backup lỗi.

Nên backup trên node **không phải Master** của MaxScale để không làm chậm đường ghi chính.

### 2.3 PITR: nguyên lý

```
trạng thái tại thời điểm T  =  backup đầy đủ (tại T0)  +  binlog phát lại từ T0 đến T
```

- **Binlog** ghi lại mọi thay đổi dữ liệu theo thứ tự (role dùng định dạng `ROW`, giữ `expire_logs_days=3`). Công cụ `mariadb-binlog` đọc binlog và in ra SQL; đưa SQL đó vào một instance đã được khôi phục từ backup thì instance "chạy lại lịch sử".
- Dừng ở **ngay trước** thời điểm sự cố (`--stop-datetime`) thì ta có dữ liệu trước khi xóa nhầm.
- **Cửa sổ PITR** = thời gian binlog còn lưu. Hiện là **3 ngày**: backup cũ hơn mà binlog tương ứng đã bị xóa thì không PITR được. Vì vậy cần **backup ít nhất hằng ngày**, hoặc tăng `mariadb_expire_logs_days`, hoặc sao chép binlog đi nơi khác.

### 2.4 Vì sao phát lại binlog trên chính node đã backup

Mỗi node Galera ghi **binlog của riêng nó**, tên file và vị trí **khác nhau** giữa các node (dù nội dung giao dịch và GTID giống nhau nhờ `wsrep_gtid_mode=ON`). `xtrabackup_binlog_info` ghi tên file và vị trí **trong binlog của node đã backup**, nên phải dùng đúng binlog của node đó. Role bật `log-slave-updates=1` để mọi writeset áp dụng từ node khác cũng được ghi vào binlog của node, nhờ vậy binlog của một node có đủ mọi giao dịch của cụm.

### 2.5 Vì sao khôi phục vào một instance tạm, không vào cụm

Nếu phát lại binlog lên một node của cụm đang chạy, các câu lệnh đó **được nhân bản sang mọi node**, trộn với dữ liệu đang sống và có thể xung đột. Instance tạm là một `mariadbd` **cô lập**: `skip-networking` (không mở cổng), `wsrep_on=OFF` (không gia nhập cụm), socket và thư mục riêng. Nhờ đó ta tự do khôi phục, kiểm tra, xuất đúng phần cần lấy, rồi mới đưa vào cụm.

## 3. Cách 1: Chạy script

### 3.1 Backup

```bash
cd ~/learn_mariadb/best_practices/07-backup-pitr
./backup_full.sh                                     # mặc định: node cuối inventory, lưu vào /backup
BACKUP_HOST=mariadb-node2 BACKUP_ROOT=/data/backup ./backup_full.sh
DRY_RUN=1 ./backup_full.sh
```

Script chạy trên **một node**: (1) kiểm tra đủ chỗ trống; (2) bật `wsrep_desync`; (3) `mariabackup --backup`; (4) **luôn** trả `wsrep_desync` về `OFF` (kể cả khi lỗi); (5) `mariabackup --prepare`. Kết quả in `BACKUP_DIR=<đường dẫn>` và nội dung `xtrabackup_binlog_info`. **Ghi lại hai thông tin này.** Sao chép backup sang máy hoặc đĩa khác, backup cùng node thì chưa an toàn.

### 3.2 PITR vào instance tạm

```bash
# 1. Dựng instance tạm và áp binlog đến thời điểm ngay trước sự cố
BACKUP_DIR=/backup/full_2026-10-31_100000 STOP_DATETIME="2026-10-31 10:30:00" ./pitr_restore.sh restore

# 2. Xuất bảng bị mất từ instance tạm ra file trên node
./pitr_restore.sh dump vn_provinces wards

# 3. Nạp file đó vào CỤM (dùng đường dẫn DUMP_FILE in ra ở bước 2)
./pitr_restore.sh apply vn_provinces /u01/restore/dump_vn_provinces_wards.sql

# 4. Dọn instance tạm
./pitr_restore.sh cleanup
```

`restore` thực hiện: `mariabackup --copy-back` vào `/u01/restore/data`, ghi `my.cnf` tối giản, khởi động `mariadbd` tạm, rồi `mariadb-binlog --start-position=<trong xtrabackup_binlog_info> --stop-datetime=<STOP_DATETIME>` qua mọi file binlog từ file ghi trong `xtrabackup_binlog_info` trở đi, đưa vào instance tạm. `--start-position` chỉ áp dụng cho **file đầu tiên**. `STOP_DATETIME` theo giờ của server MariaDB. Nếu binlog đã bị xóa (quá 3 ngày), script báo lỗi. `RESTORE_HOST` mặc định là node cuối inventory (cùng node với `backup_full.sh`), đổi bằng `RESTORE_HOST=...`.

## 4. Cách 2: Các bước thủ công và lý do

### Bước 1. Backup vật lý

```bash
BACKUP_DIR=/backup/full_$(date +%F_%H%M%S)
mkdir -p $BACKUP_DIR
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SET GLOBAL wsrep_desync=ON;"
/usr/local/mariadb/bin/mariabackup --backup --user=root --password='<mật khẩu root>' --socket=/u01/data/database/mariadb.sock --target-dir=$BACKUP_DIR --parallel=2
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SET GLOBAL wsrep_desync=OFF;"
/usr/local/mariadb/bin/mariabackup --prepare --target-dir=$BACKUP_DIR
cat $BACKUP_DIR/xtrabackup_binlog_info
```

**Tại sao từng dòng:**

- `mkdir -p`: thư mục đích có tên theo giờ để mỗi backup tách biệt.
- `wsrep_desync=ON`: mục 2.2, tránh node backup kéo cụm vào flow control.
- `mariabackup --backup`: bước 1 và 2 ở mục 2.1. `--parallel=2` chép bằng 2 luồng để nhanh hơn (đổi theo CPU và đĩa). `--user/--password/--socket` để kết nối MariaDB lấy vị trí binlog và khóa ngắn.
- `wsrep_desync=OFF`: trả node về trạng thái bình thường; **đừng quên**. Kiểm tra bằng `SHOW GLOBAL VARIABLES LIKE 'wsrep_desync'`.
- `--prepare`: đưa bản chép về nhất quán (mục 2.1). Không prepare thì không khôi phục được.
- `cat xtrabackup_binlog_info`: lấy file, vị trí, GTID điểm xuất phát PITR.

**Sao lưu logic nhỏ** (một database, dễ đọc, nhưng chậm với dữ liệu lớn):

```bash
/usr/local/mariadb/bin/mariadb-dump -u root -p -S /u01/data/database/mariadb.sock --single-transaction --routines --triggers --events --databases vn_provinces > /backup/vn_provinces_$(date +%F).sql
```

**Tại sao:** `--single-transaction` đọc một ảnh chụp nhất quán của InnoDB mà không khóa bảng. `--routines --triggers --events` lấy cả hàm, trigger, event mà mặc định `mariadb-dump` bỏ sót.

### Bước 2. Mô phỏng sự cố

```sql
SELECT NOW(), @@gtid_current_pos;
DROP TABLE vn_provinces.wards;
```

**Tại sao:** ghi nhận thời điểm và GTID **ngay trước** lỗi để có mốc dừng khi PITR. Trong thực tế bạn tìm thời điểm này từ log, audit log (`database_audit.log` ghi DDL) hoặc lời người dùng.

### Bước 3. Khôi phục vào instance tạm

```bash
# 3.1 Đưa backup vào thư mục data tạm
mkdir -p /u01/restore/data
chown -R mariadb:mariadb /u01/restore
/usr/local/mariadb/bin/mariabackup --copy-back --target-dir=/backup/full_2026-10-31_100000 --datadir=/u01/restore/data
chown -R mariadb:mariadb /u01/restore

# 3.2 Cấu hình tối giản, tách khỏi /etc/my.cnf của cụm
cat > /u01/restore/my.cnf <<'EOF'
[mysqld]
basedir=/usr/local/mariadb
datadir=/u01/restore/data
socket=/u01/restore/mariadb.sock
log-error=/u01/restore/error.log
skip-networking
wsrep_on=OFF
performance_schema=OFF
innodb_buffer_pool_size=256M
EOF

# 3.3 Chạy instance tạm
runuser -u mariadb -- /usr/local/mariadb/bin/mariadbd --defaults-file=/u01/restore/my.cnf &
mariadb -u root -p -S /u01/restore/mariadb.sock -e "SELECT VERSION();"
```

**Tại sao:**

- `--copy-back`: chép bản đã prepare vào thư mục dữ liệu đích (thư mục phải rỗng). `chown` vì `mariadbd` chạy bằng user `mariadb`.
- Dùng `--defaults-file` riêng thay vì `/etc/my.cnf`: file của cụm có `port 3306`, `extra_port 1301`, Galera, binlog... tất cả sẽ **đụng** cổng và đường dẫn của node thật. File tối giản không có Galera, không có binlog, không mở mạng.
- `skip-networking`: chỉ truy cập qua socket, không thể bị client lạ hoặc node khác nối vào.
- `wsrep_on=OFF`: tắt Galera để instance tạm không thử gia nhập cụm và không nhân bản gì ra ngoài.
- `runuser -u mariadb`: chạy bằng user sở hữu dữ liệu.
- Mật khẩu `root` ở instance tạm **giống mật khẩu cụm** vì dữ liệu `mysql.*` đến từ backup.

### Bước 4. Phát lại binlog

```bash
cat /backup/full_2026-10-31_100000/xtrabackup_binlog_info       # ví dụ: binlog.000003  1234  0-1-5678
ls /u01/logs/mariadb/binlog/
/usr/local/mariadb/bin/mariadb-binlog --start-position=1234 --stop-datetime="2026-10-31 10:30:00" /u01/logs/mariadb/binlog/binlog.000003 /u01/logs/mariadb/binlog/binlog.000004 | mariadb -u root -p -S /u01/restore/mariadb.sock
```

**Tại sao:** `mariadb-binlog` giải mã binlog thành SQL; đường ống `|` đưa SQL vào instance tạm, tức là "chạy lại lịch sử". `--start-position` bắt đầu đúng nơi backup dừng (bỏ qua mọi giao dịch đã nằm sẵn trong backup, tránh áp hai lần) và chỉ áp dụng cho file đầu tiên trong danh sách. `--stop-datetime` dừng **ngay trước** `DROP TABLE`. Liệt kê các file binlog **theo thứ tự**, từ file ghi trong `xtrabackup_binlog_info` đến file mới nhất. Dùng binlog của **chính node đã backup** (mục 2.4).

### Bước 5. Đưa dữ liệu trở lại cụm

**Cách ưu tiên (chọn lọc, không dừng cụm):**

```bash
/usr/local/mariadb/bin/mariadb-dump -u root -p -S /u01/restore/mariadb.sock --single-transaction vn_provinces wards > /tmp/wards_restore.sql
mariadb -u root -p -S /u01/data/database/mariadb.sock vn_provinces < /tmp/wards_restore.sql
```

**Tại sao:** chỉ lấy đúng bảng bị mất, nạp vào **một node** của cụm; Galera tự nhân bản sang các node còn lại. Cách này không mất dữ liệu ghi mới sau sự cố ở các bảng khác. File dump có `DROP TABLE IF EXISTS` nên sẽ ghi đè bảng cùng tên nếu còn.

**Cách cuối cùng (khôi phục cả cụm về thời điểm đó):** dừng cả 3 node, thay datadir của **một** node bằng dữ liệu đã khôi phục, bootstrap node đó ([kịch bản 4](../04-mat-toan-bo-cum-bootstrap/README.md)), đưa các node còn lại về trạng thái trống để chúng SST ([kịch bản 3](../03-node-crash-rejoin/README.md)). **Mất mọi dữ liệu sau thời điểm đó**, chỉ làm khi hỏng toàn bộ.

### Bước 6. Dọn instance tạm

```bash
mariadb-admin -u root -p -S /u01/restore/mariadb.sock shutdown
rm -rf /u01/restore
```

**Tại sao:** giải phóng đĩa (thư mục này cùng cỡ dữ liệu) và tránh để một `mariadbd` tạm chạy ngầm quên không ai biết.

## 5. Kiểm tra backup định kỳ

**Một backup chưa từng khôi phục thử là chưa có backup.** Mỗi tuần: dựng instance tạm từ backup mới nhất (`STOP_DATETIME` là thời điểm hiện tại), đếm dòng bảng chính (`SELECT COUNT(*) FROM provinces`), ghi lại **thời gian khôi phục thực tế** (đây là RTO bạn cam kết), rồi `./pitr_restore.sh cleanup`.

## 6. Lỗi thường gặp

| Triệu chứng | Nguyên nhân khả dĩ |
|---|---|
| `Không thấy binlog từ file ... trở đi` | Binlog đã bị xóa do `expire_logs_days=3`; backup quá cũ |
| Instance tạm không lên | Cổng hoặc đường dẫn đụng với node thật (dùng nhầm `/etc/my.cnf`); xem `/u01/restore/error.log` |
| Backup lỗi giữa chừng | Hết chỗ; thiếu quyền; đảm bảo `wsrep_desync` đã về `OFF` |
| Dữ liệu khôi phục thiếu giao dịch cuối | `STOP_DATETIME` quá sớm, hoặc lệch múi giờ giữa bạn và server |

## 7. Điểm cốt lõi cần nhớ

- Galera **không** thay backup: lệnh xóa nhầm cũng được nhân bản tức thì.
- Backup vật lý **phải `--prepare`** mới dùng được.
- `wsrep_desync=ON` khi backup để **không kéo cả cụm vào flow control**; luôn trả về `OFF`.
- **PITR = backup + binlog**: cửa sổ PITR bằng thời gian giữ binlog (hiện 3 ngày).
- Khôi phục vào **instance tạm cô lập**, rồi mới đưa đúng phần cần vào cụm.
- Binlog phải của **đúng node đã backup**.
