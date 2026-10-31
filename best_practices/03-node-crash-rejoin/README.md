# Kịch bản 3: Một node crash và rejoin

**Script:** [simulate_crash.sh](simulate_crash.sh) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

Quan sát và xử lý khi **một node chết bất ngờ** (OOM-killer, lỗi phần cứng, mất điện một máy). Mô phỏng để biết: cụm phản ứng thế nào, ứng dụng bị ảnh hưởng ra sao, node tự phục hồi bằng cách nào và khi nào cần can thiệp.

**Tác động:** không downtime nếu cụm còn đủ quorum. Nếu node chết đang là **Master** của MaxScale thì ghi bị gián đoạn khoảng vài giây rồi Master mới được chọn; kết nối đang mở tới node chết bị đứt và ứng dụng phải kết nối lại.

## 2. Kiến thức nền

### 2.1 Tắt êm khác crash như thế nào

| | Tắt êm (`systemctl stop`) | Crash (`kill -9`, mất điện) |
|---|---|---|
| Node báo cho cụm | Có, gửi thông báo rời cụm | Không, biến mất đột ngột |
| Cụm phát hiện | Ngay | Sau thời gian chờ liên lạc |
| Dữ liệu node | Đóng sạch, ghi `seqno` vào `grastate.dat` | InnoDB chưa đóng sạch, `grastate.dat` có `seqno: -1` |
| Khi khởi động lại | Biết ngay vị trí | Phải **phục hồi** để biết vị trí |

Với crash, các node còn lại dùng bộ phát hiện lỗi của giao thức nhóm (tham số `evs.*`, mặc định cỡ vài giây đến khoảng 15 giây): nếu một node không phản hồi đủ lâu thì bị **loại khỏi cụm**, quorum được tính lại trên các node còn lại. Trong khoảng thời gian chờ đó, các giao dịch ghi có thể bị **treo ngắn** vì cụm chưa biết chắc node đã chết.

### 2.2 Phục hồi sau crash: `galera_recovery`

Sau crash, `grastate.dat` có `seqno: -1` nghĩa là "không biết giao dịch cuối cùng đã commit là số mấy". Galera đánh dấu mỗi giao dịch bằng một số thứ tự toàn cục **`seqno`** (trong một "lịch sử" nhận dạng bằng `uuid` của cụm). Để node biết mình đang ở đâu, trước khi start unit chạy `galera_recovery`, script này mở `mariadbd --wsrep-recover`: InnoDB chạy **crash recovery** từ redo log, đọc lại vị trí Galera được lưu cùng các giao dịch, và in ra `--wsrep_start_position=<uuid>:<seqno>`. Unit systemd truyền giá trị đó khi khởi động thật. Đây là lý do role có dòng `ExecStartPre` chạy `galera_recovery`.

### 2.3 Rejoin: IST hay SST

Có vị trí rồi, node xin vào lại cụm:

- **IST:** nếu `seqno` của node nằm trong bộ đệm **`gcache`** của một node đang `Synced` (nơi mỗi node giữ các writeset gần đây trong một file vòng, kích thước `gcache.size`), donor chỉ gửi phần thiếu. Nhanh.
- **SST:** nếu node tụt quá xa (`gcache` đã bị ghi đè) hoặc dữ liệu hỏng thì phải chép lại **toàn bộ** dữ liệu từ donor.

Vì vậy **`gcache.size` quyết định node tắt bao lâu thì còn IST được**. Tải ghi càng nhiều, `gcache` càng nhanh đầy.

### 2.4 Vì sao node tự khởi động lại

Role đặt trong unit `Restart=on-failure` và `RestartSec=5`. Khi tiến trình bị kill, systemd thấy dịch vụ lỗi, đợi 5 giây rồi tự start lại. Nhờ vậy sự cố thoáng qua (OOM) tự lành mà không cần người can thiệp. Nếu lỗi **lặp lại** (thiếu thư viện, hết đĩa, dữ liệu hỏng) thì systemd cứ restart liên tục: đó là dấu hiệu cần xem log, không chờ nữa.

## 3. Cách 1: Chạy script

```bash
cd ~/learn_mariadb/best_practices/03-node-crash-rejoin
./simulate_crash.sh mariadb-node3                 # kill -9 mariadbd trên node3 rồi theo dõi
TIMEOUT=900 ./simulate_crash.sh mariadb-node3     # chờ tối đa 15 phút (mặc định 600 giây)
DRY_RUN=1 ./simulate_crash.sh mariadb-node3
```

Script: (1) hỏi xác nhận; (2) chạy `kill -9` lên tiến trình `mariadbd` của node; (3) cứ 10 giây hỏi node trạng thái `active`, `wsrep` (`wsrep_local_state_comment`), `size`, `status` cho đến khi node `Synced` và `Primary` hoặc hết thời gian chờ. Trong lúc script chạy, mở cửa sổ khác chạy `maxctrl -u admin -p mariadb list servers` trên node khác để xem MaxScale đánh dấu node chết (`Down`) và chọn Master mới.

## 4. Cách 2: Các bước thủ công và lý do

### Bước 1. Gây crash

```bash
pidof mariadbd
kill -9 $(pidof mariadbd)
```

**Tại sao:** `SIGKILL` (9) không cho tiến trình dọn dẹp hay báo cụm, mô phỏng đúng OOM-killer hoặc mất nguồn. `systemctl stop` thì **không** mô phỏng được vì đó là tắt êm. Muốn giữ node chết để quan sát lâu hơn, dùng `systemctl stop mariadb` (và nhớ đây là tắt êm).

### Bước 2. Quan sát phía cụm

Trên một node khác:

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
watch -n 1 "maxctrl -u admin -p mariadb list servers"
```

**Tại sao:** `wsrep_cluster_size` giảm (còn 2) cho thấy cụm đã loại node chết. `list servers` cho thấy MaxScale: node chết `Down`; nếu đó là Master, một node `Slave` được nâng lên `Master` (MaxScale kiểm tra mỗi `monitor_interval=2s`). Hai thông tin này đến từ **hai cơ chế độc lập** (giao thức nhóm của Galera và monitor của MaxScale), nên có thể lệch nhau vài giây.

### Bước 3. Quan sát phía node vừa crash

```bash
tail -f /u01/logs/mariadb/mariadb.error.log
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

**Tại sao:** trong log bạn sẽ thấy InnoDB chạy crash recovery, Galera xin vào cụm, rồi quá trình IST hoặc SST. Trạng thái đi theo vòng đời `Joining`, `Joined`, `Synced` (xem [kịch bản 1](../01-healthcheck/README.md)). Đừng coi node là xong khi nó mới `Joined`, chỉ `Synced` mới là đã bắt kịp.

### Bước 4. Nếu node không tự lên được

```bash
journalctl -u mariadb --no-pager | tail -50
tail -n 100 /u01/logs/mariadb/mariadb.error.log
cat /u01/data/database/grastate.dat
```

**Tại sao:** `journalctl` cho biết systemd đã thử restart bao nhiêu lần và lý do; error log cho biết lỗi bên trong MariaDB và Galera; `grastate.dat` cho biết trạng thái Galera lưu trên đĩa. `seqno: -1` sau crash là **bình thường**, `galera_recovery` sẽ xác định lại.

| Nguyên nhân thường gặp | Xử lý |
|---|---|
| Thiếu `libssl.so.1.1` (Galera cần OpenSSL 1.1) | Cài `package/os-jammy/libssl1.1_*.deb`; role tự cài khi chạy playbook |
| Hết đĩa | Xem [kịch bản 10](../10-day-dia-binlog/README.md) |
| Dữ liệu hỏng, InnoDB không phục hồi được | Ép SST (bước 5) |
| Không nối được node khác | Kiểm tra cổng 1032 giữa các node và `wsrep_cluster_address` |

### Bước 5. Ép node tải lại toàn bộ dữ liệu (SST)

Chỉ làm khi dữ liệu của node đó không còn tin cậy **và** các node còn lại đang `Primary`:

```bash
systemctl stop mariadb
mv /u01/data/database /u01/data/database.bad.$(date +%F)
mkdir /u01/data/database
chown mariadb:mariadb /u01/data/database
chmod 750 /u01/data/database
systemctl start mariadb
```

**Tại sao:** node có datadir **rỗng** không có `grastate.dat`, tức không có vị trí nào để so với `gcache`, nên cụm buộc phải làm SST đầy đủ. Dùng `mv` thay vì `rm` để giữ lại dữ liệu cũ phục vụ điều tra (và phòng khi quyết định sai); chỉ xóa sau khi cụm đã ổn. `chown` và `chmod` vì MariaDB chạy bằng user `mariadb` và thư mục dữ liệu phải thuộc user đó, không cho người khác đọc.

## 5. Kiểm tra kết quả

```bash
cd ~/learn_mariadb/best_practices/01-healthcheck
./healthcheck.sh
```

Mong đợi: `wsrep_cluster_size` về 3, mọi node `Synced`, `Primary`, MaxScale thấy đủ 3 server. Sau khi chắc chắn, xóa thư mục `.bad` nếu đã tạo.

## 6. Lỗi thường gặp

| Triệu chứng | Nguyên nhân khả dĩ |
|---|---|
| Ứng dụng báo lỗi trong vài giây đầu | Kết nối tới node chết bị đứt và cụm cần thời gian loại node; ứng dụng cần retry và kết nối lại |
| Node restart liên tục (counter systemd tăng) | Lỗi lặp lại, xem `journalctl` và error log thay vì chờ |
| Node vào được nhưng SST rất lâu | `gcache` quá nhỏ so với thời gian tắt, hoặc dữ liệu lớn |

## 7. Điểm cốt lõi cần nhớ

- Tắt êm báo cụm rời đi; **crash thì cụm phải tự phát hiện** nên có độ trễ.
- Sau crash, `seqno: -1` là bình thường; **`galera_recovery`** lấy lại vị trí từ InnoDB.
- Rejoin bằng **IST** (nhanh) nếu `gcache` còn đủ, ngược lại **SST** (chép toàn bộ).
- `gcache.size` quyết định "node tắt bao lâu thì còn rejoin nhanh".
- `mv` datadir sang `.bad` là cách ép SST **an toàn**, vì vẫn giữ được dữ liệu cũ để điều tra.
