#!/bin/bash

set -e

cd "$(dirname "$0")"

source configs/cluster.env
source scripts/common.sh

# Validate cau hinh truoc khi bat dau bat ky buoc nao
validate_cluster_env
preflight_check

MODE="${INSTALL_MODE:-fresh}"
GALERA="${ENABLE_GALERA:-false}"
ROLE="${NODE_ROLE:-bootstrap}"

echo "========================================"
echo "  MariaDB Multi-Instance Auto Deploy"
echo "  Topology : $TOPOLOGY  ($(topology_desc))"
echo "  Mode     : $MODE"
echo "  IDs      : ${INSTANCE_IDS[*]}"
if [ "$GALERA" = "true" ]; then
    echo "  Galera   : ON (NODE_ROLE=$ROLE)"
else
    echo "  Galera   : OFF (standalone)"
fi
if is_replica; then
    echo "  Replica  : ON (read_only=1, async tu PRIMARY_NODES=${PRIMARY_NODES})"
fi
echo "========================================"

# ========================
# PRE-FLIGHT SAFETY CHECK
# ========================

RUNNING_SERVICES=()
for id in "${INSTANCE_IDS[@]}"; do
    SVC="$(get_service_name "$id")"
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        RUNNING_SERVICES+=("$SVC")
    fi
done

if [ ${#RUNNING_SERVICES[@]} -gt 0 ]; then
    echo ""
    echo "[CANH BAO] Phat hien ${#RUNNING_SERVICES[@]} dich vu dang chay:"
    for svc in "${RUNNING_SERVICES[@]}"; do
        echo "  - $svc (ACTIVE)"
    done
    echo ""

    if [ "$MODE" == "fresh" ]; then
        echo "[NGUY HIEM] Mode 'fresh' se ghi de cau hinh cua tat ca instance!"
        read -rp "Tiep tuc? (yes/no): " CONFIRM
        if [ "$CONFIRM" != "yes" ]; then
            echo "Da huy."
            exit 0
        fi
    else
        echo "[AN TOAN] Mode 'expand' se KHONG dong vao instance dang chay."
    fi
fi

# Kiem tra port conflict voi tien trinh KHAC (khong phai service cua minh)
echo "Kiem tra port conflict..."
CONFLICT=0
for id in "${INSTANCE_IDS[@]}"; do
    SVC="$(get_service_name "$id")"
    for p in "${INSTANCE_PORT[$id]}" "${INSTANCE_MGNT[$id]}"; do
        if is_port_in_use "$p"; then
            if ! systemctl is-active --quiet "$SVC" 2>/dev/null; then
                echo "  [CONFLICT] Port $p (ID=$id) dang bi chiem boi tien trinh khac (khong phai $SVC)"
                CONFLICT=1
            fi
        fi
    done
done

if [ "$CONFLICT" -eq 1 ]; then
    echo ""
    echo "[LOI] Co port bi conflict. Giai phong port truoc khi tiep tuc."
    exit 1
fi

echo "[OK] Khong co port conflict."
echo ""
echo "Bat dau deploy..."
echo ""

# ========================
# PIPELINE
# Script CHI dung DB (binary + config + datadir).
# KHONG start service, KHONG set password, KHONG setup slave.
# ========================

cd scripts

bash 01_prepare_system.sh
bash 02_install_mariadb_binary.sh
bash 03_configure_mariadb.sh
bash 04_enable_mariadb_service.sh

# Galera joiner: skip 05 (data se sync tu bootstrap qua SST)
if [ "$GALERA" = "true" ] && [ "$ROLE" = "joiner" ]; then
    echo ""
    echo "[GALERA JOINER] Skip 05 (init datadir) - data se sync tu bootstrap qua mariabackup SST"
    echo ""
else
    bash 05_prepare_database.sh
fi

echo ""
echo "========================================"
echo "  DEPLOY HOAN TAT"
echo "========================================"
echo ""
echo "Buoc tiep theo (tu lam tay):"

if [ "$GALERA" = "true" ]; then
    if [ "$ROLE" = "bootstrap" ]; then
        echo "  Bootstrap node - khoi tao cluster moi cho moi instance:"
        for id in "${INSTANCE_IDS[@]}"; do
            CONF="$(get_conf_file "$id")"
            echo "    sudo galera_new_cluster --defaults-file=$CONF"
        done
        echo "  Sau khi bootstrap xong, o cac JOINER node chay:"
        for id in "${INSTANCE_IDS[@]}"; do
            echo "    sudo systemctl start $(get_service_name "$id")"
        done
    else
        echo "  Joiner node - sau khi bootstrap node da chay galera_new_cluster:"
        for id in "${INSTANCE_IDS[@]}"; do
            echo "    sudo systemctl start $(get_service_name "$id")"
        done
    fi
else
    echo "  Standalone - DB rong san sang (chua co user/password):"
    for id in "${INSTANCE_IDS[@]}"; do
        SVC="$(get_service_name "$id")"
        echo "    sudo systemctl start  $SVC"
        echo "    sudo systemctl enable $SVC"
    done
fi

if is_replica; then
    echo ""
    echo "  [REPLICA/DR] Node nay read_only=1. Sau khi start, setup async slave tu primary:"
    for id in "${INSTANCE_IDS[@]}"; do
        echo "    $(get_install_dir "$id")/bin/mariadb -u root -S $(get_data_dir "$id")/mariadb.sock"
    done
    echo "    > STOP SLAVE; RESET SLAVE ALL;"
    echo "    > SET GLOBAL gtid_slave_pos='<gtid lay tu primary>';"
    echo "    > CHANGE MASTER TO MASTER_HOST='<primary>', MASTER_USER='replicant',"
    echo "        MASTER_PASSWORD='...', MASTER_USE_GTID=slave_pos;"
    echo "    > START SLAVE; SHOW SLAVE STATUS\\G"
    if [ "$GALERA" = "true" ]; then
        echo "    (dr-cluster: chi setup slave tren 1 node; Galera tu replicate sang node con lai)"
    fi
fi

echo ""
echo "Kiem tra:"
echo "  bash scripts/show_config.sh                 # xem cau hinh + gia tri auto-tune"
echo "  systemctl status ${INSTANCE_NAME_PREFIX:-mariadb}_<ID>   # trang thai service tung instance"
echo ""
echo "Cac script 06/07/08/09 (init users, MaxScale, jobs, vector) van con trong scripts/"
echo "nhung KHONG duoc chay tu dong - dung khi can: bash scripts/<ten>.sh"
echo ""
