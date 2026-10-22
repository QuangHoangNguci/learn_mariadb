#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

source ../configs/cluster.env
source ./common.sh

check_root
log "===== START INSTALL DB JOBS (MULTI INSTANCE) ====="

# Nạp INSTANCE_IDS, INSTANCE_PORT... từ cấu hình instance
validate_cluster_env

DB_SCRIPT_DIR="${DB_SCRIPT_DIR:-/u01/apps/db_script}"
ROLE="${NODE_ROLE:-bootstrap}"
DB_JOB_OS_USER="${DB_JOB_OS_USER:-mariadb_jobs}"
MARIADB_LOG_GROUP="${MARIADB_LOG_GROUP:-mariadb_log_readers}"
# Chỉ dùng để gỡ cron của phiên bản cũ; backup mới không chạy bằng user này.
LEGACY_BACKUP_OS_USER="${BACKUP_OS_USER:-}"

ensure_dir "$DB_SCRIPT_DIR"
chmod 755 "$DB_SCRIPT_DIR"

# Partition/analyze không cần quyền root hay user của MariaDB daemon nên dùng
# một system user riêng; shell nologin vẫn chạy được từ /etc/cron.d.
if ! id "$DB_JOB_OS_USER" >/dev/null 2>&1; then
    NOLOGIN_SHELL="$(command -v nologin 2>/dev/null || true)"
    NOLOGIN_SHELL="${NOLOGIN_SHELL:-/usr/sbin/nologin}"
    useradd --system --no-create-home --home-dir /nonexistent \
        --shell "$NOLOGIN_SHELL" "$DB_JOB_OS_USER"
    log "Da tao DB job OS user: $DB_JOB_OS_USER"
fi
DB_JOB_OS_GROUP="$(id -gn "$DB_JOB_OS_USER")"
if ! getent group "$MARIADB_LOG_GROUP" >/dev/null 2>&1; then
    groupadd --system "$MARIADB_LOG_GROUP"
fi

# Tạo sẵn thư mục log_innodb cho từng instance (innodb_stat.sh cần có sẵn)
for id in "${INSTANCE_IDS[@]}"; do
    INSTANCE_LOG_DIR="$(get_log_dir "$id")"
    ensure_dir "${INSTANCE_LOG_DIR}/log_innodb"

    USER="$(get_instance_user "$id")"
    usermod -a -G "$MARIADB_LOG_GROUP" "$USER"
    chown "$USER:$MARIADB_LOG_GROUP" "$INSTANCE_LOG_DIR"
    chmod 2750 "$INSTANCE_LOG_DIR"
    chown -R "$USER:$MARIADB_LOG_GROUP" "${INSTANCE_LOG_DIR}/log_innodb"
    find "${INSTANCE_LOG_DIR}/log_innodb" -type d -exec chmod 2750 {} +
    find "${INSTANCE_LOG_DIR}/log_innodb" -type f -exec chmod 640 {} +
    for log_file in mariadb.error.log mariadb.slow.log innodb_stat.log database_audit.log; do
        log_path="$INSTANCE_LOG_DIR/$log_file"
        [ -e "$log_path" ] || continue
        chown "$USER:$MARIADB_LOG_GROUP" "$log_path"
        chmod 640 "$log_path"
    done

    # Bản cũ cài logrotate hệ thống (chạy root) cũng xoay error/slow log, trùng
    # với job rotate theo instance bên dưới. Gỡ file đó khi migrate sang non-root.
    LEGACY_LOGROTATE_FILE="/etc/logrotate.d/$(get_service_name "$id")"
    if [ -f "$LEGACY_LOGROTATE_FILE" ]; then
        rm -f "$LEGACY_LOGROTATE_FILE"
        log "Removed legacy root logrotate config: $LEGACY_LOGROTATE_FILE"
    fi
done

# IP local để innodb_stat.sh gắn nhãn server chính xác
LOCAL_IP="${DR_NODE_IP:-$(hostname -I | awk '{print $1}')}"

# Quyền sở hữu backup: mỗi instance chạy bằng đúng MariaDB OS user của nó
BACKUP_DIR_EFF="${BACKUP_DIR:-/backup/backup_mariadb}"
ensure_dir "$BACKUP_DIR_EFF"
chmod 755 "$BACKUP_DIR_EFF" "$DB_SCRIPT_DIR"
ensure_parents_traversable "$BACKUP_DIR_EFF"
ensure_parents_traversable "$DB_SCRIPT_DIR"

# mc thường được user cài đặt copy vào /usr/local/bin với mode 0760, khiến cron
# chạy bằng MariaDB OS user không thực thi được. Chuẩn hóa binary dùng chung;
# alias của root sẽ được copy sang config riêng của từng instance.
MC_BIN_EFF="${MINIO_MC_BIN:-/usr/local/bin/mc}"
MC_ALIAS_EFF="${MINIO_ALIAS:-backup}"
ROOT_HOME="$(getent passwd root | awk -F: 'NR==1 {print $6}')"
ROOT_HOME="${ROOT_HOME:-/root}"
ROOT_MC_CONFIG_DIR="${MINIO_ROOT_CONFIG_DIR:-${ROOT_HOME}/.mc}"
ROOT_MC_ALIAS_READY=false

if [ -e "$MC_BIN_EFF" ]; then
    chown root:root "$MC_BIN_EFF"
    chmod 755 "$MC_BIN_EFF"
    log "MinIO mc permission: root:root 0755 ($MC_BIN_EFF)"

    if [ -d "$ROOT_MC_CONFIG_DIR" ] && \
       "$MC_BIN_EFF" --config-dir "$ROOT_MC_CONFIG_DIR" alias ls "$MC_ALIAS_EFF" >/dev/null 2>&1; then
        ROOT_MC_ALIAS_READY=true
        log "MinIO alias '$MC_ALIAS_EFF': se copy tu $ROOT_MC_CONFIG_DIR cho tung MariaDB OS user"
    else
        warn "MinIO alias '$MC_ALIAS_EFF' chua co trong $ROOT_MC_CONFIG_DIR; backup van cai nhung se bo qua upload"
    fi
else
    warn "Khong tim thay MinIO mc: $MC_BIN_EFF; backup van cai nhung se bo qua upload"
fi

declare -A BACKUP_USER_BY_ID=()
declare -A BACKUP_GROUP_BY_ID=()
declare -A BACKUP_BASE_BY_ID=()
declare -A BACKUP_FILE_BY_ID=()
declare -A BACKUP_MC_CONFIG_BY_ID=()
declare -A INNODB_FILE_BY_ID=()
declare -A ROTATE_FILE_BY_ID=()

for id in "${INSTANCE_IDS[@]}"; do
    iuser="$(get_instance_user "$id")"
    id "$iuser" >/dev/null 2>&1 || die "Thieu MariaDB OS user: $iuser (instance $id)"
    igroup="$(id -gn "$iuser")"

    sfx="$(id_suffix "$id")"
    ibackup="${BACKUP_DIR_EFF}/instance${sfx}"
    ensure_dir "$ibackup/logs"
    chown "$iuser:$igroup" "$ibackup" "$ibackup/logs"
    chmod 700 "$ibackup" "$ibackup/logs"

    # Không phụ thuộc HOME của system user. Mỗi instance có một mc config dir
    # chỉ OS user chạy cron đọc được; nếu root đã set alias thì copy vào đây.
    imc_config="${ibackup}/.mc"
    ensure_dir "$imc_config"
    if [ "$ROOT_MC_ALIAS_READY" = true ]; then
        cp -a "${ROOT_MC_CONFIG_DIR}/." "$imc_config/"
    fi
    chown -R "$iuser:$igroup" "$imc_config"
    find "$imc_config" -type d -exec chmod 700 {} +
    find "$imc_config" -type f -exec chmod 600 {} +

    BACKUP_USER_BY_ID[$id]="$iuser"
    BACKUP_GROUP_BY_ID[$id]="$igroup"
    BACKUP_BASE_BY_ID[$id]="$ibackup"
    BACKUP_MC_CONFIG_BY_ID[$id]="$imc_config"
    log "Instance $id backup: user=$iuser dir=$ibackup"
    [ "$ROOT_MC_ALIAS_READY" = true ] && log "Instance $id MinIO config: $imc_config (alias=$MC_ALIAS_EFF)"
done

# Bản cũ tạo job root để sửa quyền datadir trước khi backup; thiết kế mới
# không dùng nữa vì backup chạy bằng chính MariaDB OS user.
LEGACY_FIXPERM_FILE="${DB_SCRIPT_DIR}/fix_db_dir_perm.sh"
if [ -f "$LEGACY_FIXPERM_FILE" ]; then
    rm -f "$LEGACY_FIXPERM_FILE"
    log "Da xoa script sua quyen backup cu: $LEGACY_FIXPERM_FILE"
fi

step "Generate auto_add_partition.sh"

AUTO_PART_FILE="${DB_SCRIPT_DIR}/auto_add_partition.sh"

{
    echo "#!/bin/bash"
    echo "# Auto create partition (2 thang, 1 run)"
    echo "# Sinh tu 08_install_db_jobs.sh - khong sua tay"
    echo ""
    echo "set -euo pipefail"
    echo "umask 077"
    printf 'IP=%q\n' "127.0.0.1"
    printf 'DB_USER=%q\n' "auto_add_partition"
    printf 'DB_PASS=%q\n' "${COMMON_PASS}"
    echo ""

    for id in "${INSTANCE_IDS[@]}"; do
        INSTALL_DIR="$(get_install_dir "$id")"
        PORT="${INSTANCE_PORT[$id]}"

        echo "# Instance $id"
        echo "${INSTALL_DIR}/bin/mariadb -u \"\$DB_USER\" -p\"\$DB_PASS\" -h \"\$IP\" -P ${PORT} -Bse \"CALL vsystem.auto_add_partition(2,1);\""
        echo "echo 'finished add partition on instance ${id}'"
        echo ""
    done
} > "$AUTO_PART_FILE"

chown "$DB_JOB_OS_USER:$DB_JOB_OS_GROUP" "$AUTO_PART_FILE"
chmod 700 "$AUTO_PART_FILE"
log "Generated: $AUTO_PART_FILE (owner=$DB_JOB_OS_USER)"

step "Generate innodb_stat script rieng cho tung instance"

for id in "${INSTANCE_IDS[@]}"; do
    SFX="$(id_suffix "$id")"
    INSTALL_DIR="$(get_install_dir "$id")"
    PORT="${INSTANCE_PORT[$id]}"
    INSTANCE_LOG_DIR="$(get_log_dir "$id")"
    INSTANCE_USER="$(get_instance_user "$id")"
    INSTANCE_GROUP="$(id -gn "$INSTANCE_USER")"
    INNODB_FILE="${DB_SCRIPT_DIR}/innodb_stat${SFX}.sh"
    INNODB_FILE_BY_ID[$id]="$INNODB_FILE"

    {
        cat <<EOF
#!/bin/bash
# Lay SHOW ENGINE INNODB STATUS cho instance ${id}
# Sinh tu 08_install_db_jobs.sh - khong sua tay
set -euo pipefail
umask 027

IP="${LOCAL_IP}"
DB_USER="monitor"
EOF
        printf 'DB_PASS=%q\n' "$COMMON_PASS"
        cat <<EOF
DATE=\$(date +%Y%m%d_%H%M)
DIR_LOG="${INSTANCE_LOG_DIR}"
OUT="\$DIR_LOG/log_innodb/innodb_stat_\$DATE.txt"

mkdir -p "\$DIR_LOG/log_innodb"
echo "TIME \$(date '+%Y-%m-%d %H:%M:%S')" > "\$OUT"
echo "SERVER \$IP" >> "\$OUT"
"${INSTALL_DIR}/bin/mariadb" -u "\$DB_USER" -p"\$DB_PASS" -h 127.0.0.1 -P "${PORT}" \
    -Bse "SHOW ENGINE INNODB STATUS\\G" >> "\$OUT"
grep -v ", not started" "\$OUT" \
  | grep -v "lock struct(s)" \
  | grep -v "waiting for completed aio requests" \
  | grep -v "node heap has" >> "\$DIR_LOG/innodb_stat.log"
EOF
    } > "$INNODB_FILE"
    chown "$INSTANCE_USER:$INSTANCE_GROUP" "$INNODB_FILE"
    chmod 700 "$INNODB_FILE"
    log "Generated: $INNODB_FILE (owner=$INSTANCE_USER)"
done

step "Generate backup script rieng cho tung instance"

DB_PASS_EFF="${BACKUP_DB_PASS:-${COMMON_PASS}}"

for id in "${INSTANCE_IDS[@]}"; do
    INSTALL_DIR="$(get_install_dir "$id")"
    DATA_DIR="$(get_data_dir "$id")"
    CONF_FILE="$(get_conf_file "$id")"
    SOCKET=""

    # cluster.env có thể đã cũ trong khi MariaDB đang chạy bằng my.cnf render
    # trước đó. Ưu tiên socket thực tế trong my.cnf để job backup không trỏ
    # nhầm vào DATA_DIR_PATTERN cũ; chỉ dùng fallback khi my.cnf chưa có.
    if [ -r "$CONF_FILE" ]; then
        SOCKET="$(awk '
            /^[[:space:]]*socket[[:space:]]*=/ {
                value=$0
                sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]*[#;].*$/, "", value)
                sub(/^[[:space:]\"]+/, "", value)
                sub(/[[:space:]\"]+$/, "", value)
                print value
                exit
            }
        ' "$CONF_FILE")"
    fi
    [ -n "$SOCKET" ] || SOCKET="${DATA_DIR}/mariadb.sock"

    if [ -S "$SOCKET" ]; then
        log "Instance $id backup socket: $SOCKET (config=$CONF_FILE)"
    else
        warn "Instance $id: socket chua ton tai: $SOCKET (kiem tra $CONF_FILE va DATA_DIR_PATTERN)"
    fi
    SFX="$(id_suffix "$id")"
    BACKUP_USER="${BACKUP_USER_BY_ID[$id]}"
    BACKUP_GROUP="${BACKUP_GROUP_BY_ID[$id]}"
    BACKUP_BASE="${BACKUP_BASE_BY_ID[$id]}"
    INSTANCE_MC_CONFIG="${BACKUP_MC_CONFIG_BY_ID[$id]}"
    BACKUP_FILE="${DB_SCRIPT_DIR}/backup_database${SFX}.sh"
    BACKUP_FILE_BY_ID[$id]="$BACKUP_FILE"

{
    echo "#!/bin/bash"
    echo "# Backup mariabackup instance ${id} - chay bang OS user ${BACKUP_USER}"
    echo "# Sinh tu 08_install_db_jobs.sh - khong sua tay"
    echo ""
    echo "set -uo pipefail"
    echo "umask 077"
    echo ""
    echo "DATETIME=\$(date +%Y%m%d%H%M)"
    echo "START_TIME=\$(date +'%F %T')"
    printf 'IP=%q\n' "$LOCAL_IP"
    printf 'INSTANCE_ID=%q\n' "$id"
    printf 'INSTANCE_SUFFIX=%q\n' "$SFX"
    printf 'INSTANCE_LABEL=%q\n' "mariadb${SFX}"
    printf 'BACKUP_DIR=%q\n' "$BACKUP_BASE"
    printf 'DAYS=%q\n' "${BACKUP_RETENTION_DAYS:-3}"
    printf 'DB_USER=%q\n' "${BACKUP_DB_USER:-mbackup}"
    printf 'DB_PASS=%q\n' "$DB_PASS_EFF"
    echo ""
    echo "# MinIO (thay cho rsync). mc chua ton tai / MC rong -> tu bo qua upload."
    printf 'MC=%q\n' "$MC_BIN_EFF"
    printf 'MC_CONFIG_DIR=%q\n' "$INSTANCE_MC_CONFIG"
    echo "export MC_CONFIG_DIR"
    printf 'MINIO_ALIAS=%q\n' "${MINIO_ALIAS:-backup}"
    printf 'MINIO_CHECKSUM_BUCKET=%q\n' "${MINIO_CHECKSUM_BUCKET:-checksum}"
    printf 'MINIO_BUCKET_PREFIX=%q\n' "${MINIO_BUCKET_PREFIX:-db-}"
    echo ""
    echo "# Ma hoa AES-256 at-rest. ENC_PASS rong -> KHONG ma hoa (backup de nguyen)."
    echo "# Dung -pass env: nen pass KHONG lo qua 'ps'. File chi OS user cua instance doc duoc."
    printf 'ENC_PASS=%q\n' "${BACKUP_ENC_PASS:-}"
    echo "export ENC_PASS"
    echo ""
    echo "ROOT_BACKUP=\"\$BACKUP_DIR/backup_\${IP}_\${INSTANCE_LABEL}_\${DATETIME}\""
    echo "LOG_DIR=\"\$BACKUP_DIR/logs\""
    echo "LOG_FILE=\"\$LOG_DIR/full_backup_\${IP}_\${DATETIME}.log\""
    echo ""
    echo "mkdir -p \"\$ROOT_BACKUP\" \"\$LOG_DIR\""
    echo "cd \"\$BACKUP_DIR\" || exit 1"
    echo ""
    echo "ihostname=\$(hostname)"
    echo ""

        cat <<EOF
# ===== Instance ${id} =====
INST_DIR${SFX}="\$ROOT_BACKUP"
mkdir -p "\$INST_DIR${SFX}"

INST_LOG${SFX}="\$LOG_DIR/instance${SFX}_\${DATETIME}.log"
INST_BIN${SFX}="${INSTALL_DIR}/bin"
INST_SOCK${SFX}="${SOCKET}"
INST_CONF${SFX}="${CONF_FILE}"

if [ ! -S "\$INST_SOCK${SFX}" ]; then
    echo "[\$(date '+%F %T')] ERROR: MariaDB socket khong ton tai: \$INST_SOCK${SFX} (config=\$INST_CONF${SFX})" | tee -a "\$INST_LOG${SFX}" "\$LOG_FILE" >&2
    exit 1
fi

INST_BACKUP_BIN${SFX}="\$INST_BIN${SFX}/mariadb-backup"
[ -x "\$INST_BACKUP_BIN${SFX}" ] || INST_BACKUP_BIN${SFX}="\$INST_BIN${SFX}/mariabackup"
if [ ! -x "\$INST_BACKUP_BIN${SFX}" ]; then
    echo "[\$(date '+%F %T')] ERROR: Khong tim thay mariadb-backup/mariabackup trong \$INST_BIN${SFX}" | tee -a "\$INST_LOG${SFX}" "\$LOG_FILE" >&2
    exit 1
fi

START${SFX}=\$(date +%s)
ITIME${SFX}=\$(date +'%F %T')

# Lay master flag (chi de log, khong gate backup)
ISMASTER${SFX}=\$("\$INST_BIN${SFX}/mariadb" -u "\$DB_USER" -p"\$DB_PASS" -S "\$INST_SOCK${SFX}" -Bse "CALL vsystem.check_master('\$ihostname','\$IP');" 2>/dev/null || echo "UNKNOWN")
echo "\$ISMASTER${SFX}" > "\$INST_DIR${SFX}/ismaster.info"

INPUT_SIZE${SFX}=\$("\$INST_BIN${SFX}/mariadb" -u "\$DB_USER" -p"\$DB_PASS" -S "\$INST_SOCK${SFX}" -Bse "SELECT CONCAT(ROUND((SUM(DATA_LENGTH)+SUM(INDEX_LENGTH))/1024/1024/1024,3),'G') FROM information_schema.tables;" 2>/dev/null || echo "0G")

# Run mariadb-backup (fallback mariabackup cho ban MariaDB cu)
"\$INST_BACKUP_BIN${SFX}" --backup --galera-info --compress \\
    --target-dir="\$INST_DIR${SFX}/database" \\
    --user="\$DB_USER" --password="\$DB_PASS" \\
    --socket="\$INST_SOCK${SFX}" \\
    >> "\$INST_LOG${SFX}" 2>&1
RC${SFX}=\$?

END${SFX}=\$(date +%s)
ETIME${SFX}=\$(date +'%F %T')
DURATION${SFX}=\$((END${SFX} - START${SFX}))

if [ "\$RC${SFX}" -eq 0 ] && grep -q "completed OK!" "\$INST_LOG${SFX}" 2>/dev/null; then
    STATUS${SFX}="OK"
    OUTPUT_SIZE${SFX}=\$(du -sh "\$INST_DIR${SFX}/database" 2>/dev/null | awk '{print \$1}')
else
    STATUS${SFX}="NOK"
    OUTPUT_SIZE${SFX}="0"
fi

# ===== PITR: copy binlog vao instance/binlog (giong production) - se duoc ma hoa o buoc chung =====
BINLOGFILE${SFX}=""; BINLOGPOS${SFX}=""; GTID${SFX}=""
if [ "\$STATUS${SFX}" = "OK" ]; then
    BLDST="\$INST_DIR${SFX}/binlog"; mkdir -p "\$BLDST"
    # Vi tri binlog luc backup: mariadb_backup_binlog_info = <file>\\t<pos>\\t<gtid>
    BLINFO="\$INST_DIR${SFX}/database/mariadb_backup_binlog_info"
    BLRAW=""
    [ -f "\$BLINFO.qp" ] && BLRAW=\$(qpress -do "\$BLINFO.qp" 2>/dev/null)
    { [ -z "\$BLRAW" ] && [ -f "\$BLINFO" ]; } && BLRAW=\$(cat "\$BLINFO")
    BINLOGFILE${SFX}=\$(printf '%s' "\$BLRAW" | awk 'NR==1{print \$1}')
    BINLOGPOS${SFX}=\$(printf '%s' "\$BLRAW" | awk 'NR==1{print \$2}')
    GTID${SFX}=\$(printf '%s' "\$BLRAW" | awk 'NR==1{print \$3}')
    # Index binlog + binlog cua lan backup truoc (de copy incremental)
    BLIDX=\$("\$INST_BIN${SFX}/mariadb" -u "\$DB_USER" -p"\$DB_PASS" -S "\$INST_SOCK${SFX}" -Bse "SELECT @@log_bin_index" 2>/dev/null)
    LASTBL=\$("\$INST_BIN${SFX}/mariadb" -u "\$DB_USER" -p"\$DB_PASS" -S "\$INST_SOCK${SFX}" -Bse "SELECT binlog_file FROM vsystem.backup_history WHERE status='OK' AND binlog_file IS NOT NULL AND ip='\$IP' ORDER BY start_time DESC LIMIT 1" 2>/dev/null)
    if [ -n "\$BLIDX" ] && [ -f "\$BLIDX" ]; then
        cp "\$BLIDX" "\$BLDST/mysql-bin.index" 2>/dev/null || true
        # tu binlog cua lan backup truoc -> het; chua co lan nao -> copy tat ca
        if [ -n "\$LASTBL" ] && grep -qF "\$LASTBL" "\$BLIDX"; then
            BLLIST=\$(awk -v k="\$LASTBL" 'index(\$0,k){f=1} f{print}' "\$BLIDX")
        else
            BLLIST=\$(cat "\$BLIDX")
        fi
        printf '%s\\n' "\$BLLIST" | while read -r bl; do
            { [ -n "\$bl" ] && [ -f "\$bl" ]; } && qpress "\$bl" "\$BLDST/\$(basename "\$bl").qp" 2>/dev/null
        done
    fi
fi

# Ghi backup_history (cluster-wide qua Galera replication)
"\$INST_BIN${SFX}/mariadb" -u "\$DB_USER" -p"\$DB_PASS" -S "\$INST_SOCK${SFX}" -Bse "
INSERT INTO vsystem.backup_history
(type, ip, ismaster, database_backup, status, start_time, end_time, duration,
 input_size, output_size, backup_dir, server_ftp, ftp_dir, ftp_status, number_backup,
 binlog_file, binlog_position, GTID)
VALUES
('mariabackup${SFX}','\$IP','\$ISMASTER${SFX}','--all-databases','\$STATUS${SFX}',
 '\$ITIME${SFX}','\$ETIME${SFX}','\$DURATION${SFX}',
 '\$INPUT_SIZE${SFX}','\$OUTPUT_SIZE${SFX}','\$ROOT_BACKUP','','','','\$DAYS',
 '\$BINLOGFILE${SFX}','\$BINLOGPOS${SFX}','\$GTID${SFX}');" 2>/dev/null || true

echo "[INSTANCE ${id}] status=\$STATUS${SFX} duration=\${DURATION${SFX}}s output=\$OUTPUT_SIZE${SFX}" | tee -a "\$LOG_FILE"

if [ "\$STATUS${SFX}" != "OK" ]; then
    echo "[INSTANCE ${id}] Backup that bai; xem log: \$INST_LOG${SFX}" | tee -a "\$LOG_FILE" >&2
    exit 1
fi

EOF
    cat <<'EOF'
# ===== Ma hoa AES-256 tung file (at-rest) - CHAY TRUOC checksum =====
# Ma hoa tung file (khong gop) -> 1 file hong chi anh huong file do.
# checksum_*.sha256 giu dang RO de doi soat; file da .enc thi bo qua (chay lai an toan).
if [ -n "$ENC_PASS" ]; then
    echo "[$(date '+%F %T')] Bat dau ma hoa AES-256-CBC..." >> "$LOG_FILE"
    find "$ROOT_BACKUP" -type f ! -name '*.enc' ! -name 'checksum_*.sha256' -print0 \
      | xargs -0 -P4 -I{} sh -c \
        'openssl enc -aes-256-cbc -pbkdf2 -md sha256 -salt -pass env:ENC_PASS -in "$1" -out "$1.enc" && rm -f "$1"' _ {} 2>> "$LOG_FILE"
    LEFT=$(find "$ROOT_BACKUP" -type f ! -name '*.enc' ! -name 'checksum_*.sha256' | wc -l)
    echo "[$(date '+%F %T')] Ma hoa xong (con $LEFT file ro chua ma hoa - can =0)" >> "$LOG_FILE"
fi

# ===== Checksum toan bo backup (checksum tinh tren file .enc) =====
CHECKSUM_FILE="$ROOT_BACKUP/checksum_${IP}_${DATETIME}.sha256"
echo "[$(date '+%F %T')] Bat dau checksum..." >> "$LOG_FILE"
( cd "$ROOT_BACKUP" && find . -type f ! -name "checksum_*.sha256" -print0 \
    | xargs -0 -P 8 sha256sum > "$CHECKSUM_FILE" 2>> "$LOG_FILE" )
echo "[$(date '+%F %T')] Da checksum $(wc -l < "$CHECKSUM_FILE" 2>/dev/null) file -> $CHECKSUM_FILE" >> "$LOG_FILE"

# ===== Day len MinIO (thay cho rsync) =====
# Kiem tra ca mc TON TAI va alias DA CAU HINH. Neu alias chua set, mc coi
# "$MINIO_ALIAS" la duong dan LOCAL -> ghi backup vao ./backup thay vi MinIO.
if [ -n "$MC" ] && [ -x "$MC" ] && "$MC" alias ls "$MINIO_ALIAS" >/dev/null 2>&1; then
    BACKUP_NAME="backup_${IP}_${INSTANCE_LABEL}_${DATETIME}"
    MINIO_BUCKET="${MINIO_BUCKET_PREFIX}${IP}"
    # (1) checksum -> bucket checksum rieng (admin tao san)
    "$MC" cp "$CHECKSUM_FILE" \
        "$MINIO_ALIAS/$MINIO_CHECKSUM_BUCKET/$IP/$INSTANCE_LABEL/checksum_${IP}_${INSTANCE_LABEL}_${DATETIME}.sha256" >> "$LOG_FILE" 2>&1
    # (2) tao bucket db-<IP> neu chua co
    "$MC" mb --ignore-existing "$MINIO_ALIAS/$MINIO_BUCKET" >> "$LOG_FILE" 2>&1
    # (3) mirror toan bo backup len MinIO
    echo "[$(date '+%F %T')] Day len MinIO bucket $MINIO_BUCKET..." >> "$LOG_FILE"
    "$MC" mirror --overwrite "$ROOT_BACKUP" "$MINIO_ALIAS/$MINIO_BUCKET/$BACKUP_NAME" >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        echo "[$(date '+%F %T')] Day MinIO OK: $BACKUP_NAME" >> "$LOG_FILE"
    else
        echo "[$(date '+%F %T')] LOI day MinIO" >> "$LOG_FILE"
    fi
else
    echo "[$(date '+%F %T')] Bo qua MinIO: mc khong execute duoc ($MC) HOAC alias '$MINIO_ALIAS' chua co trong $MC_CONFIG_DIR." >> "$LOG_FILE"
    echo "  -> Cau hinh 1 lan: $MC --config-dir $MC_CONFIG_DIR alias set $MINIO_ALIAS <url> <access_key> <secret_key>" >> "$LOG_FILE"
fi

# ===== Retention (giu DAYS ban gan nhat, local) =====
cd "$BACKUP_DIR" || exit 1
COUNT=$(find . -maxdepth 1 -mindepth 1 -type d -name "backup_${IP}_${INSTANCE_LABEL}_*" | wc -l)
while [ "$COUNT" -gt "$DAYS" ]; do
    OLDEST=$(find . -maxdepth 1 -mindepth 1 -type d -name "backup_${IP}_${INSTANCE_LABEL}_*" -printf '%T@ %f\n' | sort -n | head -1 | cut -d' ' -f2-)
    [ -z "$OLDEST" ] && break
    rm -rf "$BACKUP_DIR/$OLDEST"
    COUNT=$((COUNT - 1))
done

echo "DONE: $START_TIME -> $(date +'%F %T')" | tee -a "$LOG_FILE"
EOF
} > "$BACKUP_FILE"

chmod 700 "$BACKUP_FILE"
chown "$BACKUP_USER:$BACKUP_GROUP" "$BACKUP_FILE"
log "Generated: $BACKUP_FILE (owner=$BACKUP_USER, dir=$BACKUP_BASE)"
done

step "Generate auto_analyze.sh"

ANALYZE_FILE="${DB_SCRIPT_DIR}/auto_analyze.sh"

{
    echo "#!/bin/bash"
    echo "# Auto daily analyze tables - multi instance"
    echo "# Sinh tu 08_install_db_jobs.sh - khong sua tay"
    echo ""
    echo "set -uo pipefail"
    echo "umask 077"
    printf 'IP=%q\n' "127.0.0.1"
    printf 'DB_USER=%q\n' "tdht"
    printf 'DB_PASS=%q\n' "${ADMIN_PASS}"
    echo ""

    for id in "${INSTANCE_IDS[@]}"; do
        INSTALL_DIR="$(get_install_dir "$id")"
        PORT="${INSTANCE_PORT[$id]}"

        cat <<EOF
# Instance ${id}
CMD_${id}="${INSTALL_DIR}/bin/mariadb"
CMARIADB_${id}=\$("\$CMD_${id}" -u "\$DB_USER" -p"\$DB_PASS" -h "\$IP" -P ${PORT} -Bse "show variables like '%version_comment%';" 2>/dev/null | grep -c "MariaDB")
CSTAT_${id}=\$("\$CMD_${id}" -u "\$DB_USER" -p"\$DB_PASS" -h "\$IP" -P ${PORT} -Bse "show variables like 'use_stat_tables';" 2>/dev/null | grep -vci "NEVER")

if [ "\$CMARIADB_${id}" -ge 1 ] && [ "\$CSTAT_${id}" -ge 1 ]; then
    "\$CMD_${id}" -u "\$DB_USER" -p"\$DB_PASS" -h "\$IP" -P ${PORT} -Bse "CALL vsystem.auto_daily_analyze(1);"
else
    "\$CMD_${id}" -u "\$DB_USER" -p"\$DB_PASS" -h "\$IP" -P ${PORT} -Bse "CALL vsystem.auto_daily_analyze(0);"
fi
echo "finished analyze on instance ${id}"

EOF
    done
} > "$ANALYZE_FILE"

chown "$DB_JOB_OS_USER:$DB_JOB_OS_GROUP" "$ANALYZE_FILE"
chmod 700 "$ANALYZE_FILE"
log "Generated: $ANALYZE_FILE (owner=$DB_JOB_OS_USER)"

step "Generate rotate_mariadb_log script rieng cho tung instance"

for id in "${INSTANCE_IDS[@]}"; do
    SFX="$(id_suffix "$id")"
    INSTANCE_LOG_DIR="$(get_log_dir "$id")"
    INSTANCE_USER="$(get_instance_user "$id")"
    INSTANCE_GROUP="$(id -gn "$INSTANCE_USER")"
    ROTATE_FILE="${DB_SCRIPT_DIR}/rotate_mariadb_log${SFX}.sh"
    ROTATE_FILE_BY_ID[$id]="$ROTATE_FILE"

    cat > "$ROTATE_FILE" <<EOF
#!/bin/bash
# Rotate log MariaDB instance ${id} bang dung MariaDB OS user
# Sinh tu 08_install_db_jobs.sh - khong sua tay
set -euo pipefail
umask 027

DATE=\$(date +%Y%m%d_%H%M)
DIR_LOG="${INSTANCE_LOG_DIR}"
MARIADB_ERROR_LOG="\$DIR_LOG/mariadb.error.log"
MARIADB_SLOW_LOG="\$DIR_LOG/mariadb.slow.log"
MARIADB_INNODB_LOG="\$DIR_LOG/innodb_stat.log"
TEMP_DIR="\$DIR_LOG/log_innodb.\$DATE"

mkdir -p "\$TEMP_DIR"

# Rotate innodb_stat do cung instance user tao.
if [ -d "\$DIR_LOG/log_innodb" ]; then
    find "\$DIR_LOG/log_innodb" -maxdepth 1 -name 'innodb_stat_*' -mmin +1 \
        -type f -exec mv -t "\$TEMP_DIR" -- {} +
fi
if find "\$TEMP_DIR" -mindepth 1 -maxdepth 1 -type f -print -quit | grep -q .; then
    tar -C "\$TEMP_DIR" -czf "\$TEMP_DIR.tgz" .
fi
rm -rf -- "\$TEMP_DIR"
find "\$DIR_LOG" -maxdepth 1 -name 'log_innodb.*.tgz' -mtime +30 -type f -delete
: > "\$MARIADB_INNODB_LOG"

# Copy-truncate giu nguyen inode de Vector tiep tuc doc file ma khong can
# reset checkpoint, restart service hay quyen systemctl.
for LOG_FILE in "\$MARIADB_ERROR_LOG" "\$MARIADB_SLOW_LOG"; do
    [ -f "\$LOG_FILE" ] || continue
    [ -s "\$LOG_FILE" ] || continue
    cp -- "\$LOG_FILE" "\$LOG_FILE.\$DATE"
    : > "\$LOG_FILE"
    gzip -f -- "\$LOG_FILE.\$DATE"
    find "\$DIR_LOG" -maxdepth 1 -name "\$(basename "\$LOG_FILE").*.gz" \
        -mtime +180 -type f -delete
done
EOF

    chown "$INSTANCE_USER:$INSTANCE_GROUP" "$ROTATE_FILE"
    chmod 700 "$ROTATE_FILE"
    log "Generated: $ROTATE_FILE (owner=$INSTANCE_USER)"
done

# Các script đã được sinh ở trên; bước này chỉ chọn job nào được cài cron.
# Mỗi job có marker riêng trong /etc/cron.d nên chạy lại với lựa chọn khác sẽ
# cộng dồn (không xóa job đã cài). Chọn '0' hoặc Enter = tất cả.
# Thứ tự ưu tiên cách chọn:
#   - Tham số dòng lệnh:  ./08_install_db_jobs.sh 1,3
#   - Biến môi trường:    JOBS=all ./08_install_db_jobs.sh
#   - Menu tương tác (khi có TTY)
#   - Không TTY và không chỉ định -> mặc định 'all' (tương thích pipeline)

# Catalog job: key -> nhãn | lịch cron | role cần (bootstrap|all).
# Mọi job cài qua /etc/cron.d có cột user; không ghi job mới vào root crontab.
JOB_ORDER=(partition innodb backup analyze rotate)
declare -A JOB_LABEL JOB_SCHED JOB_ROLE
JOB_LABEL[partition]="auto_add_partition"; JOB_SCHED[partition]="0 2 5,10,15,20,25 * *"; JOB_ROLE[partition]="bootstrap"
JOB_LABEL[innodb]="innodb_stat";           JOB_SCHED[innodb]="*/5 * * * *";              JOB_ROLE[innodb]="all"
JOB_LABEL[backup]="backup_database";       JOB_SCHED[backup]="30 23 * * *";              JOB_ROLE[backup]="all"
JOB_LABEL[analyze]="auto_analyze";         JOB_SCHED[analyze]="0 3 * * *";               JOB_ROLE[analyze]="bootstrap"
JOB_LABEL[rotate]="rotate_mariadb_log";    JOB_SCHED[rotate]="59 23 7,14,21,28 * *";     JOB_ROLE[rotate]="all"

DB_JOBS_CRON_FILE="/etc/cron.d/mariadb_db_jobs"

# install_crond_job <jobkey> <cron-line> [cron-line...]
# Marker riêng giúp chạy lại với lựa chọn lẻ mà không xóa các job đã cài.
install_crond_job() {
    local jkey="$1" b e tmp line
    shift
    b="# === MARIADB_JOB_${jkey} BEGIN ==="
    e="# === MARIADB_JOB_${jkey} END ==="
    tmp="$(mktemp)"

    if [ -f "$DB_JOBS_CRON_FILE" ]; then
        sed "/^${b}\$/,/^${e}\$/d" "$DB_JOBS_CRON_FILE" > "$tmp"
    else
        {
            echo "SHELL=/bin/bash"
            echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            echo "# Sinh tu 08_install_db_jobs.sh - khong sua tay"
        } > "$tmp"
    fi

    {
        echo "$b"
        for line in "$@"; do echo "$line"; done
        echo "$e"
    } >> "$tmp"

    chown root:root "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$DB_JOBS_CRON_FILE"
    log "  [+] $jkey -> $DB_JOBS_CRON_FILE"
}

remove_crond_job() {
    local jkey="$1" b e tmp
    [ -f "$DB_JOBS_CRON_FILE" ] || return 0
    b="# === MARIADB_JOB_${jkey} BEGIN ==="
    e="# === MARIADB_JOB_${jkey} END ==="
    grep -q "^${b}$" "$DB_JOBS_CRON_FILE" || return 0
    tmp="$(mktemp)"
    sed "/^${b}\$/,/^${e}\$/d" "$DB_JOBS_CRON_FILE" > "$tmp"
    chown root:root "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$DB_JOBS_CRON_FILE"
    log "  [-] Da go $jkey khoi $DB_JOBS_CRON_FILE"
}

remove_job_cron() {
    local cuser="$1" jkey="$2" b e tmp
    id "$cuser" >/dev/null 2>&1 || return 0
    b="# === MARIADB_JOB_${jkey} BEGIN ==="; e="# === MARIADB_JOB_${jkey} END ==="
    crontab -u "$cuser" -l 2>/dev/null | grep -q "^${b}$" || return 0
    tmp="$(mktemp)"
    crontab -u "$cuser" -l 2>/dev/null | sed "/^${b}\$/,/^${e}\$/d" > "$tmp" || true
    crontab -u "$cuser" "$tmp"; rm -f "$tmp"
    log "  [-] Da go cron cu $jkey khoi user $cuser"
}

# Hàm hỗ trợ migrate crontab phiên bản cũ.
purge_old_block() {
    local cuser="$1" tmp
    id "$cuser" >/dev/null 2>&1 || return 0
    if crontab -u "$cuser" -l 2>/dev/null | grep -q '^# === MARIADB_AUTO_JOBS BEGIN ===$'; then
        tmp="$(mktemp)"
        crontab -u "$cuser" -l 2>/dev/null | sed '/^# === MARIADB_AUTO_JOBS BEGIN ===$/,/^# === MARIADB_AUTO_JOBS END ===$/d' > "$tmp"
        crontab -u "$cuser" "$tmp"; rm -f "$tmp"
        warn "[$cuser] Da go block cron gop cu (MARIADB_AUTO_JOBS) de migrate sang /etc/cron.d."
    fi
}

LEGACY_COMBINED_ROOT=false
ROOT_CRON_SNAPSHOT="$(crontab -u root -l 2>/dev/null || true)"
if grep -q '^# === MARIADB_AUTO_JOBS BEGIN ===$' <<< "$ROOT_CRON_SNAPSHOT"; then
    LEGACY_COMBINED_ROOT=true
fi
declare -A LEGACY_ROOT_JOB_PRESENT=()
declare -A LEGACY_SCRIPT_TOKEN=()
LEGACY_SCRIPT_TOKEN[partition]="${DB_SCRIPT_DIR}/auto_add_partition.sh"
LEGACY_SCRIPT_TOKEN[innodb]="${DB_SCRIPT_DIR}/innodb_stat"
LEGACY_SCRIPT_TOKEN[backup]="${DB_SCRIPT_DIR}/backup_database"
LEGACY_SCRIPT_TOKEN[analyze]="${DB_SCRIPT_DIR}/auto_analyze.sh"
LEGACY_SCRIPT_TOKEN[rotate]="${DB_SCRIPT_DIR}/rotate_mariadb_log"
for old_job in partition innodb backup analyze rotate; do
    if grep -q "^# === MARIADB_JOB_${old_job} BEGIN ===$" <<< "$ROOT_CRON_SNAPSHOT" \
       || grep -Fq "${LEGACY_SCRIPT_TOKEN[$old_job]}" <<< "$ROOT_CRON_SNAPSHOT"; then
        LEGACY_ROOT_JOB_PRESENT[$old_job]=true
    fi
done
remove_job_cron root fixperm

remove_raw_root_job_lines() {
    local token="$1" tmp
    ROOT_CRON_SNAPSHOT="$(crontab -u root -l 2>/dev/null || true)"
    grep -Fq "$token" <<< "$ROOT_CRON_SNAPSHOT" || return 0
    tmp="$(mktemp)"
    printf '%s\n' "$ROOT_CRON_SNAPSHOT" | awk -v token="$token" \
        'index($0, token) == 0 { print }' > "$tmp"
    crontab -u root "$tmp"
    rm -f "$tmp"
    log "  [-] Da go raw root cron line chua: $token"
}

SEL="${1:-${JOBS:-}}"
if [ -z "$SEL" ]; then
    if [ -t 0 ]; then
        echo ""
        echo "  Chon cron muon cai (node role=$ROLE):"
        echo "    1) auto_add_partition   (chi bootstrap, user $DB_JOB_OS_USER)"
        echo "    2) innodb_stat          (moi node, MariaDB OS user/instance)"
        echo "    3) backup_database      (moi node, moi instance chay MariaDB OS user rieng)"
        echo "    4) auto_analyze         (chi bootstrap, user $DB_JOB_OS_USER)"
        echo "    5) rotate_mariadb_log   (moi node, MariaDB OS user/instance)"
        echo "    0) TAT CA"
        read -r -p "  Nhap (vd '1,3' hoac '0'=tat ca) [0]: " SEL || true
    else
        SEL="all"
    fi
fi
[ -z "$SEL" ] && SEL="0"

declare -a WANT=()
case "$SEL" in
    0|all|ALL|a|A) WANT=("${JOB_ORDER[@]}") ;;
    *)
        IFS=', ' read -r -a _nums <<< "$SEL"
        for n in "${_nums[@]}"; do
            case "$n" in
                1) WANT+=(partition) ;;
                2) WANT+=(innodb)    ;;
                3) WANT+=(backup)    ;;
                4) WANT+=(analyze)   ;;
                5) WANT+=(rotate)    ;;
                "") ;;
                *) warn "Bo qua lua chon khong hop le: '$n'" ;;
            esac
        done
        ;;
esac

# Nếu phát hiện cron root của bản cũ, tự đưa các job đó vào danh sách migrate
# để không mất job khi người dùng chỉ chọn một mục khác trong menu.
if [ "$LEGACY_COMBINED_ROOT" = true ]; then
    WANT+=(partition innodb backup analyze rotate)
fi
for old_job in partition innodb backup analyze rotate; do
    [ "${LEGACY_ROOT_JOB_PRESENT[$old_job]:-false}" = true ] && WANT+=("$old_job")
done

# Loại trùng WANT sau khi gộp lựa chọn và job legacy cần migrate.
declare -A WANT_SEEN=()
declare -a WANT_UNIQUE=()
for j in "${WANT[@]}"; do
    [ "${WANT_SEEN[$j]:-false}" = true ] && continue
    WANT_SEEN[$j]=true
    WANT_UNIQUE+=("$j")
done
WANT=("${WANT_UNIQUE[@]}")
[ ${#WANT[@]} -gt 0 ] || die "Khong chon job nao hop le."

if [ "$LEGACY_COMBINED_ROOT" = true ]; then
    purge_old_block root
fi
for j in "${WANT[@]}"; do
    remove_job_cron root "$j"
    remove_raw_root_job_lines "${LEGACY_SCRIPT_TOKEN[$j]}"
done
if [ "$ROLE" != "bootstrap" ]; then
    remove_crond_job partition
    remove_crond_job analyze
fi

step "Cai crontab cho job: ${WANT[*]}"

for j in "${WANT[@]}"; do
    if [ "${JOB_ROLE[$j]}" = "bootstrap" ] && [ "$ROLE" != "bootstrap" ]; then
        remove_crond_job "$j"
        warn "  ${JOB_LABEL[$j]}: chi chay tren node bootstrap -> da bo qua/go job cu (role hien tai=$ROLE)"
        continue
    fi

    if [ "$j" = "backup" ]; then
        FLOCK_BIN="$(command -v flock 2>/dev/null || true)"
        [ -n "$FLOCK_BIN" ] || die "Khong tim thay flock (goi util-linux); can de backup nhieu instance khong chay dong thoi."

        # File lock chung nằm trong BACKUP_DIR, root tạo sẵn để mọi MariaDB OS user
        # mở được. Thư mục cha do root sở hữu nên các user không thể xóa lock file.
        BACKUP_LOCK="${BACKUP_DIR_EFF}/.mariadb_backup.lock"
        touch "$BACKUP_LOCK"
        chmod 666 "$BACKUP_LOCK"

        # Dọn cron phiên bản cũ: root + runuser và fix_db_dir_perm.
        remove_job_cron root backup
        if [ -n "$LEGACY_BACKUP_OS_USER" ]; then
            purge_old_block "$LEGACY_BACKUP_OS_USER"
            remove_job_cron "$LEGACY_BACKUP_OS_USER" backup
        fi

        # Không dùng crontab -u: nhiều server chỉ cho user trong /etc/cron.allow.
        # /etc/cron.d có cột user nên cron vẫn hạ quyền đúng MariaDB OS user.
        BACKUP_CRON_FILE="/etc/cron.d/mariadb_backup"
        [ -d /etc/cron.d ] || die "Khong co /etc/cron.d tren he thong."
        cron_tmp="$(mktemp "${BACKUP_CRON_FILE}.tmp.XXXXXX")"

        for id in "${INSTANCE_IDS[@]}"; do
            iuser="${BACKUP_USER_BY_ID[$id]}"
            purge_old_block "$iuser"
            remove_job_cron "$iuser" backup
        done

        {
            echo "SHELL=/bin/bash"
            echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            echo "# Sinh tu 08_install_db_jobs.sh - khong sua tay"
            for id in "${INSTANCE_IDS[@]}"; do
                iuser="${BACKUP_USER_BY_ID[$id]}"
                bfile="${BACKUP_FILE_BY_ID[$id]}"
                # Cùng lịch 23:30; flock xếp hàng khi có 5-7 instance.
                printf '%s %s "%s" -w 82800 "%s" "%s" > /dev/null 2>&1\n' \
                    "${JOB_SCHED[backup]}" "$iuser" "$FLOCK_BIN" "$BACKUP_LOCK" "$bfile"
            done
        } > "$cron_tmp"

        chown root:root "$cron_tmp"
        chmod 644 "$cron_tmp"
        mv -f "$cron_tmp" "$BACKUP_CRON_FILE"
        log "  [+] backup -> $BACKUP_CRON_FILE (moi instance chay dung MariaDB OS user)"
        continue
    fi

    declare -a cron_lines=()
    case "$j" in
        partition)
            printf -v cline '%s %s "%s" > /dev/null 2>&1' \
                "${JOB_SCHED[$j]}" "$DB_JOB_OS_USER" "$AUTO_PART_FILE"
            cron_lines+=("$cline")
            ;;
        analyze)
            printf -v cline '%s %s "%s" > /dev/null 2>&1' \
                "${JOB_SCHED[$j]}" "$DB_JOB_OS_USER" "$ANALYZE_FILE"
            cron_lines+=("$cline")
            ;;
        innodb)
            for id in "${INSTANCE_IDS[@]}"; do
                iuser="${BACKUP_USER_BY_ID[$id]}"
                ifile="${INNODB_FILE_BY_ID[$id]}"
                printf -v cline '%s %s "%s" > /dev/null 2>&1' \
                    "${JOB_SCHED[$j]}" "$iuser" "$ifile"
                cron_lines+=("$cline")
            done
            ;;
        rotate)
            for id in "${INSTANCE_IDS[@]}"; do
                iuser="${BACKUP_USER_BY_ID[$id]}"
                rfile="${ROTATE_FILE_BY_ID[$id]}"
                printf -v cline '%s %s "%s" > /dev/null 2>&1' \
                    "${JOB_SCHED[$j]}" "$iuser" "$rfile"
                cron_lines+=("$cline")
            done
            ;;
        *)
            die "Job chua co renderer cron.d: $j"
            ;;
    esac
    install_crond_job "$j" "${cron_lines[@]}"
done

# Chốt chặn: không để sót job do project sinh trong root crontab hay cột
# user=root của /etc/cron.d. Nếu còn sót thì fail rõ ràng thay vì báo DONE giả.
ROOT_CRON_FINAL="$(crontab -u root -l 2>/dev/null || true)"
for j in partition innodb backup analyze rotate; do
    if grep -Fq "${LEGACY_SCRIPT_TOKEN[$j]}" <<< "$ROOT_CRON_FINAL"; then
        die "Con DB job chay root trong root crontab: ${LEGACY_SCRIPT_TOKEN[$j]}"
    fi
done
for cron_file in "$DB_JOBS_CRON_FILE" /etc/cron.d/mariadb_backup; do
    [ -f "$cron_file" ] || continue
    if awk -v script_dir="$DB_SCRIPT_DIR" \
        'index($0, script_dir) && $0 !~ /^[[:space:]]*#/ && NF >= 7 && $6 == "root" { found=1 } END { exit(found ? 0 : 1) }' \
        "$cron_file"; then
        die "Con DB job co cot user=root trong $cron_file"
    fi
done
log "Non-root cron validation: OK"

log "Crontab da cai xong (role=$ROLE)"
log "Kiem tra backup: cat /etc/cron.d/mariadb_backup"
log "Kiem tra DB jobs: cat $DB_JOBS_CRON_FILE"

log "===== DONE INSTALL DB JOBS ====="
