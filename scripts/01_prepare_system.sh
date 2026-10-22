#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

source ../configs/cluster.env
source ./common.sh

check_root
log "===== START PREPARE SYSTEM (OFFLINE MODE) ====="

validate_cluster_env

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$BASE_DIR/package/os"
SYSCTL_FILE="/etc/sysctl.d/99-mariadb-tuning.conf"

MODE="${INSTALL_MODE:-fresh}"

# Phát hiện hệ điều hành

if grep -qi ubuntu /etc/os-release; then
    OS="ubuntu"
elif grep -qiE "centos|rhel" /etc/os-release; then
    OS="centos"
else
    die "He dieu hanh khong duoc ho tro"
fi
log "Detected OS: $OS"

# Fresh mode: hỏi xác nhận trước khi dừng/gỡ MariaDB của OS
if [ "$MODE" == "fresh" ]; then
    # Tìm MariaDB/MySQL của OS đang chạy
    OS_DB_ACTIVE=""
    for svc in mariadb mysql mysqld; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            OS_DB_ACTIVE="$OS_DB_ACTIVE $svc"
        fi
    done

    if [ -n "$OS_DB_ACTIVE" ] || [ -d /etc/mysql ] || dpkg -l 2>/dev/null | grep -qE "^ii  (mariadb|mysql)-(client|server|common)"; then
        echo ""
        echo "[CANH BAO] Fresh mode se thuc hien cac thao tac sau:"
        [ -n "$OS_DB_ACTIVE" ] && echo "  - systemctl stop + disable:$OS_DB_ACTIVE"
        [ -d /etc/mysql ]       && echo "  - rm -rf /etc/mysql"
        echo "  - dpkg --purge: mariadb-client, mariadb-client-core, mariadb-common (neu co)"
        echo ""
        read -rp "Tiep tuc? (yes/no): " CONFIRM
        if [ "$CONFIRM" != "yes" ]; then
            die "Da huy."
        fi
    fi

    rm -rf /etc/mysql 2>/dev/null || true
    for svc in mariadb mysql mysqld; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done

    dpkg --remove --force-all mariadb-client mariadb-client-core mariadb-common 2>/dev/null || true
    dpkg --purge  --force-all mariadb-client mariadb-client-core mariadb-common 2>/dev/null || true
else
    log "Expand mode -> bo qua clean MySQL conflict de bao ve instance dang chay"
fi

# Gỡ ufw (Ubuntu) để dùng iptables trực tiếp

if [ "$OS" = "ubuntu" ]; then
    if dpkg -l 2>/dev/null | grep -q "^ii  ufw"; then
        log "Dang go bo ufw"
        systemctl stop ufw 2>/dev/null || true
        dpkg --remove --force-all ufw || true
        dpkg --purge  --force-all ufw || true
        rm -rf /etc/ufw /lib/ufw || true
    fi
fi

# Cài các gói .deb offline
install_packages() {
    [ -d "$PACKAGE_DIR" ] || { warn "Khong tim thay $PACKAGE_DIR -> bo qua dpkg"; return 0; }
    ls "$PACKAGE_DIR"/*.deb >/dev/null 2>&1 || { warn "Khong co .deb trong $PACKAGE_DIR -> bo qua"; return 0; }

    if [ "$MODE" == "expand" ] \
       && ldconfig -p | grep -q jemalloc \
       && command -v numactl >/dev/null 2>&1; then
        log "Expand mode: jemalloc + numactl da co -> skip dpkg install"
        return 0
    fi

    log "Cai package offline tu $PACKAGE_DIR"

    # Bỏ các gói dễ xung đột với MySQL/MariaDB đã có trên máy
    local skip_regex='mysql-common|mariadb-common|libmariadb3'
    mapfile -t DEB_FILES < <(ls "$PACKAGE_DIR"/*.deb 2>/dev/null | grep -Ev "/($skip_regex)")
    [ "${#DEB_FILES[@]}" -gt 0 ] || die "Khong co .deb hop le sau khi loc skip-list"

    # Cài kiểu chịu lỗi: gói lỗi chỉ warn; sau đó kiểm tra gói critical, thiếu mới die
    set +e
    local dpkg_out
    dpkg_out=$(dpkg -i "${DEB_FILES[@]}" 2>&1)
    local dpkg_rc=$?
    set -e

    echo "$dpkg_out" | tee -a "$LOG_FILE_CLUSTER" >/dev/null

    if [ "$dpkg_rc" -ne 0 ]; then
        # Lấy tên gói lỗi từ output dpkg
        local failed_pkgs
        failed_pkgs=$(echo "$dpkg_out" | grep -E "Errors were encountered while processing:" -A 50 \
                      | tail -n +2 | sed 's|^ */.*/||; s/\.deb$//' \
                      | grep -v '^$' || true)

        warn "dpkg ket thuc voi exit=$dpkg_rc. Cac goi bi loi:"
        if [ -n "$failed_pkgs" ]; then
            echo "$failed_pkgs" | while read -r pkg; do
                warn "  - $pkg"
            done
        else
            warn "  (khong trich xuat duoc, xem log o tren)"
        fi

        # Thử sửa dependency
        dpkg --configure -a 2>&1 | tee -a "$LOG_FILE_CLUSTER" >/dev/null || true
    else
        dpkg --configure -a
        log "Cai dat package thanh cong (${#DEB_FILES[@]} goi)"
    fi

    # Kiểm tra gói bắt buộc: jemalloc (LD_PRELOAD), numactl (ExecStart), iptables.
    # Các gói khác không critical cho bước 01..05.
    local critical_missing=0
    if ! ldconfig -p | grep -q jemalloc; then
        error "CRITICAL: jemalloc khong tim thay - MariaDB se khong start duoc voi LD_PRELOAD"
        critical_missing=1
    fi
    if ! command -v numactl >/dev/null 2>&1; then
        error "CRITICAL: numactl khong tim thay - systemd ExecStart se fail"
        critical_missing=1
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        error "CRITICAL: iptables khong tim thay - khong the apply firewall rules"
        critical_missing=1
    fi

    if [ "$critical_missing" -eq 1 ]; then
        die "Thieu goi critical. Tham khao log de xem .deb nao bi reject va vi sao."
    fi

    if [ "$dpkg_rc" -ne 0 ]; then
        log "Critical deps OK. Cac goi loi o tren la KHONG critical - tiep tuc."
    fi
}

install_packages

# Xóa rule iptables trùng, rồi thêm rule mới
iptables-save | awk '
/^COMMIT$/ { delete x; }
!x[$0]++
' | iptables-restore

apply_rule() {
    iptables -C $1 2>/dev/null || iptables -A $1
}

[ -n "${SYSLOG_IP:-}" ] && apply_rule "OUTPUT -d $SYSLOG_IP -p udp --dport 514 -j ACCEPT"
[ -n "${NTP_IP:-}"    ] && apply_rule "OUTPUT -d $NTP_IP    -p udp --dport 123 -j ACCEPT"
[ -n "${DNS_IP:-}"    ] && apply_rule "OUTPUT -d $DNS_IP    -p udp --dport 53  -j ACCEPT"

if [ -n "${MGMT_NODES:-}" ]; then
    for MGMT in $MGMT_NODES; do
        apply_rule "INPUT -s $MGMT -p tcp --dport 22 -j ACCEPT"
        for id in "${INSTANCE_IDS[@]}"; do
            apply_rule "INPUT -s $MGMT -p tcp --dport ${INSTANCE_PORT[$id]} -j ACCEPT"
            apply_rule "INPUT -s $MGMT -p tcp --dport ${INSTANCE_MGNT[$id]} -j ACCEPT"
        done
    done
fi

# PRIMARY_NODES: cho phép replication binlog giữa primary và DR
if [ -n "${PRIMARY_NODES:-}" ]; then
    for NODE in $PRIMARY_NODES; do
        apply_rule "INPUT  -s $NODE -j ACCEPT"
        apply_rule "OUTPUT -d $NODE -j ACCEPT"
    done
fi

# Galera: cho phép WSREP/SST/IST giữa các node
if is_galera_enabled; then
    log "Galera enabled -> mo iptables WSREP ports cho CLUSTER_NODES"
    for NODE in $CLUSTER_NODES; do
        apply_rule "INPUT  -s $NODE -j ACCEPT"
        apply_rule "OUTPUT -d $NODE -j ACCEPT"
    done
fi

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

# Tinh chỉnh kernel (sysctl) theo RAM/CPU

RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
CPU=$(nproc)

MAX_CONN=$((CPU * 50))
[ $MAX_CONN -gt 500 ] && MAX_CONN=500

MIN_FREE_KB=$(awk "BEGIN {printf \"%d\", $RAM_MB*1024*0.015}")
FILE_MAX=$((MAX_CONN * 200))
[ $FILE_MAX -lt 100000 ] && FILE_MAX=100000

cat <<EOF > "$SYSCTL_FILE"
# MariaDB AUTO Tuning - Generated at $(date)
vm.swappiness=1
fs.file-max=$FILE_MAX
vm.min_free_kbytes=$MIN_FREE_KB
EOF

sysctl -p "$SYSCTL_FILE"

# Giới hạn nofile theo user (khớp open_files_limit trong my.cnf)
NOFILE="${MAX_OPEN_FILES:-1000000}"

# Xóa entry cũ của mariadb/mariadb_<số>, giữ nguyên user khác
sed -i "/^${INSTANCE_NAME_PREFIX:-mariadb}\(_[0-9]\+\)\?[[:space:]]/d" /etc/security/limits.conf

{
    for id in "${INSTANCE_IDS[@]}"; do
        IUSER="$(get_instance_user "$id")"
        echo "${IUSER} soft nofile $NOFILE"
        echo "${IUSER} hard nofile $NOFILE"
    done
} >> /etc/security/limits.conf

# Tắt Transparent Huge Pages

if [ "${ENABLE_THP_DISABLE:-false}" == "true" ]; then
    log "Disable Transparent Huge Pages (THP)..."
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled
        echo never > /sys/kernel/mm/transparent_hugepage/defrag
    fi

    THP_SERVICE="/etc/systemd/system/disable-thp.service"
    if [ ! -f "$THP_SERVICE" ]; then
        cat > "$THP_SERVICE" <<'THPEOF'
[Unit]
Description=Disable Transparent Huge Pages (for MariaDB)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
THPEOF
        systemctl daemon-reload
        systemctl enable disable-thp.service 2>/dev/null || true
    fi
fi

# NUMA: tắt zone reclaim

if [ "${ENABLE_NUMA_DISABLE:-false}" == "true" ]; then
    log "Set vm.zone_reclaim_mode=0 cho database workload"
    [ -f /proc/sys/vm/zone_reclaim_mode ] && echo 0 > /proc/sys/vm/zone_reclaim_mode

    if ! grep -q "vm.zone_reclaim_mode" "$SYSCTL_FILE" 2>/dev/null; then
        echo "vm.zone_reclaim_mode=0" >> "$SYSCTL_FILE"
        sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
    fi
fi

ldconfig

log "===== DONE PREPARE SYSTEM ====="
