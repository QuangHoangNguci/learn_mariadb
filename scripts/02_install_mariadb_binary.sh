#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

source ../configs/cluster.env
source ./common.sh

check_root
log "===== START INSTALL MARIADB (MULTI INSTANCE) ====="

validate_cluster_env

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARIADB_DIR="$BASE_DIR/package/mariadb"
TMP_DIR="/tmp/mariadb_install"

MODE="${INSTALL_MODE:-fresh}"
log "Installation Mode: $MODE"

[ -d "$MARIADB_DIR" ] || die "MariaDB package dir khong ton tai: $MARIADB_DIR"

PKG=$(ls "$MARIADB_DIR"/*.tar.gz 2>/dev/null | head -n1 || true)
[ -n "$PKG" ] || die "Khong tim thay file mariadb-*.tar.gz trong $MARIADB_DIR"

log "Using package: $PKG"

# Fresh: cài tất cả; Expand: chỉ cài ID chưa có INSTALL_DIR

declare -a TODO_IDS=()
for id in "${INSTANCE_IDS[@]}"; do
    INSTALL_DIR="$(get_install_dir "$id")"
    if [ -d "$INSTALL_DIR" ]; then
        if [ "$MODE" == "fresh" ]; then
            TODO_IDS+=("$id")
        else
            log "Expand: instance $id da co $INSTALL_DIR -> skip"
        fi
    else
        TODO_IDS+=("$id")
    fi
done

if [ "${#TODO_IDS[@]}" -eq 0 ]; then
    log "Khong co instance moi nao can cai -> skip extract & install"
    exit 0
fi

log "Extracting MariaDB package..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
tar -xzf "$PKG" -C "$TMP_DIR" || die "Extract failed"

EXTRACT_DIR=$(ls "$TMP_DIR" | head -n1)
SRC_DIR="$TMP_DIR/$EXTRACT_DIR"
[ -d "$SRC_DIR" ] || die "Invalid extract dir: $SRC_DIR"

for id in "${TODO_IDS[@]}"; do
    INSTALL_DIR="$(get_install_dir "$id")"
    USER="$(get_instance_user "$id")"
    SVC="$(get_service_name "$id")"
    DATA_DIR="$(get_data_dir "$id")"
    TMP_DATA_DIR="$(get_tmp_dir "$id")"
    LOG_DIR_I="$(get_log_dir "$id")"
    BINLOG_DIR="$(get_binlog_dir "$id")"
    PORT="${INSTANCE_PORT[$id]}"

    log "===== INSTALL INSTANCE $id (port=$PORT) ====="

    # Không đụng vào service đang chạy
    if [ -d "$INSTALL_DIR" ] && [ "$MODE" == "fresh" ]; then
        if systemctl is-active --quiet "$SVC" 2>/dev/null; then
            die "Instance $id ($SVC) dang chay! Stop truoc khi fresh install: systemctl stop $SVC"
        fi
        warn "Instance $id da ton tai. Backing up..."
        mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
    fi

    if is_port_in_use "$PORT"; then
        die "Port $PORT (instance $id) da bi chiem! Kiem tra: ss -lntp | grep :$PORT"
    fi
    if is_port_in_use "${INSTANCE_MGNT[$id]}"; then
        die "MGNT_PORT ${INSTANCE_MGNT[$id]} (instance $id) da bi chiem!"
    fi
    if is_galera_enabled; then
        compute_wsrep_ports "$id"
        for wp in "$WSREP_LISTEN" "$WSREP_SST" "$WSREP_IST"; do
            if is_port_in_use "$wp"; then
                die "WSREP port $wp (instance $id) da bi chiem! Kiem tra: ss -lntp | grep :$wp"
            fi
        done
    fi

    if id "$USER" &>/dev/null; then
        log "User $USER already exists"
    else
        useradd -r -s /usr/sbin/nologin "$USER" 2>/dev/null || \
        useradd -r -s /sbin/nologin     "$USER"
        log "Created isolated user: $USER"
    fi

    # Hardlink để tiết kiệm disk; fallback copy thường nếu khác thiết bị
    log "Copying binaries for instance $id (hardlink mode)..."
    cp -al "$SRC_DIR" "$INSTALL_DIR" 2>/dev/null || {
        log "Hardlink failed, fallback to full copy..."
        cp -a "$SRC_DIR" "$INSTALL_DIR" || die "Copy failed for instance $id"
    }
    [ -d "$INSTALL_DIR/bin" ] || die "Invalid install dir for instance $id (missing bin)"

    # Tạo thư mục, đảm bảo thư mục cha truy cập được
    mkdir -p "$DATA_DIR" "$TMP_DATA_DIR" "$LOG_DIR_I" "$BINLOG_DIR"
    ensure_parents_traversable "$DATA_DIR"
    ensure_parents_traversable "$TMP_DATA_DIR"
    ensure_parents_traversable "$LOG_DIR_I"
    ensure_parents_traversable "$BINLOG_DIR"

    chown -R "$USER:$USER" \
        "$INSTALL_DIR" \
        "$DATA_DIR" \
        "$TMP_DATA_DIR" \
        "$LOG_DIR_I" \
        "$BINLOG_DIR"

    # Vá password policy mặc định trong enterprise.cnf (nếu có)
    CONF_FILE_E="$INSTALL_DIR/etc/mariadb-enterprise.cnf"
    if [ -f "$CONF_FILE_E" ]; then
        sed -i '/simple_password_check/d' "$CONF_FILE_E"
        grep -q "AUTO PASSWORD POLICY" "$CONF_FILE_E" || cat <<EOF >> "$CONF_FILE_E"

# ===== AUTO PASSWORD POLICY =====
simple_password_check_digits=0
simple_password_check_letters_same_case=0
simple_password_check_minimal_length=6
simple_password_check_other_characters=0
EOF
    fi

    "$INSTALL_DIR/bin/mariadbd" --version || die "Binary not working for instance $id"
    log "Instance $id installed OK"
done

# Client giống nhau ở mọi instance -> chỉ cần bin của 1 instance trong PATH

PROFILE_FILE="/etc/profile.d/mariadb_multi.sh"
log "Updating $PROFILE_FILE"
{
    echo "# MariaDB Multi-instance PATH environment"
    echo "export PATH=$(get_install_dir "${INSTANCE_IDS[0]}")/bin:\$PATH"
} > "$PROFILE_FILE"
chmod 644 "$PROFILE_FILE"

# Wrapper: /usr/local/bin/mariadb (ID=0) | mariadb<ID> (ID>=1).
# Là file thực thi trong /usr/local/bin (có trong PATH của root) nên chạy được ở mọi shell
# (ssh, su -, sudo, cron...) không phụ thuộc profile.d/alias. --defaults-file luôn đứng đầu.

ensure_dir /usr/local/bin
for id in "${INSTANCE_IDS[@]}"; do
    # ID=0 -> 'mariadb' (không gắn số); ID>=1 -> 'mariadb1', ...
    # Wrapper gọi bằng full path nên không đệ quy dù trùng tên 'mariadb'.
    msfx=""; [ "$id" != "0" ] && msfx="$id"
    wrapper="/usr/local/bin/mariadb${msfx}"
    cat > "$wrapper" <<EOF
#!/bin/bash
# Auto-sinh boi 02_install_mariadb_binary.sh - login nhanh vao instance ${id}
exec "$(get_install_dir "$id")/bin/mariadb" --defaults-file="$(get_conf_file "$id")" "\$@"
EOF
    chmod 755 "$wrapper"
    log "Created login wrapper: $wrapper -> instance $id"
done

# Kiểm tra thư viện/công cụ runtime (chỉ cảnh báo)
ldconfig -p | grep -q jemalloc || warn "Missing jemalloc library"
command -v numactl >/dev/null 2>&1 || warn "Missing numactl utility"

rm -rf "$TMP_DIR"
log "===== DONE INSTALL MARIADB ====="
