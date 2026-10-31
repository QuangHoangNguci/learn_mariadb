# Bộ dữ liệu MySQL/MariaDB: Cơ sở dữ liệu đơn vị hành chính Việt Nam

**Thời điểm tạo: Sun, 20 Sep 2026 13:13:17 +0000**

Script nạp cơ sở dữ liệu tỉnh/thành và phường/xã Việt Nam vào MySQL/MariaDB.

## Các file

- `mysql_CreateTables_vn_units.sql`: tạo các bảng.
- `mysql_ImportData_vn_units.sql`: các câu `INSERT` cho vùng, loại đơn vị, tỉnh và phường/xã (343.04 KB).
- `gis/mysql_CreateGISTables.sql`: tạo hai bảng GIS (`gis_provinces`, `gis_wards`).
- `gis/mysql_ImportData_gis-part-01.sql` … `part-04.sql`: dữ liệu ranh giới (hình học) chia thành 4 phần, tổng khoảng 150MB.
- `gis/mysql_ImportData_gis.sql.manifest`: danh sách các phần GIS theo đúng thứ tự cần nạp.

## Tổng quan

Script nạp dữ liệu vào các bảng sau:

| Bảng | Số dòng | Mô tả |
|-------|------|-------------|
| `administrative_regions` | 8 | Các vùng của Việt Nam |
| `administrative_units` | 8 | Các loại đơn vị hành chính (thành phố, tỉnh, phường, ...) |
| `provinces` | 34 | Tỉnh và thành phố trực thuộc trung ương |
| `wards` | 3.321 | Phường, xã và đặc khu |
| `vn_provinces_metadata` | 1 | Phiên bản bộ dữ liệu, nghị quyết mới nhất và thời điểm tạo |

Dữ liệu GIS (thư mục `gis/`) nạp vào hai bảng `gis_provinces` và `gis_wards`.

## Cấu trúc dữ liệu

### administrative_regions

| Cột | Mô tả |
|--------|-------------|
| `id` | Mã vùng (1-8) |
| `name` | Tên vùng (tiếng Việt) |
| `name_en` | Tên vùng (tiếng Anh) |
| `code_name` | Tên mã, dùng được trong URL |
| `code_name_en` | Tên mã tiếng Anh |

### administrative_units

| Cột | Mô tả |
|--------|-------------|
| `id` | Mã loại đơn vị (1-8) |
| `full_name` / `short_name` | Tên loại đơn vị, đầy đủ và viết tắt (tiếng Việt) |
| `full_name_en` / `short_name_en` | Tên loại đơn vị, đầy đủ và viết tắt (tiếng Anh) |
| `code_name` / `code_name_en` | Tên mã |

### provinces

| Cột | Mô tả |
|--------|-------------|
| `code` | Mã tỉnh (khóa chính, ví dụ `01`) |
| `name` / `name_en` | Tên tỉnh |
| `full_name` / `full_name_en` | Tên đầy đủ kèm loại đơn vị |
| `code_name` | Tên mã (ví dụ `ha_noi`) |
| `administrative_unit_id` | Khóa ngoại tới `administrative_units.id` |
| `postal_code_prefix` | Các đầu số mã bưu chính 2 chữ số, ngăn cách bằng dấu phẩy |

### wards

| Cột | Mô tả |
|--------|-------------|
| `code` | Mã phường/xã (khóa chính, ví dụ `00004`) |
| `name` / `name_en` | Tên phường/xã |
| `full_name` / `full_name_en` | Tên đầy đủ kèm loại đơn vị |
| `code_name` | Tên mã |
| `province_code` | Khóa ngoại tới `provinces.code` |
| `administrative_unit_id` | Khóa ngoại tới `administrative_units.id` |
| `postal_code` | Mã bưu chính quốc gia 5 chữ số |

### vn_provinces_metadata

Bảng một dòng mô tả phiên bản bộ dữ liệu:

| Cột | Mô tả |
|--------|-------------|
| `dataset_version` | Phiên bản bộ dữ liệu (ví dụ `v5.1.0`) |
| `latest_decree` | Nghị quyết mới nhất được phản ánh trong dữ liệu (ví dụ `30/2026/QH16`) |
| `generated_at` | Thời điểm tạo bộ dữ liệu (UTC) |

## Dòng dữ liệu mẫu

Một dòng của bảng tỉnh:

```sql
INSERT INTO provinces(code,name,name_en,full_name,full_name_en,code_name,administrative_unit_id,postal_code_prefix) VALUES('01','Hà Nội','Ha Noi','Thành phố Hà Nội','Ha Noi City','ha_noi',1,'10, 11, 12, 13, 14');
```

## Hướng dẫn import vào MariaDB

Chạy các lệnh dưới đây từ thư mục `sample_data/mysql/`, trên node có MariaDB (kết nối qua socket của instance). Thay `/u01/data/database/mariadb.sock` nếu bạn đổi `mariadb_data_dir`. Mỗi lệnh sẽ hỏi mật khẩu của `root` (`mariadb_admin_pass`).

Với cụm Galera, nên import trên **một node** (dữ liệu tự đồng bộ sang các node còn lại). Role đã đặt `max_allowed_packet = 512M` nên không cần chỉnh thêm cho các file này.

### 1. Tạo database

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock \
  -e "CREATE DATABASE IF NOT EXISTS vn_provinces CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
```

### 2. Tạo bảng và nạp dữ liệu tỉnh, phường/xã

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock vn_provinces \
  < mysql_CreateTables_vn_units.sql

mariadb -u root -p -S /u01/data/database/mariadb.sock vn_provinces \
  < mysql_ImportData_vn_units.sql
```

### 3. Nạp dữ liệu GIS (tùy chọn)

Cần bước 2 xong trước, vì các bảng GIS có khóa ngoại tới `provinces` và `wards`.

File tạo bảng GIS viết theo cú pháp MySQL 8 (`NOT NULL SRID 4326`), MariaDB không nhận thuộc tính cột `SRID`. Bỏ phần này đi trước khi chạy (chạy lại cũng không sao nếu file đã được sửa):

```bash
sed -i 's/ NOT NULL SRID 4326/ NOT NULL/g' gis/mysql_CreateGISTables.sql
```

Trên macOS, `sed -i` cần thêm đối số rỗng: `sed -i '' 's/ NOT NULL SRID 4326/ NOT NULL/g' gis/mysql_CreateGISTables.sql`.

Tạo bảng GIS:

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock vn_provinces \
  < gis/mysql_CreateGISTables.sql
```

Nạp 4 phần dữ liệu theo đúng thứ tự trong file `.manifest`. Vòng lặp dừng ngay khi một phần lỗi (`|| break`):

```bash
for f in gis/mysql_ImportData_gis-part-01.sql \
         gis/mysql_ImportData_gis-part-02.sql \
         gis/mysql_ImportData_gis-part-03.sql \
         gis/mysql_ImportData_gis-part-04.sql; do
  mariadb -u root -p -S /u01/data/database/mariadb.sock vn_provinces < "$f" || break
done
```

Mỗi lần `mariadb` chạy sẽ hỏi mật khẩu một lần, nên vòng lặp hỏi 4 lần. Muốn nhập một lần, đặt biến môi trường `export MYSQL_PWD='<mật khẩu>'` trước khi chạy và bỏ `-p` (chỉ nên dùng cho lab). Các phần GIS khá lớn (tổng khoảng 150MB), thời gian nạp có thể vài phút.

### 4. Kiểm tra sau khi import

```bash
mariadb -u root -p -S /u01/data/database/mariadb.sock vn_provinces -e "
SELECT (SELECT COUNT(*) FROM provinces) AS provinces,
       (SELECT COUNT(*) FROM wards) AS wards,
       (SELECT COUNT(*) FROM gis_provinces) AS gis_provinces,
       (SELECT COUNT(*) FROM gis_wards) AS gis_wards;"
```

Kết quả mong đợi: `provinces` = 34, `wards` = 3321. Hai cột GIS lớn hơn 0 nếu đã nạp bước 3 (nếu bỏ qua bước 3 thì câu lệnh báo lỗi do chưa có hai bảng GIS, bỏ hai cột đó đi khi kiểm tra).

## Truy vấn mẫu

```sql
-- Tổng số tỉnh và phường/xã
SELECT (SELECT COUNT(*) FROM provinces) AS provinces, (SELECT COUNT(*) FROM wards) AS wards;

-- Phiên bản bộ dữ liệu và nghị quyết mới nhất
SELECT dataset_version, latest_decree, generated_at FROM vn_provinces_metadata;

-- Các phường/xã của Hà Nội (mã 01), sắp theo tên
SELECT w.code, w.name FROM wards w WHERE w.province_code = '01' ORDER BY w.name;

-- Tỉnh theo đầu số mã bưu chính
SELECT p.name FROM provinces p WHERE p.postal_code_prefix LIKE '%11%';

-- GIS: tỉnh chứa một điểm toạ độ
SELECT p.code, p.name
FROM provinces p
JOIN gis_provinces g ON p.code = g.province_code
WHERE ST_Within(ST_GeomFromText('POINT(105.8542 21.0285)', 4326), g.geom);
```

## GIS / GeoJSON

Thư mục `gis/` chứa các script import GIS chia thành nhiều phần (`mysql_ImportData_gis-part-NN.sql`) cùng file `.manifest` liệt kê thứ tự các phần. Sau khi nạp dữ liệu cơ bản, nạp lần lượt từng phần theo thứ tự để điền hai bảng `gis_provinces` và `gis_wards` với cột `bbox` và `geom`.
