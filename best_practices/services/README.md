# Services mô phỏng tải thật lên cụm MariaDB

Bộ ba service nhỏ để tạo **tải ghi và đọc liên tục** lên cụm Galera + MaxScale, giúp bạn quan sát cụm hoạt động và thử các kịch bản vận hành trong [best_practices](../README.md) (node chết, rolling restart, mất quorum, backup...) khi đang có "người dùng thật".

```
 MÁY LOCAL (trình duyệt của bạn)                      BASTION                               CỤM (3 node)
┌────────────────────────────┐        ┌─────────────────────────────────────────┐   ┌──────────────────────────┐
│ http://localhost:8080      │        │ writer_service.py ──INSERT──┐            │   │ node1 MaxScale :4006 ──┐ │
│   frontend_server.py       │──HTTP─►│                             ├─► chuỗi 3   ├──►│ node2 MaxScale :4006 ──┼─► MariaDB Galera
│   (trang web + proxy /api) │ :8081  │ reader_service.py ──SELECT──┘   MaxScale  │   │ node3 MaxScale :4006 ──┘ │
└────────────────────────────┘        │   (REST API JSON)                        │   └──────────────────────────┘
                                      └─────────────────────────────────────────┘
```

| File | Chạy ở đâu | Việc làm |
|---|---|---|
| [writer_service.py](writer_service.py) | bastion | Mỗi chu kỳ sinh một lô bản ghi phường/xã mới và `INSERT` vào bảng `wards_live` |
| [reader_service.py](reader_service.py) | bastion | REST API chỉ đọc (cổng 8081): tổng quan, bản ghi mới nhất, số ghi mỗi phút, phân bố theo tỉnh và theo node |
| [frontend/frontend_server.py](frontend/frontend_server.py) | **máy local** | Phục vụ trang web (cổng 8080) và chuyển tiếp `/api/*` tới reader trên bastion |
| [common.py](common.py) | (dùng chung) | Nạp cấu hình, kết nối theo chuỗi node, failover, thử lại |
| [services.sh](services.sh) | bastion | Bật/tắt writer và reader chạy nền |

## 1. Dữ liệu

Dữ liệu mẫu trong [sample_data/mysql](../../sample_data/mysql/README.md) là bảng tham chiếu (34 tỉnh, 3.321 phường/xã, khóa chính là `code`). Writer **không ghi vào các bảng đó** (mã phường/xã là duy nhất, ghi thêm sẽ trùng khóa và làm bẩn dữ liệu tham chiếu). Thay vào đó writer tạo bảng riêng **`wards_live`** có **cùng các cột và kiểu dữ liệu với `wards`**, cộng thêm `id`, `created_at` và `writer_node`:

| Cột | Ý nghĩa | Ví dụ |
|---|---|---|
| `id` | Khóa tự tăng | 1042 |
| `code` | Mã duy nhất, 20 ký tự | `L1793421756288001047` |
| `name`, `name_en`, `full_name`, `full_name_en`, `code_name` | Giống cách đặt tên trong `wards` | `Quang Châu`, `Quang Chau`, `Xã Quang Châu`, `Quang Chau Commune`, `quang_chau` |
| `postal_code` | 5 chữ số, bắt đầu bằng đầu số bưu chính của tỉnh | `10213` |
| `province_code` | Khóa ngoại tới `provinces.code` (chọn ngẫu nhiên tỉnh có thật trong DB) | `28` |
| `administrative_unit_id` | Khóa ngoại tới `administrative_units` (Phường 60%, Xã 38%, Đặc khu 2%) | `4` |
| `created_at` | Thời điểm ghi, độ chính xác mili giây | `2026-10-31 11:43:21.485` |
| `writer_node` | `@@hostname` của node MariaDB **nhận lệnh ghi** (thường là Master theo MaxScale) | `mariadb-node1` |

Cột `writer_node` cho bạn thấy **node nào đang nhận ghi** và nó đổi khi bạn làm failover.

## 2. Điều kiện cần

1. **Đã import dữ liệu mẫu** vào database `vn_provinces` (xem [hướng dẫn import](../../sample_data/mysql/README.md)): writer cần bảng `provinces` và `administrative_units` có dữ liệu.
2. **Bastion kết nối được cổng 4006** của 3 node (MaxScale đã cài và chạy, `mariadb_max_rw_port=4006`). Kiểm tra: `nc -zv <ip-node> 4006`.
3. **User có quyền và host khớp IP bastion.** Mặc định dùng `tdht` (toàn quyền, gồm `CREATE TABLE`). `users.sql` tạo `tdht` cho `127.0.0.1`, `localhost`, `10.%`, `192.168.%`, `172.%`. IP bastion không thuộc các dải này thì phải tự `CREATE USER` (xem [kịch bản 11](../11-doi-mat-khau/README.md) về cách tài khoản `user@host` hoạt động). Với MaxScale, MariaDB thấy **IP client thật** nhờ `proxy_protocol`, nên host phải khớp IP **bastion**, không phải IP MaxScale.
4. **Python 3.9 trở lên** và gói `PyMySQL` trên bastion. Máy local chỉ cần Python 3 (frontend không dùng gói ngoài).

## 3. Cài đặt trên bastion

```bash
cd ~/learn_mariadb && git pull
cd best_practices/services

python3 -m venv .venv                       # cần gói python3-venv trên Ubuntu: sudo apt install python3-venv
. .venv/bin/activate
pip install -r requirements.txt             # cài PyMySQL

cp .env.example .env
nano .env                                   # sửa DB_HOSTS, DB_PASSWORD cho đúng cụm của bạn
```

Cách khác không dùng venv: `sudo apt install python3-pymysql`. Bastion **không có internet**: trên máy khác chạy `pip download PyMySQL -d wheels`, copy thư mục `wheels` sang bastion rồi `pip install --no-index --find-links wheels PyMySQL`.

### Cấu hình (file `.env` hoặc biến môi trường)

| Biến | Ý nghĩa | Mặc định |
|---|---|---|
| `DB_HOSTS` | **Chuỗi 3 node**: địa chỉ MaxScale của từng node, cách nhau bằng dấu phẩy, thử từ trái sang phải | (bắt buộc) |
| `DB_PORT` | Cổng MaxScale `readwritesplit`. Có thể ghi riêng từng host dạng `ip:cổng` | `4006` |
| `DB_USER`, `DB_PASSWORD` | Tài khoản kết nối | `tdht`, (bắt buộc) |
| `DB_NAME` | Database | `vn_provinces` |
| `DB_CONNECT_TIMEOUT` | Giây chờ nối mỗi node | `3` |
| `DB_READ_TIMEOUT` | Giây chờ một truy vấn | `20` |
| `DB_MAX_ATTEMPTS` | Số lần thử lại khi gặp lỗi tạm thời | `5` |
| `DB_POOL_SIZE` | Số kết nối tối đa của mỗi service | `4` |
| `LOG_LEVEL` | `DEBUG`, `INFO`, `WARNING` | `INFO` |

Biến môi trường thật (`export DB_PASSWORD=...`) luôn ưu tiên hơn file `.env`. File `.env` đã được thêm vào `.gitignore`, **không commit** mật khẩu thật.

## 4. Chạy trên bastion

### Chạy trực tiếp (thấy log ngay, dừng bằng Ctrl+C)

```bash
cd ~/learn_mariadb/best_practices/services && . .venv/bin/activate

python3 writer_service.py                         # 5 bản ghi mỗi giây
python3 writer_service.py --batch 20 --interval 0.5    # tải nặng hơn: 40 bản ghi/giây
python3 writer_service.py --duration 300          # tự dừng sau 5 phút
python3 writer_service.py --max-rows 100000       # dừng sau khi ghi đủ số bản ghi

python3 reader_service.py                         # lắng nghe 0.0.0.0:8081
python3 reader_service.py --port 9000 --cache-ttl 2
```

Log của writer cứ 10 giây một dòng, ví dụ:

```
tổng=1250 (+50, 5.0 dòng/s) lỗi=0 độ trễ lô: tb=14ms max=31ms qua 172.24.220.161:4006
```

### Chạy nền bằng `services.sh`

```bash
./services.sh start                     # bật writer và reader
./services.sh status
./services.sh logs writer               # theo dõi log, Ctrl+C để thoát
./services.sh stop                      # tắt cả hai
WRITER_ARGS="--batch 20 --interval 0.5" ./services.sh start writer
```

PID lưu ở `run/`, log ở `logs/` (cả hai đã `.gitignore`).

**Kiểm tra reader chạy được:**

```bash
curl -s http://127.0.0.1:8081/api/health
curl -s http://127.0.0.1:8081/api/summary
```

Reader lắng nghe `0.0.0.0` để máy local gọi được. API **không có xác thực**, chỉ đọc, nên chỉ mở cổng 8081 cho máy của bạn bằng firewall hoặc dùng SSH tunnel (mục 5).

## 5. Chạy Frontend trên máy local

Máy local chỉ cần Python 3 (không cài gói nào). Lấy repo về máy local rồi:

```bash
cd best_practices/services/frontend
python3 frontend_server.py --reader http://<ip-bastion>:8081
# hoặc:  READER_URL=http://<ip-bastion>:8081 python3 frontend_server.py
```

Mở trình duyệt tại **http://localhost:8080**. Trang tự làm mới mỗi 3 giây và hiển thị:

- Thẻ số liệu: số tỉnh, phường/xã (dữ liệu mẫu), số bản ghi live, tốc độ ghi trong 1 phút qua, lần ghi cuối, **node vừa trả lời đọc**.
- Biểu đồ số bản ghi ghi vào mỗi phút (15 phút đến 3 giờ). Cột cuối (màu nhạt) là phút hiện tại chưa đủ.
- Thanh ngang **node đã nhận ghi** (`writer_node`) và **top tỉnh** theo số bản ghi live.
- Bảng bản ghi mới nhất, hàng mới nhấp nháy khi vừa xuất hiện, lọc được theo tỉnh.
- Ô tra cứu phường/xã trong dữ liệu mẫu (gõ tên, lọc theo tỉnh, "Tải thêm").

Vì sao frontend có bước chuyển tiếp (`/api` được proxy tới reader): trình duyệt chỉ gọi cùng địa chỉ với trang (`localhost:8080`), nên không vướng CORS và không phải nhúng địa chỉ bastion trong JavaScript. Frontend mặc định chỉ lắng nghe `127.0.0.1`; muốn người khác trong mạng xem thì thêm `--host 0.0.0.0`.

**Nếu máy local không mở được cổng 8081 trực tiếp** nhưng SSH được vào bastion, dùng tunnel:

```bash
ssh -N -L 8081:127.0.0.1:8081 ubuntu@<ip-bastion>          # giữ cửa sổ này mở
python3 frontend_server.py --reader http://127.0.0.1:8081   # ở cửa sổ khác
```

## 6. REST API của reader

Tất cả là `GET`, trả JSON. Tham số `limit` được giới hạn tối đa ở phía server.

| Endpoint | Tham số | Trả về |
|---|---|---|
| `/api/health` | | Trạng thái, node trả lời (`served_by`), thời gian DB, địa chỉ MaxScale đang dùng |
| `/api/summary` | | Số tỉnh, phường/xã, số bản ghi live, số ghi trong 1 phút, lần ghi cuối |
| `/api/provinces` | | Danh sách tỉnh kèm số phường/xã |
| `/api/wards` | `q`, `province`, `limit` (≤100), `offset` | Tra cứu bảng `wards` (dữ liệu mẫu), có `has_more` |
| `/api/live/latest` | `province`, `since_id`, `limit` (≤200) | Bản ghi mới nhất trong `wards_live` |
| `/api/live/per-minute` | `minutes` (1-360) | Số bản ghi mỗi phút, đã điền 0 cho phút không có dữ liệu |
| `/api/live/by-province` | `limit` (≤50) | Số bản ghi live theo tỉnh |
| `/api/live/by-node` | | Số bản ghi theo node đã nhận ghi |

Reader chỉ chạy truy vấn đọc, mọi tham số đi qua placeholder `%s` (không ghép chuỗi vào SQL), và cache 1 giây cho truy vấn tổng hợp (`COUNT(*)`, `GROUP BY`) để nhiều tab trình duyệt không nhân tải lên DB. `COUNT(*)` trên bảng hàng triệu dòng sẽ chậm dần, hãy `DROP TABLE` hoặc xóa bớt khi chạy lâu (mục 9).

## 7. Cách kết nối theo chuỗi 3 node và failover

Mỗi node có một MaxScale (cổng 4006). `DB_HOSTS` là danh sách 3 MaxScale đó, tương đương chuỗi kết nối kiểu JDBC `jdbc:mariadb:sequential://n1:4006,n2:4006,n3:4006/vn_provinces`:

1. Khi cần kết nối mới, client thử node **gần nhất đã thành công** trước, nếu lỗi thì thử lần lượt node kế tiếp theo vòng. Khi chuyển sang node khác sẽ có log `Failover: chuyển sang ...`.
2. Thao tác lỗi **tạm thời** được thử lại tối đa `DB_MAX_ATTEMPTS` lần với thời gian chờ tăng dần (0.5s, 1s, 1.5s...): mất kết nối (2003, 2006, 2013), node Galera chưa sẵn sàng (1047), đang tắt (1053), lock wait timeout (1205), **deadlock hoặc xung đột certification (1213)**, kết nối bị kill (1927).
3. Lỗi **cấu hình** (sai mật khẩu 1045, thiếu quyền 1044, chưa có database 1049) dừng ngay kèm gợi ý, không thử lại vô ích.
4. **Lô ghi của writer là idempotent:** mỗi bản ghi có `code` duy nhất và dùng `INSERT IGNORE`. Nếu `COMMIT` thành công nhưng mất kết nối trước khi nhận phản hồi, lần thử lại không tạo bản ghi trùng. Một lô vẫn lỗi sau mọi lần thử sẽ bị ghi nhận (`lỗi=`) rồi writer đi tiếp lô sau.
5. Phía **reader**, lỗi đọc cũng được thử lại; nếu cả 3 node không phản hồi thì API trả HTTP 503 và trang web hiện thông báo lỗi nhưng **giữ nguyên dữ liệu cũ** trên màn hình rồi tự thử lại ở lần làm mới sau.

Điều này khớp với bài học trong [kịch bản 3](../03-node-crash-rejoin/README.md): ứng dụng cần **kết nối lại và thử lại**, vì kết nối tới node chết luôn bị đứt.

## 8. Dùng cùng các kịch bản vận hành

Bật writer và reader, mở frontend, rồi làm từng kịch bản và quan sát:

| Kịch bản | Làm gì | Quan sát |
|---|---|---|
| [3. Node crash](../03-node-crash-rejoin/README.md) | `./simulate_crash.sh <node>` | Log writer có cảnh báo và (nếu node chết là Master) `writer_node` đổi; số ghi mỗi phút chỉ tụt thoáng qua |
| [5. Rolling restart](../05-rolling-restart-nang-cap/README.md) | `./rolling_restart.sh` | `lỗi=` của writer phải gần 0, biểu đồ gần như phẳng |
| [8. Mất quorum](../08-mat-quorum-split-brain/README.md) | `./simulate_partition.sh isolate <node>` | Đa số vẫn ghi; bật `isolate` trên 2 node thì writer báo lỗi liên tục |
| [7. Backup](../07-backup-pitr/README.md) | `./backup_full.sh` | Độ trễ lô trong log writer tăng nhẹ khi backup |
| [6. DDL](../06-ddl-lon/README.md) | `ALTER TABLE wards_live ...` (TOI) | Ghi bị chặn trong lúc DDL chạy: tốt để thấy TOI ảnh hưởng thế nào |

Muốn thấy tác động rõ, tăng tải: `--batch 50 --interval 0.2`.

## 9. Dọn dẹp

```bash
./services.sh stop
mariadb -u root -p -S /u01/data/database/mariadb.sock -e "DROP TABLE IF EXISTS vn_provinces.wards_live;"
```

Bảng `wards_live` không thuộc dữ liệu mẫu nên xóa an toàn. Lần chạy writer sau sẽ tạo lại.

## 10. Xử lý sự cố

| Triệu chứng | Nguyên nhân khả dĩ |
|---|---|
| `Lỗi 1045 ... Access denied` | Sai mật khẩu, hoặc `tdht` chưa có host khớp IP bastion (xem mục 2.3) |
| `Lỗi 1049 ... database chưa tồn tại` | Chưa import dữ liệu mẫu |
| `Bảng provinces trống` | Đã tạo database nhưng chưa nạp `mysql_ImportData_vn_units.sql` |
| `Không kết nối được tới node nào` | Sai `DB_HOSTS`, MaxScale chưa chạy, hoặc firewall chặn cổng 4006 từ bastion |
| Writer báo `Lỗi 1047` hoặc `1213` nhiều | Node đang non-Primary (kịch bản 8) hoặc xung đột ghi: bình thường khi đang thử kịch bản, writer tự thử lại |
| Frontend: `Frontend không kết nối được reader` | Sai `--reader`, reader chưa chạy, hoặc firewall chặn 8081 (dùng SSH tunnel, mục 5) |
| Frontend: banner `Lỗi truy vấn ... wards_live` | Writer chưa chạy lần nào nên bảng chưa có |
| Trang hiện "Chưa có bản ghi" | Writer chưa chạy hoặc đã dừng |
| `ModuleNotFoundError: No module named 'pymysql'` | Chưa kích hoạt venv (`. .venv/bin/activate`) hoặc chưa `pip install -r requirements.txt` |

## 11. Đã kiểm thử gì, chưa kiểm thử gì

Đã kiểm thử trên máy phát triển (không có MariaDB/MaxScale thật):
- Toàn bộ luồng Python (writer, reader, frontend, proxy) với một DB **giả lập trong bộ nhớ**: failover khi node đầu chết, thử lại khi `COMMIT` mất kết nối (không sinh bản ghi trùng), HTTP 400/404/503/502, chống path traversal.
- Cú pháp mọi câu SQL qua trình phân tích MySQL (`sqlglot`, 43 câu đều hợp lệ).
- Giao diện render đúng trong Chrome headless với dữ liệu giả, JavaScript không lỗi cú pháp.

**Chưa** kiểm thử trên cụm MariaDB 12.3 và MaxScale 25.10 thật. Những điểm cần xác nhận lần chạy đầu: bảng `wards_live` tạo được (khóa ngoại cần cùng charset/collation với `provinces`, nên DDL không ghi sẵn charset để thừa hưởng mặc định của database), hành vi định tuyến của `readwritesplit` với các `SELECT`, và `@@hostname` trả về đúng node. Nếu gặp lỗi, gửi log và nội dung `/api/health`.
