#!/bin/bash

# Sinh /etc/systemd/system/mariadb_<ID>.service cho mỗi instance.
# KHÔNG enable, KHÔNG start: người dùng tự làm thủ công sau khi 05 xong.

set -euo pipefail

cd "$(dirname "$0")"

source ../configs/cluster.env
source ./common.sh

check_root
log "===== START GENERATE MARIADB SYSTEMD UNITS ====="

validate_cluster_env

MODE="${INSTALL_MODE:-fresh}"
log "Installation Mode: $MODE"

JEMALLOC_PATH=$(ldconfig -p | grep jemalloc | head -n1 | awk '{print $NF}' || true)
[ -n "$JEMALLOC_PATH" ] || warn "jemalloc khong tim thay - bo qua LD_PRELOAD"

# Fresh: hỏi xác nhận trước khi disable MariaDB mặc định của OS
if [ "$MODE" == "fresh" ]; then
    OS_ENABLED=""
    for svc in mariadb mysql mysqld; do
        if systemctl is-enabled "$svc" >/dev/null 2>&1; then
            OS_ENABLED="$OS_ENABLED $svc"
        fi
    done
    if [ -n "$OS_ENABLED" ]; then
        echo ""
        echo "[CANH BAO] Phat hien default service:$OS_ENABLED dang enabled."
        echo "  Fresh mode se disable + stop cac service tren."
        read -rp "Tiep tuc? (yes/no): " CONFIRM
        [ "$CONFIRM" == "yes" ] || die "Da huy."

        for svc in $OS_ENABLED; do
            systemctl stop    "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        done
    fi
fi

log "Reload systemd daemon"
systemctl daemon-reload

for id in "${INSTANCE_IDS[@]}"; do
    INSTALL_DIR="$(get_install_dir "$id")"
    USER="$(get_instance_user "$id")"
    CONF_FILE="$(get_conf_file "$id")"
    SVC="$(get_service_name "$id")"
    SERVICE_FILE="/etc/systemd/system/${SVC}.service"

    if [ ! -d "$INSTALL_DIR" ]; then
        warn "Instance $id chua co binary -> skip"
        continue
    fi
    if [ ! -f "$CONF_FILE" ]; then
        warn "Instance $id chua co config $CONF_FILE -> skip"
        continue
    fi

    if [ -f "$SERVICE_FILE" ]; then
        if [ "$MODE" == "expand" ]; then
            log "Service $SVC da ton tai (expand mode) -> skip"
            continue
        fi
        warn "Service $SVC da ton tai - backup va ghi de"
        backup_file "$SERVICE_FILE"
    fi

    LD_PRELOAD_LINE=""
    [ -n "$JEMALLOC_PATH" ] && LD_PRELOAD_LINE="Environment=\"LD_PRELOAD=$JEMALLOC_PATH\""

    GALERA_RECOVERY_LINES=""
    GALERA_EXEC_TAIL=""

    if is_galera_enabled; then
        # Tarball build sẵn với prefix /usr/local/mysql nên các script wsrep/galera trong bin/
        # hardcode đường dẫn theo prefix đó (mariadbd, my_print_defaults, mariabackup...) -> sai
        # khi extract vào $INSTALL_DIR:
        #   - galera_recovery (ExecStartPre) -> service không start
        #   - wsrep_sst_* (SST/IST) -> joiner không sync
        # Đổi /usr/local/mysql/bin -> $INSTALL_DIR/bin (idempotent), patch cả nhóm helper.
        for _h in galera_recovery galera_new_cluster wsrep_sst_common \
                  wsrep_sst_mariabackup wsrep_sst_rsync wsrep_sst_mysqldump; do
            _hf="$INSTALL_DIR/bin/$_h"
            [ -f "$_hf" ] && sed -i "s|/usr/local/mysql/bin|$INSTALL_DIR/bin|g" "$_hf"
        done
        # Đảm bảo dòng print_defaults của galera_recovery trỏ đúng
        GR_BIN="$INSTALL_DIR/bin/galera_recovery"
        [ -f "$GR_BIN" ] && sed -i "s|^print_defaults=.*|print_defaults=\"$INSTALL_DIR/bin/my_print_defaults\"|" "$GR_BIN"
        log "Patched wsrep/galera helper scripts (build-prefix -> $INSTALL_DIR/bin)"

        # Service file cần dạng: VAR=`.../galera_recovery`; [ $? -eq 0 ] && echo _WSREP_START_POSITION=$VAR ...
        # Quy tắc heredoc (GRP không quote):
        #   \\ -> \ (giữ cho systemd nối dòng cuối dòng)
        #   \` -> ` (backtick literal cho sh command substitution)
        #   \$ -> $ (dollar literal cho sh expand $? và $VAR)
        GALERA_RECOVERY_LINES=$(cat <<GRP
EnvironmentFile=-/tmp/wsrep-new-cluster_${id}
EnvironmentFile=-/tmp/wsrep-start-position_${id}

ExecStartPre=/bin/sh -c "[ ! -e $INSTALL_DIR/bin/galera_recovery ] && VAR= || \\
 VAR=\`$INSTALL_DIR/bin/galera_recovery\`; [ \$? -eq 0 ] \\
 && echo _WSREP_START_POSITION=\$VAR > /tmp/wsrep-start-position_${id} || exit 1"
GRP
)
        GALERA_EXEC_TAIL=' $_WSREP_NEW_CLUSTER $_WSREP_START_POSITION'
    fi

    cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=MariaDB Instance ${id} (port=${INSTANCE_PORT[$id]})
Documentation=man:mariadbd(8)
After=network.target

[Service]
User=$USER
Group=$USER
SupplementaryGroups=${MARIADB_LOG_GROUP:-mariadb_log_readers}
UMask=0027

$LD_PRELOAD_LINE

$GALERA_RECOVERY_LINES

ExecStart=/usr/bin/numactl --interleave=all $INSTALL_DIR/bin/mariadbd \\
 \$MYSQLD_OPTS \\
 --defaults-file=$CONF_FILE \\
 --basedir=$INSTALL_DIR${GALERA_EXEC_TAIL}

TimeoutStartSec=9000
TimeoutStopSec=9000
Restart=on-failure
RestartSec=5
LimitNOFILE=${MAX_OPEN_FILES:-1000000}

[Install]
WantedBy=multi-user.target
SVCEOF
    chmod 644 "$SERVICE_FILE"
    log "Generated $SERVICE_FILE"
done

log "Reload systemd daemon"
systemctl daemon-reload

log ""
log "Cac service da duoc tao nhung CHUA enable / CHUA start."
if is_galera_enabled; then
    log "Galera mode (NODE_ROLE=$NODE_ROLE). Sau khi 05 xong:"
    if [ "${NODE_ROLE:-bootstrap}" = "bootstrap" ]; then
        log "  Bootstrap node - khoi tao cluster moi cho moi instance:"
        for id in "${INSTANCE_IDS[@]}"; do
            log "    sudo galera_new_cluster --defaults-file=$(get_conf_file "$id")"
        done
        log "  Sau do o cac joiner node:"
        log "    sudo systemctl start mariadb_<ID>"
    else
        log "  Joiner node - data se tu sync tu bootstrap:"
        for id in "${INSTANCE_IDS[@]}"; do
            log "    sudo systemctl start $(get_service_name "$id")"
        done
    fi
else
    log "Sau khi 05 (init datadir) xong, chay tay:"
    for id in "${INSTANCE_IDS[@]}"; do
        log "  sudo systemctl start  $(get_service_name "$id")"
    done
fi

log "===== DONE GENERATE MARIADB SYSTEMD UNITS ====="
