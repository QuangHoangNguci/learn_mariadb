#!/bin/bash

# Import schema vsystem + users vào mỗi instance.
# Chạy tay (không nằm trong pipeline deploy.sh).
#
# Cách hoạt động:
#   1) Start mariadbd tạm (skip-networking, wsrep_on=OFF) qua socket
#   2) Import vsystem.sql + users.sql (sed thay placeholder mật khẩu)
#   3) Đặt mật khẩu root
#   4) SHUTDOWN
#
# Galera:
#   - Node bootstrap: chạy 06 sau 05, trước galera_new_cluster.
#     Cluster đã có user galera_<ID> nên joiner SST được.
#   - Node joiner: không chạy 06, user được sync qua Galera replication.
#
# EMPTY_CLUSTER=true:
#   Chỉ đặt mật khẩu root, không import schema + users.
#   Dùng khi data đến từ cụm cũ qua mariabackup restore.

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

# Replica/DR: data + users đến từ primary qua async replication,
# import ở đây dễ trùng -> nên dùng EMPTY_CLUSTER=true.
if is_replica && [ "${EMPTY_CLUSTER:-false}" != "true" ]; then
    warn "TOPOLOGY=$TOPOLOGY (replica): import schema+users co the TRUNG voi data replicate tu primary."
    warn "  Khuyen nghi dat EMPTY_CLUSTER=true (chi set root pass) cho node DR."
    confirm "Van tiep tuc import day du schema + users?" || die "Huy. Dat EMPTY_CLUSTER=true roi chay lai."
fi

# Joiner: từ chối chạy vì data sẽ sync từ bootstrap, không được can thiệp
if is_galera_enabled && [ "${NODE_ROLE:-bootstrap}" = "joiner" ]; then
    die "Galera joiner KHONG duoc chay 06. Schema + users se sync tu bootstrap qua SST."
fi

# Escape giá trị cho SQL string literal trước, rồi cho vế thay thế của sed,
# để giữ nguyên dấu nháy, backslash, '&' và '|'.
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

    # Đã từng join cluster (có grastate.dat) thì không đụng vào
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

    rm -f "$SOCKET" "${DATA_DIR}/init.error.log"

    # Start DB tạm: wsrep=OFF, skip-networking để không ảnh hưởng cluster
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

    # Chờ sẵn sàng (tối đa 90s)
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

    # Bỏ qua import khi EMPTY_CLUSTER
    if [ "${EMPTY_CLUSTER:-false}" != "true" ]; then

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

        # Luôn chạy vì users.sql dùng CREATE USER IF NOT EXISTS
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

    # Đặt mật khẩu root (luôn chạy)
    log "Set root@localhost password..."
    ADMIN_PASS_SQL="$(sql_literal_escape "$ADMIN_PASS")"
    "$MYSQL_BIN" -u root -S "$SOCKET" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ADMIN_PASS_SQL}';
FLUSH PRIVILEGES;
EOF

    log "Stopping instance $id safe-mode..."
    MYSQL_PWD="${ADMIN_PASS}" "$MYSQL_BIN" -u root -S "$SOCKET" -e "SHUTDOWN;" 2>/dev/null || true

    sleep 2

    # Bỏ PID khỏi danh sách theo dõi của cleanup
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
