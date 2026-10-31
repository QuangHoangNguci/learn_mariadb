#!/bin/bash
# rolling_restart.sh: restart MariaDB lần lượt từng node, không downtime.
# Với mỗi node: drain trong MaxScale -> restart -> đợi Synced và đủ node -> clear drain.
#
# Chạy trên bastion:   ./rolling_restart.sh
# Biến tùy chọn:       ORDER="mariadb-node3 mariadb-node2 mariadb-node1"   thứ tự restart.
#                                 Mặc định: ngược thứ tự inventory. NÊN đặt node Master của MaxScale ở CUỐI
#                                 (xem Master: maxctrl -u admin -p mariadb list servers)
#                      EXPECTED=3          số node cụm phải có sau mỗi lần restart (mặc định: số host)
#                      DRAIN_WAIT=20       số giây chờ kết nối cũ tan sau khi drain (mặc định 20)
#                      NO_MAXSCALE=1       bỏ qua drain/clear (cụm chưa cài MaxScale)
#                      SKIP_HEALTHCHECK=1  bỏ qua kiểm tra sức khỏe trước khi bắt đầu
#                      DRY_RUN=1, YES=1
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
wait_synced() { # wait_synced <số node tối thiểu> <timeout giây>
  local min=$1 limit=${2:-900} waited=0 size
  while [ "$waited" -lt "$limit" ]; do
    size=$(st wsrep_cluster_size)
    if [ "$(st wsrep_local_state_comment)" = Synced ] && [ -n "$size" ] && [ "$size" -ge "$min" ]; then return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

node_restart() {
  ROOT_PW=$1; MIN=$2
  node_init
  echo "Restart mariadb trên $(hostname)"
  systemctl restart mariadb || { echo "systemctl restart thất bại"; exit 1; }
  if wait_synced "$MIN" 1200; then
    echo "OK: $(hostname) Synced, wsrep_cluster_size=$(st wsrep_cluster_size)"
  else
    echo "LỖI: sau 20 phút $(hostname) chưa Synced hoặc cụm chưa đủ $MIN node (state=$(st wsrep_local_state_comment), size=$(st wsrep_cluster_size))"
    exit 1
  fi
}

if [ "${1:-}" = "--node" ]; then
  shift
  node_restart "$@"
  exit $?
fi

# ===================== PHẦN CHẠY TRÊN BASTION =====================
source "$(dirname "$0")/../lib.sh"
SELF="$(self_path "$0")"
require_root_password

ALL_HOSTS=()
while IFS= read -r h; do [ -n "$h" ] && ALL_HOSTS+=("$h"); done < <(list_hosts)
[ "${#ALL_HOSTS[@]}" -gt 0 ] || die "Không lấy được danh sách host của nhóm $INVENTORY_GROUP"
EXPECTED="${EXPECTED:-${#ALL_HOSTS[@]}}"
DRAIN_WAIT="${DRAIN_WAIT:-20}"

if [ -n "${ORDER:-}" ]; then
  read -r -a ORDER_HOSTS <<< "$ORDER"
else
  ORDER_HOSTS=()
  for ((i=${#ALL_HOSTS[@]}-1; i>=0; i--)); do ORDER_HOSTS+=("${ALL_HOSTS[$i]}"); done
fi

log "Thứ tự restart: ${ORDER_HOSTS[*]}"
log "Cụm phải đủ $EXPECTED node sau mỗi lần restart. Node Master của MaxScale nên đứng cuối."
confirm "Bắt đầu rolling restart?"

if [ "${SKIP_HEALTHCHECK:-0}" != 1 ]; then
  log "Kiểm tra sức khỏe trước khi bắt đầu"
  EXPECTED="$EXPECTED" "$BP_DIR/01-healthcheck/healthcheck.sh" || die "Cụm chưa khỏe, dừng rolling restart (SKIP_HEALTHCHECK=1 để bỏ qua)."
fi

for h in "${ORDER_HOSTS[@]}"; do
  idx=$(host_index "$h")
  [ -n "$idx" ] || die "Host $h không có trong inventory nhóm $INVENTORY_GROUP"
  server="server_$idx"

  log "=== $h ($server) ==="
  log "Drain $server trong MaxScale trên mọi node"
  maxctrl_on_all "set server $server drain" || warn "drain không thành công trên một số node (tiếp tục)"
  [ "${NO_MAXSCALE:-0}" = 1 ] || { log "Chờ ${DRAIN_WAIT}s cho kết nối cũ kết thúc"; [ "$DRY_RUN" = 1 ] || sleep "$DRAIN_WAIT"; }

  if ! node_script "$h" "$SELF" --node "$ROOT_PASSWORD" "$EXPECTED"; then
    warn "$h restart/rejoin thất bại. Dừng rolling restart. $server vẫn đang ở trạng thái drain."
    warn "Sau khi xử lý xong, gỡ drain: maxctrl -u admin -p mariadb clear server $server drain"
    exit 1
  fi

  log "Gỡ drain $server"
  maxctrl_on_all "clear server $server drain" || warn "clear drain không thành công trên một số node"
done

log "Rolling restart hoàn tất. Chạy lại healthcheck để xác nhận:"
EXPECTED="$EXPECTED" "$BP_DIR/01-healthcheck/healthcheck.sh"
