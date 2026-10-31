#!/bin/bash
# backup_full.sh: sao lưu vật lý đầy đủ bằng mariabackup trên MỘT node (kèm prepare).
#
# Chạy trên bastion:   ./backup_full.sh
# Biến tùy chọn:       BACKUP_HOST=mariadb-node3   node thực hiện backup (mặc định: node cuối trong inventory,
#                                                  nên chọn node không phải Master của MaxScale)
#                      BACKUP_ROOT=/backup         thư mục chứa backup TRÊN NODE (mặc định /backup)
#                      DRY_RUN=1
# Kết quả: thư mục <BACKUP_ROOT>/full_<ngày_giờ> đã `--prepare`, kèm file xtrabackup_binlog_info (dùng cho PITR).
# Lưu ý: backup nằm cùng node thì chưa an toàn, hãy sao chép sang máy khác (rsync/scp) sau khi xong.
set -uo pipefail

# ===================== PHẦN CHẠY TRÊN NODE =====================
cnf_value() {
  awk -F= -v k="$1" '$1 ~ "^"k"[ \t]*$" { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' /etc/my.cnf 2>/dev/null
}
node_init() {
  MBIN=/usr/local/mariadb/bin
  SOCK="$(cnf_value socket)";     SOCK="${SOCK:-/u01/data/database/mariadb.sock}"
  DATADIR="$(cnf_value datadir)"; DATADIR="${DATADIR:-/u01/data/database}"
}
sql() { MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb" -u root -S "$SOCK" -Nse "$1" 2>/dev/null; }

node_backup() {
  ROOT_PW=$1; BACKUP_ROOT=$2
  node_init
  local bk need avail
  bk="$BACKUP_ROOT/full_$(date +%F_%H%M%S)"
  mkdir -p "$BACKUP_ROOT" || exit 1

  need=$(du -sm "$DATADIR" | awk '{print $1}')
  avail=$(df -Pm "$BACKUP_ROOT" | awk 'NR==2 {print $4}')
  if [ "$avail" -lt "$need" ]; then
    echo "Không đủ chỗ: cần khoảng ${need}MB, còn ${avail}MB tại $BACKUP_ROOT"; exit 1
  fi

  mkdir -p "$bk"
  echo "Bật wsrep_desync để node này không kéo flow control của cả cụm"
  sql "SET GLOBAL wsrep_desync=ON" || { echo "Không đặt được wsrep_desync (sai mật khẩu root?)"; exit 1; }
  # Dù lỗi hay xong, luôn trả wsrep_desync về OFF
  trap 'sql "SET GLOBAL wsrep_desync=OFF"' EXIT

  echo "mariabackup --backup -> $bk"
  if ! MYSQL_PWD="$ROOT_PW" "$MBIN/mariabackup" --backup --user=root --socket="$SOCK" \
        --target-dir="$bk" --parallel=2; then
    echo "mariabackup --backup thất bại"; exit 1
  fi

  sql "SET GLOBAL wsrep_desync=OFF"
  trap - EXIT

  echo "mariabackup --prepare"
  "$MBIN/mariabackup" --prepare --target-dir="$bk" || { echo "mariabackup --prepare thất bại"; exit 1; }

  echo "BACKUP_DIR=$bk"
  echo "xtrabackup_binlog_info: $(cat "$bk/xtrabackup_binlog_info" 2>/dev/null)"
  echo "Dung lượng: $(du -sh "$bk" | awk '{print $1}')"
  echo "wsrep_desync hiện tại: $(sql "SHOW GLOBAL VARIABLES LIKE 'wsrep_desync'" | awk '{print $2}')"
}

if [ "${1:-}" = "--node" ]; then
  shift
  node_backup "$@"
  exit $?
fi

# ===================== PHẦN CHẠY TRÊN BASTION =====================
source "$(dirname "$0")/../lib.sh"
SELF="$(self_path "$0")"
require_root_password

BACKUP_HOST="${BACKUP_HOST:-$(list_hosts | tail -1)}"
BACKUP_ROOT="${BACKUP_ROOT:-/backup}"

log "Backup đầy đủ trên $BACKUP_HOST, lưu vào $BACKUP_ROOT"
node_script "$BACKUP_HOST" "$SELF" --node "$ROOT_PASSWORD" "$BACKUP_ROOT"
rc=$?
if [ $rc -eq 0 ]; then
  log "Xong. Ghi lại dòng BACKUP_DIR ở trên để dùng cho pitr_restore.sh. Nhớ sao chép backup sang máy khác."
else
  warn "Backup thất bại (kiểm tra output ở trên). Đảm bảo wsrep_desync đã về OFF: SHOW GLOBAL VARIABLES LIKE 'wsrep_desync';"
fi
exit $rc
