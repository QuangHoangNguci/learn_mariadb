#!/bin/bash
# rsu_ddl.sh: chạy một lệnh DDL nặng theo kiểu RSU (Rolling Schema Upgrade), từng node một.
# Với mỗi node: drain trong MaxScale -> SET SESSION wsrep_OSC_method='RSU' -> chạy DDL -> đợi Synced -> clear drain.
# Chỉ dùng cho thay đổi TƯƠNG THÍCH NGƯỢC (thêm index, thêm cột NULL/có default). Trong lúc chạy các node
# có schema khác nhau tạm thời.
#
# Chạy trên bastion:
#   ./rsu_ddl.sh <database> "<câu lệnh DDL>"
#   ví dụ: ./rsu_ddl.sh vn_provinces "ALTER TABLE wards ADD INDEX idx_wards_name (name)"
# Biến tùy chọn: ORDER="host3 host2 host1"  thứ tự node (mặc định: ngược inventory; nên để Master cuối)
#                EXPECTED=3, DRAIN_WAIT=20, NO_MAXSCALE=1, DRY_RUN=1, YES=1
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
wait_synced() {
  local min=$1 limit=${2:-900} waited=0 size
  while [ "$waited" -lt "$limit" ]; do
    size=$(st wsrep_cluster_size)
    if [ "$(st wsrep_local_state_comment)" = Synced ] && [ -n "$size" ] && [ "$size" -ge "$min" ]; then return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

node_rsu() {
  ROOT_PW=$1; DB=$2; STMT=$3; MIN=$4
  node_init
  echo "$(hostname): chạy DDL kiểu RSU trên database $DB"
  # Cả hai lệnh phải cùng một session nên gộp trong một lần gọi mariadb
  if ! MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb" -u root -S "$SOCK" "$DB" \
        -e "SET SESSION wsrep_OSC_method='RSU'; $STMT;"; then
    echo "DDL thất bại trên $(hostname)"; exit 1
  fi
  if wait_synced "$MIN" 900; then
    echo "OK: $(hostname) đã chạy DDL và Synced (wsrep_cluster_size=$(st wsrep_cluster_size))"
  else
    echo "LỖI: $(hostname) chưa Synced sau DDL"; exit 1
  fi
}

if [ "${1:-}" = "--node" ]; then
  shift
  node_rsu "$@"
  exit $?
fi

# ===================== PHẦN CHẠY TRÊN BASTION =====================
source "$(dirname "$0")/../lib.sh"
SELF="$(self_path "$0")"
require_root_password

DB="${1:-}"; STMT="${2:-}"
[ -n "$DB" ] && [ -n "$STMT" ] || die "Dùng: $0 <database> \"<câu lệnh DDL>\""

ALL_HOSTS=()
while IFS= read -r h; do [ -n "$h" ] && ALL_HOSTS+=("$h"); done < <(list_hosts)
EXPECTED="${EXPECTED:-${#ALL_HOSTS[@]}}"
DRAIN_WAIT="${DRAIN_WAIT:-20}"
if [ -n "${ORDER:-}" ]; then
  read -r -a ORDER_HOSTS <<< "$ORDER"
else
  ORDER_HOSTS=()
  for ((i=${#ALL_HOSTS[@]}-1; i>=0; i--)); do ORDER_HOSTS+=("${ALL_HOSTS[$i]}"); done
fi

log "Database: $DB"
log "DDL: $STMT"
log "Thứ tự node: ${ORDER_HOSTS[*]}"
confirm "Chạy DDL này bằng RSU lần lượt từng node (thay đổi PHẢI tương thích ngược)?"

for h in "${ORDER_HOSTS[@]}"; do
  idx=$(host_index "$h")
  [ -n "$idx" ] || die "Host $h không có trong inventory"
  server="server_$idx"
  log "=== $h ($server) ==="
  maxctrl_on_all "set server $server drain" || warn "drain không thành công trên một số node"
  [ "${NO_MAXSCALE:-0}" = 1 ] || { [ "$DRY_RUN" = 1 ] || sleep "$DRAIN_WAIT"; }

  if ! node_script "$h" "$SELF" --node "$ROOT_PASSWORD" "$DB" "$STMT" "$EXPECTED"; then
    warn "DDL thất bại trên $h. Dừng. $server vẫn đang drain; gỡ bằng: maxctrl -u admin -p mariadb clear server $server drain"
    warn "Các node đã chạy trước đó đã có thay đổi, các node chưa chạy thì chưa."
    exit 1
  fi
  maxctrl_on_all "clear server $server drain" || warn "clear drain không thành công trên một số node"
done
log "Hoàn tất RSU trên mọi node. Kiểm tra schema đồng nhất: SHOW CREATE TABLE trên từng node."
