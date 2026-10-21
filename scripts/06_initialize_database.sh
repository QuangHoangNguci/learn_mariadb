#!/bin/bash

# Import schema vsystem + users vao moi instance.
# CHAY TAY (khong nam trong deploy.sh pipeline).
#
# Cach hoat dong:
#   1) Start mariadbd tam (skip-networking, wsrep_on=OFF) qua socket
#   2) Import vsystem.sql + users.sql (sed thay placeholder pass)
#   3) Set root password
#   4) SHUTDOWN
#
# Galera flow:
#   - Bootstrap node: chay 06 SAU 05, TRUOC galera_new_cluster.
#     Khi galera_new_cluster start, cluster da co user galera_<ID>
#     -> joiner SST duoc.
#   - Joiner node: KHONG chay 06. User se sync qua Galera replication.
#
# EMPTY_CLUSTER=true:
#   Chi set root password, KHONG import schema + users.
#   Dung khi data se den tu cum cu qua mariabackup restore.

set -euo pipefail

cd "$(dirname "$0")"

source ../configs/cluster.env
source ./common.sh

check_root
log "===== START INITIALIZE DATABASE (IMPORT SCHEMA + USERS) ====="

validate_cluster_env
validate_passwords_for_init

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA_FILE="$BASE_DIR/setup/mariadb/Install_Mariadb/vsystem.sql"
USER_FILE="$BASE_DIR/setup/mariadb/Install_Mariadb/users.sql"

MODE="${INSTALL_MODE:-fresh}"
log "Installation Mode: $MODE"

if [ "${EMPTY_CLUSTER:-false}" = "true" ]; then
    log "EMPTY_CLUSTER=true: chi set root pass, SKIP schema + users import"
fi

# Replica/DR: data + users se den tu primary qua async replication.
# Import users/schema o day de TRUNG voi du lieu replicate -> khuyen nghi EMPTY_CLUSTER=true.
if is_replica && [ "${EMPTY_CLUSTER:-false}" != "true" ]; then
    warn "TOPOLOGY=$TOPOLOGY (replica): import schema+users co the TRUNG voi data replicate tu primary."
    warn "  Khuyen nghi dat EMPTY_CLUSTER=true (chi set root pass) cho node DR."
    confirm "Van tiep tuc import day du schema + users?" || die "Huy. Dat EMPTY_CLUSTER=true roi chay lai."
fi

# Galera joiner: tu choi chay (data se sync tu bootstrap, khong duoc dong vao)
if is_galera_enabled && [ "${NODE_ROLE:-bootstrap}" = "joiner" ]; then
    die "Galera joiner KHONG duoc chay 06. Schema + users se sync tu bootstrap qua SST."
fi

# Escape password/user values first for an SQL string literal, then for the
# replacement side of sed. This keeps quotes, backslashes, '&' and '|' intact.
sql_literal_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

sed_replacement_escape() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

sql_template_value() {
    local escaped
    escaped="$(sql_literal_escape "$1")"
    sed_replacement_escape "$escaped"
}

declare -a TEMP_PIDS=()

cleanup() {
    for pid in "${TEMP_PIDS[@]:-}"; do
        [ -z "$pid" ] && continue
        if kill -0 "$pid" 2>/dev/null; then
            warn "Cleaning up orphaned process PID: $pid"
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

# ========================
# LOOP INSTANCE
# ========================

for id in "${INSTANCE_IDS[@]}"; do

    log "===== INIT DATA INSTANCE $id ====="

    INSTALL_DIR="$(get_install_dir "$id")"
    USER="$(get_instance_user "$id")"
    SVC="$(get_service_name "$id")"
    DATA_DIR="$(get_data_dir "$id")"
    CONF_FILE="$(get_conf_file "$id")"

    SOCKET="${DATA_DIR}/mariadb.sock"
    MYSQL_BIN="${INSTALL_DIR}/bin/mariadb"
    MYSQLD="${INSTALL_DIR}/bin/mariadbd"

    require_file "$MYSQL_BIN" "$MYSQLD" "$CONF_FILE"

    if [ ! -d "$DATA_DIR/mysql" ]; then
        warn "Instance $id chua qua 05 (thieu $DATA_DIR/mysql) -> skip"
        continue
    fi

    # Galera: neu instance da tung join cluster (co grastate.dat) -> khong dong vao
    if is_galera_enabled && [ -f "$DATA_DIR/grastate.dat" ]; then
        log "Instance $id: grastate.dat ton tai -> da tham gia cluster, skip"
        continue
    fi

    if systemctl is-active --quiet "$SVC"; then
        if [ "$MODE" = "fresh" ]; then
            die "Service $SVC dang chay! Stop truoc khi init: systemctl stop $SVC"
        else
            log "Service $SVC dang chay (expand) -> skip"
            continue
        fi
    fi

    # ------------------------
    # CLEAN OLD SOCKET + LOG
    # ------------------------
    rm -f "$SOCKET" "${DATA_DIR}/init.error.log"

    # ------------------------
    # START TEMP DB (wsrep=OFF, skip-networking)
    # ------------------------
    log "Starting instance $id in standalone safe-mode (wsrep=OFF, skip-networking)"

    "$MYSQLD" \
        --defaults-file="$CONF_FILE" \
        --user="$USER" \
        --datadir="$DATA_DIR" \
        --socket="$SOCKET" \
        --skip-networking \
        --wsrep_on=OFF \
        --log-error="${DATA_DIR}/init.error.log" &

    PID=$!
    TEMP_PIDS+=("$PID")

    # Wait ready (max 90s)
    READY=0
    for t in {1..45}; do
        if "$MYSQL_BIN" -u root -S "$SOCKET" -e "SELECT 1" >/dev/null 2>&1; then
            READY=1
            break
        fi
        sleep 2
    done

    if [ "$READY" -ne 1 ]; then
        die "Instance $id failed to start. Kiem tra ${DATA_DIR}/init.error.log"
    fi

    # ------------------------
    # IMPORT SCHEMA + USERS (skip khi EMPTY_CLUSTER)
    # ------------------------
    if [ "${EMPTY_CLUSTER:-false}" != "true" ]; then

        # Schema vsystem
        EXISTS=$("$MYSQL_BIN" -u root -S "$SOCKET" -Nse "SHOW DATABASES LIKE 'vsystem';" || true)
        if [ "$EXISTS" = "vsystem" ]; then
            log "Schema vsystem da ton tai trong instance $id -> skip schema import"
        else
            if [ -f "$SCHEMA_FILE" ]; then
                log "Importing schema vsystem tu $SCHEMA_FILE..."
                "$MYSQL_BIN" -u root -S "$SOCKET" --init-command="SET sql_log_bin=0" < "$SCHEMA_FILE"
            else
                warn "Schema file $SCHEMA_FILE khong thay -> skip schema import"
            fi
        fi

        # Users (luon chay - users.sql dung CREATE USER IF NOT EXISTS)
        if [ -f "$USER_FILE" ]; then
            GALERA_USER="${GALERA_USER_PREFIX:-galera}"
            GALERA_PASS_FOR_INSTANCE="$(get_instance_galera_pass "$id")"
            MAXSCALE_PASS_FOR_INSTANCE="$(get_instance_maxscale_pass "$id")"
            TMP_USER_SQL="/tmp/users_${id}.sql"

            SQL_GALERA_USER="$(sql_template_value "$GALERA_USER")"
            SQL_GALERA_PASS="$(sql_template_value "$GALERA_PASS_FOR_INSTANCE")"
            SQL_ADMIN_PASS="$(sql_template_value "$ADMIN_PASS")"
            SQL_COMMON_PASS="$(sql_template_value "$COMMON_PASS")"
            SQL_MAXSCALE_PASS="$(sql_template_value "$MAXSCALE_PASS_FOR_INSTANCE")"

            log "Sinh users SQL cho instance $id (galera_user=$GALERA_USER)..."

            sed -e "s|\${GALERA_USER}|${SQL_GALERA_USER}|g" \
                -e "s|\${GALERA_PASS}|${SQL_GALERA_PASS}|g" \
                -e "s|\${ADMIN_PASS}|${SQL_ADMIN_PASS}|g" \
                -e "s|\${COMMON_PASS}|${SQL_COMMON_PASS}|g" \
                -e "s|\${MAXSCALE_PASS}|${SQL_MAXSCALE_PASS}|g" \
                "$USER_FILE" > "$TMP_USER_SQL"

            log "Importing users tu $TMP_USER_SQL..."
            "$MYSQL_BIN" -u root -S "$SOCKET" < "$TMP_USER_SQL"

            rm -f "$TMP_USER_SQL"
        else
            warn "User file $USER_FILE khong thay -> skip user import"
        fi
    fi

    # ------------------------
    # SET ROOT PASSWORD (luon chay)
    # ------------------------
    log "Set root@localhost password..."
    ADMIN_PASS_SQL="$(sql_literal_escape "$ADMIN_PASS")"
    "$MYSQL_BIN" -u root -S "$SOCKET" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ADMIN_PASS_SQL}';
FLUSH PRIVILEGES;
EOF

    # ------------------------
    # SHUTDOWN
    # ------------------------
    log "Stopping instance $id safe-mode..."
    MYSQL_PWD="${ADMIN_PASS}" "$MYSQL_BIN" -u root -S "$SOCKET" -e "SHUTDOWN;" 2>/dev/null || true

    sleep 2

    # Xoa PID khoi danh sach theo doi
    NEW_PIDS=()
    for p in "${TEMP_PIDS[@]:-}"; do
        [ "$p" != "$PID" ] && NEW_PIDS+=("$p")
    done
    TEMP_PIDS=("${NEW_PIDS[@]+"${NEW_PIDS[@]}"}")

    if kill -0 "$PID" 2>/dev/null; then
        kill -9 "$PID" 2>/dev/null || true
    fi
    wait "$PID" 2>/dev/null || true

    log "Instance $id init complete"
done

log ""
log "===== DONE INITIALIZE DATABASE ====="
log ""
if is_galera_enabled && [ "${NODE_ROLE:-bootstrap}" = "bootstrap" ]; then
    log "Galera bootstrap node - schema + users da san sang."
    log "Buoc tiep theo:"
    for id in "${INSTANCE_IDS[@]}"; do
        log "  sudo galera_new_cluster --defaults-file=$(get_conf_file "$id")"
    done
    log "Sau khi cluster size=1, start joiner -> Galera tu sync user + schema sang."
elif ! is_galera_enabled; then
    log "Standalone - DB co user va schema. Start service:"
    for id in "${INSTANCE_IDS[@]}"; do
        log "  sudo systemctl start $(get_service_name "$id")"
    done
fi
