#!/bin/bash
# simulate_partition.sh: mô phỏng chia mạng bằng cách cô lập một node khỏi các node còn lại (iptables DROP).
# Node bị cô lập mất quorum (non-Primary) và từ chối đọc/ghi, hai node còn lại vẫn Primary.
#
# Chạy trên bastion:
#   ./simulate_partition.sh isolate <host>   cô lập node
#   ./simulate_partition.sh status  <host>   xem rule iptables và trạng thái Galera của node
#   ./simulate_partition.sh heal    <host>   gỡ cô lập, node tự rejoin
# Biến tùy chọn: DRY_RUN=1, YES=1
# Các rule DROP có comment "bp-partition" nên chỉ gỡ đúng rule do script này tạo. IP đồng đẳng lấy từ
# wsrep_cluster_address trong /etc/my.cnf của chính node. Bastion không bị chặn nên SSH vẫn hoạt động.
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

peers() {
  local own addr
  own=$(cnf_value wsrep_node_address | cut -d: -f1)
  addr=$(cnf_value wsrep_cluster_address | sed 's#^gcomm://##')
  echo "$addr" | tr ',' '\n' | cut -d: -f1 | grep -v '^$' | grep -vx "$own"
}

node_isolate() {
  local ip
  for ip in $(peers); do
    iptables -I INPUT  1 -s "$ip" -m comment --comment bp-partition -j DROP
    iptables -I OUTPUT 1 -d "$ip" -m comment --comment bp-partition -j DROP
    echo "Đã chặn $ip trên $(hostname)"
  done
}
node_heal() {
  local ip
  for ip in $(peers); do
    while iptables -D INPUT  -s "$ip" -m comment --comment bp-partition -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -d "$ip" -m comment --comment bp-partition -j DROP 2>/dev/null; do :; done
    echo "Đã gỡ chặn $ip trên $(hostname)"
  done
}
node_status() {
  ROOT_PW=$1
  node_init
  echo "Rule bp-partition: $(iptables -S | grep -c bp-partition)"
  echo "wsrep_cluster_status=$(st wsrep_cluster_status) wsrep_local_state_comment=$(st wsrep_local_state_comment) wsrep_cluster_size=$(st wsrep_cluster_size)"
}

if [ "${1:-}" = "--node" ]; then
  mode=$2; shift 2
  case "$mode" in
    isolate) node_isolate ;;
    heal)    node_heal ;;
    status)  node_status "$@" ;;
    *) echo "mode không hợp lệ: $mode"; exit 2 ;;
  esac
  exit $?
fi

# ===================== PHẦN CHẠY TRÊN BASTION =====================
source "$(dirname "$0")/../lib.sh"
SELF="$(self_path "$0")"
require_root_password

ACTION="${1:-}"; HOST="${2:-}"
case "$ACTION" in isolate|heal|status) ;; *) die "Dùng: $0 isolate|heal|status <host>   (các host: $(list_hosts | tr '\n' ' '))" ;; esac
[ -n "$HOST" ] || die "Thiếu tên host. Các host: $(list_hosts | tr '\n' ' ')"

case "$ACTION" in
  isolate)
    confirm "Sẽ cô lập $HOST khỏi các node còn lại. Node này sẽ mất quorum. Tiếp tục?"
    node_script "$HOST" "$SELF" --node isolate
    log "Đợi vài giây rồi kiểm tra: $0 status $HOST (kỳ vọng non-Primary) và ../01-healthcheck/healthcheck.sh (hai node còn lại vẫn Primary)"
    ;;
  heal)
    node_script "$HOST" "$SELF" --node heal
    log "Đã gỡ cô lập. Theo dõi rejoin bằng: $0 status $HOST"
    ;;
  status)
    node_script "$HOST" "$SELF" --node status "$ROOT_PASSWORD"
    ;;
esac
