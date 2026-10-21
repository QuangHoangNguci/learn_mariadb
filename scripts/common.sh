#!/bin/bash

#######################################
# GLOBAL VARS
#######################################

LOG_DIR_CLUSTER="/var/log/mariadb_cluster"
LOG_FILE_CLUSTER="$LOG_DIR_CLUSTER/cluster.log"

SCRIPT_NAME="$(basename "$0")"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

mkdir -p "$LOG_DIR_CLUSTER" 2>/dev/null || true

#######################################
# LOGGING
#######################################

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

_log() {
    local level="$1"; shift
    local msg="$*"
    local line
    line="$(timestamp) [$level] [$HOST_IP] [$SCRIPT_NAME] - $msg"
    echo "$line" | tee -a "$LOG_FILE_CLUSTER"
}

log()   { _log "INFO"  "$@"; }
warn()  { _log "WARN"  "$@"; }
error() { _log "ERROR" "$@"; }

die() { error "$1"; exit 1; }

#######################################
# CHECKS
#######################################

check_root() {
    [ "$EUID" -eq 0 ] || die "Please run as root"
}

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "Missing command: $c"
    done
}

require_file() {
    for f in "$@"; do
        [ -f "$f" ] || die "Missing file: $f"
    done
}

ensure_dir() {
    local d="$1"
    [ -d "$d" ] || mkdir -p "$d"
}

backup_file() {
    local f="$1"
    [ -f "$f" ] && cp "$f" "${f}.bak.$(date +%s)"
}

is_port_in_use() {
    ss -lnt | awk '{print $4}' | grep -q ":$1$"
}

#######################################
# CONFIRM (cho thao tac pha huy / nhay cam)
#   confirm "<cau hoi>" -> 0 neu dong y, 1 neu khong.
#   Tu dong YES khi ASSUME_YES=true. Tu dong NO khi khong co TTY (an toan).
#######################################
confirm() {
    local msg="$1" reply
    if [ "${ASSUME_YES:-false}" = "true" ]; then
        log "AUTO-YES: $msg"
        return 0
    fi
    if [ ! -t 0 ]; then
        error "Khong co TTY de xac nhan: $msg (them ASSUME_YES=true neu chay tu pipeline)"
        return 1
    fi
    while true; do
        read -r -p "  >> $msg [y/N]: " reply
        case "$reply" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO|"") return 1 ;;
            *) echo "  Tra loi y hoac n." ;;
        esac
    done
}

ensure_parents_traversable() {
    local p="$1"
    while [ "$p" != "/" ] && [ -n "$p" ]; do
        chmod o+x "$p" 2>/dev/null || true
        p="$(dirname "$p")"
    done
}

#######################################
# STEP HELPER
#######################################

STEP=0
step() {
    STEP=$((STEP + 1))
    log "[STEP $STEP] $1"
}

#######################################
# INSTANCES TABLE PARSER
#
# Parse format moi INSTANCE_<ID>=(...) hoac INSTANCES_TABLE cu.
# Format cu: ID PORT MGNT SIZE_GB BUF_MB MAX_RW MAX_RO
#   BUF_MB : "auto" / "-" / "0" = tu tinh theo SIZE_GB
#   MAX_RW : 0 / "-" / "" = tat MaxScale R/W
#   MAX_RO : 0 / "-" / "" = tat MaxScale R/O
#
# Output (qua bien toan cuc):
#   INSTANCE_IDS[]         - mang ID
#   INSTANCE_PORT[ID]      - port chinh
#   INSTANCE_MGNT[ID]      - extra_port
#   INSTANCE_SIZE[ID]      - SIZE_GB
#   INSTANCE_BUF_MB[ID]    - "auto" hoac so MB
#   INSTANCE_MAX_RW[ID]    - 0 hoac port
#   INSTANCE_MAX_RO[ID]    - 0 hoac port
#   INSTANCE_SIZE_SUM      - tong SIZE_GB cua nhung instance dung BUF auto
#######################################

declare -ga INSTANCE_IDS=()
declare -gA INSTANCE_PORT=()
declare -gA INSTANCE_MGNT=()
declare -gA INSTANCE_SIZE=()
declare -gA INSTANCE_BUF_MB=()
declare -gA INSTANCE_MAX_RW=()
declare -gA INSTANCE_MAX_RO=()
INSTANCE_SIZE_SUM=0   # tong SIZE_GB cua instance BUF=auto (de chia ti le)

_normalize_port() {
    # Tra ve 0 neu rong / "-" / "0", nguoc lai tra ve nguyen ban (validate sau)
    local v="${1:-}"
    case "$v" in
        ""|"-"|"0") echo 0 ;;
        *) echo "$v" ;;
    esac
}

parse_instances_table() {
    INSTANCE_IDS=()
    INSTANCE_PORT=()
    INSTANCE_MGNT=()
    INSTANCE_SIZE=()
    INSTANCE_BUF_MB=()
    INSTANCE_MAX_RW=()
    INSTANCE_MAX_RO=()
    INSTANCE_SIZE_SUM=0

    # Format moi: mot indexed array cho moi instance, tu dong tim theo ten
    # INSTANCE_<ID>. Thu tu field:
    # PORT MGNT SIZE_GB BUF_MB MAX_RW MAX_RO CLUSTER_NAME GALERA_PASS MAXSCALE_PASS
    local -a compact_vars=()
    mapfile -t compact_vars < <(
        compgen -A variable \
            | awk '/^INSTANCE_[0-9]+$/ { print }' \
            | sort -t_ -k2,2n
    )

    if [ "${#compact_vars[@]}" -gt 0 ]; then
        INSTANCES_TABLE=""
        local row_var
        for row_var in "${compact_vars[@]}"; do
            local compact_id="${row_var#INSTANCE_}"
            if ! declare -p "$row_var" 2>/dev/null | grep -q '^declare \-a '; then
                die "$row_var phai la indexed array: $row_var=(PORT MGNT SIZE BUF RW RO CLUSTER GALERA_PASS MAXSCALE_PASS)"
            fi

            local -n compact_row="$row_var"
            if [ "${#compact_row[@]}" -ne 9 ]; then
                die "$row_var phai co dung 9 field, hien co ${#compact_row[@]}"
            fi
            INSTANCES_TABLE+="$compact_id ${compact_row[0]} ${compact_row[1]} ${compact_row[2]} ${compact_row[3]} ${compact_row[4]} ${compact_row[5]}"$'\n'
            unset -n compact_row
        done
    fi

    [ -n "${INSTANCES_TABLE:-}" ] \
        || die "Khong co INSTANCE_<ID> hoac INSTANCES_TABLE trong cluster.env"

    local line id port mgnt size buf max_rw max_ro
    while IFS= read -r line; do
        line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [ -z "$line" ] && continue
        [[ "$line" =~ ^# ]] && continue

        # 7 cot. Cot thieu se thanh chuoi rong.
        read -r id port mgnt size buf max_rw max_ro <<< "$line"

        # Validate cot bat buoc
        [[ "$id"   =~ ^[0-9]+$ ]] || die "Instance ID khong hop le: '$id'"
        [[ "$port" =~ ^[0-9]+$ ]] || die "Instance $id: PORT khong hop le: '$port'"
        [[ "$mgnt" =~ ^[0-9]+$ ]] || die "Instance $id: MGNT khong hop le: '$mgnt'"
        [[ "$size" =~ ^[0-9]+$ ]] || die "Instance $id: SIZE_GB khong hop le: '$size'"

        # BUF_MB: "auto" hoac so nguyen >= 64 (khong thi vo nghia)
        local buf_norm
        case "${buf:-auto}" in
            ""|"-"|"0"|"auto"|"AUTO") buf_norm="auto" ;;
            *)
                if ! [[ "$buf" =~ ^[0-9]+$ ]]; then
                    die "Instance $id: BUF_MB khong hop le: '$buf' (dung 'auto' hoac so MB)"
                fi
                if [ "$buf" -lt 64 ]; then
                    die "Instance $id: BUF_MB qua nho: ${buf}MB (toi thieu 64MB)"
                fi
                buf_norm="$buf"
                ;;
        esac

        local rw_norm ro_norm
        rw_norm="$(_normalize_port "${max_rw:-}")"
        ro_norm="$(_normalize_port "${max_ro:-}")"

        for col in "rw_norm:$rw_norm" "ro_norm:$ro_norm"; do
            local v="${col#*:}"
            [ "$v" = "0" ] && continue
            [[ "$v" =~ ^[0-9]+$ ]] || die "Instance $id: MAX_* khong hop le: '$v'"
        done

        if [ -n "${INSTANCE_PORT[$id]:-}" ]; then
            die "Instance ID $id bi lap"
        fi

        INSTANCE_IDS+=("$id")
        INSTANCE_PORT[$id]="$port"
        INSTANCE_MGNT[$id]="$mgnt"
        INSTANCE_SIZE[$id]="$size"
        INSTANCE_BUF_MB[$id]="$buf_norm"
        INSTANCE_MAX_RW[$id]="$rw_norm"
        INSTANCE_MAX_RO[$id]="$ro_norm"

        # Chi cong tong SIZE cho instance BUF=auto (de chia ti le dung)
        if [ "$buf_norm" = "auto" ]; then
            INSTANCE_SIZE_SUM=$((INSTANCE_SIZE_SUM + size))
        fi
    done <<< "$INSTANCES_TABLE"

    [ "${#INSTANCE_IDS[@]}" -gt 0 ] || die "Khong co instance hop le"
}

#######################################
# PATH RENDER
#
# Thay {ID} trong PATTERN bang ID thuc te
#######################################

# Suffix dung cho ten install dir / user / service / file config.
# Quyet dinh theo ID (KHONG dung co global):
#   ID = 0  -> rong  (ten MAC DINH: mariadb, /etc/my.cnf ...)
#   ID >= 1 -> "_<ID>" (mariadb_1, /etc/my_1.cnf ...)
# Nho the tren CUNG 1 server co the tron: ID 0 = my.cnf, ID 1 = my_1.cnf
id_suffix() {
    if [ "$1" = "0" ]; then
        echo ""
    else
        echo "_$1"
    fi
}

render_path() {
    local pattern="$1"
    local id="$2"
    if [ "$id" = "0" ]; then
        # ID=0: bo ca "_{ID}" lan "{ID}" de ra duong dan khong so.
        #   /u01/data_{ID}/database -> /u01/data/database
        #   /etc/my_{ID}.cnf        -> /etc/my.cnf
        pattern="${pattern//_\{ID\}/}"
        pattern="${pattern//\{ID\}/}"
        echo "$pattern"
    else
        echo "${pattern//\{ID\}/$id}"
    fi
}

get_install_dir() {
    echo "${INSTALL_BASE_DIR:-/usr/local}/${INSTANCE_NAME_PREFIX:-mariadb}$(id_suffix "$1")"
}

get_instance_user() {
    echo "${INSTANCE_NAME_PREFIX:-mariadb}$(id_suffix "$1")"
}

get_service_name() {
    echo "${INSTANCE_NAME_PREFIX:-mariadb}$(id_suffix "$1")"
}

get_data_dir()    { render_path "$DATA_DIR_PATTERN"    "$1"; }
get_tmp_dir()     { render_path "$TMP_DIR_PATTERN"     "$1"; }
get_log_dir()     { render_path "$LOG_DIR_PATTERN"     "$1"; }
get_binlog_dir()  { render_path "$BINLOG_DIR_PATTERN"  "$1"; }
get_conf_file()   { render_path "$CONFIG_FILE_PATTERN" "$1"; }

#######################################
# PER-INSTANCE SETTINGS
#
# New config stores all values in INSTANCE_<ID> arrays. Legacy per-ID and
# global variables are still accepted as fallback.
#######################################

get_instance_setting() {
    local base="$1" id="$2" fallback="${3:-}"
    local scoped="${base}_${id}"
    local compact_var="INSTANCE_${id}" compact_index=""

    case "$base" in
        CLUSTER_NAME) compact_index=6 ;;
        GALERA_PASS)  compact_index=7 ;;
        MAXSCALE_PASS) compact_index=8 ;;
    esac

    if [ -n "$compact_index" ] \
       && declare -p "$compact_var" 2>/dev/null | grep -q '^declare \-a '; then
        local -n compact_row="$compact_var"
        printf '%s\n' "${compact_row[$compact_index]:-}"
        return 0
    fi

    if declare -p "$scoped" >/dev/null 2>&1; then
        printf '%s\n' "${!scoped}"
    else
        printf '%s\n' "$fallback"
    fi
}

get_instance_cluster_name() {
    local id="$1"
    local default_name="${CLUSTER_NAME_PREFIX:-cluster}$(id_suffix "$id")"
    get_instance_setting "CLUSTER_NAME" "$id" "$default_name"
}

get_instance_galera_pass() {
    get_instance_setting "GALERA_PASS" "$1" "${GALERA_PASS:-}"
}

get_instance_maxscale_pass() {
    get_instance_setting "MAXSCALE_PASS" "$1" "${MAXSCALE_PASS:-}"
}

#######################################
# TOPOLOGY  (cong tac tong: single | dr | cluster | dr-cluster)
#
# derive_topology() doc TOPOLOGY va SET 2 bien suy ra:
#   ENABLE_GALERA = true  khi cluster / dr-cluster
#   REPLICA_MODE  = true  khi dr / dr-cluster   (read_only=1 trong my.cnf)
# Cac script cu doc ENABLE_GALERA / is_galera_enabled van chay binh thuong.
#######################################

# Back-compat: neu env cu chua co TOPOLOGY nhung co ENABLE_GALERA, suy nguoc ra.
derive_topology() {
    if [ -z "${TOPOLOGY:-}" ]; then
        if [ "${ENABLE_GALERA:-false}" = "true" ]; then
            TOPOLOGY="cluster"
        else
            TOPOLOGY="single"
        fi
        warn "TOPOLOGY chua dat trong env -> suy ra '$TOPOLOGY' tu ENABLE_GALERA (env cu)."
    fi

    case "$TOPOLOGY" in
        single)     ENABLE_GALERA=false; REPLICA_MODE=false ;;
        dr)         ENABLE_GALERA=false; REPLICA_MODE=true  ;;
        cluster)    ENABLE_GALERA=true;  REPLICA_MODE=false ;;
        dr-cluster) ENABLE_GALERA=true;  REPLICA_MODE=true  ;;
        *) die "TOPOLOGY khong hop le: '$TOPOLOGY' (chon: single | dr | cluster | dr-cluster)" ;;
    esac
    export TOPOLOGY ENABLE_GALERA REPLICA_MODE
}

# Mo ta ngan cho 1 topology (in trong summary)
topology_desc() {
    case "${TOPOLOGY:-single}" in
        single)     echo "standalone master read-write (binlog ON)" ;;
        dr)         echo "standalone replica read_only (async tu PRIMARY_NODES)" ;;
        cluster)    echo "Galera cluster read-write" ;;
        dr-cluster) echo "Galera cluster replica read_only (async tu primary cluster)" ;;
        *)          echo "?" ;;
    esac
}

#######################################
# GALERA / REPLICA HELPERS
#######################################

is_galera_enabled() {
    [ "${ENABLE_GALERA:-false}" = "true" ]
}

# Replica/DR mode: them read_only=1 + mo iptables PRIMARY_NODES + goi y CHANGE MASTER.
is_replica() {
    [ "${REPLICA_MODE:-false}" = "true" ]
}

# Tinh port WSREP cho mot ID instance
# Tra ve qua bien WSREP_LISTEN, WSREP_SST, WSREP_IST
compute_wsrep_ports() {
    local id="$1"
    local base=$(( ${WSREP_BASE_PORT:-1030} + id * ${WSREP_PORT_STEP:-100} ))
    WSREP_SST=$((    base + 1 ))
    WSREP_LISTEN=$(( base + 2 ))
    WSREP_IST=$((    base + 3 ))
}

# Vi tri server hien tai trong CLUSTER_NODES (1-based).
# Tra ve qua bien NODE_INDEX, NODE_COUNT, LOCAL_CLUSTER_IP.
detect_node_index() {
    NODE_INDEX=0
    NODE_COUNT=0
    LOCAL_CLUSTER_IP=""

    is_galera_enabled || return 0
    [ -n "${CLUSTER_NODES:-}" ] || die "ENABLE_GALERA=true nhung CLUSTER_NODES rong"

    local detect_ip="${DR_NODE_IP:-$(hostname -I | awk '{print $1}')}"
    LOCAL_CLUSTER_IP="$detect_ip"

    local idx=0 ip
    for ip in $CLUSTER_NODES; do
        idx=$((idx + 1))
        if [ "$ip" = "$detect_ip" ]; then
            NODE_INDEX=$idx
        fi
    done
    NODE_COUNT=$idx

    if [ "$NODE_INDEX" -eq 0 ]; then
        die "IP local ($detect_ip) khong co trong CLUSTER_NODES=\"$CLUSTER_NODES\". Dat DR_NODE_IP thu cong neu detect sai."
    fi
}

#######################################
# DISK TYPE DETECT
#######################################

detect_disk_type() {
    local explicit="${DISK_TYPE:-auto}"
    case "$explicit" in
        ssd|hdd) echo "$explicit"; return ;;
    esac

    # auto: doc /sys/block/<dev>/queue/rotational
    # rotational=0 -> SSD/NVMe ; =1 -> HDD
    local dev rot
    for dev in /sys/block/sd? /sys/block/nvme?n? /sys/block/vd?; do
        [ -d "$dev" ] || continue
        rot=$(cat "$dev/queue/rotational" 2>/dev/null || echo 1)
        if [ "$rot" = "0" ]; then
            echo "ssd"
            return
        fi
    done
    echo "hdd"
}

#######################################
# AUTO-TUNE COMPUTE
#
# Doc: HOST_RAM_MB, HOST_CPU, INSTANCE_SIZE[ID], INSTANCE_SIZE_SUM, RESERVED_RAM_PCT
# Output qua bien toan cuc cho 1 ID:
#   TUNE_BP_MB                   - innodb_buffer_pool_size (MB)
#   TUNE_BP_INSTANCES            - innodb_buffer_pool_instances
#   TUNE_LOG_FILE_MB             - innodb_log_file_size (MB)
#   TUNE_IO_CAP / TUNE_IO_MAX    - innodb_io_capacity (max)
#   TUNE_THREAD_POOL             - thread_pool_size
#######################################

compute_tune_for_id() {
    local id="$1"
    local size="${INSTANCE_SIZE[$id]:-0}"
    [ "$size" -gt 0 ] || die "compute_tune_for_id: SIZE_GB cua ID=$id = 0"

    local reserved="${RESERVED_RAM_PCT:-25}"
    local usable=$((100 - reserved))
    [ "$usable" -gt 0 ] || die "RESERVED_RAM_PCT khong hop le: $reserved"

    HOST_RAM_MB="${HOST_RAM_MB:-$(free -m | awk '/Mem:/ {print $2}')}"
    HOST_CPU="${HOST_CPU:-$(nproc)}"

    local buf="${INSTANCE_BUF_MB[$id]:-auto}"
    TUNE_BP_SRC="auto"
    if [ "$buf" != "auto" ]; then
        # Override thu cong
        TUNE_BP_MB="$buf"
        TUNE_BP_SRC="manual"
    else
        # Auto: chi chia phan RAM con lai cho cac instance auto khac
        # (instance manual da chiem phan cua minh roi)
        local used_by_manual=0
        local oid
        for oid in "${INSTANCE_IDS[@]}"; do
            if [ "${INSTANCE_BUF_MB[$oid]}" != "auto" ]; then
                used_by_manual=$(( used_by_manual + ${INSTANCE_BUF_MB[$oid]} ))
            fi
        done

        local pool_mb=$(( HOST_RAM_MB * usable / 100 - used_by_manual ))
        [ "$pool_mb" -lt 128 ] && pool_mb=128

        if [ "$INSTANCE_SIZE_SUM" -gt 0 ]; then
            TUNE_BP_MB=$(( pool_mb * size / INSTANCE_SIZE_SUM ))
        else
            TUNE_BP_MB=128
        fi
        [ "$TUNE_BP_MB" -lt 128 ] && TUNE_BP_MB=128
    fi

    # Buffer pool instances: floor(BP_GB), cap 1..8
    local bp_gb=$(( TUNE_BP_MB / 1024 ))
    TUNE_BP_INSTANCES=$bp_gb
    [ "$TUNE_BP_INSTANCES" -lt 1 ] && TUNE_BP_INSTANCES=1
    [ "$TUNE_BP_INSTANCES" -gt 8 ] && TUNE_BP_INSTANCES=8

    # innodb_log_file_size = 25% buffer pool, floor 256M cap 2048M
    TUNE_LOG_FILE_MB=$(( TUNE_BP_MB / 4 ))
    [ "$TUNE_LOG_FILE_MB" -lt 256 ]  && TUNE_LOG_FILE_MB=256
    [ "$TUNE_LOG_FILE_MB" -gt 2048 ] && TUNE_LOG_FILE_MB=2048

    # IO capacity theo disk type
    local dtype
    dtype=$(detect_disk_type)
    if [ "$dtype" = "ssd" ]; then
        TUNE_IO_CAP=4000
        TUNE_IO_MAX=10000
    else
        TUNE_IO_CAP=200
        TUNE_IO_MAX=2000
    fi
    TUNE_DISK_TYPE="$dtype"

    # Thread pool: CPU*2, cap 64
    TUNE_THREAD_POOL=$(( HOST_CPU * 2 ))
    [ "$TUNE_THREAD_POOL" -gt 64 ] && TUNE_THREAD_POOL=64
    [ "$TUNE_THREAD_POOL" -lt 4 ]  && TUNE_THREAD_POOL=4
    return 0
}

#######################################
# VALIDATE CLUSTER.ENV
#######################################

validate_cluster_env() {
    local errors=0 id

    # Suy ra ENABLE_GALERA / REPLICA_MODE tu TOPOLOGY (die neu TOPOLOGY sai)
    derive_topology

    local required=(
        "TOPOLOGY"
        "DATA_DIR_PATTERN"
        "TMP_DIR_PATTERN"
        "LOG_DIR_PATTERN"
        "BINLOG_DIR_PATTERN"
        "INSTALL_BASE_DIR"
        "INSTANCE_NAME_PREFIX"
        "CONFIG_FILE_PATTERN"
        "INSTALL_MODE"
        "RESERVED_RAM_PCT"
    )
    for v in "${required[@]}"; do
        if [ -z "${!v:-}" ]; then
            error "cluster.env: thieu bien bat buoc: $v"
            errors=$((errors + 1))
        fi
    done

    case "${INSTALL_MODE:-}" in
        fresh|expand) ;;
        *) error "INSTALL_MODE phai la 'fresh' hoac 'expand' (hien: ${INSTALL_MODE:-unset})"
           errors=$((errors + 1)) ;;
    esac

    # Galera-specific
    if [ "${ENABLE_GALERA:-false}" = "true" ]; then
        case "${NODE_ROLE:-}" in
            bootstrap|joiner) ;;
            *) error "ENABLE_GALERA=true thi NODE_ROLE phai 'bootstrap' hoac 'joiner' (hien: ${NODE_ROLE:-unset})"
               errors=$((errors + 1)) ;;
        esac
        if [ -z "${CLUSTER_NODES:-}" ]; then
            error "ENABLE_GALERA=true thi CLUSTER_NODES khong duoc rong"
            errors=$((errors + 1))
        fi
        if [ -z "${WSREP_BASE_PORT:-}" ] || [ -z "${WSREP_PORT_STEP:-}" ]; then
            error "ENABLE_GALERA=true thi WSREP_BASE_PORT + WSREP_PORT_STEP phai co"
            errors=$((errors + 1))
        fi
    fi

    # Replica/DR-specific: can PRIMARY_NODES de mo iptables keo binlog tu primary.
    if is_replica && [ -z "${PRIMARY_NODES:-}" ]; then
        error "TOPOLOGY=$TOPOLOGY (replica) thi PRIMARY_NODES khong duoc rong (IP primary de mo iptables)"
        errors=$((errors + 1))
    fi

    case "${DISK_TYPE:-auto}" in
        auto|ssd|hdd) ;;
        *) error "DISK_TYPE phai la 'auto' / 'ssd' / 'hdd' (hien: ${DISK_TYPE})"
           errors=$((errors + 1)) ;;
    esac

    if ! [[ "${RESERVED_RAM_PCT:-25}" =~ ^[0-9]+$ ]] \
       || [ "${RESERVED_RAM_PCT:-25}" -lt 5 ] \
       || [ "${RESERVED_RAM_PCT:-25}" -gt 90 ]; then
        error "RESERVED_RAM_PCT phai trong [5..90] (hien: ${RESERVED_RAM_PCT:-unset})"
        errors=$((errors + 1))
    fi

    [ "$errors" -eq 0 ] || die "Tim thay $errors loi trong cluster.env"

    parse_instances_table

    # Settings co the khai bao rieng theo ID. Bien global cu van la fallback.
    for id in "${INSTANCE_IDS[@]}"; do
        if is_galera_enabled; then
            if [ -z "$(get_instance_cluster_name "$id")" ]; then
                error "INSTANCE_${id}: CLUSTER_NAME (field 7) khong duoc rong"
                errors=$((errors + 1))
            fi
            if [ -z "$(get_instance_galera_pass "$id")" ]; then
                error "INSTANCE_${id}: GALERA_PASS (field 8) khong duoc rong"
                errors=$((errors + 1))
            fi
        fi
    done

    [ "$errors" -eq 0 ] || die "Tim thay $errors loi trong cluster.env"

    # Check port trung lap (PORT, MGNT, MAX_RW, MAX_RO, va WSREP neu galera)
    declare -A seen_port=()
    for id in "${INSTANCE_IDS[@]}"; do
        local p_list=(
            "${INSTANCE_PORT[$id]}"
            "${INSTANCE_MGNT[$id]}"
            "${INSTANCE_MAX_RW[$id]}"
            "${INSTANCE_MAX_RO[$id]}"
        )
        if [ "${ENABLE_GALERA:-false}" = "true" ]; then
            compute_wsrep_ports "$id"
            p_list+=("$WSREP_LISTEN" "$WSREP_SST" "$WSREP_IST")
        fi
        for x in "${p_list[@]}"; do
            [ "$x" = "0" ] && continue  # 0 = tat, khong tinh trung
            if [ -n "${seen_port[$x]:-}" ]; then
                die "Port $x bi lap (xem ID=$id va ID=${seen_port[$x]})"
            fi
            seen_port[$x]="$id"
        done
    done

    # Tong buffer manual khong vuot RAM usable
    local usable_mb manual_sum=0 oid
    HOST_RAM_MB_VALIDATE=$(free -m | awk '/Mem:/ {print $2}')
    usable_mb=$(( HOST_RAM_MB_VALIDATE * (100 - ${RESERVED_RAM_PCT:-25}) / 100 ))
    for oid in "${INSTANCE_IDS[@]}"; do
        if [ "${INSTANCE_BUF_MB[$oid]}" != "auto" ]; then
            manual_sum=$(( manual_sum + ${INSTANCE_BUF_MB[$oid]} ))
        fi
    done
    if [ "$manual_sum" -gt "$usable_mb" ]; then
        die "Tong BUF_MB manual (${manual_sum}MB) vuot RAM usable (${usable_mb}MB = $(( 100 - ${RESERVED_RAM_PCT:-25} ))% cua ${HOST_RAM_MB_VALIDATE}MB)"
    fi

    log "cluster.env validation: OK (${#INSTANCE_IDS[@]} instance(s), manual_buf=${manual_sum}MB, auto_size_sum=${INSTANCE_SIZE_SUM}GB)"
}

#######################################
# PASSWORD VALIDATE (chi goi tu 06)
#######################################

validate_passwords_for_init() {
    local errors=0

    if [ "${EMPTY_CLUSTER:-false}" = "true" ]; then
        # EMPTY_CLUSTER chi can ADMIN_PASS de set root
        if [ -z "${ADMIN_PASS:-}" ]; then
            error "EMPTY_CLUSTER=true van can ADMIN_PASS (de set root password)"
            errors=$((errors + 1))
        fi
    else
        for v in ADMIN_PASS COMMON_PASS; do
            if [ -z "${!v:-}" ]; then
                error "Script 06 yeu cau $v khong rong (sua trong cluster.env)"
                errors=$((errors + 1))
            fi
        done
    fi

    # Check do dai >= 6 (khop password policy)
    for v in ADMIN_PASS COMMON_PASS; do
        local val="${!v:-}"
        if [ -n "$val" ] && [ ${#val} -lt 6 ]; then
            warn "$v chi co ${#val} ky tu (khuyen nghi >= 6)"
        fi
    done

    if [ "${EMPTY_CLUSTER:-false}" != "true" ]; then
        local id galera_pass maxscale_pass
        for id in "${INSTANCE_IDS[@]}"; do
            maxscale_pass="$(get_instance_maxscale_pass "$id")"
            if [ -z "$maxscale_pass" ]; then
                error "Script 06 yeu cau MAXSCALE_PASS trong field 9 cua INSTANCE_${id}"
                errors=$((errors + 1))
            elif [ ${#maxscale_pass} -lt 6 ]; then
                warn "INSTANCE_${id}: MAXSCALE_PASS chi co ${#maxscale_pass} ky tu (khuyen nghi >= 6)"
            fi

            if is_galera_enabled; then
                galera_pass="$(get_instance_galera_pass "$id")"
                if [ -z "$galera_pass" ]; then
                    error "Script 06 yeu cau GALERA_PASS trong field 8 cua INSTANCE_${id}"
                    errors=$((errors + 1))
                elif [ ${#galera_pass} -lt 6 ]; then
                    warn "INSTANCE_${id}: GALERA_PASS chi co ${#galera_pass} ky tu (khuyen nghi >= 6)"
                fi
            fi
        done
    fi

    [ "$errors" -eq 0 ] || die "Tim thay $errors loi password."
}

#######################################
# RESOURCE PRECHECK
#######################################

check_disk_space() {
    local path="$1" min_mb="$2"
    local avail
    avail=$(df -Pm "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -n "$avail" ] || return 0
    if [ "$avail" -lt "$min_mb" ]; then
        warn "Disk it ($path): ${avail}MB < ${min_mb}MB khuyen nghi"
    fi
}

preflight_check() {
    # Don gian: chi warn neu RAM hoac disk it
    local n=${#INSTANCE_IDS[@]}
    [ "$n" -eq 0 ] && return 0

    local ram
    ram=$(free -m | awk '/Mem:/ {print $2}')
    local min_ram=$(( n * 1024 + 2048 ))
    if [ "$ram" -lt "$min_ram" ]; then
        warn "RAM thap: ${ram}MB (khuyen nghi >= ${min_ram}MB cho $n instance)"
    fi

    # check 1 sample data/log path (lay tu instance dau)
    local first_id="${INSTANCE_IDS[0]}"
    local data_sample log_sample
    data_sample="$(get_data_dir "$first_id")"
    log_sample="$(get_log_dir "$first_id")"

    [ -d "$(dirname "$data_sample")" ] && check_disk_space "$(dirname "$data_sample")" $(( n * 5120 ))
    [ -d "$(dirname "$log_sample")"  ] && check_disk_space "$(dirname "$log_sample")"  $(( n * 2048 ))
    check_disk_space "${INSTALL_BASE_DIR:-/usr/local}" $(( n * 2048 ))
}
