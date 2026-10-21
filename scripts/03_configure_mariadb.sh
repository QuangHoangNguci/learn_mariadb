#!/bin/bash

set -euo pipefail
# Dam bao dir moi tao co quyen 755 (others co x de traverse).
# Tranh truong hop /etc/login.defs UMASK=077 lam parent dir /u01/data_<ID> mode 700.
umask 022

cd "$(dirname "$0")"

source ../configs/cluster.env
source ./common.sh
source ./lib/render_mycnf.sh

check_root
log "===== START CONFIGURE MARIADB (MULTI INSTANCE) ====="

validate_cluster_env

MODE="${INSTALL_MODE:-fresh}"
log "Topology: $TOPOLOGY ($(topology_desc))"
log "Installation Mode: $MODE"

# ========================
# DEPENDENCIES
# ========================

ldconfig -p | grep -q jemalloc || die "Missing jemalloc"
command -v numactl >/dev/null 2>&1 || die "Missing numactl"

# Host resources (de compute_tune_for_id khong phai goi free/nproc moi instance)
HOST_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
HOST_CPU=$(nproc)
export HOST_RAM_MB HOST_CPU
log "Host: RAM=${HOST_RAM_MB}MB, CPU=${HOST_CPU}, DISK=$(detect_disk_type)"

# Shared read-only group cho Vector. MariaDB van la owner va la tien trinh duy
# nhat ghi log; setgid tren log dir dam bao file moi ke thua group nay.
MARIADB_LOG_GROUP="${MARIADB_LOG_GROUP:-mariadb_log_readers}"
if ! getent group "$MARIADB_LOG_GROUP" >/dev/null 2>&1; then
    groupadd --system "$MARIADB_LOG_GROUP"
fi

if is_galera_enabled; then
    # detect_node_index die som neu IP local khong nam trong CLUSTER_NODES
    detect_node_index
    log "Galera mode: NODE_INDEX=$NODE_INDEX/$NODE_COUNT (local=$LOCAL_CLUSTER_IP), NODE_ROLE=${NODE_ROLE:-bootstrap}"
fi

# ========================
# LOOP INSTANCE
# ========================

for id in "${INSTANCE_IDS[@]}"; do

    log "===== CONFIG INSTANCE $id ====="

    INSTALL_DIR="$(get_install_dir "$id")"
    CONF_FILE="$(get_conf_file "$id")"
    USER="$(get_instance_user "$id")"
    SVC="$(get_service_name "$id")"

    DATA_DIR="$(get_data_dir "$id")"
    TMP_DATA_DIR="$(get_tmp_dir "$id")"
    LOG_DIR_I="$(get_log_dir "$id")"
    BINLOG_DIR="$(get_binlog_dir "$id")"

    if [ ! -d "$INSTALL_DIR" ]; then
        warn "Instance $id chua co binary ($INSTALL_DIR) -> skip"
        continue
    fi

    # Fresh + service active -> tu choi ghi de
    if [ "$MODE" == "fresh" ] && systemctl is-active --quiet "$SVC" 2>/dev/null; then
        die "Instance $id ($SVC) dang chay! Stop truoc khi ghi de config: systemctl stop $SVC"
    fi

    TARGET_CONF_FILE="$CONF_FILE"
    PENDING_NOTICE=0

    if [ "$MODE" == "expand" ] && [ -f "$CONF_FILE" ]; then
        # Recompute buffer pool theo bang moi; chi ghi .new neu khac (tranh dong config dang chay)
        compute_tune_for_id "$id"
        NEW_BP="$TUNE_BP_MB"
        OLD_BP=$(grep -E "^innodb_buffer_pool_size" "$CONF_FILE" 2>/dev/null \
            | grep -oE "[0-9]+" | head -1 || echo "0")

        if [ "${OLD_BP:-0}" = "$NEW_BP" ]; then
            log "Instance $id: config da khop (buffer pool ${NEW_BP}M) -> skip"
            continue
        fi

        TARGET_CONF_FILE="${CONF_FILE}.new"
        PENDING_NOTICE=1
        warn "Instance $id: buffer pool can recompute"
        warn "  Cu:  innodb_buffer_pool_size = ${OLD_BP}M"
        warn "  Moi: innodb_buffer_pool_size = ${NEW_BP}M"
        warn "  Config moi se ghi vao: $TARGET_CONF_FILE (KHONG ghi de $CONF_FILE)"
    fi

    # ========================
    # TAO DIR + PERM
    # ========================

    mkdir -p "$DATA_DIR" "$TMP_DATA_DIR" "$LOG_DIR_I" "$BINLOG_DIR"

    # Parent dir (vd /u01/data_<ID>) phai 755 de mariadb_<ID> traverse vao dir con.
    # Force lai phong khi dir da ton tai voi mode 700 tu lan chay truoc co umask 077.
    for d in "$DATA_DIR" "$TMP_DATA_DIR" "$LOG_DIR_I" "$BINLOG_DIR"; do
        parent="$(dirname "$d")"
        [ "$parent" != "/" ] && chmod 755 "$parent"
    done

    usermod -a -G "$MARIADB_LOG_GROUP" "$USER"

    chown -R "$USER:$USER" "$DATA_DIR" "$TMP_DATA_DIR"
    chmod 750 "$DATA_DIR" "$TMP_DATA_DIR"

    chown "$USER:$MARIADB_LOG_GROUP" "$LOG_DIR_I"
    chmod 2750 "$LOG_DIR_I"
    for log_file in mariadb.error.log mariadb.slow.log innodb_stat.log database_audit.log; do
        log_path="$LOG_DIR_I/$log_file"
        [ -e "$log_path" ] || continue
        chown "$USER:$MARIADB_LOG_GROUP" "$log_path"
        chmod 640 "$log_path"
    done
    if [ -d "$LOG_DIR_I/log_innodb" ]; then
        chown -R "$USER:$MARIADB_LOG_GROUP" "$LOG_DIR_I/log_innodb"
        find "$LOG_DIR_I/log_innodb" -type d -exec chmod 2750 {} +
        find "$LOG_DIR_I/log_innodb" -type f -exec chmod 640 {} +
    fi

    # Binlog co the nam ben trong LOG_DIR nhung khong duoc Vector doc.
    chown -R "$USER:$USER" "$BINLOG_DIR"
    find "$BINLOG_DIR" -type d -exec chmod 750 {} +
    find "$BINLOG_DIR" -type f -exec chmod go-rwx {} +

    # ========================
    # BACKUP CONFIG CU (neu ghi de truc tiep)
    # ========================

    if [ "$TARGET_CONF_FILE" = "$CONF_FILE" ] && [ -f "$CONF_FILE" ]; then
        cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%s)"
    fi

    # ========================
    # RENDER MY.CNF (template + 2 switch galera/dr theo TOPOLOGY)
    # ========================

    render_mycnf "$id" "$TARGET_CONF_FILE"
    chown "$USER:$USER" "$TARGET_CONF_FILE"
    chmod 600 "$TARGET_CONF_FILE"

    log "Instance $id config rendered -> $TARGET_CONF_FILE"
    log "  tune: buffer_pool=${TUNE_BP_MB}M bp_inst=${TUNE_BP_INSTANCES} log_file=${TUNE_LOG_FILE_MB}M io=${TUNE_IO_CAP}/${TUNE_IO_MAX} thread_pool=${TUNE_THREAD_POOL} disk=${TUNE_DISK_TYPE}"

    if [ "$PENDING_NOTICE" -eq 1 ]; then
        warn "===== INSTANCE $id: CAN ROLLING RESTART ====="
        warn "Config moi da ghi vao: $TARGET_CONF_FILE"
        warn "Ap dung khi san sang:"
        warn "  cp $CONF_FILE ${CONF_FILE}.bak.\$(date +%s)"
        warn "  mv $TARGET_CONF_FILE $CONF_FILE"
        warn "  systemctl restart $SVC"
    fi

    # Khong cai /etc/logrotate.d cho error/slow log: daemon logrotate chay root
    # va trung voi rotate_mariadb_log_<ID>.sh cua script 08. Xoa file legacy do
    # project tung sinh; audit log van tu rotate theo server_audit_* trong my.cnf.
    LOGROTATE_FILE="/etc/logrotate.d/$(get_service_name "$id")"
    if [ -f "$LOGROTATE_FILE" ]; then
        rm -f "$LOGROTATE_FILE"
        log "Removed legacy root logrotate config: $LOGROTATE_FILE"
    fi

    log "Instance $id config done"
done

log "===== DONE CONFIGURE MARIADB ====="
