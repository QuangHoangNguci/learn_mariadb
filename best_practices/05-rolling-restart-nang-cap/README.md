# Kịch bản 5: Rolling restart và nâng cấp không downtime

**Script:** [rolling_restart.sh](rolling_restart.sh) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

Thay đổi một thứ cần **restart MariaDB** mà ứng dụng không gián đoạn:

- Đổi tham số tĩnh trong `/etc/my.cnf` (tham số không đổi được bằng `SET GLOBAL`).
- Vá bản cập nhật hệ điều hành cần reboot.
- Nâng cấp phiên bản MariaDB.
- Áp dụng cấu hình mới sau khi thêm hoặc xóa node (kịch bản 2).

**Tác động:** không downtime nếu **mỗi lần chỉ một node** và cụm luôn giữ quorum. Ứng dụng chỉ thấy kết nối tới node đang restart bị đứt.

## 2. Kiến thức nền

### 2.1 Vì sao mỗi lần một node, và phải đợi

Cụm 3 node cần **2 node** để giữ quorum. Restart một node còn 2 node: vẫn đủ. Nếu restart hai node cùng lúc chỉ còn 1: mất quorum, cụm ngừng phục vụ (kịch bản 8). Nên sau mỗi node phải **đợi node quay lại `Synced` và cụm đủ số node** rồi mới sang node tiếp. Chỉ "node đã start" chưa đủ: nó có thể mới `Joined` và đang bắt kịp các giao dịch đã xảy ra lúc nó tắt.

### 2.2 Node quay lại bắt kịp bằng IST

Trong lúc node tắt, cụm vẫn nhận ghi. Khi node quay lại, nó nhận phần thiếu bằng **IST** từ `gcache` của donor (xem kịch bản 3). Vì vậy:

- Restart ngắn thì IST nhanh. Nếu node tắt quá lâu, `gcache` đã bị ghi đè và node phải **SST** toàn bộ (lâu, tốn I/O donor).
- Nâng cấp mất nhiều thời gian trên một node là rủi ro: phải ước lượng thời gian trước.

### 2.3 Vì sao `drain` trước khi restart

Nếu restart ngay, các kết nối đang chạy tới node đó bị cắt giữa chừng và lỗi đến ứng dụng. `drain` trong MaxScale làm server **ngừng nhận kết nối mới**, còn kết nối cũ chạy tiếp đến khi xong. Sau khoảng chờ ngắn, hầu hết kết nối đã tự kết thúc, lúc đó restart gây ít gián đoạn nhất. Mỗi node có **một MaxScale độc lập**, nên `drain` phải chạy trên **cả 3 MaxScale**, nếu chỉ drain ở một node thì client đi qua các MaxScale khác vẫn vào node đó.

### 2.4 Vì sao node Master làm cuối

MaxScale `readwritesplit` dồn mọi lệnh ghi về **một Master**. Restart node Master làm MaxScale phải chọn Master mới và mọi kết nối ghi tới node cũ bị đứt. Nếu restart Master **sớm** rồi Master mới lại được chọn trúng node sắp bị restart tiếp theo, bạn gây gián đoạn ghi **hai lần**. Làm Master cuối thì chỉ gián đoạn một lần. Với `disable_master_failback=1`, Master sau khi đổi không tự quay về node cũ.

### 2.5 Tham số tĩnh và tham số động

- **Động:** đổi ngay bằng `SET GLOBAL` (ví dụ `max_connections`, `innodb_buffer_pool_size`, kích thước buffer pool có thể đổi **online**). Không cần restart, nhưng giá trị mất khi restart nếu không ghi vào `my.cnf`.
- **Tĩnh:** chỉ đọc lúc khởi động (ví dụ `proxy_protocol_networks`, `wsrep_cluster_address`, `innodb_log_file_size` ở một số phiên bản). Muốn đổi phải sửa `my.cnf` và **restart** (đây là chỗ cần rolling restart).

Quy tắc an toàn: đổi động để có hiệu lực ngay (nếu được) **và** ghi vào `my.cnf` để bền qua lần restart.

### 2.6 Nâng cấp binary bằng role: vì sao `fresh` và vì sao start thủ công

- Role có hai chế độ cài: `expand` (giữ instance đang chạy, **bỏ qua** cài binary nếu thư mục cài đã có) và `fresh` (cài lại binary, **từ chối** nếu service đang chạy). Nâng cấp cần cài binary mới nên dùng `fresh` khi node **đã tắt**.
- `fresh` chuyển thư mục cũ thành `/usr/local/mariadb.bak.<epoch>` (cơ sở để rollback), giải nén tarball mới vào chỗ cũ, ghi lại `my.cnf` và unit. Các bước `datadir` và `init` không chạy, nên **dữ liệu không bị đụng**.
- **Không để role start node:** role suy ra vai trò từ vị trí trong inventory và node đầu tiên luôn là bootstrap. Chạy bước `start` của role trên node đó khi service tắt sẽ **bootstrap một cụm mới**, nguy hiểm. Chỉ dùng các tag `os,install,config,service`, rồi `systemctl start` bằng tay.
- Role chọn tarball **đầu tiên theo thứ tự tên** trong `package/mariadb/`. Nếu bản cũ nằm cạnh bản mới thì nó cài bản cũ. Hãy để **đúng một** tarball đích.
- `mariadb-upgrade` cập nhật các bảng hệ thống (`mysql.*`) cho phù hợp phiên bản mới. Nâng minor thường không cần; nâng major thì cần và phải làm đúng theo tài liệu nâng cấp Galera của phiên bản đích.

## 3. Cách 1: Chạy script (rolling restart)

```bash
cd ~/learn_mariadb/best_practices/05-rolling-restart-nang-cap
./rolling_restart.sh                                              # mặc định: ngược thứ tự inventory
ORDER="mariadb-node3 mariadb-node1 mariadb-node2" ./rolling_restart.sh   # tự chọn thứ tự, Master để cuối
NO_MAXSCALE=1 ./rolling_restart.sh                                # cụm chưa cài MaxScale
DRAIN_WAIT=60 ./rolling_restart.sh                                # chờ 60 giây cho kết nối cũ tan
DRY_RUN=1 ./rolling_restart.sh                                    # xem trước
```

Xem node Master trước để đặt thứ tự: `maxctrl -u admin -p mariadb list servers` (node `Master`). Script:

1. Chạy `01-healthcheck/healthcheck.sh` lúc bắt đầu; nếu cụm chưa khỏe thì **dừng** (bỏ qua bằng `SKIP_HEALTHCHECK=1`).
2. Với từng node theo thứ tự: `maxctrl set server server_N drain` trên **mọi** node, chờ `DRAIN_WAIT` giây (mặc định 20), restart `mariadb` trên node đó, đợi `Synced` và cụm đủ `EXPECTED` node (tối đa 20 phút), rồi `maxctrl clear server server_N drain`.
3. Nếu một node không rejoin được thì **dừng ngay**, nhắc cách gỡ `drain`, không động tới node tiếp theo.
4. Cuối cùng chạy lại healthcheck.

Cú pháp `drain` theo hiểu biết chung về MaxScale, chưa kiểm chứng trên bản 25.10; nếu không hợp, dùng `maintenance` (xem [kịch bản 2](../02-them-xoa-node/README.md)).

## 4. Cách 2: Rolling restart thủ công và lý do

Lặp lại các bước sau cho từng node (ví dụ `server_2`):

### Bước 1. Rút node khỏi định tuyến, trên MỖI node

```bash
maxctrl -u admin -p mariadb set server server_2 drain
maxctrl -u admin -p mariadb list servers         # đợi Connections của server_2 về 0
```

**Tại sao:** mục 2.3. Phải làm trên **mọi** MaxScale vì mỗi node có một MaxScale riêng. Cột `Connections` về 0 nghĩa là không còn giao dịch nào chạy trên node đó.

### Bước 2. Restart node

```bash
systemctl restart mariadb
```

**Tại sao:** `restart` tắt êm (node báo rời cụm, cụm còn 2 node vẫn có quorum) rồi start lại. Với vá hệ điều hành, thay bằng việc bảo trì rồi reboot.

### Bước 3. Đợi node `Synced` và đủ node

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS WHERE Variable_name IN ('wsrep_local_state_comment','wsrep_cluster_size');"
```

Chạy lại lệnh cho đến khi `wsrep_local_state_comment` là `Synced` và `wsrep_cluster_size` là 3.

**Tại sao:** `Synced` nghĩa là node đã bắt kịp mọi giao dịch cụm đã commit trong lúc nó tắt (mục 2.2). Chưa `Synced` mà đã sang node tiếp theo là rủi ro mất dự phòng và nguy cơ mất quorum.

### Bước 4. Đưa node trở lại, trên MỖI node

```bash
maxctrl -u admin -p mariadb clear server server_2 drain
```

**Tại sao:** gỡ trạng thái `drain` để MaxScale lại gửi kết nối tới node. Quên bước này là node chạy khỏe nhưng không được dùng.

### Đổi tham số động không cần restart

```sql
SET GLOBAL max_connections = 300;
SET GLOBAL innodb_buffer_pool_size = 2147483648;   -- resize online (2GB)
```

**Tại sao:** nếu tham số đổi được online thì tránh luôn việc restart. Nhớ ghi cùng giá trị vào `/etc/my.cnf` (hoặc biến Ansible) để giá trị còn sau lần restart sau.

## 5. Nâng cấp binary MariaDB bằng role

Chuẩn bị trên bastion:

- Chỉ để **đúng một** tarball đích trong `package/mariadb/` (mục 2.6).
- Đọc release notes phiên bản đích: nâng minor thường dễ; nâng major cần `mariadb-upgrade` và làm đúng quy trình.
- Backup đầy đủ ([kịch bản 7](../07-backup-pitr/README.md)).

Lần lượt từng node (Slave trước, Master cuối). Rút node khỏi MaxScale bằng `../02-them-xoa-node/maxscale_server.sh drain server_N`, sau đó:

### Bước a. Dừng MariaDB trên node

```bash
ssh <node> 'systemctl stop mariadb'
```

**Tại sao:** `fresh` từ chối chạy khi service đang chạy, để tránh ghi đè binary dưới chân một tiến trình đang chạy.

### Bước b. Cài binary mới, ghi lại config và unit

```bash
cd ~/learn_mariadb/ansible-mariadb
ansible-playbook projects/install_mariadb.yml -e @projects/lab.yml --limit <node> -e mariadb_install_mode=fresh --tags os,install,config,service
```

**Tại sao:** `--limit` chỉ động node này. Các tag `os,install,config,service` cài binary và ghi cấu hình nhưng **không** có `datadir`, `init` (không đụng dữ liệu) và **không** có `start` (tránh nguy cơ bootstrap, mục 2.6). Thư mục cài cũ được giữ làm `.bak`.

### Bước c. Start thủ công và đợi `Synced`

```bash
ssh <node> 'systemctl start mariadb'
ssh <node> "/usr/local/mariadb/bin/mariadb -u root -p -S /u01/data/database/mariadb.sock -e \"SELECT VERSION(); SHOW STATUS LIKE 'wsrep_local_state_comment';\""
```

**Tại sao:** start bằng systemd thường: node vào cụm như một thành viên bình thường (không có cờ bootstrap), nhận IST phần thiếu. `SELECT VERSION()` xác nhận đã chạy đúng binary mới.

### Bước d. Nếu nâng major

Sau khi **cả cụm** đã ở bản mới, theo tài liệu phiên bản đích:

```bash
/usr/local/mariadb/bin/mariadb-upgrade -u root -p -S /u01/data/database/mariadb.sock
```

**Tại sao:** cập nhật bảng hệ thống cho khớp phiên bản mới. Làm sau khi cả cụm đã nâng để các node không dùng hai phiên bản schema hệ thống khác nhau lâu.

### Bước e. Gỡ drain rồi kiểm tra trước khi sang node kế

```bash
../02-them-xoa-node/maxscale_server.sh clear server_N
../01-healthcheck/healthcheck.sh
```

### Rollback một node

Dừng service, đổi tên thư mục cài cũ `/usr/local/mariadb.bak.<epoch>` về `/usr/local/mariadb`, start. Chỉ an toàn khi **chưa chạy `mariadb-upgrade`** và dữ liệu chưa được chuyển sang định dạng mới.

## 6. Kiểm tra kết quả

Sau mỗi node: `healthcheck.sh` đạt, MaxScale thấy đủ 3 server `Synced, Running`. Với ứng dụng: không có lỗi kéo dài, chỉ có đứt kết nối thoáng qua tới node vừa restart.

## 7. Lỗi thường gặp

| Triệu chứng | Nguyên nhân khả dĩ |
|---|---|
| Ứng dụng lỗi nhiều khi restart node | Chưa `drain` hoặc `DRAIN_WAIT` quá ngắn; hoặc đang restart node Master quá sớm |
| Node không bao giờ `Synced` sau restart | Tắt quá lâu nên SST kéo dài; hoặc thiếu thư viện, xem [kịch bản 3](../03-node-crash-rejoin/README.md) |
| `fresh` báo từ chối vì service đang chạy | Chưa dừng MariaDB trên node (bước a) |
| Sau nâng cấp vẫn thấy phiên bản cũ | Còn tarball cũ trong `package/mariadb/` nên role cài bản cũ |

## 8. Điểm cốt lõi cần nhớ

- **Một node mỗi lần**, và đợi `Synced` và đủ node: quorum là điều kiện sống còn.
- `drain` trên **mọi** MaxScale trước khi restart để không cắt giao dịch.
- **Master làm cuối** để chỉ gián đoạn ghi một lần.
- Nâng cấp bằng `fresh` khi node đã tắt, **start thủ công**, để dữ liệu nguyên vẹn và tránh bootstrap nhầm.
- Chỉ **một tarball** trong `package/mariadb/`.
