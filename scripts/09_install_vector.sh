#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

source ../configs/cluster.env
source ./common.sh

check_root
log "===== START INSTALL VECTOR SERVICE (MULTI INSTANCE) ====="

# Populate INSTANCE_IDS... tu cau hinh instance
validate_cluster_env

# ========================
# PATH SETUP
# ========================

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VECTOR_SRC_DIR="${BASE_DIR}/setup/mariadb/Install_Mariadb/scripts_vector"
VECTOR_PKG_DIR="${BASE_DIR}/package/vector"

VECTOR_INSTALL_DIR="/u01/apps/vector_mariadb"
VECTOR_BIN="${VECTOR_INSTALL_DIR}/vector"
VECTOR_YAML="${VECTOR_INSTALL_DIR}/vector.yaml"
VECTOR_CHECKPOINT_DIR="${VECTOR_INSTALL_DIR}/vector-check-points"

SERVICE_NAME="vector_mariadb"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
VECTOR_USER="${VECTOR_OS_USER:-vector_mariadb}"
VECTOR_GROUP="${VECTOR_OS_GROUP:-vector_mariadb}"
MARIADB_LOG_GROUP="${MARIADB_LOG_GROUP:-mariadb_log_readers}"

# Vector chi can doc MariaDB log va ghi checkpoint cua chinh no.
if ! getent group "$MARIADB_LOG_GROUP" >/dev/null 2>&1; then
    groupadd --system "$MARIADB_LOG_GROUP"
fi
if ! getent group "$VECTOR_GROUP" >/dev/null 2>&1; then
    groupadd --system "$VECTOR_GROUP"
fi
if ! id "$VECTOR_USER" >/dev/null 2>&1; then
    NOLOGIN_SHELL="$(command -v nologin 2>/dev/null || true)"
    NOLOGIN_SHELL="${NOLOGIN_SHELL:-/usr/sbin/nologin}"
    useradd --system --no-create-home --home-dir "$VECTOR_INSTALL_DIR" \
        --shell "$NOLOGIN_SHELL" --gid "$VECTOR_GROUP" "$VECTOR_USER"
fi
usermod -a -G "$MARIADB_LOG_GROUP" "$VECTOR_USER"

# ========================
# CREATE INSTALL DIR
# ========================

step "Prepare install directory"
ensure_dir "$VECTOR_INSTALL_DIR"
ensure_dir "$VECTOR_CHECKPOINT_DIR"
ensure_dir "/log/apps/vector_mariadb"
ensure_parents_traversable "$VECTOR_INSTALL_DIR"
ensure_parents_traversable "/log/apps/vector_mariadb"

chown root:"$VECTOR_GROUP" "$VECTOR_INSTALL_DIR"
chmod 750 "$VECTOR_INSTALL_DIR"
chown -R "$VECTOR_USER:$VECTOR_GROUP" "$VECTOR_CHECKPOINT_DIR" "/log/apps/vector_mariadb"
chmod 700 "$VECTOR_CHECKPOINT_DIR"
chmod 750 "/log/apps/vector_mariadb"

# Retrofit quyen doc cho log da ton tai. Khong mo quyen binlog/datadir.
for id in "${INSTANCE_IDS[@]}"; do
    INSTANCE_USER="$(get_instance_user "$id")"
    INSTANCE_LOG_DIR="$(get_log_dir "$id")"
    id "$INSTANCE_USER" >/dev/null 2>&1 || die "Thieu MariaDB OS user: $INSTANCE_USER"
    usermod -a -G "$MARIADB_LOG_GROUP" "$INSTANCE_USER"
    ensure_dir "$INSTANCE_LOG_DIR"
    ensure_parents_traversable "$INSTANCE_LOG_DIR"
    chown "$INSTANCE_USER:$MARIADB_LOG_GROUP" "$INSTANCE_LOG_DIR"
    chmod 2750 "$INSTANCE_LOG_DIR"

    for log_file in mariadb.error.log mariadb.slow.log innodb_stat.log database_audit.log; do
        log_path="$INSTANCE_LOG_DIR/$log_file"
        [ -e "$log_path" ] || continue
        chown "$INSTANCE_USER:$MARIADB_LOG_GROUP" "$log_path"
        chmod 640 "$log_path"
    done

    if [ -d "$INSTANCE_LOG_DIR/log_innodb" ]; then
        chown -R "$INSTANCE_USER:$MARIADB_LOG_GROUP" "$INSTANCE_LOG_DIR/log_innodb"
        find "$INSTANCE_LOG_DIR/log_innodb" -type d -exec chmod 2750 {} +
        find "$INSTANCE_LOG_DIR/log_innodb" -type f -exec chmod 640 {} +
    fi
done

# ========================
# COPY VECTOR BINARY
# ========================

step "Install vector binary"

if [ -x "$VECTOR_BIN" ]; then
    log "Vector binary already present: $VECTOR_BIN -> skip"
else
    # Tim binary trong package/vector hoac setup/mariadb/Install_Mariadb
    SRC_BIN=""
    if [ -x "${VECTOR_PKG_DIR}/vector" ]; then
        SRC_BIN="${VECTOR_PKG_DIR}/vector"
    elif [ -x "${VECTOR_SRC_DIR}/vector" ]; then
        SRC_BIN="${VECTOR_SRC_DIR}/vector"
    elif [ -x "${BASE_DIR}/setup/mariadb/Install_Mariadb/vector" ]; then
        SRC_BIN="${BASE_DIR}/setup/mariadb/Install_Mariadb/vector"
    fi

    if [ -z "$SRC_BIN" ]; then
        die "Khong tim thay Vector binary; can copy vao ${VECTOR_PKG_DIR}/vector hoac ${VECTOR_SRC_DIR}/vector"
    fi

    cp "$SRC_BIN" "$VECTOR_BIN"
    log "Installed vector binary tu $SRC_BIN -> $VECTOR_BIN"
fi
chown root:root "$VECTOR_BIN"
chmod 755 "$VECTOR_BIN"

# ========================
# COPY + PATCH VECTOR.YAML
# ========================

step "Install vector.yaml"

if [ -f "$VECTOR_YAML" ]; then
    backup_file "$VECTOR_YAML"
fi

SRC_YAML=""
if [ -f "${VECTOR_SRC_DIR}/vector.yaml" ]; then
    SRC_YAML="${VECTOR_SRC_DIR}/vector.yaml"
elif [ -f "${BASE_DIR}/setup/mariadb/Install_Mariadb/vector.yaml" ]; then
    SRC_YAML="${BASE_DIR}/setup/mariadb/Install_Mariadb/vector.yaml"
fi

if [ -z "$SRC_YAML" ]; then
    die "Khong tim thay vector.yaml template (kiem tra ${VECTOR_SRC_DIR}/vector.yaml)"
fi

cp "$SRC_YAML" "$VECTOR_YAML"
log "Copied template tu $SRC_YAML"

# ------------------------
# PATCH LOG PATHS CHO MULTI INSTANCE
# 03_configure_mariadb.sh ghi log vao get_log_dir(id) (LOG_DIR_PATTERN):
#   <LOG_DIR>/mariadb.error.log
#   <LOG_DIR>/mariadb.slow.log
#   <LOG_DIR>/innodb_stat.log (do innodb_stat.sh)
# ------------------------

# Sinh block include cho slow log
SLOW_INCLUDES=""
ERROR_INCLUDES=""
INNODB_INCLUDES=""
for id in "${INSTANCE_IDS[@]}"; do
    INST_LOG_DIR="$(get_log_dir "$id")"
    SLOW_INCLUDES+="      - ${INST_LOG_DIR}/mariadb.slow.log"$'\n'
    ERROR_INCLUDES+="      - ${INST_LOG_DIR}/mariadb.error.log"$'\n'
    INNODB_INCLUDES+="      - ${INST_LOG_DIR}/innodb_stat.log"$'\n'
done

# Loai bo trailing newline
SLOW_INCLUDES="${SLOW_INCLUDES%$'\n'}"
ERROR_INCLUDES="${ERROR_INCLUDES%$'\n'}"
INNODB_INCLUDES="${INNODB_INCLUDES%$'\n'}"

# Lay IP local cho field server trong transform
LOCAL_IP="${DR_NODE_IP:-$(hostname -I | awk '{print $1}')}"

# Sinh vector.yaml hoan toan tu config muoi instance (overwrite template log paths)
# Giu nguyen kafka sinks, transforms cua template - chi noi path cho dung
command -v python3 >/dev/null 2>&1 || die "python3 bat buoc de render vector.yaml multi-instance"
python3 - <<PYEOF
import re
import sys

path = "${VECTOR_YAML}"
slow_block = """${SLOW_INCLUDES}"""
error_block = """${ERROR_INCLUDES}"""
innodb_block = """${INNODB_INCLUDES}"""
local_ip = "${LOCAL_IP}"

with open(path) as f:
    content = f.read()

# Patch data_dir
content = re.sub(
    r"^data_dir:.*$",
    "data_dir: ${VECTOR_CHECKPOINT_DIR}",
    content,
    count=1,
    flags=re.MULTILINE,
)

def replace_include(src_name, new_block, text):
    pattern = re.compile(
        r"(  " + re.escape(src_name) + r":\n    include:\n)((?:      - .*\n)+)",
        re.MULTILINE,
    )
    return pattern.sub(lambda m: m.group(1) + new_block + "\n", text)

content = replace_include("mariadb_slow_log_file", slow_block, content)
content = replace_include("mariadb_error_log_file", error_block, content)
content = replace_include("mariadb_innodb_log_file", innodb_block, content)

# Patch server IP trong cac transform
content = re.sub(
    r'\.server\s*=\s*"[^"]*"',
    f'.server = "{local_ip}"',
    content,
)

with open(path, "w") as f:
    f.write(content)

print("OK")
PYEOF

chown root:"$VECTOR_GROUP" "$VECTOR_YAML"
chmod 640 "$VECTOR_YAML"
log "Patched vector.yaml voi ${#INSTANCE_IDS[@]} instance log path"

# ========================
# VALIDATE CONFIG + PERMISSION (bat buoc)
# ========================

step "Validate vector config va quyen doc log bang user $VECTOR_USER"
command -v runuser >/dev/null 2>&1 || die "Thieu runuser (util-linux)"

for id in "${INSTANCE_IDS[@]}"; do
    INSTANCE_LOG_DIR="$(get_log_dir "$id")"
    for log_file in mariadb.error.log mariadb.slow.log innodb_stat.log; do
        log_path="$INSTANCE_LOG_DIR/$log_file"
        [ -e "$log_path" ] || continue
        runuser -u "$VECTOR_USER" -- test -r "$log_path" \
            || die "Vector user khong doc duoc: $log_path"
    done
done

if runuser -u "$VECTOR_USER" -- "$VECTOR_BIN" validate --no-environment "$VECTOR_YAML" >/dev/null 2>&1; then
    log "vector validate as $VECTOR_USER: OK"
else
    die "vector validate FAIL voi user $VECTOR_USER: $VECTOR_BIN validate --no-environment $VECTOR_YAML"
fi

# ========================
# GENERATE SYSTEMD UNIT
# ========================

step "Generate systemd unit"

if [ -f "$SERVICE_FILE" ]; then
    backup_file "$SERVICE_FILE"
fi

cat > "$SERVICE_FILE" <<EOF
# Vector-dev transform va push log Mariadb sang Kafka / Elasticsearch
# Sinh tu 09_install_vector.sh - khong sua tay
[Unit]
Description=Vector (MariaDB log shipper)
Documentation=https://vector.dev
After=network-online.target
Requires=network-online.target

[Service]
Type=simple
User=${VECTOR_USER}
Group=${VECTOR_GROUP}
SupplementaryGroups=${MARIADB_LOG_GROUP}
UMask=0027
StandardOutput=journal
StandardError=journal
ExecStartPre=${VECTOR_BIN} validate --no-environment ${VECTOR_YAML}
ExecStart=${VECTOR_BIN} -c ${VECTOR_YAML}
ExecReload=${VECTOR_BIN} validate --no-environment ${VECTOR_YAML}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
EnvironmentFile=-/log/apps/vector_mariadb/vector.env

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_FILE"
log "Generated $SERVICE_FILE"

VECTOR_ENV_FILE="/log/apps/vector_mariadb/vector.env"
if [ -f "$VECTOR_ENV_FILE" ]; then
    chown root:"$VECTOR_GROUP" "$VECTOR_ENV_FILE"
    chmod 640 "$VECTOR_ENV_FILE"
fi

# ========================
# ENABLE SERVICE
# ========================

step "Enable va start vector service"
systemctl daemon-reload

systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    || die "systemctl enable ${SERVICE_NAME} fail"
systemctl restart "${SERVICE_NAME}.service" \
    || die "systemctl restart ${SERVICE_NAME} fail; xem: journalctl -u ${SERVICE_NAME} -n 100"
systemctl is-active --quiet "${SERVICE_NAME}.service" \
    || die "${SERVICE_NAME} khong active sau khi start"

ACTUAL_USER="$(systemctl show -p User --value "${SERVICE_NAME}.service")"
[ "$ACTUAL_USER" = "$VECTOR_USER" ] \
    || die "${SERVICE_NAME} dang cau hinh user '$ACTUAL_USER', mong doi '$VECTOR_USER'"
log "Vector active: service=$SERVICE_NAME user=$ACTUAL_USER"

log "===== DONE INSTALL VECTOR SERVICE ====="
