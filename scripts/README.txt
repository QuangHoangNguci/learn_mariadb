==================================================================
  MARIADB MULTI-INSTANCE  -  AUTO DEPLOY
==================================================================

  >> MO HINH MOI: 1 bien TOPOLOGY = single | dr | cluster | dr-cluster.
     Xem README.md (thu muc goc) de hieu 4 topology. File nay mo ta
     chi tiet tung script trong pipeline.
       single     = standalone master read-write
       dr         = standalone replica read_only (async tu PRIMARY_NODES)
       cluster    = Galera cluster read-write
       dr-cluster = Galera cluster replica read_only
     ENABLE_GALERA / REPLICA_MODE duoc SUY RA tu TOPOLOGY (khong set tay).

  Script CHI dung DB (binary + config + datadir).
  KHONG start service, KHONG set password, KHONG setup slave.
  Tat ca cac viec tren NGUOI VAN HANH tu lam tay sau khi deploy.sh.

  Pipeline mac dinh (deploy.sh):

    Standalone (ENABLE_GALERA=false):
      01  ->  02  ->  03  ->  04  ->  05

    Galera bootstrap node (ENABLE_GALERA=true, NODE_ROLE=bootstrap):
      01  ->  02  ->  03  ->  04  ->  05
      Sau do CHAY TAY tren bootstrap node:
        galera_new_cluster --defaults-file=/etc/my_<ID>.cnf
      Cho cluster ready roi moi start cac joiner.

    Galera joiner node (ENABLE_GALERA=true, NODE_ROLE=joiner):
      01  ->  02  ->  03  ->  04            (SKIP 05)
      Sau do CHAY TAY:
        systemctl start mariadb_<ID>
      Data se tu sync tu bootstrap qua mariabackup SST.

  Cac script 06/07/08/11 (init users, MaxScale, jobs, vector) van con
  trong scripts/ nhung KHONG duoc deploy.sh chay tu dong.
  Khi can dung: bash scripts/<ten>.sh

  Script 06/07 doc truc tiep ba field cuoi cua moi INSTANCE_<ID>.

  Script 08/11 van dung cac cau hinh job/vector rieng neu can.


==================================================================
  CAU HINH (configs/cluster.env)
==================================================================

  Tat ca cau hinh nam trong configs/cluster.env. Mau cau hinh:

    # PORT MGNT SIZE BUF RW RO CLUSTER_NAME GALERA_PASS MAXSCALE_PASS
    INSTANCE_1=(3306 1301 1700 auto 4006 4016 "money"  'sst-1' 'max-1')
    INSTANCE_2=(3307 1302 70   2048 4007 4017 "report" 'sst-2' 'max-2')

  ID      : khong nhat thiet lien tuc (vd: 1, 2, 6, 9). Render thanh:
            /usr/local/mariadb_<ID>
            /etc/my_<ID>.cnf
            mariadb_<ID>.service
            user mariadb_<ID>
  PORT    : port MariaDB chinh
  MGNT    : extra_port (management)
  SIZE_GB : uoc luong data, dung khi BUF_MB=auto de chia ti le RAM
  BUF_MB  : innodb_buffer_pool_size MB.  "auto" = tu tinh theo SIZE_GB.
            Vi du: 2048 = 2GB, 51200 = 50GB.
  MAX_RW  : port MaxScale read-write listener.  0 hoac "-" = tat.
  MAX_RO  : port MaxScale read-only  listener.  0 hoac "-" = tat.

  Validate tu dong:
    - Tat ca port (PORT, MGNT, MAX_RW, MAX_RO, va WSREP neu galera)
      khong trung lap
    - Tong BUF_MB manual khong vuot (100 - RESERVED_RAM_PCT)% RAM

  GALERA (khi TOPOLOGY = cluster / dr-cluster):
    TOPOLOGY=cluster|dr-cluster : moi instance la 1 NODE cua 1 cluster Galera
    CLUSTER_NODES="ip1 ip2 ip3" : tat ca server tham gia cluster
    NODE_ROLE=bootstrap|joiner : vai tro server NAY trong cluster
    WSREP_BASE_PORT, WSREP_PORT_STEP : tinh port wsrep cho moi ID:
      BASE = WSREP_BASE_PORT + ID * WSREP_PORT_STEP
      LISTEN = BASE + 2, SST = BASE + 1, IST = BASE + 3
    Ba field cuoi tren moi dong la ten cluster, pass SST va pass MaxScale.

    Vi du voi WSREP_BASE_PORT=1030, STEP=100 va cac INSTANCE_<ID>
    co ID 1, 2, 6, 9:
      ID=1 -> LISTEN=1132 SST=1131 IST=1133
      ID=2 -> LISTEN=1232 SST=1231 IST=1233
      ID=6 -> LISTEN=1632 SST=1631 IST=1633
      ID=9 -> LISTEN=1932 SST=1931 IST=1933

    Voi 3 server A, B, C va cac instance tren -> tao 4 cluster doc lap:
      cluster_1 = {A.1, B.1, C.1}
      cluster_2 = {A.2, B.2, C.2}
      cluster_6 = {A.6, B.6, C.6}
      cluster_9 = {A.9, B.9, C.9}

  PATH (co {ID} placeholder):
        DATA_DIR_PATTERN     = /u01/data_{ID}/database
        TMP_DIR_PATTERN      = /u01/data_{ID}/database_tmp
        LOG_DIR_PATTERN      = /u01/logs_{ID}/mariadb
        BINLOG_DIR_PATTERN   = /u01/logs_{ID}/mariadb/binlog
        CONFIG_FILE_PATTERN  = /etc/my_{ID}.cnf

  MODE:
        fresh   : cai moi, SE HOI truoc khi stop/disable MariaDB cua OS
        expand  : them instance vao server da co instance khac chay

  AUTO TUNING (tu sinh theo system, khong can dien tay):
        innodb_buffer_pool_size      = (100-RESERVED_RAM_PCT)% RAM
                                       * SIZE_GB / sum(SIZE_GB)
        innodb_buffer_pool_instances = floor(buffer_pool_GB), cap 8
        innodb_log_file_size         = 25% buffer_pool, floor 256M cap 2G
        innodb_io_capacity/max       = 4000/10000 (SSD) | 200/2000 (HDD)
        thread_pool_size             = CPU * 2, cap 64

        Xem truoc gia tri tinh ra:  bash scripts/show_config.sh


==================================================================
  PIPELINE - CHI TIET TUNG SCRIPT
==================================================================

------------------------------------------------------------------
01_prepare_system.sh - Chuan bi he dieu hanh
------------------------------------------------------------------

  - Detect OS: Ubuntu / CentOS / RHEL (die neu khong ho tro)

  - Fresh mode + DB cua OS dang chay:
      HOI nguoi van hanh truoc khi rm -rf /etc/mysql, stop+disable
      mariadb/mysql/mysqld, dpkg --purge mariadb-client*
    Expand mode: bo qua tat ca cleanup tren

  - Cai package OS offline tu package/os/*.deb (jemalloc, numactl,
    libmicrohttpd, sshpass, ...)
    Expand + jemalloc + numactl da co -> skip

  - Don dup iptables rules, them rule:
      SYSLOG_IP udp/514, NTP_IP udp/123, DNS_IP udp/53 (neu set)
      MGMT_NODES tcp/22 + tat ca PORT/MGNT_PORT cua moi instance
      PRIMARY_NODES: ACCEPT all (input + output) - de DR keo binlog
    Save vao /etc/iptables/rules.v4

  - Sysctl /etc/sysctl.d/99-mariadb-tuning.conf:
      vm.swappiness=1
      fs.file-max
      vm.min_free_kbytes
      vm.zone_reclaim_mode=0 (neu ENABLE_NUMA_DISABLE=true)

  - /etc/security/limits.conf:
      sed -i xoa entry cu cua prefix mariadb_<so>, KHONG dong vao
      cac entry cua DB cu khac
      Append nofile cho moi mariadb_<ID>

  - THP disable (neu ENABLE_THP_DISABLE=true):
      Tat ngay + tao /etc/systemd/system/disable-thp.service

  - NUMA: vm.zone_reclaim_mode=0 (neu ENABLE_NUMA_DISABLE=true)

------------------------------------------------------------------
02_install_mariadb_binary.sh - Cai binary MariaDB
------------------------------------------------------------------

  - Tu dong tim cac dong INSTANCE_<ID> -> danh sach ID can cai
      Fresh: cai tat ca ID
      Expand: chi cai ID chua co /usr/local/mariadb_<ID>

  - Early exit neu khong co ID nao can cai

  - Extract package/mariadb/*.tar.gz vao /tmp/mariadb_install (1 lan)

  - Loop tung ID:
      * Fresh + service active -> die (yeu cau stop)
      * Fresh + INSTALL_DIR ton tai -> backup .bak.<timestamp>
      * Port check (PORT + MGNT_PORT)
      * Tao user mariadb_<ID> (system user, nologin)
      * cp -al /usr/local/mariadb_<ID> (hardlink, fallback cp -a)
      * Tao DATA_DIR / TMP_DIR / LOG_DIR / BINLOG_DIR
      * chown -R mariadb_<ID>:mariadb_<ID> moi thu
      * Patch enterprise.cnf de tat simple_password_check_*
      * Verify mariadbd --version

  - Sinh /etc/profile.d/mariadb_multi.sh: export PATH cho moi instance

------------------------------------------------------------------
03_configure_mariadb.sh - Sinh /etc/my_<ID>.cnf
------------------------------------------------------------------

  - DR_NODE_IP = DR_NODE_IP cua cluster.env hoac hostname -I[0]
    server-id = (IP last octet * 100) + ID

  - Loop tung ID:
      * Skip neu binary chua co (/usr/local/mariadb_<ID> thieu)

      * Expand mode + /etc/my_<ID>.cnf da co:
          - Compute NEW_BP theo bang moi
          - Neu OLD_BP == NEW_BP -> skip
          - Khac -> ghi /etc/my_<ID>.cnf.new, KHONG ghi de
            User phai rolling restart thu cong de ap dung

      * Fresh + service active -> die

      * Tao DATA_DIR + chown + chmod 750

      * Auto-tune compute (xem show_config.sh):
          BUFFER_POOL_MB, BP_INSTANCES, LOG_FILE_MB,
          IO_CAP/IO_MAX, THREAD_POOL_SIZE

      * Sinh /etc/my_<ID>.cnf voi:
          [mysqld]
            basedir, datadir, tmpdir, socket, pid-file, log-error
            user = mariadb_<ID>
            port, extra_port
            server-id, gtid_domain_id
            log-bin (binlog), binlog_format=ROW, expire_logs_days=7
            innodb_buffer_pool_size = (auto-tune)
            innodb_buffer_pool_instances, innodb_log_file_size (auto)
            innodb_io_capacity/max, innodb_flush_neighbors (theo SSD/HDD)
            thread_pool_size (auto)
            performance_schema, event_scheduler
            server_audit (DDL, DCL, CONNECT)
          [mysqld_safe]
          [client]

      * Sinh /etc/logrotate.d/mariadb_<ID>

  Config sinh tu template (configs/templates/) qua render_mycnf:
    - my.cnf.base.tmpl : phan chung moi topology
    - block.galera.tmpl: them wsrep_* khi TOPOLOGY = cluster / dr-cluster
    - block.dr.tmpl    : them read_only=1 khi TOPOLOGY = dr / dr-cluster
  server-id: galera = SERVER_ID_BASE + ID; non-galera = (octet IP cuoi)*100 + ID.

------------------------------------------------------------------
04_enable_mariadb_service.sh - Sinh systemd unit (KHONG enable, KHONG start)
------------------------------------------------------------------

  - Fresh + default mariadb/mysql cua OS dang enabled:
      HOI nguoi van hanh truoc khi stop + disable

  - Loop tung ID:
      * Sinh /etc/systemd/system/mariadb_<ID>.service:
          User=mariadb_<ID>
          Environment=LD_PRELOAD=<jemalloc path>
          ExecStart=numactl --interleave=all <basedir>/bin/mariadbd
                    --defaults-file=/etc/my_<ID>.cnf
          Restart=on-failure, TimeoutStartSec=9000
      * Expand + service file da co -> skip

  - systemctl daemon-reload
  - KHONG systemctl enable. KHONG systemctl start.
    Nguoi van hanh chay tay: systemctl start mariadb_<ID>

------------------------------------------------------------------
05_prepare_database.sh - Init datadir RONG (chua co user/password)
------------------------------------------------------------------

  - Loop tung ID:
      * Skip neu binary thieu, config thieu
      * Service active:
          Fresh -> die (stop truoc)
          Expand -> skip
      * DATA_DIR/mysql da co -> skip (da init truoc do)
      * DATA_DIR non-empty + thieu schema:
          Fresh -> wipe + init lai
          Expand -> die (an toan, yeu cau check tay)
      * mariadb-install-db --user --datadir --basedir --defaults-file
      * chown -R + chmod 750

  Sau buoc nay: DB rong san sang. root@localhost KHONG co password.

------------------------------------------------------------------
show_config.sh - Preview auto-tune (READ ONLY)
------------------------------------------------------------------

  Khong sua file. In ra bang:
    Host RAM/CPU/Disk type
    Tung ID: PORT, MGNT, SIZE_GB, BP, BP_INST, LOG_FILE, IO_CAP/MAX, THR_POOL
    Tong buffer pool / RAM, ti le %
    Tat ca duong dan (DATA_DIR, LOG_DIR) se duoc tao


==================================================================
  SCRIPT CON LAI (KHONG chay tu dong)
==================================================================

  06_initialize_database.sh - Import users + schema (vsystem.sql + users.sql).
                              Can ADMIN_PASS / COMMON_PASS va pass theo tung ID.

  07_maxscale_install.sh    - Cai MaxScale proxy.
                              Sinh maxctrl<ID> tu gan REST port rieng:
                                maxctrl1 list servers
                                maxctrl2 list servers
                              ID=0 dung lenh maxctrl nhu cu.

  08_install_db_jobs.sh     - Sinh cron jobs (backup, partition, analyze, ...).
                              Bootstrap va joiner deu cai backup. Moi instance co
                              script backup rieng; /etc/cron.d/
                              mariadb_backup chay dung MariaDB OS user tuong ung.
                              innodb_stat/rotate cung chay bang MariaDB OS user;
                              partition/analyze chay bang user mariadb_jobs.
                              Khong co DB job moi nao chay bang root.
                              Cac backup dung flock de xep hang, tranh chay dong thoi.
                              Can ADMIN_PASS / COMMON_PASS.

  09_install_vector.sh      - Cai Vector log shipper (MariaDB -> Kafka/ELS).
                              Service chay bang user vector_mariadb, doc log qua
                              group mariadb_log_readers, checkpoint do user nay ghi.
                              Config hop le thi enable + start service va verify active.
                              Doi log path:
                                /u01/logs_<ID>/mariadb/{error,slow}.log

  Khi can dung: chay rieng le va dieu chinh cau hinh truoc.


==================================================================
  KHI NAO CHAY 06 (import schema + users)
==================================================================

  06 KHONG nam trong deploy.sh pipeline. Chay tay theo nhu cau.

  Truoc khi chay, dien trong cluster.env:
    ADMIN_PASS    : root@localhost, tdht@*           (>= 6 ky tu)
    COMMON_PASS   : monitor, mbackup, mysqlexp, ...
    Hai field cuoi cua INSTANCE_<ID>: pass Galera va pass MaxScale rieng.

  EMPTY_CLUSTER=true (tuy chon):
    Chi set root password, KHONG import schema + users.
    Dung khi cluster se nhan data tu cum cu qua mariabackup restore.

  ------------------------------------------------------------------
  Truong hop 1: Standalone + can app users (tdht, monitor, ...)
  ------------------------------------------------------------------
    sudo bash deploy.sh                       # 01..05 (DB rong)
    sudo bash scripts/06_initialize_database.sh
    sudo systemctl start mariadb_<ID>

  ------------------------------------------------------------------
  Truong hop 2: Standalone + KHONG can app users (vi du chi de
                test, hoac user se duoc tao tu app sau)
  ------------------------------------------------------------------
    sudo bash deploy.sh                       # 01..05 (DB rong)
    sudo systemctl start mariadb_<ID>
    # Set root pass thu cong:
    /usr/local/mariadb_<ID>/bin/mariadb-secure-installation \\
        -S /u01/data_<ID>/database/mariadb.sock

  ------------------------------------------------------------------
  Truong hop 3: Galera bootstrap
  ------------------------------------------------------------------
    sudo bash deploy.sh                       # 01..05 (DB rong)
    sudo bash scripts/06_initialize_database.sh   # tao galera_<ID> + users
    sudo galera_new_cluster --defaults-file=/etc/my_<ID>.cnf
    # -> cluster size=1, joiner sau do se SST duoc

  ------------------------------------------------------------------
  Truong hop 4: Galera joiner
  ------------------------------------------------------------------
    sudo bash deploy.sh                       # 01..04 (skip 05)
    # KHONG chay 06 - schema + users tu sync tu bootstrap qua SST
    sudo systemctl start mariadb_<ID>

  ------------------------------------------------------------------
  Truong hop 5: Cum se nhan data tu cum cu (restore)
  ------------------------------------------------------------------
    # Trong cluster.env: EMPTY_CLUSTER=true
    sudo bash deploy.sh                       # 01..05 (DB rong)
    sudo bash scripts/06_initialize_database.sh
    # -> chi set root password, khong import schema/users
    sudo systemctl start mariadb_<ID>
    # Restore data tu cum cu (mariabackup, mysqldump, replication, ...)


==================================================================
  CHAY DEPLOY - GALERA MULTI-INSTANCE (Vi du)
==================================================================

  Setup: 3 server A=10.0.0.1, B=10.0.0.2, C=10.0.0.3.
         Moi server cai instance 1, 2, 6, 9.
         -> Tao 4 Galera cluster, moi cluster 3 node.

  1. Tren CA 3 server, chinh configs/cluster.env:

       TOPOLOGY="cluster"        # hoac "dr-cluster" neu cum DR (+ PRIMARY_NODES)
       CLUSTER_NODES="10.0.0.1 10.0.0.2 10.0.0.3"
       INSTANCE_1=(3306 1301 1700 auto 4006 4016 "money" 'sst-1' 'max-1')
       INSTANCE_2=(3307 1302 70 2048 4007 4017 "report" 'sst-2' 'max-2')

  2. Tren server A (bootstrap):
       NODE_ROLE="bootstrap"
       sudo bash deploy.sh

     Sau khi deploy xong, IMPORT user de joiner co the SST:
       sudo bash scripts/06_initialize_database.sh

     Roi KHOI TAO cluster:
       sudo galera_new_cluster --defaults-file=/etc/my_1.cnf
       sudo galera_new_cluster --defaults-file=/etc/my_2.cnf
       sudo galera_new_cluster --defaults-file=/etc/my_6.cnf
       sudo galera_new_cluster --defaults-file=/etc/my_9.cnf

  3. Tren server B + C (joiner):
       NODE_ROLE="joiner"
       sudo bash deploy.sh
       # deploy.sh tu skip 05 vi joiner se nhan data qua SST

     Sau khi deploy xong, START service - Galera tu keo data:
       sudo systemctl start mariadb_1
       sudo systemctl start mariadb_2
       sudo systemctl start mariadb_6
       sudo systemctl start mariadb_9

  4. Verify tren A/B/C:
       systemctl status mariadb_<ID>    # trang thai tung instance
       # Check thu: wsrep_cluster_size = 3 (qua mariadb client)

==================================================================
  CHAY DEPLOY - STANDALONE (khong Galera)
==================================================================

  1. Chinh configs/cluster.env (cac dong INSTANCE_<ID>, PATH, ...)

  2. Preview gia tri auto-tune:
       bash scripts/show_config.sh

  3. Deploy:
       sudo bash deploy.sh

  4. Tu start service (deploy.sh KHONG tu start):
       sudo systemctl start  mariadb_<ID>
       sudo systemctl enable mariadb_<ID>     # neu muon auto-start

  5. Kiem tra:
       systemctl status mariadb_<ID>    # trang thai tung instance

  6. Cac viec sau ban tu lam tay:
       - Set root password
       - Tao app users
       - Setup replication slave (neu can)


==================================================================
  EXPAND - Them instance moi
==================================================================

  Tinh huong: san co instance 1, 2, 6 dang chay. Muon them ID=9.

  1. Chinh configs/cluster.env tren server:
       INSTALL_MODE="expand"
       INSTANCE_9=(3309 1309 1800 auto 4009 4019 "cluster_9" 'sst-9' 'max-9')

  2. Preview:  bash scripts/show_config.sh
     (Buffer pool cua instance cu se BI GIAM vi chia lai theo SIZE_GB)

  3. sudo bash deploy.sh

     Script 03 se:
       - Sinh /etc/my_9.cnf cho instance moi.
       - Voi instance cu (1, 2, 6): neu buffer_pool can recompute,
         ghi config moi vao /etc/my_<ID>.cnf.new
         (KHONG ghi de file dang chay).

  4. [TRUOC khi start instance moi] Rolling restart instance cu de
     ap dung buffer_pool MOI (giai phong RAM truoc):

       diff /etc/my_1.cnf /etc/my_1.cnf.new
       cp   /etc/my_1.cnf /etc/my_1.cnf.bak.$(date +%s)
       mv   /etc/my_1.cnf.new /etc/my_1.cnf
       sudo systemctl restart mariadb_1
       # lap voi mariadb_2, mariadb_6

  5. Start instance MOI:
       sudo systemctl start mariadb_9

  6. Verify:
       systemctl status mariadb_<ID>    # trang thai tung instance
