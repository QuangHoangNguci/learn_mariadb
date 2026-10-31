#!/bin/bash
# lib.sh: hàm dùng chung cho các script chạy trên bastion. File này được `source`, không chạy trực tiếp.
#
# Quy ước chung của mọi script trong thư mục này:
#   - Chạy trên bastion, trong bất kỳ thư mục nào:  best_practices/<thư-mục-kịch-bản>/<tên-script>.sh
#     (mỗi kịch bản có thư mục riêng; file lib.sh này dùng chung và nằm ở best_practices/)
#   - Dùng inventory và ansible.cfg của ../ansible-mariadb (đổi bằng biến ANSIBLE_DIR)
#   - Mỗi script vừa là script bastion vừa là script chạy trên node: bastion dùng module `script` của Ansible
#     để copy chính file đó lên node và gọi lại với tham số `--node`.
#   - DRY_RUN=1  chỉ in các lệnh ansible sẽ chạy, không thực thi (dùng để xem trước)
#   - YES=1      bỏ qua bước hỏi xác nhận
#   - MARIADB_ROOT_PASSWORD  mật khẩu root MariaDB. Nếu không đặt, lấy mariadb_admin_pass trong group_vars/mariadb.yml
#   - MAXCTRL_PASSWORD       mật khẩu user REST `admin` của MaxScale (mặc định: mariadb)

BP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${ANSIBLE_DIR:-$BP_DIR/../ansible-mariadb}"
GROUP_VARS="${GROUP_VARS:-$ANSIBLE_DIR/projects/inventory/group_vars/mariadb.yml}"
INVENTORY_GROUP="${INVENTORY_GROUP:-mariadb}"
DRY_RUN="${DRY_RUN:-0}"
MAXCTRL_PASSWORD="${MAXCTRL_PASSWORD:-mariadb}"
MAXCTRL_BIN=/usr/local/bin/maxctrl

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[CẢNH BÁO]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[LỖI]\033[0m %s\n' "$*" >&2; exit 1; }

# Đọc giá trị của một biến dạng `ten: "gia tri"` trong group_vars
read_var() {
  [ -f "$GROUP_VARS" ] || return 0
  grep -E "^$1:" "$GROUP_VARS" | head -1 \
    | sed -E "s/^[^:]+:[[:space:]]*//; s/[[:space:]]+#.*\$//; s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/"
}

# Gán ROOT_PASSWORD cho script gọi. Thoát script nếu không xác định được mật khẩu.
require_root_password() {
  ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-$(read_var mariadb_admin_pass)}"
  case "$ROOT_PASSWORD" in
    ''|'!vault'*)
      if [ "$DRY_RUN" = 1 ]; then
        ROOT_PASSWORD='dry-run-password'
      else
        die "Không đọc được mật khẩu root từ $GROUP_VARS. Đặt biến môi trường MARIADB_ROOT_PASSWORD (ví dụ: export MARIADB_ROOT_PASSWORD='...')."
      fi
      ;;
  esac
}

# Bọc một chuỗi trong nháy đơn, an toàn khi truyền qua shell từ xa
shq() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

# Chạy ansible trong thư mục ansible-mariadb (có ansible.cfg và inventory). Hỗ trợ DRY_RUN.
run_ansible() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[DRY-RUN] (cd %s && ansible' "$ANSIBLE_DIR"
    printf ' %q' "$@"
    printf ')\n'
    return 0
  fi
  command -v ansible >/dev/null 2>&1 || die "Không thấy lệnh ansible trên máy này. Chạy script trên bastion đã cài Ansible."
  [ -d "$ANSIBLE_DIR" ] || die "Không thấy thư mục $ANSIBLE_DIR (đặt biến ANSIBLE_DIR)."
  (cd "$ANSIBLE_DIR" && ansible "$@")
}

# node_script <host-pattern> <file-script> [tham-số...]: copy script lên node và chạy bằng quyền root
node_script() {
  local pattern=$1 file=$2 args="" a
  shift 2
  for a in "$@"; do args+=" $(shq "$a")"; done
  run_ansible "$pattern" -b -m script -a "$file$args"
}

# Giống node_script nhưng in kết quả một dòng mỗi node (dùng để bắt giá trị trả về)
node_script_oneline() {
  local pattern=$1 file=$2 args="" a
  shift 2
  for a in "$@"; do args+=" $(shq "$a")"; done
  run_ansible "$pattern" -b -o -m script -a "$file$args"
}

# shell_all <host-pattern> <lệnh>: chạy một lệnh shell trên các node bằng quyền root
shell_on() { run_ansible "$1" -b -m shell -a "$2"; }

# Danh sách host của nhóm inventory, mỗi host một dòng, đúng thứ tự trong inventory
list_hosts() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "${DRY_HOSTS:-mariadb-node1 mariadb-node2 mariadb-node3}" | tr ' ' '\n'
    return 0
  fi
  run_ansible "$INVENTORY_GROUP" --list-hosts | sed '1d' | tr -d ' '
}

# Số thứ tự (bắt đầu từ 1) của host trong inventory, khớp với tên server_N của MaxScale
host_index() {
  list_hosts | awk -v h="$1" '$0 == h { print NR; exit }'
}

# Chạy lệnh maxctrl trên TẤT CẢ node (mỗi node có một MaxScale độc lập)
maxctrl_on_all() {
  [ "${NO_MAXSCALE:-0}" = 1 ] && return 0
  shell_on "$INVENTORY_GROUP" "$MAXCTRL_BIN -u admin -p $(shq "$MAXCTRL_PASSWORD") $*"
}

confirm() {
  [ "${YES:-0}" = 1 ] && return 0
  local answer
  read -r -p "$1 [gõ yes để tiếp tục]: " answer
  [ "$answer" = yes ] || die "Đã hủy."
}

# Đường dẫn tuyệt đối của script đang chạy (để copy lên node)
self_path() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
