#!/bin/bash
# bootstrap_cluster.sh: khôi phục cụm Galera sau khi TẤT CẢ node đã tắt (mất điện, tắt nhầm).
# Các bước: xác nhận mọi node đang tắt -> đo vị trí Galera (galera_recovery) của từng node -> chọn node có seqno
# lớn nhất -> đặt safe_to_bootstrap=1 và bootstrap node đó -> start các node còn lại lần lượt từng node.
#
# Chạy trên bastion:   ./bootstrap_cluster.sh
# Biến tùy chọn:       BOOTSTRAP_HOST=mariadb-node2   ép bootstrap từ node này (bỏ qua việc so seqno).
#                                                      Chỉ dùng khi bạn CHẮC node đó có dữ liệu mới nhất.
#                      DRY_RUN=1  chỉ in các lệnh ansible (không đo được seqno nên dừng sau bước đo)
#                      YES=1      không hỏi xác nhận
# CẢNH BÁO: bootstrap nhầm node có dữ liệu cũ sẽ làm mất các giao dịch mới nhất của cụm.
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

# In ra: RECOVER <seqno> <uuid>. Thoát 3 nếu node đang chạy, 4 nếu không xác định được vị trí.
node_recover() {
  node_init
  if systemctl is-active --quiet mariadb; then echo "RUNNING"; exit 3; fi
  local out pos
  out=$(runuser -u mariadb -- "$MBIN/galera_recovery" 2>&1)
  pos=$(echo "$out" | grep -o 'wsrep_start_position=[^ ]*' | tail -1 | cut -d= -f2)
  if [ -z "$pos" ]; then
    echo "Không đọc được vị trí từ galera_recovery. Output:"; echo "$out" | tail -5; exit 4
  fi
  echo "RECOVER ${pos##*:} ${pos%:*}"
  echo "grastate: $(grep -E 'seqno|safe_to_bootstrap' "$DATADIR/grastate.dat" 2>/dev/null | tr '\n' ' ')"
}

node_bootstrap() {
  ROOT_PW=$1
  node_init
  local flag=/run/mariadb/wsrep-new-cluster
  if systemctl is-active --quiet mariadb; then echo "mariadb đang chạy, từ chối bootstrap"; exit 1; fi
  if [ -f "$DATADIR/grastate.dat" ]; then
    sed -i 's/^safe_to_bootstrap:.*/safe_to_bootstrap: 1/' "$DATADIR/grastate.dat"
    echo "Đã đặt safe_to_bootstrap: 1"
  fi
  install -d -o mariadb -g mariadb -m 0750 /run/mariadb
  printf '_WSREP_NEW_CLUSTER=--wsrep-new-cluster\n' > "$flag"
  chmod 600 "$flag"
  # Luôn xóa cờ sau khi start để lần restart sau không bootstrap lại cụm mới
  trap 'rm -f /run/mariadb/wsrep-new-cluster' EXIT
  systemctl start mariadb || { echo "systemctl start thất bại"; exit 1; }
  if wait_synced 1 300; then
    echo "OK: $(hostname) đã bootstrap, wsrep_cluster_size=$(st wsrep_cluster_size), $(st wsrep_cluster_status)"
  else
    echo "LỖI: bootstrap xong nhưng chưa Synced sau 5 phút"; exit 1
  fi
}

node_start() {
  ROOT_PW=$1; MIN=$2
  node_init
  systemctl start mariadb || { echo "systemctl start thất bại"; exit 1; }
  if wait_synced "$MIN" 1800; then
    echo "OK: $(hostname) Synced, wsrep_cluster_size=$(st wsrep_cluster_size)"
  else
    echo "LỖI: $(hostname) chưa Synced hoặc cụm chưa đủ $MIN node sau 30 phút"; exit 1
  fi
}

if [ "${1:-}" = "--node" ]; then
  mode=$2; shift 2
  case "$mode" in
    recover)   node_recover "$@" ;;
    bootstrap) node_bootstrap "$@" ;;
    start)     node_start "$@" ;;
    *) echo "mode không hợp lệ: $mode"; exit 2 ;;
  esac
  exit $?
fi

# ===================== PHẦN CHẠY TRÊN BASTION =====================
source "$(dirname "$0")/../lib.sh"
SELF="$(self_path "$0")"
require_root_password

ALL_HOSTS=()
while IFS= read -r h; do [ -n "$h" ] && ALL_HOSTS+=("$h"); done < <(list_hosts)
[ "${#ALL_HOSTS[@]}" -gt 0 ] || die "Không lấy được danh sách host của nhóm $INVENTORY_GROUP"

log "Bước 1: kiểm tra mọi node đang tắt và đo vị trí Galera"
best_host=""; best_seq=-2
for h in "${ALL_HOSTS[@]}"; do
  out=$(node_script_oneline "$h" "$SELF" --node recover)
  if [ "$DRY_RUN" = 1 ]; then echo "$out"; continue; fi
  echo "$out" | grep -q 'RUNNING' && die "Node $h đang chạy. Script này chỉ dùng khi CẢ CỤM đã tắt."
  seq=$(echo "$out" | sed -n 's/.*RECOVER \(-\{0,1\}[0-9]\{1,\}\) .*/\1/p' | head -1)
  uuid=$(echo "$out" | sed -n 's/.*RECOVER -\{0,1\}[0-9]\{1,\} \([0-9a-f-]\{1,\}\).*/\1/p' | head -1)
  if [ -z "$seq" ]; then
    warn "Không đo được vị trí của $h: $out"
    continue
  fi
  log "  $h: seqno=$seq uuid=$uuid"
  if [ "$seq" -gt "$best_seq" ]; then best_seq=$seq; best_host=$h; fi
done

if [ "$DRY_RUN" = 1 ]; then
  log "DRY_RUN: dừng tại đây vì không thể đo seqno. Các bước tiếp theo: bootstrap node có seqno lớn nhất rồi start các node còn lại."
  exit 0
fi

if [ -n "${BOOTSTRAP_HOST:-}" ]; then
  warn "BOOTSTRAP_HOST=$BOOTSTRAP_HOST được ép dùng, bỏ qua kết quả so seqno (node tốt nhất theo seqno: ${best_host:-không xác định})"
  best_host=$BOOTSTRAP_HOST
fi
[ -n "$best_host" ] || die "Không xác định được node để bootstrap. Xem grastate.dat từng node rồi đặt BOOTSTRAP_HOST."
if [ "$best_seq" = "-1" ] && [ -z "${BOOTSTRAP_HOST:-}" ]; then
  die "Mọi node đều có seqno -1 (không phục hồi được vị trí). Xem grastate.dat / error log từng node rồi đặt BOOTSTRAP_HOST."
fi

log "Bước 2: sẽ bootstrap từ $best_host (seqno $best_seq)"
confirm "Bootstrap cụm mới từ $best_host?"
node_script "$best_host" "$SELF" --node bootstrap "$ROOT_PASSWORD" || die "Bootstrap $best_host thất bại, dừng lại. Xem log: /u01/logs/mariadb/mariadb.error.log"

log "Bước 3: start các node còn lại, mỗi lần một node"
min=2
for h in "${ALL_HOSTS[@]}"; do
  [ "$h" = "$best_host" ] && continue
  log "  start $h (đợi cụm >= $min node)"
  node_script "$h" "$SELF" --node start "$ROOT_PASSWORD" "$min" || die "Node $h không join được, dừng lại."
  min=$((min + 1))
done

log "Hoàn tất. Chạy kiểm tra: ../01-healthcheck/healthcheck.sh"
