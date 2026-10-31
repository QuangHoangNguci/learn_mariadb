#!/bin/bash
# simulate_crash.sh: mô phỏng một node MariaDB crash (kill -9) rồi theo dõi quá trình tự rejoin.
#
# Chạy trên bastion:   ./simulate_crash.sh <host>        ví dụ: ./simulate_crash.sh mariadb-node3
# Biến tùy chọn:       TIMEOUT=600   số giây tối đa chờ node trở lại Synced (mặc định 600)
#                      DRY_RUN=1, YES=1
# Role đặt Restart=on-failure, RestartSec=5 nên systemd tự khởi động lại sau khoảng 5 giây.
set -uo pipefail

# ===================== PHẦN CHẠY TRÊN NODE =====================
cnf_value() {
  awk -F= -v k="$1" '$1 ~ "^"k"[ \t]*$" { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' /etc/my.cnf 2>/dev/null
}
node_init() {
  MBIN=/usr/local/mariadb/bin
  SOCK="$(cnf_value socket)"; SOCK="${SOCK:-/u01/data/database/mariadb.sock}"
}
sql() { MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb" -u root -S "$SOCK" -Nse "$1" 2>/dev/null; }
st()  { sql "SHOW GLOBAL STATUS LIKE '$1'" | awk '{print $2}'; }

node_kill() {
  local pid
  pid=$(pidof mariadbd) || { echo "Không thấy tiến trình mariadbd"; exit 1; }
  echo "kill -9 $pid trên $(hostname) lúc $(date +%T)"
  kill -9 $pid
}
node_state() {
  ROOT_PW=$1
  node_init
  echo "STATE active=$(systemctl is-active mariadb) wsrep=$(st wsrep_local_state_comment) size=$(st wsrep_cluster_size) status=$(st wsrep_cluster_status)"
}

if [ "${1:-}" = "--node" ]; then
  mode=$2; shift 2
  case "$mode" in
    kill)  node_kill ;;
    state) node_state "$@" ;;
    *) echo "mode không hợp lệ: $mode"; exit 2 ;;
  esac
  exit $?
fi

# ===================== PHẦN CHẠY TRÊN BASTION =====================
source "$(dirname "$0")/../lib.sh"
SELF="$(self_path "$0")"
require_root_password

HOST="${1:-}"
[ -n "$HOST" ] || die "Thiếu tên host. Dùng: $0 <host>   (các host: $(list_hosts | tr '\n' ' '))"
TIMEOUT="${TIMEOUT:-600}"

confirm "Sẽ kill -9 mariadbd trên $HOST. Cụm cần còn đủ quorum. Tiếp tục?"
log "Kill mariadbd trên $HOST"
node_script "$HOST" "$SELF" --node kill || die "Không kill được tiến trình trên $HOST"

log "Theo dõi $HOST mỗi 10 giây (tối đa ${TIMEOUT}s). Xem thêm MaxScale: maxctrl -u admin -p mariadb list servers"
[ "$DRY_RUN" = 1 ] && { node_script_oneline "$HOST" "$SELF" --node state "$ROOT_PASSWORD"; exit 0; }
waited=0
while [ "$waited" -lt "$TIMEOUT" ]; do
  sleep 10; waited=$((waited + 10))
  out=$(node_script_oneline "$HOST" "$SELF" --node state "$ROOT_PASSWORD" | sed -n 's/.*\(STATE [^\\]*\).*/\1/p' | head -1)
  log "[$waited s] ${out:-chưa kết nối được tới node}"
  case "$out" in *"wsrep=Synced"*"status=Primary"*) log "Node đã rejoin và Synced."; exit 0 ;; esac
done
warn "Hết ${TIMEOUT}s mà $HOST chưa Synced. Xem: journalctl -u mariadb và /u01/logs/mariadb/mariadb.error.log trên node đó."
exit 1
