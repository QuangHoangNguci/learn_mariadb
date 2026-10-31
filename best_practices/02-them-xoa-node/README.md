# Kịch bản 2: Thêm và xóa node

**Script:** [maxscale_server.sh](maxscale_server.sh) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

- **Thêm node:** mở rộng cụm (3 lên 4 hoặc 5 node), thay node hỏng, tăng khả năng chịu lỗi hoặc dung lượng đọc.
- **Xóa node:** thu hồi, thay phần cứng, thu nhỏ cụm.

**Tác động:** không downtime nếu làm đúng. Thêm node làm một node **donor** chậm đi trong lúc gửi dữ liệu. Xóa node làm cụm **mất dự phòng**: cụm 3 node xuống 2 node không còn chịu được thêm lỗi nào.

## 2. Kiến thức nền

### 2.1 Một node mới "gia nhập" cụm như thế nào

Node mới khởi động với `wsrep_cluster_address = gcomm://ip1:1032,ip2:1032,...`. Danh sách này chỉ để node **tìm đường vào**: node thử liên lạc với các địa chỉ đó, nếu gặp một node đang ở thành phần `Primary` thì xin vào. Sau khi vào, thành viên cụm được quản lý **động** bằng giao thức nhóm (cổng 1032), không phụ thuộc danh sách nữa.

Node mới chưa có dữ liệu nên cần **truyền trạng thái** từ một node đang `Synced`, gọi là **donor**:

| Cơ chế | Khi nào | Cách làm |
|---|---|---|
| **SST** (State Snapshot Transfer) | Node mới, hoặc quá lệch | Donor tạo bản sao đầy đủ bằng `mariabackup`, gửi qua cổng 1031 (dùng user `galera` trong `wsrep_sst_auth`). Donor chuyển `Donor/Desynced` trong lúc gửi, tốn I/O |
| **IST** (Incremental State Transfer) | Node đã có dữ liệu, chỉ thiếu phần gần đây | Donor gửi các writeset còn trong bộ đệm `gcache`, qua cổng 1033 |

Node mới hoàn toàn rỗng nên **luôn SST**. Role cho phép **một joiner mỗi lần** (`serial: 1`) để tránh nhiều node cùng SST làm quá tải donor.

### 2.2 Vì sao quorum quan trọng khi thêm hoặc bớt

Galera dùng đa số phiếu để tránh hai nửa cụm cùng nhận ghi khi đứt mạng (xem kịch bản 8). Hệ quả khi chọn số node:

| Số node | Chịu mất tối đa | Ghi chú |
|---|---|---|
| 3 | 1 node | Cấu hình chuẩn |
| 2 | 0 node | Mất 1 node là mất quorum, **không dùng** làm cấu hình lâu dài |
| 4 | 1 node | Không hơn 3 node về chịu lỗi (cần 3 trên 4 để có quorum), nên tránh số chẵn hoặc thêm `garbd` |
| 5 | 2 node | |

### 2.3 Hai điểm đặc thù của role này

1. **Node đầu tiên trong inventory là bootstrap.** Vai trò (bootstrap hay joiner) được suy ra từ **vị trí** trong inventory. Vì vậy thêm node mới ở **cuối** danh sách, không chèn lên đầu.
2. **`expand` không ghi đè `/etc/my.cnf` đang chạy** nếu buffer pool không đổi. Hệ quả: `wsrep_cluster_address` và `proxy_protocol_networks` trên node cũ **không** tự có IP của node mới. Việc này không chặn node mới gia nhập (vì danh sách chỉ để tìm đường, mục 2.1), nhưng cần cập nhật để các lần restart sau nhất quán.

### 2.4 `proxy_protocol_networks` để làm gì

MaxScale đứng giữa client và MariaDB nên MariaDB chỉ thấy IP của MaxScale. Với `proxy_protocol=true`, MaxScale gửi kèm một tiêu đề cho biết IP client thật; MariaDB chỉ **tin** tiêu đề này nếu nguồn nằm trong `proxy_protocol_networks` (biến chỉ đọc, cần restart để đổi). Nhờ đó quyền `user@host` được kiểm tra theo IP client thật. Node mới chưa có trong danh sách của node cũ thì MaxScale **trên node mới** gửi tiêu đề này bị node cũ từ chối.

### 2.5 `drain` là gì

Trong MaxScale, `set server X drain` làm server không nhận **kết nối mới**, còn kết nối đang mở được chạy tiếp đến khi xong. Dùng trước khi gỡ hoặc bảo trì để không cắt ngang giao dịch đang chạy.

## 3. Cách 1: Chạy script (phần MaxScale)

Phần cài và join MariaDB làm bằng Ansible (mục 4). Script `maxscale_server.sh` lo phần MaxScale vì **mỗi node có một MaxScale độc lập**, mọi thay đổi phải áp dụng cho từng node. Script chạy lệnh `maxctrl` trên **tất cả** node.

```bash
cd ~/learn_mariadb/best_practices/02-them-xoa-node
./maxscale_server.sh list                          # trạng thái server trên mọi node
./maxscale_server.sh add server_4 172.24.220.x     # thêm server mới (mặc định cổng 3306)
./maxscale_server.sh remove server_3               # drain, gỡ khỏi dịch vụ và monitor, xóa
./maxscale_server.sh drain server_2                # ngừng nhận kết nối mới
./maxscale_server.sh clear server_2                # gỡ drain
./maxscale_server.sh maintenance server_2          # đưa vào bảo trì
./maxscale_server.sh unmaintenance server_2        # gỡ bảo trì
DRY_RUN=1 ./maxscale_server.sh add server_4 172.24.220.x
```

`add` thực hiện: `create server ... proxy_protocol=true`, rồi `link monitor Galera-Monitor`, `link service Read-Write-Service`, `link service Read-Only-Service`. `remove` thực hiện ngược lại: `drain`, `unlink` khỏi hai dịch vụ và monitor, `destroy server`. Lỗi trên chính node mới khi `add` (server đã tồn tại do cấu hình sinh ra đã có đủ server, hoặc MaxScale chưa cài) là bình thường. Mật khẩu REST là `MAXCTRL_PASSWORD` (mặc định `mariadb`). Cú pháp `maxctrl` dựa vào hiểu biết chung về MaxScale, chưa kiểm chứng trên bản 25.10, kiểm tra bằng `maxctrl create server --help`.

## 4. Cách 2: Thêm node, các bước thủ công và lý do

### Bước 1. Chuẩn bị node mới

Cùng hệ điều hành với các node cũ, đồng bộ giờ (NTP), cùng SSH key với bastion, đủ RAM và đĩa; mở mạng các cổng 22, 3306, 1301, 1031, 1032, 1033 giữa node mới và các node cũ (cả security group của nền tảng ảo hóa).

**Tại sao:** Galera cần mạng **đầy đủ giữa mọi cặp node** (mesh): 1032 cho giao tiếp nhóm, 1031 cho SST, 1033 cho IST, 3306 cho client và MaxScale. Thiếu một cổng là join kẹt (kịch bản gặp thật: timeout ở cổng 1032). Giờ lệch làm log khó đối chiếu và có thể ảnh hưởng timestamp dữ liệu.

### Bước 2. Thêm vào inventory, ở cuối

```yaml
# ansible-mariadb/projects/inventory/databases.yaml
mariadb-node4: { ansible_host: 172.24.220.x }
```

**Tại sao:** vai trò suy ra từ vị trí (mục 2.3), nên node mới đặt cuối để được coi là joiner. `ansible_host` bắt buộc vì khi chạy `--limit` một node, role không thu thập facts của node khác nên cần IP khai báo sẵn.

### Bước 3. Mở firewall trên các node cũ

```bash
cd ~/learn_mariadb/ansible-mariadb
ansible-playbook projects/install_mariadb.yml -e @projects/lab.yml -e mariadb_install_mode=expand --tags os
```

**Tại sao:** role thêm quy tắc iptables ACCEPT cho IP các node trong cụm. Node cũ chưa có IP node mới trong quy tắc nên chặn gói tin từ nó. Giai đoạn `os` cập nhật quy tắc đó và an toàn khi chạy lại (idempotent). Dùng `expand` vì cụm đang chạy; `fresh` sẽ từ chối.

### Bước 4. Cài và join node mới

```bash
ansible-playbook projects/install_mariadb.yml -e @projects/lab.yml --limit mariadb-node4
```

**Tại sao:** `--limit` chỉ động tới node mới. Role cài binary, ghi `my.cnf` có `wsrep_cluster_address` đủ 4 node, bỏ qua `datadir` và `init` cho joiner (dữ liệu sẽ đến từ SST), rồi start và đợi `Synced`. Theo dõi: trên node mới `tail -f /u01/logs/mariadb/mariadb.error.log`; trên donor `wsrep_local_state_comment` chuyển `Donor/Desynced` rồi về `Synced`.

### Bước 5. Cập nhật cấu hình các node cũ

Trên **mỗi node cũ**:

```bash
grep -nE 'wsrep_cluster_address|proxy_protocol_networks' /etc/my.cnf
sed -i 's|^wsrep_cluster_address = gcomm://\(.*\)$|wsrep_cluster_address = gcomm://\1,172.24.220.x:1032|' /etc/my.cnf
sed -i 's|^proxy_protocol_networks = \(.*\)$|proxy_protocol_networks = \1,172.24.220.x|' /etc/my.cnf
```

**Tại sao:** `wsrep_cluster_address` đọc **lúc khởi động**; sửa file không đổi gì cho tiến trình đang chạy. Nhưng nếu node cũ restart với danh sách thiếu node4 thì nó vẫn vào được cụm (qua node khác) và biết node4 từ thông tin thành viên. Cập nhật để cấu hình khớp thực tế. `proxy_protocol_networks` là biến chỉ đọc nên hiệu lực **sau lần restart kế tiếp** (kết hợp rolling restart, kịch bản 5). Cho đến lúc đó, MaxScale của node4 kết nối vào node cũ có thể bị từ chối.

### Bước 6. Thêm node vào MaxScale

```bash
# MaxScale trên node mới: để role sinh cấu hình có đủ 4 server
cd ~/learn_mariadb/ansible-mariadb
ansible-playbook projects/install_mariadb.yml -e @projects/lab.yml --limit mariadb-node4 -e mariadb_install_maxscale=true --tags maxscale
```

Trên **từng node cũ**:

```bash
maxctrl -u admin -p mariadb create server server_4 172.24.220.x 3306 proxy_protocol=true
maxctrl -u admin -p mariadb link monitor Galera-Monitor server_4
maxctrl -u admin -p mariadb link service Read-Write-Service server_4
maxctrl -u admin -p mariadb link service Read-Only-Service server_4
```

**Tại sao:** MaxScale trên node cũ đang chạy với danh sách server cố định đọc từ `/etc/maxscale.cnf` lúc cài; role không ghi đè nó khi `expand`. Vì vậy phải thêm server **động** bằng `maxctrl`. Bốn lệnh theo đúng mô hình đối tượng của MaxScale: một `server` (kết nối tới MariaDB), được `monitor` (kiểm tra trạng thái Galera) theo dõi và được hai `service` (đường đọc/ghi và đường chỉ đọc) dùng. `proxy_protocol=true` khớp với cấu hình của các server cũ (mục 2.4).

### Kiểm tra khi thêm node

```bash
cd ~/learn_mariadb/best_practices/01-healthcheck
EXPECTED=4 ./healthcheck.sh
```

`wsrep_cluster_size` phải là 4 trên mọi node và `server_4` ở trạng thái `Synced, Running` trong `maxctrl list servers`.

## 5. Cách 2: Xóa node, các bước thủ công và lý do

### Bước 1. Đảm bảo vẫn còn quorum sau khi xóa

Chạy `./healthcheck.sh` ở kịch bản 1; `wsrep_cluster_size` phải từ 3 trở lên và tất cả `Synced`.

**Tại sao:** xóa node khi cụm đang thiếu node dễ đẩy cụm xuống dưới quorum. Cụm 3 xuống 2 chỉ nên làm khi bạn sắp thêm node thay thế (mục 2.2).

### Bước 2. Gỡ khỏi MaxScale trên mọi node

```bash
maxctrl -u admin -p mariadb set server server_3 drain
maxctrl -u admin -p mariadb list servers          # đợi cột Connections của server_3 về 0
maxctrl -u admin -p mariadb unlink service Read-Write-Service server_3
maxctrl -u admin -p mariadb unlink service Read-Only-Service server_3
maxctrl -u admin -p mariadb unlink monitor Galera-Monitor server_3
maxctrl -u admin -p mariadb destroy server server_3
```

**Tại sao:** gỡ khỏi định tuyến **trước** khi tắt MariaDB để ứng dụng không bị cắt kết nối giữa chừng. Thứ tự: `drain` (ngừng kết nối mới) rồi đợi kết nối cũ xong rồi mới `unlink` khỏi dịch vụ và monitor, cuối cùng `destroy` (MaxScale không cho xóa server còn được liên kết).

### Bước 3. Tắt MariaDB trên node cần xóa

```bash
systemctl stop mariadb
```

**Tại sao:** tắt êm làm node **gửi thông báo rời cụm**, các node còn lại cấu hình lại thành viên ngay và tính quorum theo cụm mới. Khác với crash (kịch bản 3), nơi cụm phải chờ hết thời gian chờ mới nhận ra node mất.

### Bước 4. Dọn node (tùy chọn)

```bash
cd ~/learn_mariadb/ansible-mariadb
ansible-playbook projects/uninstall_mariadb.yml -e @projects/lab.yml --limit mariadb-node3
```

**Tại sao:** xóa binary, dữ liệu, cấu hình và unit khỏi node. Có `--limit` để chỉ gỡ đúng node đó. Playbook này **xóa dữ liệu**, nên chỉ chạy khi chắc chắn không cần node nữa.

### Bước 5. Cập nhật cấu hình các node còn lại

Bỏ IP node đã xóa khỏi `wsrep_cluster_address` và `proxy_protocol_networks` trong `/etc/my.cnf` của từng node còn lại, rồi xóa host khỏi inventory.

**Tại sao:** nếu quên, cụm vẫn chạy bình thường (danh sách chỉ dùng lúc khởi động), chỉ có thêm cảnh báo khi một node restart rồi cố liên lạc node không còn tồn tại.

## 6. Kiểm tra và rollback

- **Kiểm tra:** `EXPECTED=<số node mới> ./healthcheck.sh`; `./maxscale_server.sh list` thấy đúng danh sách server.
- **Rollback thêm node:** nếu join lỗi, gỡ node mới bằng `uninstall_mariadb.yml --limit` rồi `maxscale_server.sh remove`.
- **Rollback xóa node:** thêm lại như một node mới (mục 4); dữ liệu cũ của node bị xóa nên sẽ SST lại từ đầu.

## 7. Lỗi thường gặp

| Triệu chứng | Nguyên nhân khả dĩ |
|---|---|
| Node mới kẹt `Joining` rất lâu | Thiếu cổng 1031/1032 giữa node mới và donor; hoặc dữ liệu lớn nên SST lâu (bình thường) |
| `Timeout when waiting for <ip>:1032` | Firewall hoặc security group chưa mở cổng Galera |
| `server_4` ở MaxScale node cũ báo `Auth Error` | User `maxscale` không có host khớp IP node mới (xem [users.sql](../../setup/mariadb/Install_Mariadb/users.sql)) |
| `server_4` ở MaxScale node mới báo `Down` trước khi restart node cũ | `proxy_protocol_networks` trên node cũ chưa có IP node mới (bước 5) |

## 8. Điểm cốt lõi cần nhớ

- Node mới luôn **SST** (truyền toàn bộ dữ liệu), vì vậy làm **từng node một** và chọn giờ ít tải.
- `wsrep_cluster_address` chỉ giúp **tìm đường vào** lúc khởi động; thành viên cụm sau đó tự quản lý.
- Mỗi node có **một MaxScale riêng**; mọi thay đổi MaxScale phải áp dụng cho từng node.
- `drain` trước, bảo trì sau: để không cắt giao dịch đang chạy.
- Giữ số node **lẻ**; cụm 2 node không có khả năng chịu lỗi.
