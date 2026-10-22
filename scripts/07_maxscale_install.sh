#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

source ../configs/cluster.env
source ./common.sh

check_root
log "===== START INSTALL MAXSCALE (MULTI INSTANCE) ====="

if [ "${ENABLE_MAXSCALE:-false}" != "true" ]; then
    log "ENABLE_MAXSCALE is not true -> skipping MaxScale installation."
    exit 0
fi

# Nạp INSTANCE_IDS, INSTANCE_PORT, INSTANCE_MAX_RW, INSTANCE_MAX_RO
validate_cluster_env

# MaxScale bắt buộc có Galera (backend lấy từ CLUSTER_NODES)
if ! is_galera_enabled; then
    die "ENABLE_MAXSCALE=true yeu cau ENABLE_GALERA=true (MaxScale routing den Galera cluster)"
fi
if [ -z "${CLUSTER_NODES:-}" ]; then
    die "CLUSTER_NODES rong - MaxScale can it nhat 1 backend"
fi

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$BASE_DIR/package/maxscale"
NODE_PKG_DIR="$BASE_DIR/package/nodejs"

INSTALL_DIR="/usr/local/maxscale"

# Giá trị mặc định, có thể ghi đè trong cluster.env
MAXSCALE_USER="${MAXSCALE_USER:-maxscale}"
MAXSCALE_REST_BASE_PORT="${MAXSCALE_REST_BASE_PORT:-8989}"

MODE="${INSTALL_MODE:-fresh}"
log "Installation Mode: $MODE"
log "MaxScale instances: ${INSTANCE_IDS[*]}"

step "Ensure maxscale user"
if id "maxscale" &>/dev/null; then
    log "User maxscale exists -> skip"
else
    useradd -r -s /bin/false maxscale
    log "Created user maxscale"
fi

step "Install NodeJS (offline)"
if command -v node &>/dev/null; then
    log "NodeJS already installed -> skip"
else
    TAR_FILE=$(ls "$NODE_PKG_DIR"/node-*.tar.* 2>/dev/null | head -n1 || true)

    if [ -z "$TAR_FILE" ]; then
        warn "NodeJS package not found in $NODE_PKG_DIR. MaxGUI might not work."
    else
        log "Extracting NodeJS: $TAR_FILE"
        TMP_NODE_DIR="/tmp/nodejs_install"
        rm -rf "$TMP_NODE_DIR"
        mkdir -p "$TMP_NODE_DIR"

        tar -xf "$TAR_FILE" -C "$TMP_NODE_DIR"
        NODE_SRC=$(find "$TMP_NODE_DIR" -maxdepth 1 -type d -name "node-*" | head -n1)

        rm -rf /usr/local/lib/node
        mv "$NODE_SRC" /usr/local/lib/node

        ln -sf /usr/local/lib/node/bin/node /usr/bin/node
        ln -sf /usr/local/lib/node/bin/npm /usr/bin/npm
        ln -sf /usr/local/lib/node/bin/npx /usr/bin/npx
        log "NodeJS installed successfully"
    fi
fi

# MaxScale luôn tìm /var/lib/maxscale/maxscale.cnf.d khi khởi động;
# không tạo trước sẽ gây cảnh báo hoặc lỗi quyền.
step "Prepare MaxScale global directories"
mkdir -p /var/lib/maxscale/maxscale.cnf.d
mkdir -p /etc/maxscale.modules.d
chown -R maxscale:maxscale /var/lib/maxscale
chown -R maxscale:maxscale /etc/maxscale.modules.d

# Mở quyền traverse (o+x) cho thư mục cha phòng khi server siết quyền (drwxr-x---).
ensure_parents_traversable_global() {
    local p="$1"
    while [ "$p" != "/" ] && [ -n "$p" ]; do
        chmod o+x "$p" 2>/dev/null || true
        p="$(dirname "$p")"
    done
}
ensure_parents_traversable_global /var/lib/maxscale
ensure_parents_traversable_global /etc/maxscale.modules.d

# Tự chọn kiểu cài theo file trong $PKG_DIR:
#   *.deb    -> dpkg -i
#   *.tar.gz -> giải nén vào /usr/local/maxscale
# Ép kiểu bằng MAXSCALE_PACKAGE_TYPE=deb|tar trong cluster.env.

step "Detect MaxScale package format"

MAXSCALE_PKG_TYPE="${MAXSCALE_PACKAGE_TYPE:-auto}"
DEB_FILE=""
TAR_FILE=""

case "$MAXSCALE_PKG_TYPE" in
    deb)
        DEB_FILE=$(ls "$PKG_DIR"/*.deb 2>/dev/null | head -n1 || true)
        [ -n "$DEB_FILE" ] || die "MAXSCALE_PACKAGE_TYPE=deb nhung khong tim thay .deb trong $PKG_DIR"
        ;;
    tar)
        TAR_FILE=$(ls "$PKG_DIR"/*.tar.gz 2>/dev/null | head -n1 || true)
        [ -n "$TAR_FILE" ] || die "MAXSCALE_PACKAGE_TYPE=tar nhung khong tim thay .tar.gz trong $PKG_DIR"
        ;;
    auto)
        DEB_FILE=$(ls "$PKG_DIR"/*.deb 2>/dev/null | head -n1 || true)
        TAR_FILE=$(ls "$PKG_DIR"/*.tar.gz 2>/dev/null | head -n1 || true)
        if [ -n "$DEB_FILE" ] && [ -n "$TAR_FILE" ]; then
            warn "Tim thay ca .deb va .tar.gz - uu tien .deb. De force tar: MAXSCALE_PACKAGE_TYPE=tar"
            TAR_FILE=""
        fi
        [ -n "$DEB_FILE" ] || [ -n "$TAR_FILE" ] || die "Khong tim thay MaxScale .deb hoac .tar.gz trong $PKG_DIR"
        ;;
    *)
        die "MAXSCALE_PACKAGE_TYPE khong hop le: '$MAXSCALE_PKG_TYPE' (chap nhan: deb / tar / auto)"
        ;;
esac

if [ -n "$DEB_FILE" ]; then
    step "Install MaxScale (.deb)"
    if dpkg -l maxscale 2>/dev/null | awk '/^ii/ {found=1} END {exit !found}'; then
        log "MaxScale package da cai dat (dpkg) -> skip"
    else
        # Offline: cài tất cả *.deb trong PKG_DIR một lần, dpkg tự xử lý thứ tự/deps.
        # Yêu cầu bundle đủ deps (nodejs, libboost-serialization, libmemcached11t64,
        # libmicrohttpd12t64, librdkafka++1, libtbb12...) vào package/maxscale/.
        DEB_COUNT=$(ls "$PKG_DIR"/*.deb 2>/dev/null | wc -l)
        log "Installing $DEB_COUNT .deb file(s) tu $PKG_DIR (offline mode)..."

        # Không fail ngay nếu lỗi: thử apt -f trước khi kết luận.
        DPKG_OUT=$(DEBIAN_FRONTEND=noninteractive dpkg -i "$PKG_DIR"/*.deb 2>&1) \
            || warn "dpkg -i co loi, se thu apt-get -f install..."

        # Server offline không có repo -> apt -f chỉ giúp được nếu deps thiếu
        # đã có sẵn trong apt cache (vd /var/cache/apt/archives).
        if ! dpkg -l maxscale 2>/dev/null | awk '/^ii/ {found=1} END {exit !found}'; then
            DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>&1 || true
        fi

        if ! dpkg -l maxscale 2>/dev/null | awk '/^ii/ {found=1} END {exit !found}'; then
            warn "==============================================="
            warn "MaxScale CHUA cai duoc. Thieu dependencies."
            warn "==============================================="
            warn "Output dpkg:"
            echo "$DPKG_OUT" | tail -30 | while IFS= read -r line; do warn "  $line"; done
            warn ""
            warn "Cac package thieu (extract tu loi 'depends on ... however'):"
            echo "$DPKG_OUT" | awk '/depends on/ {gsub(/[(;]/," "); print "  - "$3}' | sort -u \
                | while IFS= read -r line; do warn "$line"; done
            warn ""
            warn "Cach fix: tai cac .deb thieu ve, bo vao $PKG_DIR, chay lai script."
            warn "Vi du tren may co Internet:"
            warn "  apt-get download nodejs libboost-serialization1.83.0 libmemcached11t64 \\"
            warn "    libmicrohttpd12t64 librdkafka++1 libtbb12"
            die "MaxScale .deb cai that bai - bundle them deps vao $PKG_DIR"
        fi
        log "MaxScale installed via dpkg"
    fi

    # .deb mặc định enable + start maxscale.service với /etc/maxscale.cnf -> xung đột
    # với service theo từng instance sinh sau; tắt đi để khỏi chiếm port mặc định.
    if systemctl is-enabled maxscale >/dev/null 2>&1 || systemctl is-active maxscale >/dev/null 2>&1; then
        log "Disable + stop default maxscale.service (se thay bang maxscale_<i>.service)"
        systemctl stop maxscale 2>/dev/null || true
        systemctl disable maxscale 2>/dev/null || true
    fi

    MAXSCALE_BIN="/usr/bin/maxscale"
    MAXCTRL_BIN="/usr/bin/maxctrl"
    LIB_BASE_DIR="/usr/lib/x86_64-linux-gnu"
    LIB_MODULES_DIR="/usr/lib/x86_64-linux-gnu/maxscale"

    [ -x "$MAXSCALE_BIN" ] || die "MaxScale binary khong ton tai sau khi cai: $MAXSCALE_BIN"
    [ -d "$LIB_MODULES_DIR" ] || warn "Khong thay $LIB_MODULES_DIR - kiem tra path module"

else
    step "Extract MaxScale (.tar.gz)"
    if [ -d "$INSTALL_DIR" ] && find "$INSTALL_DIR" -name maxscale | grep -q bin 2>/dev/null; then
        log "MaxScale already extracted at $INSTALL_DIR -> skip"
    else
        TMP_MAX_DIR="/tmp/maxscale_install"
        rm -rf "$TMP_MAX_DIR"
        mkdir -p "$TMP_MAX_DIR"

        tar -xzf "$TAR_FILE" -C "$TMP_MAX_DIR" || die "Failed to extract MaxScale"

        EXTRACT_DIR=$(ls "$TMP_MAX_DIR" | head -n1)
        mv "$TMP_MAX_DIR/$EXTRACT_DIR" "$INSTALL_DIR"
        rm -rf "$TMP_MAX_DIR"
        log "MaxScale extracted to $INSTALL_DIR"
    fi

    # Tar có thể giữ umask của máy build (vd 077 -> mode 700), mà MaxScale chạy
    # bằng User=maxscale (không phải root) nên 'others' cần rx để chdir và đọc bin/lib.
    # X (hoa) chỉ thêm x cho thư mục, không thêm x cho file thường.
    chmod -R go+rX "$INSTALL_DIR" 2>/dev/null || true
    ensure_parents_traversable_global "$INSTALL_DIR"

    MAXSCALE_BIN=$(find "$INSTALL_DIR" -type f -name maxscale | grep /bin/ | head -n1)
    MAXCTRL_BIN="$(dirname "$MAXSCALE_BIN")/maxctrl"

    # Đường dẫn thư viện cho LD_LIBRARY_PATH
    LIB_BASE_DIR="$(dirname "$(dirname "$MAXSCALE_BIN")")/lib/x86_64-linux-gnu"
    LIB_MODULES_DIR="${LIB_BASE_DIR}/maxscale"

    ln -sf "$MAXSCALE_BIN" /usr/bin/maxscale
    ln -sf "$MAXCTRL_BIN" /usr/bin/maxctrl
fi

log "Using MaxScale binary: $MAXSCALE_BIN"
log "Using modules dir:    $LIB_MODULES_DIR"

read -ra NODES <<< "$CLUSTER_NODES"
log "Detected ${#NODES[@]} database nodes"

declare -a NEW_INSTANCES=()

# chmod o+x các thư mục cha để systemd chdir không fail trên server siết quyền (/var, /var/lib = 750).
ensure_parents_traversable() {
    local p="$1"
    while [ "$p" != "/" ] && [ -n "$p" ]; do
        chmod o+x "$p" 2>/dev/null || true
        p="$(dirname "$p")"
    done
}

# Sinh lệnh tiện lợi theo ID: ID=0 -> maxctrl, ID>=1 -> maxctrl<ID>.
# Wrapper chỉ thêm REST host mặc định nếu người dùng chưa truyền -h/--hosts.
create_maxctrl_wrapper() {
    local id="$1" rest_port="$2" command_name wrapper_file
    if [ "$id" = "0" ]; then
        command_name="maxctrl"
    else
        command_name="maxctrl${id}"
    fi
    wrapper_file="/usr/local/bin/${command_name}"
    ensure_dir /usr/local/bin

    cat > "$wrapper_file" <<EOF
#!/bin/bash
# ${command_name} -> REST MaxScale ID=${id}. Sinh boi 07_maxscale_install.sh.
for _a in "\$@"; do
  case "\$_a" in
    -h|--hosts|-h=*|--hosts=*) exec "$MAXCTRL_BIN" "\$@" ;;
  esac
done
exec "$MAXCTRL_BIN" --hosts=127.0.0.1:${rest_port} "\$@"
EOF
    chmod 755 "$wrapper_file"
    log "Wrapper '$command_name' -> 127.0.0.1:${rest_port} ($wrapper_file)"
}

for id in "${INSTANCE_IDS[@]}"; do

    DB_PORT="${INSTANCE_PORT[$id]}"
    RW_PORT="${INSTANCE_MAX_RW[$id]}"
    RO_PORT="${INSTANCE_MAX_RO[$id]}"

    # Bỏ qua nếu không bật listener nào
    if [ "$RW_PORT" = "0" ] && [ "$RO_PORT" = "0" ]; then
        log "Instance $id: MAX_RW=0 va MAX_RO=0 -> bo qua MaxScale instance"
        continue
    fi

    MAXSCALE_PASS_FOR_INSTANCE="$(get_instance_maxscale_pass "$id")"
    [ -n "$MAXSCALE_PASS_FOR_INSTANCE" ] \
        || die "INSTANCE_${id}: MAXSCALE_PASS (field 9) rong trong cluster.env"

    step "Configuring MaxScale Instance $id (DB=$DB_PORT RW=$RW_PORT RO=$RO_PORT)"

    # ID=0 -> không hậu tố (tên mặc định, giống quy ước MariaDB); ID>=1 -> "_<ID>".
    SFX="$(id_suffix "$id")"
    # OID: chèn vào tên object trong .cnf; id=0 -> rỗng (server_1), id>=1 -> giữ số (server1_1).
    OID=""; [ "$id" != "0" ] && OID="$id"
    CONFIG_FILE="/etc/maxscale${SFX}.cnf"
    SERVICE_FILE="/etc/systemd/system/maxscale${SFX}.service"
    SERVICE_NAME="maxscale${SFX}"

    # Port REST admin: ID=0 -> BASE+1 (vd 1800 -> 1801); ID>=1 -> BASE+ID.
    if [ "$id" = "0" ]; then
        REST_API_PORT=$((MAXSCALE_REST_BASE_PORT + 1))
    else
        REST_API_PORT=$((MAXSCALE_REST_BASE_PORT + id))
    fi

    create_maxctrl_wrapper "$id" "$REST_API_PORT"
    if [ "$id" = "0" ]; then
        rm -f /etc/profile.d/maxctrl.sh   # dọn alias cũ
    fi

    # Mode expand: không ghi đè instance đang chạy
    if [ -f "$CONFIG_FILE" ] || [ -f "$SERVICE_FILE" ]; then
        if [ "$MODE" == "fresh" ]; then
            warn "Instance $id already has config! Overwriting..."
            cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)" 2>/dev/null || true
        else
            log "Instance $id config exists (Expand Mode) -> skipping to protect active proxy."
            continue
        fi
    fi

    NEW_INSTANCES+=("$id")

    # Thư mục riêng cho từng instance, không dùng chung
    LOG_DIR="/var/log/maxscale${SFX}"
    DATA_DIR="/var/lib/maxscale${SFX}"
    RUN_DIR="/run/maxscale${SFX}"
    PERSIST_DIR="${DATA_DIR}/maxscale.cnf.d"

    for dir in "$LOG_DIR" "$DATA_DIR" "$RUN_DIR" "$PERSIST_DIR"; do
        ensure_dir "$dir"
        chown -R maxscale:maxscale "$dir"
    done

    ensure_parents_traversable "$LOG_DIR"
    ensure_parents_traversable "$DATA_DIR"
    ensure_parents_traversable "$RUN_DIR"

    # proxy_protocol=true theo tài liệu mục 8.4: bắt buộc khi MariaDB có
    # proxy_protocol_networks, thiếu sẽ bị từ chối kết nối.
    SERVER_BLOCK=""
    SERVER_LIST=""
    idx=1
    for ip in "${NODES[@]}"; do
        SERVER_BLOCK+="
[server${OID}_${idx}]
type=server
proxy_protocol=true
address=${ip}
port=${DB_PORT}
protocol=MariaDBBackend
priority=1
"
        SERVER_LIST+="server${OID}_${idx},"
        ((idx++))
    done
    SERVER_LIST=${SERVER_LIST%,}

    # Chỉ sinh service/listener khi port != 0
    RW_SERVICE_BLOCK=""
    RW_LISTENER_BLOCK=""
    if [ "$RW_PORT" != "0" ]; then
        RW_SERVICE_BLOCK="
[Read-Write-Service${SFX}]
type=service
router=readwritesplit
servers=${SERVER_LIST}
user=${MAXSCALE_USER}
password=${MAXSCALE_PASS_FOR_INSTANCE}
"
        RW_LISTENER_BLOCK="
[Read-Write-Listener${SFX}]
type=listener
service=Read-Write-Service${SFX}
protocol=MariaDBClient
port=${RW_PORT}
"
    fi

    RO_SERVICE_BLOCK=""
    RO_LISTENER_BLOCK=""
    if [ "$RO_PORT" != "0" ]; then
        RO_SERVICE_BLOCK="
[Read-Only-Service${SFX}]
type=service
router=readconnroute
router_options=synced
servers=${SERVER_LIST}
user=${MAXSCALE_USER}
password=${MAXSCALE_PASS_FOR_INSTANCE}
"
        RO_LISTENER_BLOCK="
[Read-Only-Listener${SFX}]
type=listener
service=Read-Only-Service${SFX}
protocol=MariaDBClient
port=${RO_PORT}
"
    fi

    log "Generating $CONFIG_FILE..."
    cat > "$CONFIG_FILE" <<EOF
[maxscale]
threads=auto
skip_name_resolve=1
admin_secure_gui=false
admin_port=${REST_API_PORT}
admin_host=127.0.0.1

libdir=${LIB_MODULES_DIR}
logdir=${LOG_DIR}
datadir=${DATA_DIR}
piddir=${RUN_DIR}
persistdir=${PERSIST_DIR}

${SERVER_BLOCK}

[Galera-Monitor${SFX}]
type=monitor
module=galeramon
servers=${SERVER_LIST}
user=${MAXSCALE_USER}
password=${MAXSCALE_PASS_FOR_INSTANCE}
monitor_interval=2s
disable_master_failback=1
available_when_donor=1
${RW_SERVICE_BLOCK}${RO_SERVICE_BLOCK}${RW_LISTENER_BLOCK}${RO_LISTENER_BLOCK}
EOF

    chown maxscale:maxscale "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    log "Generating systemd service for instance $id..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MariaDB MaxScale Proxy Instance ${id} (RW=${RW_PORT} RO=${RO_PORT} REST=${REST_API_PORT})
After=network.target

[Service]
Type=simple
User=maxscale
Group=maxscale

Environment="LD_LIBRARY_PATH=${LIB_BASE_DIR}:${LIB_MODULES_DIR}"

RuntimeDirectory=maxscale${SFX}
RuntimeDirectoryMode=0755
WorkingDirectory=$INSTALL_DIR

ExecStart=${MAXSCALE_BIN} --nodaemon --config=${CONFIG_FILE}

Restart=always
RestartSec=5
LimitNOFILE=65535

TimeoutStartSec=60
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"
    log "MaxScale Instance $id configured (RW=$RW_PORT RO=$RO_PORT REST=$REST_API_PORT)"

done

step "Reload systemd and initialize instances"
systemctl daemon-reload

if [ ${#NEW_INSTANCES[@]} -eq 0 ]; then
    log "Khong co MaxScale instance moi nao can khoi dong."
    log "===== DONE INSTALL MAXSCALE ====="
    exit 0
fi

log "Cac instance moi can khoi dong: ${NEW_INSTANCES[*]}"

for id in "${NEW_INSTANCES[@]}"; do
    SFX="$(id_suffix "$id")"
    SERVICE_NAME="maxscale${SFX}"
    MAXSCALE_PASS_FOR_INSTANCE="$(get_instance_maxscale_pass "$id")"
    if [ "$id" = "0" ]; then
        REST_API_PORT=$((MAXSCALE_REST_BASE_PORT + 1))
    else
        REST_API_PORT=$((MAXSCALE_REST_BASE_PORT + id))
    fi

    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME"
    log "Starting $SERVICE_NAME and waiting for REST API (Port $REST_API_PORT)..."

    # Chờ 3 giây xem service có chết ngay sau khi khởi động không
    sleep 3
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        die "Service $SERVICE_NAME FAILED to start! Check logs: tail -n 30 /var/log/maxscale${SFX}/maxscale.log"
    fi

    # Chờ tối đa 30 giây cho port REST mở (kết nối backend + galera monitor có thể >10s).
    READY=0
    for t in {1..30}; do
        if ss -tln | grep -q ":${REST_API_PORT} "; then
            READY=1
            break
        fi
        sleep 1
    done

    if [ "$READY" -ne 1 ]; then
        die "Service is running but Port $REST_API_PORT is NOT open! Check logs immediately!"
    fi

    log "Initializing admin user for Instance $id..."

    # Tạm tắt set -e để bắt output và mã thoát của maxctrl
    set +e
    INIT_OUT=$("$MAXCTRL_BIN" -h 127.0.0.1:${REST_API_PORT} create user admin "${MAXSCALE_PASS_FOR_INSTANCE}" --type=admin 2>&1)
    INIT_STATUS=$?
    set -e

    if [ $INIT_STATUS -eq 0 ]; then
        log "Admin user created successfully for Instance $id."
    else
        # Trùng user thì bỏ qua, lỗi khác thì dừng
        if echo "$INIT_OUT" | grep -qi "Duplicate username"; then
            log "Admin user already exists for Instance $id -> Skipping."
        else
            die "UNKNOWN ERROR while creating user on Instance $id: $INIT_OUT"
        fi
    fi
done

log "===== DONE INSTALL MAXSCALE ====="
