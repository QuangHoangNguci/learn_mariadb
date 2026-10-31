# Kịch bản 4: Mất toàn bộ cụm và bootstrap lại

**Script:** [bootstrap_cluster.sh](bootstrap_cluster.sh) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

Khôi phục khi **cả 3 node cùng tắt** (mất điện toàn bộ, tắt nhầm cả cụm, lỗi hạ tầng). Đây là kịch bản rủi ro cao nhất: chọn sai node để khởi tạo cụm sẽ **mất các giao dịch mới nhất**.

**Tác động:** có downtime cho đến khi node đầu tiên lên và cụm được dựng lại.

## 2. Kiến thức nền

### 2.1 Vì sao không thể "chỉ start cả ba node"

Mỗi node khi start sẽ đi tìm một node **đang chạy** trong `wsrep_cluster_address` để gia nhập. Nếu không ai đang chạy thì không có cụm nào để vào, node chờ mãi (và nếu hết thời gian, MariaDB báo lỗi kết nối nhóm và dừng). Phải có **một node tạo ra cụm mới** (`--wsrep-new-cluster`): node đó tự coi mình là thành phần `Primary` đầu tiên (chỉ có 1 thành viên), các node còn lại mới vào được.

### 2.2 Vì sao phải chọn node có dữ liệu mới nhất

Dữ liệu cụm mới = dữ liệu của node bootstrap. Các node join sau sẽ **đồng bộ về trạng thái của node đó**: node có dữ liệu mới hơn sẽ bị SST ghi đè và **mất** các giao dịch mà node bootstrap chưa có. Do đó phải chọn node có **`seqno` lớn nhất**, `seqno` là số thứ tự toàn cục của giao dịch đã commit trong lịch sử của cụm (nhận dạng bằng `uuid`).

### 2.3 `grastate.dat` và `safe_to_bootstrap`

Trong datadir, file `grastate.dat` lưu trạng thái Galera của node:

```
uuid:    <uuid lịch sử cụm>
seqno:   <giao dịch cuối đã commit, hoặc -1>
safe_to_bootstrap: <0 hoặc 1>
```

- Khi node **tắt êm**, Galera ghi `seqno` thật. **Node tắt cuối cùng** ghi `safe_to_bootstrap: 1` (nó chắc chắn có dữ liệu mới nhất vì không còn ai tiếp tục sau nó).
- Khi **crash hoặc mất điện**, mọi node có `seqno: -1` và `safe_to_bootstrap: 0` (không ai biết ai mới nhất).

`safe_to_bootstrap` là **lớp bảo vệ**: Galera từ chối bootstrap từ node mang `0` để bạn không vô tình khởi tạo từ node cũ. Khi đã **tự xác định** được node mới nhất, bạn đổi nó thành `1`.

### 2.4 `galera_recovery`: tìm node mới nhất khi `seqno = -1`

`galera_recovery` chạy `mariadbd --wsrep-recover`: InnoDB thực hiện crash recovery rồi đọc lại vị trí Galera đã được lưu **bên trong dữ liệu giao dịch InnoDB**, in ra `--wsrep_start_position=<uuid>:<seqno>`. Chạy lệnh này trên từng node (khi MariaDB đang tắt) cho ra `seqno` thật; node có số lớn nhất là node mới nhất.

### 2.5 Cờ bootstrap và vì sao phải xóa ngay

Unit systemd của role đọc file `/run/mariadb/wsrep-new-cluster` làm `EnvironmentFile`. Nếu file có dòng `_WSREP_NEW_CLUSTER=--wsrep-new-cluster`, `mariadbd` được truyền thêm cờ này và khởi tạo cụm mới. **Phải xóa file ngay sau khi start**, nếu không lần restart sau của node đó lại bootstrap một cụm mới, tách khỏi cụm thật (nguy cơ **split-brain**, xem [kịch bản 8](../08-mat-quorum-split-brain/README.md)). File nằm trong `/run` (tmpfs, mất khi reboot) và chỉ root đọc được để tránh người khác vô tình kích hoạt.

### 2.6 Vì sao start các node còn lại từng cái một

Mỗi node join phải nhận SST hoặc IST từ một donor. Start nhiều node cùng lúc làm chúng tranh nhau một donor duy nhất, quá tải I/O và dễ lỗi. Làm từng node, đợi `Synced` rồi mới sang node kế.

## 3. Cách 1: Chạy script

```bash
cd ~/learn_mariadb/best_practices/04-mat-toan-bo-cum-bootstrap
./bootstrap_cluster.sh
BOOTSTRAP_HOST=mariadb-node2 ./bootstrap_cluster.sh     # ép bootstrap từ node đã biết chắc là mới nhất
DRY_RUN=1 ./bootstrap_cluster.sh
```

Script thực hiện:

1. Chạy `--node recover` trên từng node: nếu **bất kỳ node nào đang chạy** thì dừng (script này chỉ dùng khi cả cụm tắt). Nếu tắt, chạy `galera_recovery` bằng user `mariadb` và in `RECOVER <seqno> <uuid>`.
2. Chọn node có `seqno` lớn nhất. Nếu mọi `seqno` đều `-1` thì dừng và yêu cầu bạn đặt `BOOTSTRAP_HOST` sau khi tự xem `grastate.dat`.
3. Hỏi xác nhận, rồi trên node đã chọn: đặt `safe_to_bootstrap: 1`, tạo thư mục `/run/mariadb`, ghi cờ, `systemctl start mariadb`, **luôn xóa cờ** (dù thành công hay lỗi), đợi `Synced`.
4. Start các node còn lại **lần lượt**, mỗi node đợi `Synced` và cụm đủ số node mong đợi.

`BOOTSTRAP_HOST` ép dùng một node và bỏ qua kết quả so `seqno`, chỉ dùng khi bạn chắc chắn. Script **chưa chạy trên cụm thật**; hãy thử trên lab, và với `DRY_RUN=1` chỉ dừng sau bước đo vì không thể đo `seqno` khi không chạy thật.

## 4. Cách 2: Các bước thủ công và lý do

> Không dùng `ansible-playbook install_mariadb.yml --tags start` cho việc này. Role coi node **đầu tiên trong inventory** luôn là bootstrap, và nếu service chưa chạy nó sẽ bootstrap một cụm mới dù dữ liệu của node đó có thể không phải mới nhất.

### Bước 1. Không start gì cả, xem `grastate.dat` trên mỗi node

```bash
cat /u01/data/database/grastate.dat
```

**Tại sao:** đây là nơi Galera ghi trạng thái dừng. Nếu có node `safe_to_bootstrap: 1`, đó là node tắt cuối, chọn nó và nhảy tới bước 3. Nếu mọi node là `0` và `seqno: -1`, đó là crash, làm bước 2. Việc **không** start gì trước khi quyết định rất quan trọng: một node start nhầm có thể tự bootstrap và tách cụm.

### Bước 2. Đo vị trí từng node bằng `galera_recovery`

Trên từng node, khi MariaDB đang tắt:

```bash
runuser -u mariadb -- /usr/local/mariadb/bin/galera_recovery
```

**Tại sao:** chạy bằng user `mariadb` vì các file dữ liệu thuộc user này (chạy bằng root sẽ tạo file thuộc root và làm service sau đó không start được). `runuser -u` chạy lệnh trực tiếp, không cần shell của user (shell của `mariadb` là `nologin`). Kết quả dạng `--wsrep_start_position=<uuid>:<seqno>`: chọn node có `seqno` lớn nhất. Nếu script lỗi, dùng cách thay thế:

```bash
runuser -u mariadb -- /usr/local/mariadb/bin/mariadbd --defaults-file=/etc/my.cnf --wsrep-recover
grep 'Recovered position' /u01/logs/mariadb/mariadb.error.log | tail -1
```

### Bước 3. Cho phép bootstrap trên node đã chọn

```bash
sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /u01/data/database/grastate.dat
```

**Tại sao:** vượt qua lớp bảo vệ ở mục 2.3. Bạn đang **tự cam kết** rằng node này mới nhất, dựa trên kết quả bước 2. Làm bước này trên node sai là nguyên nhân mất dữ liệu.

### Bước 4. Bootstrap trên node đã chọn

```bash
mkdir -p /run/mariadb
chown mariadb:mariadb /run/mariadb
chmod 750 /run/mariadb
echo '_WSREP_NEW_CLUSTER=--wsrep-new-cluster' > /run/mariadb/wsrep-new-cluster
systemctl start mariadb
rm -f /run/mariadb/wsrep-new-cluster
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

**Tại sao:** `/run` là tmpfs nên mất sau reboot, cần tạo lại thư mục (unit thường tự tạo qua `RuntimeDirectory`, nhưng tạo thủ công cho chắc). Cờ truyền `--wsrep-new-cluster` cho `mariadbd` qua unit (mục 2.5). `systemctl start` rồi **xóa cờ ngay** để lần restart sau không bootstrap lại. Kỳ vọng: `wsrep_cluster_size = 1` và `wsrep_cluster_status = Primary`: cụm một thành viên đã hình thành.

### Bước 5. Start các node còn lại, mỗi lần một node

```bash
systemctl start mariadb
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

**Tại sao:** các node này start **bình thường** (không có cờ), nên chúng đi tìm cụm đang chạy trong `wsrep_cluster_address`, thấy node bootstrap và gia nhập qua IST hoặc SST (mục 2.6). Đợi `Synced` rồi mới start node kế.

### Bước 6. MaxScale

MaxScale thường tự nhận lại các server sau vài giây. Nếu vẫn `Down`: `systemctl restart maxscale` và xem `/var/log/maxscale/maxscale.log`.

## 5. Kiểm tra kết quả

```bash
cd ~/learn_mariadb/best_practices/01-healthcheck
./healthcheck.sh
```

Sau đó ghi thử một dòng qua cổng 4006 để chắc ứng dụng ghi được. So sánh dữ liệu mới nhất (ví dụ dòng cuối của bảng quan trọng) với kỳ vọng để biết có mất giao dịch không.

## 6. Phòng ngừa

- Khi tắt cả cụm **có chủ đích**, tắt từng node một và ghi nhớ node tắt cuối; bật theo thứ tự ngược lại.
- Luôn có backup ([kịch bản 7](../07-backup-pitr/README.md)) vì bootstrap sai có thể không cứu được dữ liệu.
- Cân nhắc UPS hoặc nguồn dự phòng; đặt các node ở các miền lỗi khác nhau.

## 7. Điểm cốt lõi cần nhớ

- Bootstrap **tạo ra cụm mới** từ dữ liệu của **một** node; các node khác bị ép đồng bộ về node đó.
- Chọn node có **`seqno` lớn nhất** (`galera_recovery`), không chọn theo cảm tính.
- `safe_to_bootstrap` là lớp bảo vệ; tự đổi nó là **cam kết của bạn**.
- **Xóa cờ bootstrap ngay** sau khi start để tránh một lần restart sau tạo ra cụm thứ hai.
- Start node còn lại **từng cái một**, đợi `Synced`.
