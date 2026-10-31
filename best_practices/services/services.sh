#!/bin/bash
# services.sh: bật/tắt writer và reader chạy nền trên bastion.
#   ./services.sh start [writer|reader|all]     (mặc định all)
#   ./services.sh stop  [writer|reader|all]
#   ./services.sh status
#   ./services.sh logs  writer|reader           (theo dõi log, thoát bằng Ctrl+C)
# Tham số bổ sung cho từng service đặt qua biến, ví dụ:
#   WRITER_ARGS="--batch 20 --interval 0.5" ./services.sh start writer
#   READER_ARGS="--port 9000" ./services.sh start reader
# Nếu có thư mục .venv cạnh file này thì tự dùng Python trong đó.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
RUN_DIR=run; LOG_DIR=logs
mkdir -p "$RUN_DIR" "$LOG_DIR"
PYTHON=python3; [ -x .venv/bin/python ] && PYTHON=.venv/bin/python

args_for() { case "$1" in writer) echo "${WRITER_ARGS:-}" ;; reader) echo "${READER_ARGS:-}" ;; esac; }

is_running() { [ -f "$RUN_DIR/$1.pid" ] && kill -0 "$(cat "$RUN_DIR/$1.pid")" 2>/dev/null; }

start_one() {
  local name=$1
  if is_running "$name"; then echo "$name: đã chạy (pid $(cat "$RUN_DIR/$name.pid"))"; return; fi
  # shellcheck disable=SC2046
  nohup "$PYTHON" "${name}_service.py" $(args_for "$name") >> "$LOG_DIR/$name.log" 2>&1 &
  echo $! > "$RUN_DIR/$name.pid"
  sleep 2
  if is_running "$name"; then echo "$name: đã chạy (pid $(cat "$RUN_DIR/$name.pid")), log: $LOG_DIR/$name.log"
  else echo "$name: KHÔNG chạy được, xem log:"; tail -n 15 "$LOG_DIR/$name.log"; rm -f "$RUN_DIR/$name.pid"; return 1; fi
}

stop_one() {
  local name=$1
  if is_running "$name"; then
    kill "$(cat "$RUN_DIR/$name.pid")" && echo "$name: đã gửi tín hiệu dừng"
    for _ in 1 2 3 4 5 6 7 8 9 10; do is_running "$name" || break; sleep 1; done
    is_running "$name" && { kill -9 "$(cat "$RUN_DIR/$name.pid")"; echo "$name: buộc dừng"; }
  else echo "$name: không chạy"; fi
  rm -f "$RUN_DIR/$name.pid"
}

targets() { case "${1:-all}" in all) echo "writer reader" ;; writer|reader) echo "$1" ;; *) echo "Dùng: $0 start|stop [writer|reader|all]" >&2; exit 2 ;; esac; }

case "${1:-}" in
  start)  for n in $(targets "${2:-all}"); do start_one "$n"; done ;;
  stop)   for n in $(targets "${2:-all}"); do stop_one "$n"; done ;;
  status) for n in writer reader; do if is_running "$n"; then echo "$n: đang chạy (pid $(cat "$RUN_DIR/$n.pid"))"; else echo "$n: không chạy"; fi; done ;;
  logs)   [ -n "${2:-}" ] || { echo "Dùng: $0 logs writer|reader" >&2; exit 2; }; tail -n 50 -f "$LOG_DIR/$2.log" ;;
  *)      echo "Dùng: $0 start|stop|status|logs ..." >&2; exit 2 ;;
esac
