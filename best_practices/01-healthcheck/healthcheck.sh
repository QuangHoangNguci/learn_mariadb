#!/bin/bash
# healthcheck.sh: kiểm tra sức khỏe cụm MariaDB Galera + MaxScale trên tất cả node.
#
# Chạy trên bastion:   ./healthcheck.sh
# Biến tùy chọn:       EXPECTED=3   số node mong đợi (mặc định: số host trong inventory)
#                      LIMIT=mariadb-node2   chỉ kiểm tra một node
#                      DRY_RUN=1    chỉ in lệnh ansible, không chạy
# Thoát mã 0 nếu mọi node đều đạt, khác 0 nếu có node không đạt.
set -uo pipefail

# ===================== PHẦN CHẠY TRÊN NODE (gọi với --node) =====================
cnf_value() {
  awk -F= -v k="$1" '$1 ~ "^"k"[ \t]*$" { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' /etc/my.cnf 2>/dev/null
}

node_init() {
  MBIN=/usr/local/mariadb/bin
  SOCK="$(cnf_value socket)";   SOCK="${SOCK:-/u01/data/database/mariadb.sock}"
  DATADIR="$(cnf_value datadir)"; DATADIR="${DATADIR:-/u01/data/database}"
  ERRLOG="$(cnf_value log-error)"; ERRLOG="${ERRLOG:-/u01/logs/mariadb/mariadb.error.log}"
}
sql() { MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb" -u root -S "$SOCK" -Nse "$1" 2>/dev/null; }
st()  { sql "SHOW GLOBAL STATUS LIKE '$1'" | awk '{print $2}'; }

node_check() {
  ROOT_PW=$1; EXPECTED=$2; MAXPW=$3
  node_init
  local fail=0 out rc used max
  eq() { if [ "$2" = "$3" ]; then echo "[ OK ] $1 = $2"; else echo "[FAIL] $1 = $2 (mong đợi $3)"; fail=1; fi; }
  lt() { if awk -v v="${2:-0}" -v t="$3" 'BEGIN{exit !(v+0<t+0)}'; then echo "[ OK ] $1 = ${2:-0}"; else echo "[FAIL] $1 = ${2:-0} (ngưỡng < $3)"; fail=1; fi; }

  echo "===== $(hostname) ====="
  eq "service mariadb"            "$(systemctl is-active mariadb)" active
  eq "wsrep_cluster_status"       "$(st wsrep_cluster_status)" Primary
  eq "wsrep_local_state_comment"  "$(st wsrep_local_state_comment)" Synced
  eq "wsrep_cluster_size"         "$(st wsrep_cluster_size)" "$EXPECTED"
  eq "wsrep_ready"                "$(st wsrep_ready)" ON
  eq "wsrep_connected"            "$(st wsrep_connected)" ON
  lt "wsrep_flow_control_paused"  "$(st wsrep_flow_control_paused)" 0.1
  lt "wsrep_local_recv_queue_avg" "$(st wsrep_local_recv_queue_avg)" 1

  used=$(st Threads_connected); max=$(sql "SELECT @@max_connections")
  if [ -n "$used" ] && [ -n "$max" ] && [ "$max" -gt 0 ] 2>/dev/null; then
    lt "connections_used_pct" "$(( 100 * used / max ))" 80
  else
    echo "[FAIL] không đọc được Threads_connected / max_connections"; fail=1
  fi
  lt "disk_used_pct $DATADIR" "$(df --output=pcent "$DATADIR" | tail -1 | tr -dc 0-9)" 80

  echo "[INFO] số dòng [ERROR] trong $ERRLOG: $(grep -c '\[ERROR\]' "$ERRLOG" 2>/dev/null)"
  grep '\[ERROR\]' "$ERRLOG" 2>/dev/null | tail -3

  if [ -x /usr/local/bin/maxctrl ]; then
    out=$(/usr/local/bin/maxctrl -u admin -p "$MAXPW" list servers 2>&1); rc=$?
    if [ $rc -ne 0 ]; then
      echo "[FAIL] maxctrl list servers lỗi (sai mật khẩu REST admin hoặc MaxScale chưa chạy):"; echo "$out" | head -5; fail=1
    elif echo "$out" | grep -qE 'Down|Auth Error'; then
      echo "[FAIL] MaxScale báo có server Down / Auth Error:"; echo "$out"; fail=1
    else
      echo "[ OK ] MaxScale thấy đủ server:"; echo "$out"
    fi
  else
    echo "[INFO] node này chưa cài MaxScale, bỏ qua kiểm tra MaxScale"
  fi
  return $fail
}

if [ "${1:-}" = "--node" ]; then
  shift
  node_check "$@"
  exit $?
fi

# ===================== PHẦN CHẠY TRÊN BASTION =====================
source "$(dirname "$0")/../lib.sh"
SELF="$(self_path "$0")"
require_root_password

HOST_COUNT=$(list_hosts | wc -l | tr -d ' ')
EXPECTED="${EXPECTED:-$HOST_COUNT}"
TARGET="${LIMIT:-$INVENTORY_GROUP}"

log "Kiểm tra sức khỏe $TARGET (mong đợi cụm $EXPECTED node)"
node_script "$TARGET" "$SELF" --node "$ROOT_PASSWORD" "$EXPECTED" "$MAXCTRL_PASSWORD"
rc=$?
if [ $rc -eq 0 ]; then
  log "Tất cả node đạt."
else
  warn "Có node không đạt (xem dòng [FAIL] ở trên)."
fi
exit $rc
