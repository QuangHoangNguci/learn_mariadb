#!/bin/bash
# maxscale_server.sh: thêm, xóa, drain, bảo trì server trong MaxScale trên TẤT CẢ node
# (mỗi node có một MaxScale độc lập nên mọi thay đổi phải áp dụng cho từng node).
#
# Chạy trên bastion:
#   ./maxscale_server.sh list                              trạng thái server trên mọi node
#   ./maxscale_server.sh add <tên_server> <ip> [<cổng>]    thêm server mới vào monitor và hai dịch vụ (mặc định cổng 3306)
#   ./maxscale_server.sh remove <tên_server>               gỡ khỏi dịch vụ, monitor rồi xóa server
#   ./maxscale_server.sh drain <tên_server>                ngừng nhận kết nối mới
#   ./maxscale_server.sh clear <tên_server>                gỡ drain
#   ./maxscale_server.sh maintenance <tên_server>          đưa vào bảo trì
#   ./maxscale_server.sh unmaintenance <tên_server>        gỡ bảo trì
# Tên server theo thứ tự inventory: server_1, server_2, ... Mật khẩu REST admin: MAXCTRL_PASSWORD (mặc định mariadb).
# Biến tùy chọn: DRY_RUN=1, YES=1
set -uo pipefail

source "$(dirname "$0")/../lib.sh"

ACTION="${1:-}"
NAME="${2:-}"
SERVICES="Read-Write-Service Read-Only-Service"
MONITOR="Galera-Monitor"

need_name() { [ -n "$NAME" ] || die "Thiếu tên server. Dùng: $0 $ACTION <tên_server>"; }

case "$ACTION" in
  list)
    maxctrl_on_all "list servers"
    ;;
  add)
    need_name
    IP="${3:-}"; PORT="${4:-3306}"
    [ -n "$IP" ] || die "Thiếu IP. Dùng: $0 add <tên_server> <ip> [<cổng>]"
    confirm "Thêm server $NAME ($IP:$PORT) vào MaxScale trên mọi node?"
    maxctrl_on_all "create server $NAME $IP $PORT proxy_protocol=true"
    maxctrl_on_all "link monitor $MONITOR $NAME"
    for s in $SERVICES; do maxctrl_on_all "link service $s $NAME" || warn "Không link được dịch vụ $s (dịch vụ có thể không bật trên cấu hình này)"; done
    maxctrl_on_all "list servers"
    ;;
  remove)
    need_name
    confirm "Gỡ server $NAME khỏi MaxScale trên mọi node?"
    maxctrl_on_all "set server $NAME drain" || warn "drain không thành công"
    for s in $SERVICES; do maxctrl_on_all "unlink service $s $NAME" || warn "Không unlink được dịch vụ $s"; done
    maxctrl_on_all "unlink monitor $MONITOR $NAME"
    maxctrl_on_all "destroy server $NAME"
    maxctrl_on_all "list servers"
    ;;
  drain)          need_name; maxctrl_on_all "set server $NAME drain" ;;
  clear)          need_name; maxctrl_on_all "clear server $NAME drain" ;;
  maintenance)    need_name; maxctrl_on_all "set server $NAME maintenance" ;;
  unmaintenance)  need_name; maxctrl_on_all "clear server $NAME maintenance" ;;
  *)
    die "Dùng: $0 list | add <tên> <ip> [cổng] | remove <tên> | drain <tên> | clear <tên> | maintenance <tên> | unmaintenance <tên>"
    ;;
esac
