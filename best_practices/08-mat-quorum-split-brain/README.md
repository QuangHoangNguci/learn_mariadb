# Kịch bản 8: Mất quorum và split-brain

**Script:** [simulate_partition.sh](simulate_partition.sh) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

Hiểu và xử lý khi cụm **bị chia mạng** hoặc **mất đa số node**: node nào còn phục vụ, node nào tự dừng, cách cụm tự lành và cách can thiệp thủ công an toàn. Đây là nơi dễ **mất hoặc làm lệch dữ liệu** nhất nếu thao tác sai, nên cần hiểu nguyên lý trước khi bấm lệnh.

**Tác động:** phía thiểu số (không đủ quorum) **ngừng đọc/ghi**. Phía đa số vẫn chạy bình thường.

## 2. Kiến thức nền

### 2.1 Vì sao cần quorum

Nếu mạng đứt làm cụm tách thành hai nửa và **cả hai nửa cùng nhận ghi**, dữ liệu hai nửa sẽ lệch nhau và không thể tự trộn lại. Đó là **split-brain**. Galera ngăn điều này bằng **quorum**: một nhóm node chỉ được phép hoạt động nếu chiếm **hơn nửa** tổng số (tính theo trọng số) thành viên đã biết. Hai nửa không thể cùng chiếm hơn nửa, nên chỉ **tối đa một** nửa là `Primary`.

| Cụm 3 node | Hệ quả khi chia |
|---|---|
| 2 node thấy nhau, 1 node bị tách | Nhóm 2 node là `Primary` (2/3), node đơn lẻ là `non-Primary` (1/3) |
| 3 node mất liên lạc hoàn toàn với nhau | Không ai đủ quorum, cả ba `non-Primary` |

Node `non-Primary` **tự từ chối** đọc/ghi (thông báo `WSREP has not yet prepared node for application use`). Đây là **hành vi bảo vệ đúng**, không phải lỗi: thà ngừng còn hơn tạo dữ liệu lệch.

### 2.2 Cụm 2 node và số node chẵn

Với 2 node, mất 1 là mất quorum (1/2 không lớn hơn một nửa). Với 4 node chia 2-2, **không** bên nào có quá nửa, cả hai `non-Primary`. Vì vậy nên dùng số node **lẻ** (3, 5). Nếu bắt buộc số chẵn hoặc chỉ có 2 node dữ liệu, thêm **Galera Arbitrator `garbd`** (có sẵn trong `/usr/local/mariadb/bin/garbd`, role chưa cấu hình): nó tham gia **bỏ phiếu** quorum nhưng **không lưu dữ liệu**, đặt trên máy thứ ba.

### 2.3 Phát hiện và tự lành

- **Phát hiện:** giao thức nhóm gửi nhịp tim liên tục. Một node im lặng quá ngưỡng thời gian (tham số `evs.*`, cỡ vài giây đến chục giây) bị coi là mất liên lạc, và quorum được tính lại.
- **Tự lành:** khi mạng thông trở lại, node `non-Primary` thấy lại nhóm `Primary`, **tự gia nhập lại** và đồng bộ (IST hoặc SST, xem [kịch bản 3](../03-node-crash-rejoin/README.md)). Không cần can thiệp.

### 2.4 Khi nào phải can thiệp: `pc.bootstrap`

Nếu hai trong ba node **chết thật** (không phải chỉ mất mạng), node còn lại là `non-Primary` mãi mãi vì không bao giờ thấy được đa số. Khi đó bạn có thể **ép** nó thành `Primary`:

```
SET GLOBAL wsrep_provider_options='pc.bootstrap=YES';
```

Lệnh này nói với node: "coi những gì bạn đang thấy là thành phần Primary mới". Hợp lý **chỉ khi chắc chắn** các node kia đã chết hoặc ngoại tuyến lâu dài. Nếu các node kia thật ra **vẫn sống ở phía bên kia mạng bị chia** và bạn cũng ép chúng thành Primary, cả hai bên cùng nhận ghi: split-brain thật.

### 2.5 Split-brain thật và cách xử lý

Hai nửa cùng `Primary` với **lịch sử khác nhau** thì không còn cách trộn tự động. Phải **chọn một bên làm chuẩn** (bên có dữ liệu quan trọng hơn theo nghiệp vụ), và bên còn lại buộc phải **bỏ dữ liệu** của mình và nhận lại toàn bộ từ bên chuẩn bằng SST. Dữ liệu ghi riêng trên bên bị bỏ **sẽ mất**, nên nếu cần phải đối chiếu thủ công từ bản `.bad` được giữ lại.

### 2.6 Cách mô phỏng chia mạng bằng iptables

Script chặn gói tin giữa một node và các node còn lại bằng `iptables -j DROP`:

- **DROP** (bỏ gói tin im lặng) mô phỏng mạng đứt thật: bên kia **không nhận được phản hồi** và phải chờ hết thời gian mới kết luận mất liên lạc. `REJECT` thì phản hồi lỗi ngay, không giống đứt mạng thật.
- Rule được **chèn ở đầu** chain (`-I INPUT 1`) vì rule `ACCEPT` do role thêm nằm ở **cuối** chain; iptables duyệt từ trên xuống và dừng ở rule khớp đầu tiên, nên rule `DROP` ở đầu thắng.
- Mỗi rule có `comment bp-partition` để chỉ **gỡ đúng rule do script tạo**, không đụng rule của role.
- Chỉ chặn **IP các node DB** khác, không chặn bastion nên SSH vẫn hoạt động.

## 3. Cách 1: Chạy script

```bash
cd ~/learn_mariadb/best_practices/08-mat-quorum-split-brain
./simulate_partition.sh isolate mariadb-node3        # cô lập node3
./simulate_partition.sh status  mariadb-node3        # kỳ vọng non-Primary
../01-healthcheck/healthcheck.sh                     # node3 FAIL, node1 và node2 vẫn Primary
./simulate_partition.sh heal    mariadb-node3        # gỡ cô lập, node3 tự rejoin
./simulate_partition.sh status  mariadb-node3        # Synced
DRY_RUN=1 ./simulate_partition.sh isolate mariadb-node3
```

`isolate` hỏi xác nhận rồi, trên node đó, lấy danh sách IP đồng đẳng từ `wsrep_cluster_address` trong `/etc/my.cnf` của **chính node** (trừ IP của nó), chèn `DROP` cho INPUT và OUTPUT của từng IP. `heal` gỡ **đúng** các rule có `comment bp-partition`. `status` in số rule còn lại và các chỉ số `wsrep_cluster_status`, `wsrep_local_state_comment`, `wsrep_cluster_size`.

## 4. Cách 2: Các bước thủ công và lý do

### Bước 1. Cô lập node3 (trên node3)

```bash
iptables -I INPUT 1 -s <ip-node1> -j DROP
iptables -I OUTPUT 1 -d <ip-node1> -j DROP
iptables -I INPUT 1 -s <ip-node2> -j DROP
iptables -I OUTPUT 1 -d <ip-node2> -j DROP
```

**Tại sao:** cần chặn **cả hai chiều** (INPUT từ nguồn, OUTPUT tới đích) vì chia mạng thật là hai chiều; chặn một chiều gây hiện tượng bất đối xứng khó đoán. `-I ... 1` chèn lên đầu (mục 2.6). Thực hiện trên node bị cô lập nên các node còn lại không cần đụng gì.

### Bước 2. Quan sát phía thiểu số (node3, 1/3)

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SELECT 1 FROM vn_provinces.provinces LIMIT 1;"
```

**Tại sao:** sau vài giây node3 báo `non-Primary` và mọi truy vấn trả lỗi `WSREP has not yet prepared node for application use`. Đây chính là cơ chế bảo vệ ở mục 2.1: node thiểu số tự chặn để không tạo dữ liệu mà đa số không biết.

### Bước 3. Quan sát phía đa số (node1 hoặc node2, 2/3)

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
maxctrl -u admin -p mariadb list servers
```

**Tại sao:** `wsrep_cluster_size = 2` và vẫn `Primary`, ứng dụng vẫn đọc ghi qua MaxScale; `server_3` ở MaxScale chuyển `Down`. Đây là minh họa: **mất một node trong ba là không gián đoạn dịch vụ**.

### Bước 4. Gỡ cô lập (trên node3)

```bash
iptables -D INPUT -s <ip-node1> -j DROP
iptables -D OUTPUT -d <ip-node1> -j DROP
iptables -D INPUT -s <ip-node2> -j DROP
iptables -D OUTPUT -d <ip-node2> -j DROP
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

**Tại sao:** `-D` xóa đúng rule đã chèn (phải giống hệt tham số đã `-I`). Khi mạng thông, node3 tự thấy lại nhóm `Primary`, gia nhập và đồng bộ; trạng thái đi `Joining` rồi `Joined` rồi `Synced` (mục 2.3). **Không cần restart.**

### Bước 5. Mất đa số thật sự (ví dụ 2 trong 3 node chết)

**Điều kiện tiên quyết:** xác nhận hai node kia thật sự đã chết (vào máy, xem nguồn, hỏi hạ tầng), **không** chỉ là mất mạng tới node này.

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SET GLOBAL wsrep_provider_options='pc.bootstrap=YES';"
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
```

**Tại sao:** mục 2.4. Node còn lại không thể tự thấy đa số nên bạn **ép** nó thành `Primary` để ứng dụng chạy tiếp. Kỳ vọng `Primary`, `wsrep_cluster_size = 1`. Cụm lúc này **không có dự phòng**, hãy đưa các node kia lên càng sớm càng tốt: start từng node một, chúng sẽ SST hoặc IST từ node này.

### Bước 6. Xử lý split-brain thật

Dấu hiệu: hai nhóm node cùng `Primary` nhưng `wsrep_cluster_state_uuid` khác nhau (`SHOW STATUS LIKE 'wsrep_cluster_state_uuid'` trên từng node), hoặc dữ liệu khác nhau.

Quy trình: (1) chọn bên chuẩn; (2) với các node bên còn lại: dừng MariaDB, chuyển datadir sang `.bad`, start lại để SST (xem bước 5 của [kịch bản 3](../03-node-crash-rejoin/README.md)); (3) đối chiếu thủ công từ `.bad` nếu cần dữ liệu ghi riêng.

**Tại sao:** không có cách tự động hợp nhất hai lịch sử khác nhau. SST là cách duy nhất đưa bên bị bỏ về đúng trạng thái bên chuẩn.

## 5. Kiểm tra kết quả

```bash
../01-healthcheck/healthcheck.sh
```

Sau `heal`: mọi node `Primary`, `Synced`, `wsrep_cluster_size = 3`, và không còn rule `bp-partition` (`iptables -S | grep bp-partition` rỗng).

## 6. Phòng ngừa

- Luôn **số node lẻ** (3, 5). Cần số chẵn thì thêm `garbd`.
- Đặt node ở các miền lỗi khác nhau (rack, vùng khả dụng) để một sự cố hạ tầng không lấy đi đa số.
- Giám sát `wsrep_cluster_size` và `wsrep_cluster_status` để phát hiện sớm.
- Chỉ dùng `pc.bootstrap` khi **chắc chắn** các node còn lại đã chết.

## 7. Điểm cốt lõi cần nhớ

- Quorum = **hơn nửa** node; hai nửa không thể cùng có quorum, nên chỉ một nửa nhận ghi.
- Node thiểu số **tự ngừng** (`non-Primary`): đó là bảo vệ dữ liệu chứ không phải lỗi.
- Mất mạng thoáng qua thì **tự lành**; mất node thật thì mới cần can thiệp.
- `pc.bootstrap=YES` chỉ khi **chắc chắn** các node kia đã chết, nếu không sẽ gây split-brain.
- Split-brain thật buộc bên bị bỏ **mất dữ liệu riêng**: phòng ngừa tốt hơn chữa.
