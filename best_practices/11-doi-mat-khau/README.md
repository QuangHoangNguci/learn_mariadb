# Kịch bản 11: Đổi mật khẩu user

**Script:** không có (mỗi mật khẩu nằm ở nơi khác nhau và đổi sai thứ tự có thể làm hỏng SST hoặc MaxScale, nên làm có kiểm soát từng bước) · **Tài liệu chung:** [best_practices](../README.md)

## 1. Mục tiêu và khi nào dùng

Xoay mật khẩu định kỳ, khi nhân sự nghỉ việc, hoặc khi nghi mật khẩu bị lộ, **mà không làm gián đoạn dịch vụ**. Khó ở chỗ mỗi mật khẩu thường nằm ở **hai nơi phải khớp nhau**: trong MariaDB và trong cấu hình của thành phần dùng nó. Đổi một nơi mà quên nơi kia thì thành phần đó mất kết nối.

## 2. Kiến thức nền

### 2.1 Tài khoản MariaDB là cặp `user@host`

Trong MariaDB, `'tdht'@'localhost'` và `'tdht'@'10.%'` là **hai tài khoản khác nhau**, mỗi cái có mật khẩu riêng. File `users.sql` của project tạo mỗi user cho **nhiều host** (`127.0.0.1`, `localhost`, `10.%`, `192.168.%`, `172.%`), nên đổi mật khẩu phải thực hiện cho **từng** `user@host`. Liệt kê để biết có bao nhiêu tài khoản cần đổi:

```sql
SELECT user, host FROM mysql.user ORDER BY user;
```

### 2.2 Đổi mật khẩu có tự nhân bản sang các node không

Có. Câu lệnh quản lý tài khoản (`ALTER USER`, `CREATE USER`, `GRANT`) được Galera nhân bản sang mọi node, nên chỉ cần chạy **một lần trên một node**. Không cần chạy lại ở các node khác (nhưng cần chạy trên node đó cho **mọi host** của user).

### 2.3 Mỗi mật khẩu nằm ở đâu

| User | Dùng ở đâu | Phải khớp với |
|---|---|---|
| `root`, `tdht` | Người vận hành, ứng dụng | Chuỗi kết nối ứng dụng; biến `MARIADB_ROOT_PASSWORD` khi chạy các script trong thư mục này |
| `galera` | **SST**: `wsrep_sst_auth` trong `/etc/my.cnf` | Mật khẩu của user `galera` trong DB. Khi một node làm donor, `mariabackup` đăng nhập bằng thông tin này |
| `maxscale` | `/etc/maxscale.cnf` (monitor `Galera-Monitor` và các dịch vụ) | Mật khẩu của user `maxscale` trong DB, trên **mỗi** node có MaxScale |
| `admin` (REST của MaxScale) | `maxctrl` | Lưu bên trong MaxScale, **không** liên quan MariaDB |

### 2.4 Thứ tự đổi quan trọng đến mức nào

Nếu đổi mật khẩu `galera` trong DB mà **chưa** cập nhật `wsrep_sst_auth` trên các node, lần SST kế tiếp (khi một node join hoặc rejoin) sẽ **thất bại** vì donor đăng nhập sai. Tương tự, đổi `maxscale` trong DB mà không cập nhật `maxscale.cnf` thì MaxScale báo `Auth Error` và coi cả cụm `Down`, ứng dụng mất kết nối. Nguyên tắc: **đổi nơi cấu hình dùng mật khẩu và đổi trong DB sát nhau**, và kiểm tra ngay sau đó.

### 2.5 `wsrep_sst_auth` đổi động được không

Thông thường biến này có thể đặt khi đang chạy bằng `SET GLOBAL wsrep_sst_auth='galera:<mật khẩu mới>'`, giúp không phải restart. Nếu `SET GLOBAL` báo biến là chỉ đọc ở phiên bản của bạn thì sửa `/etc/my.cnf` và chấp nhận hiệu lực sau lần restart kế tiếp (kết hợp [rolling restart](../05-rolling-restart-nang-cap/README.md)). Kiểm tra bằng `SELECT @@GLOBAL.wsrep_sst_auth;` (nên cẩn trọng vì lệnh hiển thị mật khẩu).

## 3. Cách 1: Script

Không có script. Mỗi mật khẩu có nơi cập nhật khác nhau và bạn cần xác nhận từng bước (đặc biệt `galera` và `maxscale`, đổi sai có thể gây `Auth Error` hoặc SST hỏng).

## 4. Cách 2: Các bước thủ công và lý do

### Bước 1. Đổi `root` và `tdht` (người vận hành, ứng dụng)

```sql
-- chạy một lần trên một node, tự nhân bản sang cả cụm
ALTER USER 'root'@'localhost' IDENTIFIED BY 'MatKhauMoi#1';
ALTER USER 'tdht'@'localhost' IDENTIFIED BY 'MatKhauMoi#1';
ALTER USER 'tdht'@'127.0.0.1' IDENTIFIED BY 'MatKhauMoi#1';
ALTER USER 'tdht'@'10.%' IDENTIFIED BY 'MatKhauMoi#1';
ALTER USER 'tdht'@'192.168.%' IDENTIFIED BY 'MatKhauMoi#1';
ALTER USER 'tdht'@'172.%' IDENTIFIED BY 'MatKhauMoi#1';
FLUSH PRIVILEGES;
```

**Tại sao:** `ALTER USER` cho từng `user@host` (mục 2.1). `FLUSH PRIVILEGES` nạp lại bảng quyền để chắc mọi thay đổi có hiệu lực ngay. Kết nối đang mở **không bị ảnh hưởng**, chỉ kết nối **mới** dùng mật khẩu mới, nên cập nhật ứng dụng ngay sau đó. Với `root`: đừng quên cập nhật biến `MARIADB_ROOT_PASSWORD` và mật khẩu bạn gõ khi dùng `-p`.

### Bước 2. Đổi `galera` (SST)

Làm theo thứ tự này để không có khoảng thời gian donor dùng mật khẩu sai:

```sql
-- (1) Trên một node: đổi trong DB (nhân bản sang cả cụm)
ALTER USER 'galera'@'localhost' IDENTIFIED BY 'MatKhauMoiGalera#1';
FLUSH PRIVILEGES;
```

```sql
-- (2) Trên TỪNG node: cập nhật ngay giá trị cấu hình đang chạy
SET GLOBAL wsrep_sst_auth = 'galera:MatKhauMoiGalera#1';
```

```bash
# (3) Trên TỪNG node: ghi vào file để bền qua restart
sed -i 's|^wsrep_sst_auth *=.*|wsrep_sst_auth            = galera:MatKhauMoiGalera#1|' /etc/my.cnf
grep wsrep_sst_auth /etc/my.cnf
```

**Tại sao:** (1) đổi trong DB; (2) cập nhật cấu hình **đang chạy** để SST ngay lúc này dùng mật khẩu mới (mục 2.5, nếu báo chỉ đọc thì dựa vào bước 3 và restart sau); (3) ghi vào `my.cnf` để sau restart cấu hình khớp DB. Trong lúc làm, **tránh** để node nào join hoặc rejoin (không SST). Cập nhật biến `mariadb_galera_pass` trong group_vars (hoặc ansible-vault) để lần cài lại không dùng mật khẩu cũ.

### Bước 3. Đổi `maxscale` (monitor và dịch vụ)

```sql
-- (1) Trên một node MariaDB: đổi trong DB cho mọi host của user maxscale
ALTER USER 'maxscale'@'localhost' IDENTIFIED BY 'MatKhauMoiMaxscale#1';
ALTER USER 'maxscale'@'127.0.0.1' IDENTIFIED BY 'MatKhauMoiMaxscale#1';
ALTER USER 'maxscale'@'10.%' IDENTIFIED BY 'MatKhauMoiMaxscale#1';
ALTER USER 'maxscale'@'192.168.%' IDENTIFIED BY 'MatKhauMoiMaxscale#1';
ALTER USER 'maxscale'@'172.%' IDENTIFIED BY 'MatKhauMoiMaxscale#1';
FLUSH PRIVILEGES;
```

```bash
# (2) Trên TỪNG node có MaxScale: cập nhật monitor và hai dịch vụ rồi kiểm tra
maxctrl -u admin -p mariadb alter monitor Galera-Monitor password=MatKhauMoiMaxscale#1
maxctrl -u admin -p mariadb alter service Read-Write-Service password=MatKhauMoiMaxscale#1
maxctrl -u admin -p mariadb alter service Read-Only-Service password=MatKhauMoiMaxscale#1
maxctrl -u admin -p mariadb list servers
```

**Tại sao:** MaxScale dùng user `maxscale` ở **ba chỗ** (monitor để theo dõi Galera, và hai dịch vụ để lấy danh sách user và xác thực client), nên phải đổi cả ba. `alter` áp dụng ngay không cần restart (cú pháp theo hiểu biết chung về `maxctrl`, kiểm tra bằng `maxctrl alter monitor --help`; nếu không được, sửa `/etc/maxscale.cnf` rồi `systemctl restart maxscale`). `list servers` phải vẫn `Synced, Running`, nếu thấy `Auth Error` nghĩa là còn nơi chưa khớp. Làm tuần tự từng node MaxScale để cụm luôn có ít nhất một đường vào hoạt động. Nhớ cập nhật `mariadb_maxscale_pass` trong group_vars.

### Bước 4. Đổi mật khẩu REST `admin` của MaxScale

```bash
maxctrl -u admin -p mariadb alter user admin 'MatKhauRestMoi#1'
maxctrl -u admin -p 'MatKhauRestMoi#1' list servers
```

**Tại sao:** user này sống **bên trong MaxScale**, không liên quan MariaDB, và mỗi node có một MaxScale riêng nên phải đổi **trên từng node**. Kiểm tra bằng lệnh thứ hai với mật khẩu mới. Sau đó đặt biến `MAXCTRL_PASSWORD` khi chạy các script trong thư mục này để chúng dùng mật khẩu mới.

### Bước 5. Cập nhật nơi lưu cấu hình

Cập nhật `group_vars/mariadb.yml` (hoặc dùng `ansible-vault encrypt_string`) với các giá trị mới của `mariadb_admin_pass`, `mariadb_common_pass`, `mariadb_galera_pass`, `mariadb_maxscale_pass`.

**Tại sao:** nếu không, lần cài lại hoặc thêm node tiếp theo sẽ tạo user với mật khẩu **cũ** và lệch với cụm đang chạy. Đừng để mật khẩu thật trong file plaintext trên repo công khai.

## 5. Kiểm tra kết quả

```bash
# Đăng nhập thử bằng mật khẩu mới
mariadb -u tdht -p -h 127.0.0.1 -e "SELECT 1;"
# Cụm và MaxScale vẫn khỏe
../01-healthcheck/healthcheck.sh
```

Khi chạy healthcheck sau khi đổi mật khẩu `root` hoặc REST `admin`, nhớ đặt `MARIADB_ROOT_PASSWORD` và `MAXCTRL_PASSWORD` theo giá trị mới. Thử một lần SST có kiểm soát (ví dụ rejoin một node trên lab) để chắc `wsrep_sst_auth` khớp.

## 6. Lỗi thường gặp

| Triệu chứng | Nguyên nhân khả dĩ |
|---|---|
| `Auth Error` ở MaxScale sau khi đổi | Còn một trong ba nơi (monitor, hai dịch vụ) chưa cập nhật, hoặc chưa cập nhật mọi node MaxScale |
| SST thất bại sau khi đổi `galera` | `wsrep_sst_auth` trên donor chưa khớp mật khẩu mới trong DB |
| Ứng dụng báo `Access denied` | Ứng dụng chưa dùng mật khẩu mới, hoặc đổi mật khẩu thiếu một `user@host` |
| `SET GLOBAL wsrep_sst_auth` báo chỉ đọc | Biến không đổi động ở phiên bản này; sửa `my.cnf` và áp dụng khi restart |

## 7. Điểm cốt lõi cần nhớ

- Tài khoản là **`user@host`**: đổi cho **từng host** của user.
- Câu lệnh quản lý tài khoản **tự nhân bản** qua Galera: chạy một lần trên một node.
- Mật khẩu nằm ở **hai nơi phải khớp** (DB và cấu hình); đổi sát nhau và kiểm tra ngay.
- `galera` (SST) và `maxscale` là hai mật khẩu **dễ làm hỏng cụm** nếu đổi lệch.
- Cập nhật cả **group_vars** để lần cài sau không quay về mật khẩu cũ.
