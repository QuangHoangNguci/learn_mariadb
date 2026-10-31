#!/bin/bash
# pitr_restore.sh: khôi phục về một thời điểm (point-in-time recovery) vào MỘT INSTANCE TẠM trên node,
# không đụng tới cụm đang chạy. Sau đó xuất dữ liệu cần lấy lại và (tùy chọn) nạp vào cụm.
#
# Điều kiện: đã có backup từ ./backup_full.sh (đã prepare) và các file binlog còn trên node (giữ 3 ngày).
#
# Chạy trên bastion:
#   BACKUP_DIR=/backup/full_2026-10-31_100000 STOP_DATETIME="2026-10-31 10:30:00" ./pitr_restore.sh restore
#   RESTORE_HOST=... ./pitr_restore.sh dump <database> [<table>]   xuất dữ liệu từ instance tạm ra file
#   RESTORE_HOST=... ./pitr_restore.sh apply <database> <file.sql> nạp file đó vào CỤM (qua node RESTORE_HOST)
#   RESTORE_HOST=... ./pitr_restore.sh cleanup                     tắt và xóa instance tạm
# Biến:  RESTORE_HOST   node có backup và binlog (mặc định: node cuối trong inventory, trùng với backup_full.sh)
#        BACKUP_DIR     thư mục backup trên node (bắt buộc với `restore`)
#        STOP_DATETIME  thời điểm dừng áp binlog, giờ của server, dạng "YYYY-MM-DD HH:MM:SS" (bắt buộc với `restore`)
#        RESTORE_DIR    thư mục instance tạm (mặc định /u01/restore)
#        DRY_RUN=1, YES=1
set -uo pipefail

# ===================== PHẦN CHẠY TRÊN NODE =====================
cnf_value() {
  awk -F= -v k="$1" '$1 ~ "^"k"[ \t]*$" { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' /etc/my.cnf 2>/dev/null
}
node_init() {
  MBIN=/usr/local/mariadb/bin
  SOCK="$(cnf_value socket)"; SOCK="${SOCK:-/u01/data/database/mariadb.sock}"
}

node_restore() {
  ROOT_PW=$1; BK=$2; STOP=$3; RD=$4
  node_init
  local binlog_base bindir prefix files start_file start_pos i
  [ -d "$BK" ] || { echo "Không thấy thư mục backup $BK"; exit 1; }
  [ -f "$BK/xtrabackup_binlog_info" ] || { echo "Thiếu $BK/xtrabackup_binlog_info (backup chưa chạy --prepare hoặc không phải backup mariabackup)"; exit 1; }
  [ ! -e "$RD" ] || { echo "$RD đã tồn tại. Chạy ./pitr_restore.sh cleanup trước"; exit 1; }

  install -d -o mariadb -g mariadb -m 0750 "$RD" "$RD/data"
  echo "mariabackup --copy-back -> $RD/data"
  "$MBIN/mariabackup" --copy-back --target-dir="$BK" --datadir="$RD/data" || { echo "copy-back thất bại"; exit 1; }
  chown -R mariadb:mariadb "$RD"

  cat > "$RD/my.cnf" <<EOF
[mysqld]
basedir=/usr/local/mariadb
datadir=$RD/data
socket=$RD/mariadb.sock
log-error=$RD/error.log
skip-networking
wsrep_on=OFF
performance_schema=OFF
innodb_buffer_pool_size=256M
EOF
  chown mariadb:mariadb "$RD/my.cnf"

  echo "Chạy instance tạm (không mở mạng, không Galera)"
  runuser -u mariadb -- "$MBIN/mariadbd" --defaults-file="$RD/my.cnf" >/dev/null 2>&1 &
  for i in $(seq 1 60); do
    MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb" -u root -S "$RD/mariadb.sock" -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 2
    [ "$i" -eq 60 ] && { echo "Instance tạm không lên. Xem $RD/error.log"; tail -20 "$RD/error.log"; exit 1; }
  done

  read -r start_file start_pos _ < "$BK/xtrabackup_binlog_info"
  binlog_base="$(cnf_value log-bin)"
  [ -n "$binlog_base" ] || { echo "Không tìm thấy log-bin trong /etc/my.cnf"; exit 1; }
  bindir="$(dirname "$binlog_base")"; prefix="$(basename "$binlog_base")"
  files=$(ls "$bindir/$prefix".[0-9]* 2>/dev/null | sort | awk -v s="$start_file" 'f || index($0, s) { f = 1; print }')
  [ -n "$files" ] || { echo "Không thấy binlog từ file $start_file trở đi trong $bindir (binlog có thể đã bị xóa do expire_logs_days)"; exit 1; }

  echo "Áp binlog từ $start_file vị trí $start_pos đến $STOP"
  echo "Các file: $(echo $files | tr '\n' ' ')"
  # --start-position chỉ áp dụng cho file đầu tiên trong danh sách
  "$MBIN/mariadb-binlog" --start-position="$start_pos" --stop-datetime="$STOP" $files \
    | MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb" -u root -S "$RD/mariadb.sock"
  if [ "${PIPESTATUS[0]}" -ne 0 ] || [ "${PIPESTATUS[1]}" -ne 0 ]; then
    echo "Áp binlog gặp lỗi (kiểm tra output phía trên)"; exit 1
  fi
  echo "OK: instance tạm đã ở trạng thái đến $STOP. Socket: $RD/mariadb.sock"
  MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb" -u root -S "$RD/mariadb.sock" -Nse "SHOW DATABASES"
}

node_dump() {
  ROOT_PW=$1; RD=$2; DB=$3; TABLE=${4:-}
  node_init
  local out="$RD/dump_${DB}${TABLE:+_$TABLE}.sql"
  [ -S "$RD/mariadb.sock" ] || { echo "Instance tạm chưa chạy ($RD/mariadb.sock)"; exit 1; }
  MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb-dump" -u root -S "$RD/mariadb.sock" --single-transaction "$DB" ${TABLE:+"$TABLE"} > "$out" \
    || { echo "mariadb-dump thất bại"; exit 1; }
  echo "DUMP_FILE=$out ($(du -h "$out" | awk '{print $1}'))"
}

node_apply() {
  ROOT_PW=$1; DB=$2; FILE=$3
  node_init
  [ -f "$FILE" ] || { echo "Không thấy file $FILE"; exit 1; }
  MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb" -u root -S "$SOCK" "$DB" < "$FILE" || { echo "Nạp vào cụm thất bại"; exit 1; }
  echo "OK: đã nạp $FILE vào database $DB của cụm (qua $(hostname))"
}

node_cleanup() {
  ROOT_PW=$1; RD=$2
  node_init
  case "$RD" in
    /u01/restore*|/restore*|/tmp/restore*) ;;
    *) echo "Từ chối xóa đường dẫn không an toàn: $RD"; exit 1 ;;
  esac
  if [ -S "$RD/mariadb.sock" ]; then
    MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb-admin" -u root -S "$RD/mariadb.sock" shutdown 2>/dev/null
    sleep 5
  fi
  rm -rf "$RD"
  echo "Đã xóa $RD"
}

if [ "${1:-}" = "--node" ]; then
  mode=$2; shift 2
  case "$mode" in
    restore) node_restore "$@" ;;
    dump)    node_dump "$@" ;;
    apply)   node_apply "$@" ;;
    cleanup) node_cleanup "$@" ;;
    *) echo "mode không hợp lệ: $mode"; exit 2 ;;
  esac
  exit $?
fi

# ===================== PHẦN CHẠY TRÊN BASTION =====================
source "$(dirname "$0")/../lib.sh"
SELF="$(self_path "$0")"
require_root_password

ACTION="${1:-}"
RESTORE_HOST="${RESTORE_HOST:-$(list_hosts | tail -1)}"
RESTORE_DIR="${RESTORE_DIR:-/u01/restore}"

case "$ACTION" in
  restore)
    [ -n "${BACKUP_DIR:-}" ]    || die "Thiếu BACKUP_DIR (thư mục backup trên $RESTORE_HOST, ví dụ /backup/full_2026-10-31_100000)"
    [ -n "${STOP_DATETIME:-}" ] || die "Thiếu STOP_DATETIME (ví dụ \"2026-10-31 10:30:00\", ngay TRƯỚC thời điểm xảy ra sự cố)"
    confirm "Dựng instance tạm tại $RESTORE_HOST:$RESTORE_DIR và áp binlog đến $STOP_DATETIME?"
    node_script "$RESTORE_HOST" "$SELF" --node restore "$ROOT_PASSWORD" "$BACKUP_DIR" "$STOP_DATETIME" "$RESTORE_DIR"
    ;;
  dump)
    DB="${2:-}"; TABLE="${3:-}"
    [ -n "$DB" ] || die "Dùng: $0 dump <database> [<table>]"
    node_script "$RESTORE_HOST" "$SELF" --node dump "$ROOT_PASSWORD" "$RESTORE_DIR" "$DB" "$TABLE"
    ;;
  apply)
    DB="${2:-}"; FILE="${3:-}"
    [ -n "$DB" ] && [ -n "$FILE" ] || die "Dùng: $0 apply <database> <file.sql trên node>"
    confirm "Nạp $FILE vào database $DB của CỤM đang chạy (có thể ghi đè bảng cùng tên)?"
    node_script "$RESTORE_HOST" "$SELF" --node apply "$ROOT_PASSWORD" "$DB" "$FILE"
    ;;
  cleanup)
    confirm "Tắt và xóa instance tạm $RESTORE_HOST:$RESTORE_DIR?"
    node_script "$RESTORE_HOST" "$SELF" --node cleanup "$ROOT_PASSWORD" "$RESTORE_DIR"
    ;;
  *)
    die "Dùng: $0 restore | dump <db> [<table>] | apply <db> <file> | cleanup   (xem hướng dẫn ở đầu file)"
    ;;
esac
