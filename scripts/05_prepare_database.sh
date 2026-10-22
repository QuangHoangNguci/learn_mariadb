#!/bin/bash

# Tạo DB rỗng bằng mariadb-install-db.
# Không đặt mật khẩu root, không import schema, không tạo user.

set -euo pipefail

cd "$(dirname "$0")"

source ../configs/cluster.env
source ./common.sh

check_root
log "===== START PREPARE DATABASE (EMPTY DATADIR) ====="

validate_cluster_env

MODE="${INSTALL_MODE:-fresh}"
log "Installation Mode: $MODE"

for id in "${INSTANCE_IDS[@]}"; do

    INSTALL_DIR="$(get_install_dir "$id")"
    USER="$(get_instance_user "$id")"
    SVC="$(get_service_name "$id")"
    CONF_FILE="$(get_conf_file "$id")"
    DATA_DIR="$(get_data_dir "$id")"
    INSTALL_DB="${INSTALL_DIR}/scripts/mariadb-install-db"

    log "===== INIT DB INSTANCE $id ====="

    if [ ! -d "$INSTALL_DIR" ]; then
        warn "Instance $id chua co binary -> skip"
        continue
    fi
    if [ ! -f "$CONF_FILE" ]; then
        warn "Instance $id chua co config $CONF_FILE -> skip"
        continue
    fi

    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        if [ "$MODE" == "fresh" ]; then
            die "Instance $id ($SVC) dang chay! Stop truoc khi init: systemctl stop $SVC"
        else
            log "Instance $id dang chay (expand) -> skip init"
            continue
        fi
    fi

    # Đã init trước đó
    if [ -d "$DATA_DIR/mysql" ]; then
        log "Instance $id da init truoc do ($DATA_DIR/mysql ton tai) -> skip"
        continue
    fi

    require_file "$INSTALL_DB" "$CONF_FILE"

    ensure_dir "$DATA_DIR"

    # Data dir còn file rác
    if [ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
        [ "$DATA_DIR" != "/" ] || die "CRITICAL: DATA_DIR la root, abort"

        FILE_COUNT=$(ls -A "$DATA_DIR" | wc -l)
        warn "Data dir $DATA_DIR co $FILE_COUNT file/dir nhung khong co 'mysql' schema"

        if [ "$MODE" == "fresh" ]; then
            warn "Fresh mode: wipe data dir..."
            rm -rf "${DATA_DIR:?}"/*
        else
            die "Expand mode: tu choi xoa du lieu bat thuong. Kiem tra thu cong truoc khi tiep tuc."
        fi
    fi

    log "Initializing empty database for instance $id..."
    "$INSTALL_DB" \
        --user="$USER" \
        --datadir="$DATA_DIR" \
        --basedir="$INSTALL_DIR" \
        --defaults-file="$CONF_FILE" \
        || die "Init DB failed for instance $id"

    chown -R "$USER:$USER" "$DATA_DIR"
    chmod 750 "$DATA_DIR"

    log "Instance $id: DB rong san sang (chua co user/password)"
done

log ""
log "===== DONE PREPARE DATABASE ====="
log ""
log "DB rong da san sang. Cac viec tiep theo BAN TU LAM TAY:"
log "  1) sudo systemctl start <service>   (xem ten service o script 04)"
log "  2) sudo systemctl enable <service>  (neu muon auto-start khi reboot)"
log "  3) Set root password / tao app users / setup slave..."
log ""
log "Vi du connect:"
for id in "${INSTANCE_IDS[@]}"; do
    INSTALL_DIR="$(get_install_dir "$id")"
    DATA_DIR="$(get_data_dir "$id")"
    log "  ${INSTALL_DIR}/bin/mariadb -u root -S ${DATA_DIR}/mariadb.sock"
done
