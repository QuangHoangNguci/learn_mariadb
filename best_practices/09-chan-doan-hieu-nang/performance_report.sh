#!/bin/bash
# performance_report.sh: thu thập ảnh chụp chẩn đoán hiệu năng trên tất cả node (chỉ đọc, không thay đổi gì).
# Gồm: tải hệ thống, chỉ số InnoDB/kết nối, chỉ số Galera (flow control, queue, xung đột), truy vấn đang chạy,
# giao dịch mở lâu, top câu lệnh theo performance_schema, bảng/index đọc nhiều (userstat), top slow log.
#
# Chạy trên bastion:   ./performance_report.sh
# Biến tùy chọn:       LIMIT=mariadb-node1   chỉ chạy trên một node
#                      DRY_RUN=1
set -uo pipefail

# ===================== PHẦN CHẠY TRÊN NODE =====================
cnf_value() {
  awk -F= -v k="$1" '$1 ~ "^"k"[ \t]*$" { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' /etc/my.cnf 2>/dev/null
}
node_init() {
  MBIN=/usr/local/mariadb/bin
  SOCK="$(cnf_value socket)";       SOCK="${SOCK:-/u01/data/database/mariadb.sock}"
  DATADIR="$(cnf_value datadir)";   DATADIR="${DATADIR:-/u01/data/database}"
  ERRLOG="$(cnf_value log-error)";  ERRLOG="${ERRLOG:-/u01/logs/mariadb/mariadb.error.log}"
  SLOWLOG="$(cnf_value slow_query_log_file)"; SLOWLOG="${SLOWLOG:-/u01/logs/mariadb/mariadb.slow.log}"
}
sqlt() { MYSQL_PWD="$ROOT_PW" "$MBIN/mariadb" -u root -S "$SOCK" --table -e "$1" 2>&1; }
section() { printf '\n--- %s ---\n' "$1"; }

node_report() {
  ROOT_PW=$1
  node_init
  echo "################ $(hostname)  $(date '+%F %T') ################"

  section "Hệ thống"
  uptime
  free -m
  df -h "$DATADIR" | tail -2

  section "Kết nối và InnoDB"
  sqlt "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Max_used_connections','Aborted_connects','Slow_queries','Created_tmp_disk_tables','Innodb_row_lock_waits','Innodb_row_lock_time_avg','Innodb_buffer_pool_wait_free');"
  sqlt "SELECT ROUND(100 * (1 - r.v / q.v), 2) AS buffer_pool_hit_pct FROM (SELECT VARIABLE_VALUE+0 v FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Innodb_buffer_pool_reads') r, (SELECT VARIABLE_VALUE+0 v FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests') q;"
  sqlt "SELECT @@max_connections AS max_connections, @@innodb_buffer_pool_size/1024/1024 AS buffer_pool_mb, @@long_query_time AS long_query_time;"

  section "Galera: flow control, hàng đợi, xung đột"
  sqlt "SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_local_state_comment','wsrep_cluster_size','wsrep_cluster_status','wsrep_flow_control_paused','wsrep_flow_control_sent','wsrep_flow_control_recv','wsrep_local_recv_queue_avg','wsrep_local_send_queue_avg','wsrep_local_cert_failures','wsrep_local_bf_aborts','wsrep_cert_deps_distance','wsrep_apply_oooe');"

  section "Truy vấn đang chạy (không tính Sleep)"
  sqlt "SELECT id, user, host, db, command, time, state, LEFT(info, 120) AS query FROM information_schema.processlist WHERE command <> 'Sleep' AND id <> CONNECTION_ID() ORDER BY time DESC LIMIT 15;"

  section "Giao dịch InnoDB mở lâu"
  sqlt "SELECT trx_id, trx_state, trx_started, TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS open_sec, trx_rows_locked, trx_rows_modified, LEFT(trx_query, 100) AS query FROM information_schema.INNODB_TRX ORDER BY trx_started LIMIT 10;"

  section "Top 10 câu lệnh theo tổng thời gian (performance_schema)"
  sqlt "SELECT LEFT(DIGEST_TEXT, 100) AS digest, COUNT_STAR AS calls, ROUND(SUM_TIMER_WAIT/1e12, 2) AS total_sec, ROUND(AVG_TIMER_WAIT/1e12, 4) AS avg_sec, SUM_ROWS_EXAMINED AS rows_examined, SUM_NO_INDEX_USED AS no_index FROM performance_schema.events_statements_summary_by_digest ORDER BY SUM_TIMER_WAIT DESC LIMIT 10;"

  section "Top bảng và index được đọc nhiều (userstat)"
  sqlt "SELECT * FROM information_schema.TABLE_STATISTICS ORDER BY ROWS_READ DESC LIMIT 10;"
  sqlt "SELECT * FROM information_schema.INDEX_STATISTICS ORDER BY ROWS_READ DESC LIMIT 10;"

  section "Slow log: top 5 theo tổng thời gian"
  if [ -f "$SLOWLOG" ]; then
    ls -lh "$SLOWLOG" | awk '{print $5, $9}'
    "$MBIN/mariadb-dumpslow" -s t -t 5 "$SLOWLOG" 2>&1 | head -40
  else
    echo "Không thấy $SLOWLOG"
  fi

  section "Xung đột Galera và lỗi gần đây trong error log"
  grep -iE 'conflict|deadlock' "$ERRLOG" 2>/dev/null | tail -5
  grep '\[ERROR\]' "$ERRLOG" 2>/dev/null | tail -5
}

if [ "${1:-}" = "--node" ]; then
  shift
  node_report "$@"
  exit $?
fi

# ===================== PHẦN CHẠY TRÊN BASTION =====================
source "$(dirname "$0")/../lib.sh"
SELF="$(self_path "$0")"
require_root_password

TARGET="${LIMIT:-$INVENTORY_GROUP}"
log "Thu thập báo cáo hiệu năng trên $TARGET (chỉ đọc)"
node_script "$TARGET" "$SELF" --node "$ROOT_PASSWORD"
