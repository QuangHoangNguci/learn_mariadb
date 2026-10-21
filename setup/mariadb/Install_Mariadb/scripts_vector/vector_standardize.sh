#!/usr/bin/env bash
# =============================================================================
# vector_standardize.sh  (BAN DAY DU - thay the fix_vector_slowlog.sh)
#
# Chuan hoa cau hinh Vector pipeline MariaDB slow/error/innodb -> Kafka.
# Idempotent (chay lai khong sao). Tu backup -> sua -> validate -> reload.
# Validate LOI -> tu rollback ve backup.
#
# VA BUG (moi server):
#   1. multiline slow: '^# User' -> '^# Time'   (het orphan '# Time')
#   2. regex slow: nuot 'use <db>;' + Schema rong + command toi het entry
#   3. .server: IP hardcode -> hostname dong
#
# BO SUNG NEU THIEU (nang b" ban rut gon" len day du):
#   4. read_from: beginning + ignore_older_secs + ignore_not_found + fingerprint  (3 source)
#   5. source vector_internal_metrics  +  sink prometheus_exporter cong 21039
#   6. compression: zstd (3 kafka sink)
#   7. .server cho transform innodb (neu chua co)
#
# An toan: moi chen cau truc deu duoc 'vector validate' gac cong; sai la rollback.
#
# Dung:
#   bash vector_standardize.sh                  # /log/apps/vector.yaml
#   bash vector_standardize.sh /duong/dan.yaml
# =============================================================================
set -uo pipefail

CONFIG="${1:-/log/apps/vector.yaml}"
HOST="$(hostname)"
TS="$(date +%F-%H%M%S)"
BAK="${CONFIG}.bak.std.${TS}"

if [ ! -f "$CONFIG" ]; then echo "[SKIP] $HOST: khong thay $CONFIG"; exit 0; fi

# --- tu do interpreter python (CentOS7/RHEL7 chi co python2 = /usr/bin/python) ---
PY=""
for c in python3 python2 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
    echo "[FAIL] $HOST: khong co python3/python2/python -> KHONG sua duoc (config VAN CHUA chuan!)."
    echo "        Cach 1: cai python roi chay lai script."
    echo "        Cach 2: sua tay theo mau con z4-37 da chuan."
    exit 1
fi
echo "[INFO] $HOST: dung interpreter '$PY'"

cp -a "$CONFIG" "$BAK"

"$PY" - "$CONFIG" << 'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().split("\n")
changed = set()

NEW_REGEX = (
    r"(?s)^\#\sUser@Host:\s(?P<client>[^\n]*)\n"
    r"\#\sThread_id:\s(?P<thread_id>\d+)\s+Schema:\s*(?P<schema>\S*)\s+QC_hit:\s(?P<qc_hit>\w+)\n"
    r"\#\sQuery_time:\s(?P<query_time>[\d.]+)\s+Lock_time:\s(?P<lock_time>[\d.]+)\s+"
    r"Rows_sent:\s(?P<rows_sent>\d+)\s+Rows_examined:\s(?P<rows_examined>\d+)\n"
    r"\#\sRows_affected:\s(?P<rows_affected>\d+)\s+Bytes_sent:\s(?P<byte_sent>\d+)\n"
    r"(?:(?:\#|use\s)[^\n]*\n)*SET\stimestamp=(?P<timestamp>\d+);\n"
    r"(?P<command>[\s\S]*?)(?:\n\#\sTime:[^\n]*)?\s*$"
)
HOSTNAME_EXPR = '.server = split(get_hostname() ?? "unknown", ".")[0]'

# ---------- Pass 0: va bug (multiline / regex / .server) ----------
for i, l in enumerate(lines):
    s = l.strip(); ind = l[:len(l) - len(l.lstrip())]
    # multiline slow: gom theo entry (# User@Host), KHONG theo # Time (tranh gop nhieu query 1 giay)
    if s.startswith("start_pattern:") and ("User" in l or "Time" in l) and "User@Host" not in l:
        lines[i] = ind + "start_pattern: '^# User@Host'"; changed.add("slow multiline"); continue
    if s.startswith("condition_pattern:") and ("User" in l or "Time" in l) and "User@Host" not in l:
        lines[i] = ind + "condition_pattern: '^# User@Host'"; changed.add("slow multiline"); continue
    # regex slow: thay tru khi da la ban moi nhat (co dau hieu cat # Time cuoi)
    if "parse_regex!(.message" in l and "User@Host" in l and r"*?)(?:\n\#\sTime" not in l:
        lines[i] = ind + ". |= parse_regex!(.message, r'" + NEW_REGEX + "')"; changed.add("slow regex"); continue
    if s.startswith(".server =") and "get_hostname" not in l and ('"' in s or "'" in s):
        lines[i] = ind + HOSTNAME_EXPR; changed.add(".server hostname"); continue

# ---------- Pass 1: them options cho moi 'type: file' chua co read_from ----------
FILE_OPTS = [
    "    read_from: end",
    "    ignore_older_secs: 600",
    "    ignore_not_found: true",
    "    fingerprint:",
    "      strategy: checksum",
    "      ignored_header_bytes: 5",
    "      lines: 20",
]
out = []
for i, l in enumerate(lines):
    out.append(l)
    if l.strip() == "type: file":
        j = i + 1; has_rf = False
        while j < len(lines):
            nx = lines[j]; st = nx.strip()
            if st.startswith("read_from:"): has_rf = True; break
            if st.startswith("multiline:"): break
            if nx and (len(nx) - len(nx.lstrip())) <= 2 and st.endswith(":"): break
            j += 1
        if not has_rf:
            out.extend(FILE_OPTS); changed.add("source options(read_from/fingerprint)")
lines = out

# ---------- Pass 2: them source vector_internal_metrics neu thieu ----------
if not any(l.strip() == "vector_internal_metrics:" for l in lines):
    out = []
    for l in lines:
        if l.rstrip() == "transforms:":
            out += ["  vector_internal_metrics:",
                    "    type: internal_metrics",
                    "    scrape_interval_secs: 30",
                    ""]
            changed.add("internal_metrics source")
        out.append(l)
    lines = out

# ---------- Pass 3: them compression: zstd sau moi 'codec: json' neu thieu ----------
out = []
for idx, l in enumerate(lines):
    out.append(l)
    if l.strip() == "codec: json":
        nxt = lines[idx+1:idx+4]
        if not any("compression:" in x for x in nxt):
            out.append("    compression: zstd"); changed.add("kafka zstd")
lines = out

# ---------- Pass 4: them sink prometheus_exporter 21039 neu thieu ----------
if not any(l.strip() == "vector_internal_metrics_sink:" for l in lines):
    while lines and lines[-1].strip() == "": lines.pop()
    lines += [
        "",
        "  vector_internal_metrics_sink:",
        "    type: prometheus_exporter",
        "    inputs:",
        "      - vector_internal_metrics",
        "      - mariadb_slow_log_transform",
        "      - mariadb_error_log_transform",
        "      - mariadb_innodb_log_transform",
        '    address: "0.0.0.0:21039"',
    ]
    changed.add("exporter 21039")

# ---------- Pass 5: them .server cho transform innodb neu chua co ----------
in_innodb = False; has_innodb_server = False
for l in lines:
    if l.strip() == "mariadb_innodb_log_transform:": in_innodb = True; continue
    if in_innodb:
        if l.strip().startswith(".server ="): has_innodb_server = True; break
        if l.rstrip() == "sinks:": break
        if l and (len(l) - len(l.lstrip())) <= 2 and l.strip().endswith(":") and "transform" in l: break
if not has_innodb_server:
    out = []
    for l in lines:
        if l.rstrip() == "sinks:":
            out.append("      " + HOSTNAME_EXPR)   # cuoi block source innodb
            out.append("")
            changed.add("innodb .server")
        out.append(l)
    lines = out

# ---------- Pass 6: SLOW transform giu field .timestamp (epoch) cho ClickHouse ----------
# Loi: '.@timestamp = del(.timestamp)' xoa mat field timestamp -> cot ClickHouse = 1970.
# Sua ve dung kieu z4-35: giu .timestamp (epoch), chi parse ra .@timestamp.
out = []
in_slow = False
for l in lines:
    s = l.strip()
    if s == "mariadb_slow_log_transform:":
        in_slow = True
    elif (len(l) - len(l.lstrip())) <= 2 and s.endswith(":") and s:
        in_slow = False
    if in_slow and s.startswith(".timestamp = parse_timestamp(.timestamp,"):
        changed.add("slow timestamp keep"); continue          # bo dong ghi de epoch
    if in_slow and s == ".@timestamp = del(.timestamp)":
        ind = l[:len(l) - len(l.lstrip())]
        out.append(ind + '.@timestamp = parse_timestamp(.timestamp, format: "%s") ?? now()')
        changed.add("slow timestamp keep"); continue
    out.append(l)
lines = out

# ---------- Pass 7: dam bao include co path /var/log/mariadb/ (nhieu con de log o day) ----------
# ignore_not_found:true nen them thua khong sao; con nao khong dung thi bo qua.
PATHMAP = {
    "mariadb_slow_log_file:":   "      - /var/log/mariadb/mysqld.slow.log",
    "mariadb_error_log_file:":  "      - /var/log/mariadb/mysqld.error.log",
    "mariadb_innodb_log_file:": "      - /var/log/mariadb/innodb_stat.log",
}
have = [x.strip() for x in lines]
out = []
cur = None
for l in lines:
    s = l.strip()
    if s in PATHMAP:
        cur = s
    out.append(l)
    if cur and s == "include:":
        add = PATHMAP[cur]
        if add.strip() not in have:
            out.append(add); changed.add("include /var/log/mariadb")
        cur = None
lines = out

open(path, "w").write("\n".join(lines))
print("[EDIT] " + (", ".join(sorted(changed)) if changed else "khong co thay doi"))
PYEOF
PYRC=$?
if [ "$PYRC" -ne 0 ]; then
    echo "[FAIL] $HOST: python loi (rc=$PYRC) -> rollback ve $BAK"
    cp -a "$BAK" "$CONFIG"; exit 1
fi

if cmp -s "$CONFIG" "$BAK"; then
    echo "[OK] $HOST: da chuan day du tu truoc, khong sua gi."; rm -f "$BAK"; exit 0
fi

VEC_PID="$(pgrep -f -- "vector -c ${CONFIG}" | head -1)"
VEC_BIN="$(ps -p "${VEC_PID:-0}" -o args= 2>/dev/null | awk '{print $1}')"
[ -z "${VEC_BIN}" ] && VEC_BIN="/log/apps/vector"

echo "[VALIDATE] $VEC_BIN validate $CONFIG"
if "$VEC_BIN" validate "$CONFIG"; then
    if [ -n "${VEC_PID}" ]; then
        kill -HUP "$VEC_PID" && echo "[RELOAD] $HOST: reload OK (PID $VEC_PID). Backup: $BAK"
    else
        echo "[WARN] $HOST: khong thay PID vector -> reload thu cong. Backup: $BAK"
    fi
else
    echo "[FAIL] $HOST: validate LOI -> rollback ve $BAK"
    cp -a "$BAK" "$CONFIG"; exit 1
fi
