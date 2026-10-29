# Kiến trúc cụm MariaDB Galera 3 node + MaxScale

Tài liệu mô tả cụm do role `mariadb` dựng ra khi chạy với `mariadb_topology: cluster` và `mariadb_install_maxscale=true`. Cách cài xem [README.md](README.md).

## 1. Tổng quan

![Kiến trúc tổng quan](docs/images/architecture.svg)

- **3 node MariaDB** chạy Galera Cluster. Cả 3 đều là **master** (multi-master), cùng chứa một bản dữ liệu đầy đủ.
- **MaxScale** là proxy đứng trước cluster. Role cài một instance MaxScale trên **mỗi node**. Mỗi MaxScale kết nối tới cả 3 MariaDB và tự theo dõi node nào còn sống.
- Ứng dụng kết nối vào **MaxScale**, không kết nối thẳng vào MariaDB: cổng `4006` để đọc/ghi, cổng `4016` để chỉ đọc.

## 2. Các thành phần

| Thành phần | Vai trò | Cổng |
|---|---|---|
| MariaDB Server | Lưu dữ liệu, xử lý SQL | `3306` (client), `1301` (`extra_port`, cổng quản trị dự phòng) |
| Galera (wsrep) | Đồng bộ dữ liệu giữa các node | `1032` giao tiếp nhóm, `1031` SST, `1033` IST |
| MaxScale `readwritesplit` | Nhận kết nối đọc/ghi, tách ghi về 1 node, đọc sang các node còn lại | `4006` |
| MaxScale `readconnroute` | Nhận kết nối chỉ đọc, chia đều cho các node `Synced` | `4016` |
| MaxScale REST API | Quản trị MaxScale (chỉ lắng nghe `127.0.0.1`) | `8990` |

Cổng 1031–1033 tính từ `mariadb_wsrep_base_port` (mặc định 1030) cộng 1, 2, 3.

## 3. Galera: 3 node đều là master, đồng bộ như thế nào

**Galera** là cơ chế sao chép đồng bộ (virtually synchronous, certification-based) cho MariaDB. Khác với replication master/slave truyền thống:

| | Replication master/slave | Galera |
|---|---|---|
| Node ghi được | Chỉ master | **Cả 3 node** |
| Cách đồng bộ | Bất đồng bộ (slave kéo binlog, có thể chậm) | Đồng bộ khi commit |
| Mất node | Phải promote slave thủ công | Các node còn lại tự tiếp tục (đủ quorum) |
| Dữ liệu trên các node | Có thể lệch | Giống nhau tại mọi thời điểm commit |

### Luồng một lần ghi

![Luồng ghi trong Galera](docs/images/write-flow.svg)

1. Client gửi `INSERT/UPDATE` tới MaxScale (cổng 4006).
2. MaxScale chuyển lệnh ghi tới node Master mà nó đang chọn.
3. Khi `COMMIT`, node đó gói các thay đổi thành một **writeset**.
4. Writeset được phát tới các node còn lại theo một thứ tự toàn cục (total order).
5. **Mỗi node tự certify**: kiểm tra writeset có xung đột với giao dịch khác không. Quy tắc giống nhau trên mọi node nên kết quả giống nhau, không cần bỏ phiếu.
6. Nếu hợp lệ, node nhận lệnh trả OK cho client. Các node còn lại áp dụng (apply) writeset ngay sau đó, song song bằng `wsrep_slave_threads`.

Hệ quả:
- **Không mất dữ liệu đã commit** khi một node chết: writeset đã có trên các node khác.
- **Xung đột:** hai node cùng sửa một dòng cùng lúc thì giao dịch đến sau bị rollback (`Deadlock found when trying to get lock`). Ứng dụng cần retry. Đây là lý do MaxScale gom hết lệnh ghi về một node (mục 4).
- **Độ trễ ghi** bằng thời gian một vòng mạng giữa các node, nên cần mạng nội bộ nhanh và ổn định.
- **Đọc ngay sau ghi trên node khác** có thể thấy dữ liệu cũ trong một khoảng rất ngắn, vì apply chạy sau khi trả OK. MariaDB có `wsrep_sync_wait` và MaxScale có `causal_reads` để chặn, nhưng role **không bật** hai thứ này.
- Bảng nên có `PRIMARY KEY`, dùng InnoDB.

### Quorum và split-brain

Galera dùng đa số phiếu (quorum) để tránh hai nửa cụm cùng nhận ghi khi đứt mạng. Vì vậy **dùng số node lẻ (3)**:

| Số node còn liên lạc được | Trạng thái |
|---|---|
| 3/3 | Bình thường |
| 2/3 | Vẫn `Primary`, tiếp tục nhận ghi |
| 1/3 | Mất quorum, node còn lại chuyển `non-Primary` và từ chối đọc/ghi để không lệch dữ liệu |

### Node mới hoặc node quay lại: SST và IST

- **SST** (State Snapshot Transfer): node mới/đã lệch quá xa nhận **toàn bộ dữ liệu** từ một node donor. Role dùng `mariabackup` (`wsrep_sst_method`), donor vẫn phục vụ được trong lúc đó.
- **IST** (Incremental State Transfer): node tắt ngắn hạn chỉ nhận phần thay đổi bị bỏ lỡ, lấy từ bộ đệm `gcache` của donor. `gcache` càng lớn thì node tắt càng lâu vẫn IST được (cấu hình bằng `mariadb_gcache_size`).

## 4. MaxScale: đọc ghi và HA

MaxScale không lưu dữ liệu, chỉ định tuyến kết nối. Cấu hình do role sinh ra ([maxscale.cnf.j2](roles/mariadb/templates/maxscale.cnf.j2)):

| Thành phần | Cấu hình | Ý nghĩa |
|---|---|---|
| Monitor `galeramon` | `monitor_interval=2s` | Mỗi 2 giây hỏi trạng thái Galera của từng node, biết node nào `Synced`, node nào chết hoặc đang làm donor |
| Dịch vụ ghi, cổng 4006 | `readwritesplit` | Ghi đi về **một node Master** do monitor chọn trong các node `Synced`, đọc có thể đi sang các node còn lại |
| Dịch vụ đọc, cổng 4016 | `readconnroute`, `router_options=synced` | Mỗi kết nối được gán cho một node `Synced`, chia đều giữa các node |
| `disable_master_failback=1` | | Khi node cũ hồi phục không giành lại vai trò Master, tránh đổi Master qua lại |
| `available_when_donor=1` | | Node đang làm donor cho SST vẫn nhận kết nối |
| `proxy_protocol=true` | | MaxScale gửi kèm IP thật của client để MariaDB kiểm tra quyền theo IP thật (MariaDB bật `proxy_protocol_networks` cho các IP trong cluster) |

### Tại sao ghi về một node dù cả 3 đều là master

Về lý thuyết ghi vào node nào cũng được. Nhưng nếu nhiều client ghi cùng lúc vào các node khác nhau lên cùng dữ liệu, tỉ lệ certification thất bại (rollback) tăng. `readwritesplit` gom ghi về một node nên:
- giảm xung đột và lỗi `Deadlock found`;
- vẫn tận dụng hai node còn lại để **đọc**.

Ba node vẫn đều giữ đủ dữ liệu và đều có thể thay làm Master bất cứ lúc nào.

### Đọc/ghi từ ứng dụng

| Mục đích | Kết nối | Ghi chú |
|---|---|---|
| Đọc và ghi (ứng dụng bình thường) | `<maxscale>:4006` | MaxScale tự tách: lệnh ghi và giao dịch về Master, `SELECT` có thể sang node khác |
| Chỉ đọc (báo cáo, batch nặng) | `<maxscale>:4016` | Chia kết nối đều giữa các node `Synced`, không nhận ghi đúng nghĩa |
| Quản trị, chẩn đoán | `<node>:3306` hoặc `:1301` | Vào thẳng MariaDB, bỏ qua MaxScale |

### Khi một node chết (failover)

![Failover](docs/images/failover.svg)

1. Node 1 (đang là Master) chết. Galera loại nó khỏi cluster, 2 node còn lại vẫn đủ quorum và tiếp tục chạy.
2. Trong tối đa khoảng 2 giây (`monitor_interval`) MaxScale thấy node 1 không còn `Synced` và chọn Master mới trong các node còn lại.
3. Kết nối đang mở tới node 1 bị đứt. Ứng dụng cần kết nối lại và retry giao dịch đang dở. Giao dịch đã commit trước đó không mất.
4. Khi node 1 hồi phục, nó tự rejoin cluster (IST hoặc SST) và quay lại làm node đọc, không giành lại Master nhờ `disable_master_failback=1`.

Chết một node **đọc** thì MaxScale chỉ ngừng gửi kết nối tới node đó, không ảnh hưởng ghi.

### HA của chính MaxScale

Role cài MaxScale trên cả 3 node, mỗi instance chạy độc lập và cùng cấu hình, nên MaxScale không phải điểm lỗi duy nhất. Tuy nhiên:

- Ứng dụng cần một địa chỉ để kết nối. Có hai cách:
  - **Địa chỉ ảo (VIP)** dùng keepalived trỏ vào một MaxScale đang sống. Role **chưa cấu hình** keepalived (gói `keepalived` có sẵn trong `package/os/`, bạn tự cài và cấu hình).
  - **Danh sách nhiều host** trong connection string của driver (failover phía client), ví dụ `jdbc:mariadb:sequential://n1:4006,n2:4006,n3:4006/db`.
- Nếu không có VIP hay danh sách host, ứng dụng chỉ trỏ vào một MaxScale thì node đó chết là mất đường vào dù cluster vẫn khỏe.

## 5. Tóm tắt

| Câu hỏi | Trả lời |
|---|---|
| 3 node có đều là master không? | Có. Galera là multi-master, cả 3 đều nhận ghi và giữ dữ liệu đầy đủ |
| Dữ liệu đồng bộ ra sao? | Đồng bộ khi commit qua writeset + certification, không lệch giữa các node |
| MaxScale làm gì? | Proxy: tách ghi/đọc, phát hiện node chết, chuyển Master, ẩn topology khỏi ứng dụng |
| Ghi ở đâu? | Qua MaxScale cổng 4006, MaxScale đưa về một node Master (giảm xung đột) |
| Đọc ở đâu? | Cổng 4006 (tách tự động) hoặc 4016 (chia đều giữa các node `Synced`) |
| Chết một node thì sao? | Cluster vẫn chạy (2/3 đủ quorum). MaxScale đổi Master trong ~2 giây nếu cần |
| Chết hai node thì sao? | Mất quorum, node còn lại ngừng nhận đọc/ghi để bảo vệ dữ liệu |
| HA cho MaxScale? | 3 instance sẵn có, cần thêm VIP (keepalived, chưa cấu hình trong role) hoặc danh sách host phía client |
