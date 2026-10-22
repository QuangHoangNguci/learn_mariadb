#!/bin/bash

# Xem trước các giá trị auto-tune sẽ render vào my_<ID>.cnf (không sửa file nào).

set -euo pipefail

cd "$(dirname "$0")"

source ../configs/cluster.env
source ./common.sh

validate_cluster_env

HOST_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
HOST_CPU=$(nproc)
export HOST_RAM_MB HOST_CPU

DISK_DETECTED=$(detect_disk_type)
USABLE_PCT=$(( 100 - ${RESERVED_RAM_PCT:-25} ))

echo ""
echo "============================================================"
echo "  PREVIEW AUTO-TUNE"
echo "============================================================"
echo "Topology          : ${TOPOLOGY}  ($(topology_desc))"
echo "  Galera          : ${ENABLE_GALERA}     Replica/DR (read_only): ${REPLICA_MODE}"
if is_replica; then
    echo "  PRIMARY_NODES   : ${PRIMARY_NODES:-?}   (mo iptables de keo binlog)"
fi
echo "Host RAM          : ${HOST_RAM_MB} MB"
echo "Host CPU          : ${HOST_CPU} cores"
echo "Disk type         : ${DISK_DETECTED}  (config: ${DISK_TYPE:-auto})"
echo "Reserved RAM      : ${RESERVED_RAM_PCT:-25}% (usable=${USABLE_PCT}% cho tat ca buffer pool)"
echo "Tong SIZE_GB      : ${INSTANCE_SIZE_SUM}"
echo "So instance       : ${#INSTANCE_IDS[@]}"
echo ""

FMT="%-4s %-6s %-6s %-8s %-13s %-8s %-10s %-9s %-9s %-9s %-7s %-7s\n"
printf "$FMT" \
    "ID" "PORT" "MGNT" "SIZE_GB" "BUFFER_POOL" "BP_INST" "LOG_FILE" "IO_CAP" "IO_MAX" "THR_POOL" "MAX_RW" "MAX_RO"
printf "$FMT" \
    "---" "----" "----" "-------" "-----------" "-------" "--------" "------" "------" "--------" "------" "------"

TOTAL_BP=0
fmt_port() { [ "$1" = "0" ] && echo "-" || echo "$1"; }

for id in "${INSTANCE_IDS[@]}"; do
    compute_tune_for_id "$id"
    TOTAL_BP=$(( TOTAL_BP + TUNE_BP_MB ))
    BP_DISPLAY="${TUNE_BP_MB}M"
    [ "$TUNE_BP_SRC" = "manual" ] && BP_DISPLAY="${TUNE_BP_MB}M*"
    printf "$FMT" \
        "$id" \
        "${INSTANCE_PORT[$id]}" \
        "${INSTANCE_MGNT[$id]}" \
        "${INSTANCE_SIZE[$id]}" \
        "$BP_DISPLAY" \
        "$TUNE_BP_INSTANCES" \
        "${TUNE_LOG_FILE_MB}M" \
        "$TUNE_IO_CAP" \
        "$TUNE_IO_MAX" \
        "$TUNE_THREAD_POOL" \
        "$(fmt_port "${INSTANCE_MAX_RW[$id]}")" \
        "$(fmt_port "${INSTANCE_MAX_RO[$id]}")"
done

echo "(* = manual override BUF_MB)"

echo ""
echo "Tong buffer_pool   : ${TOTAL_BP} MB / ${HOST_RAM_MB} MB host RAM"
RATIO=$(( TOTAL_BP * 100 / HOST_RAM_MB ))
echo "Ti le buffer_pool  : ${RATIO}% RAM (ceiling cau hinh = ${USABLE_PCT}%)"
echo ""

if [ "${ENABLE_GALERA:-false}" = "true" ]; then
    echo "============================================================"
    echo "  GALERA CLUSTER"
    echo "============================================================"
    echo "ENABLE_GALERA      : true"
    echo "NODE_ROLE          : ${NODE_ROLE:-?}"
    echo "CLUSTER_NODES      : ${CLUSTER_NODES:-?}"
    echo "NODE_NAME_PREFIX   : ${NODE_NAME_PREFIX:-?}"
    echo ""
    printf "%-4s %-10s %-10s %-10s %-30s\n" "ID" "WSREP" "SST" "IST" "CLUSTER_NAME"
    printf "%-4s %-10s %-10s %-10s %-30s\n" "---" "-----" "---" "---" "------------"
    for id in "${INSTANCE_IDS[@]}"; do
        compute_wsrep_ports "$id"
        printf "%-4s %-10s %-10s %-10s %-30s\n" \
            "$id" "$WSREP_LISTEN" "$WSREP_SST" "$WSREP_IST" \
            "$(get_instance_cluster_name "$id")"
    done
    echo ""
fi

echo "============================================================"
echo "  DUONG DAN SE TAO"
echo "============================================================"
printf "%-4s %-40s %-40s\n" "ID" "DATA_DIR" "LOG_DIR"
printf "%-4s %-40s %-40s\n" "---" "--------" "-------"
for id in "${INSTANCE_IDS[@]}"; do
    printf "%-4s %-40s %-40s\n" "$id" "$(get_data_dir "$id")" "$(get_log_dir "$id")"
done
echo ""
echo "Ten theo ID: ID=0 -> ten MAC DINH (my.cnf, khong so); ID>=1 -> _<ID>"
printf "%-4s %-22s %-16s %-26s\n" "ID" "CONFIG" "SERVICE" "INSTALL_DIR"
printf "%-4s %-22s %-16s %-26s\n" "---" "------" "-------" "-----------"
for id in "${INSTANCE_IDS[@]}"; do
    printf "%-4s %-22s %-16s %-26s\n" \
        "$id" "$(get_conf_file "$id")" "$(get_service_name "$id")" "$(get_install_dir "$id")"
done
echo ""
