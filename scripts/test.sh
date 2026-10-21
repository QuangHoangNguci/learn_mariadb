#!/bin/bash

# Unit checks for the multi-instance config parser and per-ID settings.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
source scripts/common.sh
set -e

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_file_contains() {
    grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_file_not_matches() {
    ! grep -Eq -- "$2" "$1" || fail "$1 still matches forbidden pattern: $2"
}

INSTANCE_1=(3306 1301 100 auto 4006 4016 "core_cluster" "galera-one" "maxscale-one")
INSTANCE_2=(3307 1302 50 2048 4007 4017 "orders_cluster" "galera-two" "maxscale-two")
parse_instances_table

assert_eq "${#INSTANCE_IDS[@]}" "2"
assert_eq "${INSTANCE_BUF_MB[2]}" "2048"
assert_eq "$(get_instance_cluster_name 2)" "orders_cluster"
assert_eq "$(get_instance_galera_pass 2)" "galera-two"
assert_eq "$(get_instance_maxscale_pass 2)" "maxscale-two"

unset INSTANCE_1 INSTANCE_2
INSTANCES_TABLE="2 3307 1302 50 2048 4007 4017"
parse_instances_table
CLUSTER_NAME_PREFIX="legacy_cluster"
GALERA_PASS="legacy-galera"
MAXSCALE_PASS="legacy-maxscale"
assert_eq "$(get_instance_cluster_name 2)" "legacy_cluster_2"
assert_eq "$(get_instance_galera_pass 2)" "legacy-galera"
assert_eq "$(get_instance_maxscale_pass 2)" "legacy-maxscale"

# Security regressions: DB jobs va Vector khong duoc quay lai chay root.
assert_file_not_matches scripts/08_install_db_jobs.sh 'JOB_USER\[[^]]+\]="root"'
assert_file_not_matches scripts/09_install_vector.sh '^(User|Group)=root$'
assert_file_contains scripts/08_install_db_jobs.sh 'DB_JOB_OS_USER="${DB_JOB_OS_USER:-mariadb_jobs}"'
assert_file_contains scripts/08_install_db_jobs.sh 'ROTATE_FILE_BY_ID[$id]'
assert_file_contains scripts/09_install_vector.sh 'User=${VECTOR_USER}'
assert_file_contains scripts/09_install_vector.sh 'SupplementaryGroups=${MARIADB_LOG_GROUP}'

echo "All tests passed."
