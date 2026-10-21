#!/bin/bash
# ============================================================
#  MariaDB Multi-Instance  -  APP / MENU
#  Chay:  sudo bash setup.sh
#
#  - Menu chinh dieu khien toan bo pipeline.
#  - Wizard hoi tung dong de sinh configs/cluster.env (khong can sua tay).
#  - Nhap so instance = 0  -> 1 instance ten MAC DINH (my.cnf, user mariadb,
#    /usr/local/mariadb) - khong co hau to _<ID>.
# ============================================================

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

ROOT_DIR="$(pwd)"
ENV_FILE="$ROOT_DIR/configs/cluster.env"
SCRIPTS_DIR="$ROOT_DIR/scripts"

# ----- mau sac (tat neu khong phai terminal) -----
if [ -t 1 ]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_GRN=$'\e[32m'
    C_YEL=$'\e[33m'; C_RED=$'\e[31m'; C_CYN=$'\e[36m'
else
    C_RESET=""; C_BOLD=""; C_GRN=""; C_YEL=""; C_RED=""; C_CYN=""
fi

hr()   { echo "========================================================"; }
info() { echo "${C_CYN}$*${C_RESET}"; }
ok()   { echo "${C_GRN}$*${C_RESET}"; }
warnx(){ echo "${C_YEL}$*${C_RESET}"; }
errx() { echo "${C_RED}$*${C_RESET}"; }

pause() { read -rp "Nhan Enter de tiep tuc..." _; }

# ask "Cau hoi" "default" -> tra ve gia tri qua stdout
# (prompt cua 'read -p' di ra stderr nen $(...) bat duoc dung gia tri)
ask() {
    local prompt="$1" default="${2:-}" reply
    if [ -n "$default" ]; then
        read -rp "  $prompt [$default]: " reply
        echo "${reply:-$default}"
    else
        read -rp "  $prompt: " reply
        echo "$reply"
    fi
}

ask_secret() {
    local prompt="$1" reply
    read -rsp "  $prompt: " reply
    echo 1>&2
    printf '%s\n' "$reply"
}

ask_yes() {  # ask_yes "Cau hoi" "y|n" -> tra ve 0 (yes) / 1 (no)
    local prompt="$1" default="${2:-y}" reply
    reply="$(ask "$prompt (y/n)" "$default")"
    case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# menu_pick "Tieu de" "lua chon 1" "lua chon 2" ...
#   In menu (ra stderr) + doc so -> echo INDEX 1-based ra stdout (de $(...) bat).
menu_pick() {
    local title="$1"; shift
    local opts=("$@") i choice
    {
        echo "  ${title}"
        for i in "${!opts[@]}"; do printf "    %d) %s\n" "$((i + 1))" "${opts[i]}"; done
    } 1>&2
    while true; do
        read -rp "  Chon so [1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#opts[@]}" ]; then
            echo "$choice"; return 0
        fi
        echo "    -> Nhap so 1..${#opts[@]}" 1>&2
    done
}

# collect_instances
#   Nhap nhanh tung dong: ID PORT MGNT SIZE_GB [BUF] [RW] [RO]
#   Lenh: list | del N | done | help
#   KHONG goi qua $(...) - ham set bien global: INST_TABLE_ROWS, INST_COUNT
collect_instances() {
    local -a r_id=() r_port=() r_mgnt=() r_size=() r_buf=() r_rw=() r_ro=()
    local line a_id a_port a_mgnt a_size a_buf a_rw a_ro i

    echo
    info ">>> Nhap instance (moi dong:  ID PORT MGNT SIZE_GB [BUF] [RW] [RO])"
    echo  "    ID=0 -> ten mac dinh my.cnf (khong so); ID>=1 -> my_<ID>.cnf"
    echo  "    BUF bo trong = auto;  RW/RO bo trong = tat (-)"
    echo  "    Lenh:  list (xem) | del N (xoa dong N) | done (xong) | help"

    _ci_list() {
        if [ "${#r_id[@]}" -eq 0 ]; then echo "    (chua co dong nao)"; return; fi
        printf "    %-3s %-4s %-6s %-6s %-8s %-6s %-6s %-6s\n" "#" "ID" "PORT" "MGNT" "SIZE_GB" "BUF" "RW" "RO"
        for i in "${!r_id[@]}"; do
            printf "    %-3s %-4s %-6s %-6s %-8s %-6s %-6s %-6s\n" \
                "$((i + 1))" "${r_id[i]}" "${r_port[i]}" "${r_mgnt[i]}" "${r_size[i]}" "${r_buf[i]}" "${r_rw[i]}" "${r_ro[i]}"
        done
    }

    while true; do
        read -rp "  instance> " line || break
        line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [ -z "$line" ] && continue

        case "$line" in
            done|DONE)
                [ "${#r_id[@]}" -ge 1 ] && break
                warnx "    Can it nhat 1 instance truoc khi done."
                continue ;;
            help|HELP|'?')
                echo "    Vi du:  1 3306 1301 1700            (buf auto, khong maxscale)"
                echo "            2 3307 1302 70 2048          (buf 2048MB)"
                echo "            6 3308 1306 700 auto 4008 4018  (co maxscale RW/RO)"
                continue ;;
            list|LIST|ls) _ci_list; continue ;;
            del\ *|DEL\ *|del|DEL)
                local n="${line#* }"
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#r_id[@]}" ]; then
                    unset 'r_id[n-1]' 'r_port[n-1]' 'r_mgnt[n-1]' 'r_size[n-1]' 'r_buf[n-1]' 'r_rw[n-1]' 'r_ro[n-1]'
                    r_id=("${r_id[@]}"); r_port=("${r_port[@]}"); r_mgnt=("${r_mgnt[@]}")
                    r_size=("${r_size[@]}"); r_buf=("${r_buf[@]}"); r_rw=("${r_rw[@]}"); r_ro=("${r_ro[@]}")
                    ok "    Da xoa dong $n."
                else
                    warnx "    'del N' voi N = 1..${#r_id[@]}"
                fi
                continue ;;
        esac

        # ----- parse 1 dong instance -----
        read -r a_id a_port a_mgnt a_size a_buf a_rw a_ro _rest <<< "$line"

        if [ -z "$a_size" ]; then
            warnx "    Thieu truong. Toi thieu:  ID PORT MGNT SIZE_GB"; continue
        fi
        if ! [[ "$a_id" =~ ^[0-9]+$ && "$a_port" =~ ^[0-9]+$ && "$a_mgnt" =~ ^[0-9]+$ && "$a_size" =~ ^[0-9]+$ ]]; then
            warnx "    ID/PORT/MGNT/SIZE_GB phai la so."; continue
        fi
        # BUF: auto / so >=64
        case "${a_buf:-auto}" in
            ""|"-"|"0"|auto|AUTO) a_buf="auto" ;;
            *) if ! [[ "$a_buf" =~ ^[0-9]+$ ]] || [ "$a_buf" -lt 64 ]; then
                   warnx "    BUF phai 'auto' hoac so MB >=64."; continue
               fi ;;
        esac
        # RW/RO: "-" (tat) hoac so
        case "${a_rw:-}" in ""|"-"|"0") a_rw="-" ;; *) [[ "$a_rw" =~ ^[0-9]+$ ]] || { warnx "    RW phai so hoac '-'."; continue; } ;; esac
        case "${a_ro:-}" in ""|"-"|"0") a_ro="-" ;; *) [[ "$a_ro" =~ ^[0-9]+$ ]] || { warnx "    RO phai so hoac '-'."; continue; } ;; esac

        # Check trung ID + trung port voi cac dong da co
        local dup=0
        for i in "${!r_id[@]}"; do
            [ "${r_id[i]}" = "$a_id" ] && { warnx "    ID $a_id da co (dong $((i+1)))."; dup=1; break; }
            for p in "${r_port[i]}" "${r_mgnt[i]}"; do
                if [ "$p" = "$a_port" ] || [ "$p" = "$a_mgnt" ]; then
                    warnx "    Port $a_port/$a_mgnt trung voi dong $((i+1))."; dup=1; break 2
                fi
            done
        done
        [ "$a_port" = "$a_mgnt" ] && { warnx "    PORT va MGNT khong duoc trung nhau."; dup=1; }
        [ "$dup" -eq 1 ] && continue

        r_id+=("$a_id"); r_port+=("$a_port"); r_mgnt+=("$a_mgnt"); r_size+=("$a_size")
        r_buf+=("$a_buf"); r_rw+=("$a_rw"); r_ro+=("$a_ro")
        ok "    + #${#r_id[@]} ID=$a_id port=$a_port mgnt=$a_mgnt size=$a_size buf=$a_buf rw=$a_rw ro=$a_ro"
    done

    # Build INST_TABLE_ROWS (cung format header: ID PORT MGNT SIZE BUF RW RO)
    INST_TABLE_ROWS=""
    for i in "${!r_id[@]}"; do
        INST_TABLE_ROWS+="   ${r_id[i]}  ${r_port[i]}  ${r_mgnt[i]}  ${r_size[i]}  ${r_buf[i]}  ${r_rw[i]}  ${r_ro[i]}"$'\n'
    done
    INST_COUNT="${#r_id[@]}"
}

need_root() {
    if [ "$EUID" -ne 0 ]; then
        errx "Thao tac nay can quyen root. Chay lai: sudo bash setup.sh"
        return 1
    fi
    return 0
}

need_env() {
    if [ ! -f "$ENV_FILE" ]; then
        errx "Chua co cau hinh ($ENV_FILE)."
        warnx "Hay chay muc [1] Wizard tao cau hinh truoc."
        return 1
    fi
    return 0
}

# ============================================================
#  WIZARD  -  sinh configs/cluster.env
# ============================================================
run_wizard() {
    clear
    hr; echo "${C_BOLD}  WIZARD TAO CAU HINH (configs/cluster.env)${C_RESET}"; hr
    echo

    local N TABLE_ROWS

    # ----- thu thap instance (go nhanh tung dong; Enter = them 1 instance) -----
    # Sai thi go lai dung dong do; 'del N' xoa dong da them; 'done' khi xong.
    collect_instances
    TABLE_ROWS="$INST_TABLE_ROWS"
    N="$INST_COUNT"

    # ----- path pattern -----
    echo; info ">>> Duong dan du lieu (co the giu mac dinh):"
    local DATA_P TMP_P LOG_P BINLOG_P INSTALL_BASE CONF_P
    DATA_P="$(ask   "DATA_DIR_PATTERN"   "/u01/data_{ID}/database")"
    TMP_P="$(ask    "TMP_DIR_PATTERN"    "/u01/data_{ID}/database_tmp")"
    LOG_P="$(ask    "LOG_DIR_PATTERN"    "/u01/logs_{ID}/mariadb")"
    BINLOG_P="$(ask "BINLOG_DIR_PATTERN" "/u01/logs_{ID}/mariadb/binlog")"
    INSTALL_BASE="$(ask "INSTALL_BASE_DIR" "/usr/local")"
    CONF_P="$(ask   "CONFIG_FILE_PATTERN" "/etc/my_{ID}.cnf")"

    # ----- topology (cong tac tong) - bam so -----
    echo
    local TOPOLOGY GALERA="false" MAXSCALE="false" IS_REPLICA="false" _ti
    _ti=$(menu_pick "Loai trien khai (TOPOLOGY):" \
        "single     - standalone master read-write" \
        "dr         - standalone replica read_only (async tu PRIMARY_NODES)" \
        "cluster    - Galera cluster read-write" \
        "dr-cluster - Galera cluster replica read_only (async tu primary cluster)")
    case "$_ti" in 1) TOPOLOGY=single ;; 2) TOPOLOGY=dr ;; 3) TOPOLOGY=cluster ;; 4) TOPOLOGY=dr-cluster ;; esac
    case "$TOPOLOGY" in cluster|dr-cluster) GALERA="true" ;; esac
    case "$TOPOLOGY" in dr|dr-cluster)      IS_REPLICA="true" ;; esac
    ok "  -> TOPOLOGY=$TOPOLOGY (galera=$GALERA, replica=$IS_REPLICA)"

    # ----- mode - bam so -----
    echo; local MODE _mi
    _mi=$(menu_pick "INSTALL_MODE:" \
        "fresh  - server trang / cai moi" \
        "expand - them instance vao server da co instance khac chay")
    case "$_mi" in 1) MODE=fresh ;; 2) MODE=expand ;; esac

    # ----- PRIMARY_NODES (chi replica: dr / dr-cluster) -----
    local PRIMARY_NODES=""
    if [ "$IS_REPLICA" = "true" ]; then
        echo; info ">>> Replica/DR: can IP primary de mo iptables keo binlog."
        PRIMARY_NODES="$(ask "PRIMARY_NODES (IP primary, cach nhau space)" "")"
    fi

    # ----- Galera (chi cluster / dr-cluster) -----
    local CLUSTER_NODES="" NODE_ROLE="bootstrap"
    if [ "$GALERA" = "true" ]; then
        echo; info ">>> Galera cluster:"
        CLUSTER_NODES="$(ask "CLUSTER_NODES (IP cac node, cach nhau dau space)" "")"
        local _ri; _ri=$(menu_pick "NODE_ROLE (vai tro server NAY):" \
            "bootstrap - node DAU khoi tao cluster" \
            "joiner    - node 2+ (data sync qua SST, deploy skip 05)")
        case "$_ri" in 1) NODE_ROLE=bootstrap ;; 2) NODE_ROLE=joiner ;; esac
        echo
        if ask_yes "Bat MaxScale? (chi dung cho Galera)" "n"; then MAXSCALE="true"; fi
    fi

    # ----- tuning -----
    echo; local RESERVED DISK _di
    RESERVED="$(ask "RESERVED_RAM_PCT (% RAM giu cho OS)" "25")"
    _di=$(menu_pick "DISK_TYPE:" "auto - tu detect SSD/HDD" "ssd" "hdd")
    case "$_di" in 1) DISK=auto ;; 2) DISK=ssd ;; 3) DISK=hdd ;; esac

    # ----- passwords -----
    echo; info ">>> Mat khau chung (noi dung nhap se khong hien):"
    local ADMIN_PASS COMMON_PASS INSTANCE_CONFIG_ROWS="" INSTANCE_SETTINGS_SUMMARY=""
    ADMIN_PASS="$(ask_secret "ADMIN_PASS (root)")"
    COMMON_PASS="$(ask_secret "COMMON_PASS (monitor/backup...)")"

    echo; info ">>> Cau hinh rieng cho tung instance:"
    local sid _port _mgnt _size _buf _rw _ro cluster_name galera_pass maxscale_pass
    local q_cluster q_galera q_maxscale galera_status maxscale_status
    while read -r sid _port _mgnt _size _buf _rw _ro; do
        [ -n "$sid" ] || continue
        if [ "$sid" = "0" ]; then
            cluster_name="cluster"
        else
            cluster_name="cluster_${sid}"
        fi
        galera_pass=""

        echo "  Instance ID=$sid"
        if [ "$GALERA" = "true" ]; then
            cluster_name="$(ask "CLUSTER_NAME_${sid}" "$cluster_name")"
            galera_pass="$(ask_secret "GALERA_PASS_${sid} (SST mariabackup)")"
        fi
        maxscale_pass="$(ask_secret "MAXSCALE_PASS_${sid}")"

        printf -v q_cluster '%q' "$cluster_name"
        printf -v q_galera '%q' "$galera_pass"
        printf -v q_maxscale '%q' "$maxscale_pass"
        INSTANCE_CONFIG_ROWS+="INSTANCE_${sid}=(${_port} ${_mgnt} ${_size} ${_buf} ${_rw} ${_ro} ${q_cluster} ${q_galera} ${q_maxscale})"$'\n'
        galera_status="-"
        [ "$GALERA" = "true" ] && galera_status="$([ -n "$galera_pass" ] && echo da-nhap || echo CHUA-NHAP)"
        maxscale_status="$([ -n "$maxscale_pass" ] && echo da-nhap || echo CHUA-NHAP)"
        INSTANCE_SETTINGS_SUMMARY+="    ID=$sid  cluster=$cluster_name  galera=$galera_status  maxscale=$maxscale_status"$'\n'
    done <<< "$TABLE_ROWS"
    INSTANCE_CONFIG_ROWS="${INSTANCE_CONFIG_ROWS%$'\n'}"

    # ----- preview -----
    clear; hr; echo "${C_BOLD}  XEM LAI CAU HINH${C_RESET}"; hr
    echo "  TOPOLOGY         : $TOPOLOGY  (galera=$GALERA, replica=$IS_REPLICA)"
    [ "$IS_REPLICA" = "true" ] && echo "  PRIMARY_NODES    : ${PRIMARY_NODES:-(chua dien!)}"
    echo "  So instance      : $N"
    echo "  INSTALL_MODE     : $MODE"
    echo "  MaxScale         : $MAXSCALE"
    echo "  RESERVED_RAM_PCT : $RESERVED    DISK_TYPE: $DISK"
    echo "  Quy uoc ten      : ID=0 -> my.cnf (khong so); ID>=1 -> my_<ID>.cnf"
    echo "  Bang instance (ID PORT MGNT SIZE BUF RW RO):"
    echo "${TABLE_ROWS}" | sed 's/^/    /'
    echo "  Settings theo ID (mat khau khong hien):"
    printf '%s' "$INSTANCE_SETTINGS_SUMMARY"
    hr
    if ! ask_yes "Ghi cau hinh nay vao $ENV_FILE?" "y"; then
        warnx "Da huy, khong ghi."; pause; return
    fi

    # backup ban cu
    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"
        ok "Da backup ban cu -> ${ENV_FILE}.bak.*"
    fi
    mkdir -p "$(dirname "$ENV_FILE")"

    write_env_file \
        "$DATA_P" "$TMP_P" "$LOG_P" "$BINLOG_P" "$INSTALL_BASE" "$CONF_P" \
        "$MODE" "$TOPOLOGY" "$CLUSTER_NODES" "$NODE_ROLE" "$INSTANCE_CONFIG_ROWS" \
        "$MAXSCALE" "$RESERVED" "$DISK" \
        "$ADMIN_PASS" "$COMMON_PASS" "$PRIMARY_NODES"

    ok "Da ghi $ENV_FILE"
    echo
    if ask_yes "Chay deploy.sh ngay bay gio?" "n"; then
        do_deploy
    else
        pause
    fi
}

write_env_file() {
    local DATA_P="$1" TMP_P="$2" LOG_P="$3" BINLOG_P="$4" INSTALL_BASE="$5" CONF_P="$6" \
          MODE="$7" TOPOLOGY="$8"
    shift 8
    local CLUSTER_NODES="$1" NODE_ROLE="$2" INSTANCE_CONFIG_ROWS="$3" \
          MAXSCALE="$4" RESERVED="$5" DISK="$6" \
          ADMIN_PASS="$7" COMMON_PASS="$8" PRIMARY_NODES="$9"
    local ADMIN_PASS_Q COMMON_PASS_Q
    printf -v ADMIN_PASS_Q '%q' "$ADMIN_PASS"
    printf -v COMMON_PASS_Q '%q' "$COMMON_PASS"

    cat > "$ENV_FILE" <<EOF
# Sinh boi setup.sh. Mo ta chi tiet: README.md

# CORE / TOPOLOGY
TOPOLOGY="$TOPOLOGY"
INSTALL_MODE="$MODE"
DR_NODE_IP=""
PRIMARY_NODES="$PRIMARY_NODES"

# INSTANCES: PORT MGNT SIZE_GB BUF_MB MAX_RW MAX_RO CLUSTER GALERA_PASS MAXSCALE_PASS
$INSTANCE_CONFIG_ROWS

# PATHS / NAMING
DATA_DIR_PATTERN="$DATA_P"
TMP_DIR_PATTERN="$TMP_P"
LOG_DIR_PATTERN="$LOG_P"
BINLOG_DIR_PATTERN="$BINLOG_P"
INSTALL_BASE_DIR="$INSTALL_BASE"
INSTANCE_NAME_PREFIX="mariadb"
CONFIG_FILE_PATTERN="$CONF_P"

# GALERA
CLUSTER_NODES="$CLUSTER_NODES"
NODE_ROLE="$NODE_ROLE"
NODE_NAME_PREFIX="db"
WSREP_BASE_PORT=1030
WSREP_PORT_STEP=100
GALERA_USER_PREFIX="galera"
SERVER_ID_BASE=1
GTID_DOMAIN_BASE=100

# MAXSCALE
ENABLE_MAXSCALE=$MAXSCALE
MAXSCALE_USER="maxscale"
MAXSCALE_REST_BASE_PORT=1800
MAXSCALE_PACKAGE_TYPE="auto"

# DATABASE INIT / TUNING
ADMIN_PASS=$ADMIN_PASS_Q
COMMON_PASS=$COMMON_PASS_Q
EMPTY_CLUSTER=false
RESERVED_RAM_PCT=$RESERVED
DISK_TYPE="$DISK"
EXPIRE_LOGS_DAYS=3

# BACKUP / DB JOBS
DB_SCRIPT_DIR="/u01/apps/db_script"
DB_JOB_OS_USER="mariadb_jobs"
VECTOR_OS_USER="vector_mariadb"
VECTOR_OS_GROUP="vector_mariadb"
MARIADB_LOG_GROUP="mariadb_log_readers"
BACKUP_DIR="/backup/backup_mariadb"
BACKUP_RETENTION_DAYS=3
BACKUP_DB_USER="mbackup"
BACKUP_DB_PASS=""
MINIO_MC_BIN="/usr/local/bin/mc"
MINIO_ALIAS="backup"
MINIO_CHECKSUM_BUCKET="checksum"
MINIO_BUCKET_PREFIX="db-"
BACKUP_ENC_PASS=""

# HOST / NETWORK
ENABLE_NUMA_DISABLE=true
ENABLE_THP_DISABLE=true
MAX_OPEN_FILES=1000000
SYSLOG_IP="127.0.0.1"
NTP_IP="127.0.0.1"
DNS_IP="8.8.8.8"
MGMT_NODES=""
EOF
}

# ============================================================
#  HANH DONG
# ============================================================
show_summary() {
    need_env || return
    ( cd "$ROOT_DIR" && bash scripts/show_config.sh ) 2>&1 | less -R 2>/dev/null \
        || ( cd "$ROOT_DIR" && bash scripts/show_config.sh )
    pause
}

do_deploy() {
    need_env || { pause; return; }
    need_root || { pause; return; }
    ( cd "$ROOT_DIR" && bash deploy.sh )
    pause
}

run_one() {  # run_one "scripts/XX.sh"
    need_env || { pause; return; }
    need_root || { pause; return; }
    if [ ! -f "$ROOT_DIR/$1" ]; then errx "Khong thay $1"; pause; return; fi
    ( cd "$ROOT_DIR" && bash "$1" )
    pause
}

steps_menu() {
    while true; do
        clear; hr; echo "${C_BOLD}  CHAY TUNG BUOC${C_RESET}"; hr
        cat <<MENU
  1) 01_prepare_system        (sysctl, limits, user, folder)
  2) 02_install_mariadb_binary
  3) 03_configure_mariadb     (sinh my.cnf)
  4) 04_enable_mariadb_service (systemd unit)
  5) 05_prepare_database      (init datadir)
  6) 06_initialize_database   (root pass + import users/schema)
  7) 07_maxscale_install
  8) 08_install_db_jobs       (cron jobs)
  9) 09_install_vector        (log shipping)
  0) Quay lai
MENU
        hr
        local c; c="$(ask "Chon" "0")"
        case "$c" in
            1) run_one "scripts/01_prepare_system.sh" ;;
            2) run_one "scripts/02_install_mariadb_binary.sh" ;;
            3) run_one "scripts/03_configure_mariadb.sh" ;;
            4) run_one "scripts/04_enable_mariadb_service.sh" ;;
            5) run_one "scripts/05_prepare_database.sh" ;;
            6) run_one "scripts/06_initialize_database.sh" ;;
            7) run_one "scripts/07_maxscale_install.sh" ;;
            8) run_one "scripts/08_install_db_jobs.sh" ;;
            9) run_one "scripts/09_install_vector.sh" ;;
            0) return ;;
            *) ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        hr
        echo "${C_BOLD}  MARIADB MULTI-INSTANCE  -  SETUP${C_RESET}"
        if [ -f "$ENV_FILE" ]; then
            local ids topo
            topo="$(grep -E '^TOPOLOGY=' "$ENV_FILE" | head -1 | cut -d'"' -f2)"
            ids="$(sed -nE 's/^INSTANCE_([0-9]+)=.*/\1/p' "$ENV_FILE" | tr '\n' ' ')"
            if [ -z "$ids" ]; then
                ids="$(awk '/INSTANCES_TABLE=/{f=1;next} /^"/{f=0} f && $1 ~ /^[0-9]+$/{printf "%s ",$1}' "$ENV_FILE")"
            fi
            echo "  Topology: ${topo:-?}   |   Instance ID: ${ids:-?}"
        else
            warnx "  (chua co cau hinh - chay [1] truoc)"
        fi
        hr
        cat <<MENU
  1) Wizard tao / sua cau hinh   (configs/cluster.env)
  2) Xem cau hinh + gia tri auto-tune
  3) DEPLOY day du               (deploy.sh: 01->05)
  4) Chay tung buoc (01..09)
  5) Init DB: root pass + users  (06)
  6) Cai MaxScale                (07)
  7) Cai cron jobs               (08)
  8) Cai Vector log shipping     (09)
  0) Thoat
MENU
        hr
        local c; c="$(ask "Chon" "")"
        case "$c" in
            1) run_wizard ;;
            2) show_summary ;;
            3) do_deploy ;;
            4) steps_menu ;;
            5) run_one "scripts/06_initialize_database.sh" ;;
            6) run_one "scripts/07_maxscale_install.sh" ;;
            7) run_one "scripts/08_install_db_jobs.sh" ;;
            8) run_one "scripts/09_install_vector.sh" ;;
            0|q|Q) ok "Tam biet."; exit 0 ;;
            *) ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main_menu
fi
