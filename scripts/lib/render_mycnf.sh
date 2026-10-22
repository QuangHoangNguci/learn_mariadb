#!/bin/bash
#
# render_mycnf.sh - sinh /etc/my_<ID>.cnf từ template theo TOPOLOGY.
#
# Nội dung config nằm ở template (configs/templates/), logic tính toán nằm ở đây.
# Output giống bản heredoc cũ trong 03 cho cluster/single, thêm block DR (read_only)
# khi TOPOLOGY = dr / dr-cluster.
#
# Yêu cầu gọi trước:
#   - source configs/cluster.env
#   - source scripts/common.sh
#   - parse_instances_table và derive_topology (đã chạy trong validate_cluster_env)
#   - INSTALL_DIR của instance đã tồn tại (để tìm libgalera_*.so khi dùng galera)
#
# API:
#   render_mycnf <ID> <out_file>
#

# Thư mục template (repo/configs/templates), có thể override bằng env.
_RENDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${TEMPLATE_DIR:-$(cd "$_RENDER_LIB_DIR/../.." && pwd)/configs/templates}"
TEMPLATE_MYCNF_BASE="${TEMPLATE_MYCNF_BASE:-$TEMPLATE_DIR/my.cnf.base.tmpl}"
TEMPLATE_BLOCK_GALERA="${TEMPLATE_BLOCK_GALERA:-$TEMPLATE_DIR/block.galera.tmpl}"
TEMPLATE_BLOCK_DR="${TEMPLATE_BLOCK_DR:-$TEMPLATE_DIR/block.dr.tmpl}"

# Cache: detect_node_index chỉ cần chạy 1 lần/host (galera)
_RENDER_NODE_DONE=0

# Server-id non-galera lấy theo octet cuối của IP để không trùng giữa các server.
_render_local_ip() {
    echo "${DR_NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
}

# Tính mọi giá trị (scalar + block galera) cho 1 instance, gán vào biến R_*.
_compute_mycnf_vars() {
    local id="$1"

    R_INSTALL_DIR="$(get_install_dir "$id")"
    R_USER="$(get_instance_user "$id")"
    R_PORT="${INSTANCE_PORT[$id]}"
    R_MGNT_PORT="${INSTANCE_MGNT[$id]}"
    R_DATA_DIR="$(get_data_dir "$id")"
    R_TMP_DIR="$(get_tmp_dir "$id")"
    R_LOG_DIR="$(get_log_dir "$id")"
    R_BINLOG_DIR="$(get_binlog_dir "$id")"
    R_EXPIRE_LOGS_DAYS="${EXPIRE_LOGS_DAYS:-3}"
    R_MAX_OPEN_FILES="${MAX_OPEN_FILES:-1000000}"

    # Auto-tune: buffer pool, log, io, thread pool, disk
    compute_tune_for_id "$id"
    R_BUFFER_POOL_MB="$TUNE_BP_MB"
    R_BUFFER_POOL_INSTANCES="$TUNE_BP_INSTANCES"
    R_LOG_FILE_SIZE_MB="$TUNE_LOG_FILE_MB"
    R_IO_CAPACITY="$TUNE_IO_CAP"
    R_IO_CAPACITY_MAX="$TUNE_IO_MAX"
    R_THREAD_POOL="$TUNE_THREAD_POOL"
    if [ "$TUNE_DISK_TYPE" = "ssd" ]; then
        R_FLUSH_NEIGHBORS=0
    else
        R_FLUSH_NEIGHBORS=1
    fi

    # server-id / gtid domain
    if is_galera_enabled; then
        R_SERVER_ID=$(( ${SERVER_ID_BASE:-1} + id ))
        R_GTID_DOMAIN_ID=$(( ${GTID_DOMAIN_BASE:-100} + id ))
        R_WSREP_GTID_DOMAIN_ID="$R_GTID_DOMAIN_ID"
    else
        local lip octet
        lip="$(_render_local_ip)"
        octet=$(echo "$lip" | awk -F. '{print $NF}')
        [[ "$octet" =~ ^[0-9]+$ ]] || octet=100
        R_SERVER_ID=$(( octet * 100 + id ))
        R_GTID_DOMAIN_ID="$R_SERVER_ID"
        R_WSREP_GTID_DOMAIN_ID=""
    fi

    # Block galera (chỉ khi bật galera)
    R_PROXY_PROTOCOL_LINE=""
    R_WSREP_PROVIDER=""
    R_WSREP_CLUSTER_NAME=""
    R_WSREP_NODE_NAME=""
    R_LOCAL_CLUSTER_IP=""
    R_WSREP_LISTEN=""
    R_WSREP_SST=""
    R_WSREP_IST=""
    R_WSREP_CLUSTER_ADDRESS=""
    R_GALERA_SST_AUTH=""
    R_AUTO_INC_INCREMENT=""
    R_AUTO_INC_OFFSET=""
    R_GCACHE_SIZE="${GCACHE_SIZE:-2048M}"

    if is_galera_enabled; then
        if [ "$_RENDER_NODE_DONE" -eq 0 ]; then
            detect_node_index   # đặt NODE_INDEX, NODE_COUNT, LOCAL_CLUSTER_IP (die nếu IP local không thuộc CLUSTER_NODES)
            _RENDER_NODE_DONE=1
        fi
        compute_wsrep_ports "$id"   # đặt WSREP_LISTEN/SST/IST

        R_LOCAL_CLUSTER_IP="$LOCAL_CLUSTER_IP"
        R_WSREP_LISTEN="$WSREP_LISTEN"
        R_WSREP_SST="$WSREP_SST"
        R_WSREP_IST="$WSREP_IST"

        # gcomm:// chứa tất cả node trên WSREP_LISTEN của instance này
        local ip addr="gcomm://"
        for ip in $CLUSTER_NODES; do
            addr+="${ip}:${WSREP_LISTEN},"
        done
        R_WSREP_CLUSTER_ADDRESS="${addr%,}"

        R_WSREP_NODE_NAME="${NODE_NAME_PREFIX:-db}_${NODE_INDEX}_${id}"
        R_WSREP_CLUSTER_NAME="$(get_instance_cluster_name "$id")"
        # SST user dùng chung tên, password tách riêng theo instance.
        R_GALERA_SST_AUTH="${GALERA_USER_PREFIX:-galera}:$(get_instance_galera_pass "$id")"

        # Galera: autoinc giống nhau trên mọi node (certification tự xử lý conflict)
        R_AUTO_INC_INCREMENT=2
        R_AUTO_INC_OFFSET=1

        # proxy_protocol cho MaxScale: chấp nhận PROXY header từ các IP trong cluster
        local pn
        pn=$(echo "$CLUSTER_NODES" | sed 's/ /,/g')
        [ -n "$pn" ] && R_PROXY_PROTOCOL_LINE="proxy_protocol_networks = $pn"

        # libgalera_*.so: bản enterprise hoặc community
        local cand
        for cand in "$R_INSTALL_DIR/lib/libgalera_enterprise_smm.so" "$R_INSTALL_DIR/lib/libgalera_smm.so"; do
            if [ -f "$cand" ]; then R_WSREP_PROVIDER="$cand"; break; fi
        done
        [ -n "$R_WSREP_PROVIDER" ] || die "Khong tim thay libgalera_*.so trong $R_INSTALL_DIR/lib (instance $id)"
    fi
}

# Escape vế phải của sed s|..|..| (delimiter '|')
_sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

render_mycnf() {
    local id="$1" out="$2"
    [ -n "$out" ] || die "render_mycnf: thieu out_file"
    [ -f "$TEMPLATE_MYCNF_BASE" ] || die "Thieu template: $TEMPLATE_MYCNF_BASE"

    _compute_mycnf_vars "$id"

    # 1) Ghép block galera/dr vào base (xóa marker nếu không dùng)
    local gblock="" dblock=""
    is_galera_enabled && gblock="$TEMPLATE_BLOCK_GALERA"
    is_replica        && dblock="$TEMPLATE_BLOCK_DR"
    [ -z "$gblock" ] || [ -f "$gblock" ] || die "Thieu template galera: $gblock"
    [ -z "$dblock" ] || [ -f "$dblock" ] || die "Thieu template DR: $dblock"

    local assembled
    assembled="$(mktemp)"
    # Chỉ khớp marker khi chiếm trọn 1 dòng (tránh ăn nhầm dòng comment có chứa chữ marker)
    awk -v gf="$gblock" -v df="$dblock" '
        /^[[:space:]]*__GALERA_BLOCK__[[:space:]]*$/ { if (gf != "") { while ((getline l < gf) > 0) print l; close(gf) } next }
        /^[[:space:]]*__DR_BLOCK__[[:space:]]*$/     { if (df != "") { while ((getline l < df) > 0) print l; close(df) } next }
        { print }
    ' "$TEMPLATE_MYCNF_BASE" > "$assembled"

    # 2) Thay mọi placeholder scalar (1 lần sed)
    local -a pairs=(
        "__INSTALL_DIR__"            "$R_INSTALL_DIR"
        "__USER__"                   "$R_USER"
        "__PORT__"                   "$R_PORT"
        "__MGNT_PORT__"              "$R_MGNT_PORT"
        "__DATA_DIR__"               "$R_DATA_DIR"
        "__TMP_DIR__"                "$R_TMP_DIR"
        "__LOG_DIR__"                "$R_LOG_DIR"
        "__BINLOG_DIR__"             "$R_BINLOG_DIR"
        "__PROXY_PROTOCOL_LINE__"    "$R_PROXY_PROTOCOL_LINE"
        "__SERVER_ID__"              "$R_SERVER_ID"
        "__GTID_DOMAIN_ID__"         "$R_GTID_DOMAIN_ID"
        "__EXPIRE_LOGS_DAYS__"       "$R_EXPIRE_LOGS_DAYS"
        "__THREAD_POOL__"            "$R_THREAD_POOL"
        "__MAX_OPEN_FILES__"         "$R_MAX_OPEN_FILES"
        "__BUFFER_POOL_MB__"         "$R_BUFFER_POOL_MB"
        "__BUFFER_POOL_INSTANCES__"  "$R_BUFFER_POOL_INSTANCES"
        "__LOG_FILE_SIZE_MB__"       "$R_LOG_FILE_SIZE_MB"
        "__IO_CAPACITY__"            "$R_IO_CAPACITY"
        "__IO_CAPACITY_MAX__"        "$R_IO_CAPACITY_MAX"
        "__FLUSH_NEIGHBORS__"        "$R_FLUSH_NEIGHBORS"
        "__WSREP_PROVIDER__"         "$R_WSREP_PROVIDER"
        "__WSREP_CLUSTER_NAME__"     "$R_WSREP_CLUSTER_NAME"
        "__WSREP_NODE_NAME__"        "$R_WSREP_NODE_NAME"
        "__LOCAL_CLUSTER_IP__"       "$R_LOCAL_CLUSTER_IP"
        "__WSREP_LISTEN__"           "$R_WSREP_LISTEN"
        "__WSREP_SST__"              "$R_WSREP_SST"
        "__WSREP_IST__"              "$R_WSREP_IST"
        "__WSREP_CLUSTER_ADDRESS__"  "$R_WSREP_CLUSTER_ADDRESS"
        "__GALERA_SST_AUTH__"        "$R_GALERA_SST_AUTH"
        "__WSREP_GTID_DOMAIN_ID__"   "$R_WSREP_GTID_DOMAIN_ID"
        "__AUTO_INC_INCREMENT__"     "$R_AUTO_INC_INCREMENT"
        "__AUTO_INC_OFFSET__"        "$R_AUTO_INC_OFFSET"
        "__GCACHE_SIZE__"            "$R_GCACHE_SIZE"
    )

    local sed_script="" i key val esc
    for ((i=0; i<${#pairs[@]}; i+=2)); do
        key="${pairs[i]}"
        val="${pairs[i+1]}"
        esc="$(_sed_escape "$val")"
        sed_script+="s|${key}|${esc}|g;"
    done

    sed -E "$sed_script" "$assembled" > "$out"
    rm -f "$assembled"
}
