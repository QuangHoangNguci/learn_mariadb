# MariaDB Multi-Instance Auto — 4 Topology (single / dr / cluster / dr-cluster)

Bo cai dat MariaDB multi-instance hop nhat. Mot bien duy nhat **`TOPOLOGY`**
quyet dinh loai trien khai. Script CHI dung DB (binary + config + datadir) —
KHONG start service, KHONG set password, KHONG setup slave; nguoi van hanh tu
lam tay sau khi deploy.

## Mo hinh: TOPOLOGY = Galera × Role

`TOPOLOGY` la to hop cua 2 truc: **Galera** (cluster dong bo on/off) ×
**Role** (master read-write / replica DR read_only).

| TOPOLOGY     | Galera | Role    | Config dac trung |
|--------------|--------|---------|------------------|
| `single`     | off    | master  | standalone read-write, binlog ON (san sang lam master cho DR sau) |
| `dr`         | off    | replica | standalone `read_only=1`, async keo binlog tu `PRIMARY_NODES` |
| `cluster`    | on     | master  | Galera cluster read-write (`wsrep_*`) |
| `dr-cluster` | on     | replica | Galera cluster + `read_only=1` + async keo binlog tu primary cluster |

Tu `TOPOLOGY`, script tu suy ra (trong `scripts/common.sh`):

```
ENABLE_GALERA = true   khi cluster / dr-cluster
REPLICA_MODE  = true   khi dr / dr-cluster     (them read_only=1 vao my.cnf)
```

> Khong set `ENABLE_GALERA` bang tay nua — chi can dat `TOPOLOGY`.
> (Env cu chi co `ENABLE_GALERA` van chay: tu suy ra `single`/`cluster`.)

## Cau truc config sinh my.cnf (template)

`03_configure_mariadb.sh` khong con heredoc inline; no goi `render_mycnf`
(trong `scripts/lib/render_mycnf.sh`) de ghep template theo TOPOLOGY:

```
configs/templates/
├── my.cnf.base.tmpl     <- phan chung moi topology (co 2 marker)
├── block.galera.tmpl    <- chen khi galera   (cluster / dr-cluster)
└── block.dr.tmpl        <- chen khi replica  (dr / dr-cluster) -> read_only=1
```

Sua tuning chung tai `my.cnf.base.tmpl`; sua phan rieng galera/DR tai 2 file block.
Auto-tune (buffer pool, log file, io capacity, thread pool) van do
`compute_tune_for_id` tinh, render chi thay placeholder.

## Quick start

```bash
# Cach 1: menu / wizard (hoi TOPOLOGY truoc, an field khong lien quan)
sudo bash setup.sh

# Cach 2: sua tay configs/cluster.env roi deploy
vi configs/cluster.env          # dat TOPOLOGY + cac dong INSTANCE_<ID>
bash scripts/show_config.sh      # preview auto-tune + topology (read-only)
sudo bash deploy.sh              # pipeline 01->05 (joiner galera tu skip 05)
```

`configs/cluster.env` toi thieu can:

```bash
TOPOLOGY="single"                # single | dr | cluster | dr-cluster
# PORT MGNT SIZE BUF RW RO CLUSTER_NAME GALERA_PASS MAXSCALE_PASS
INSTANCE_1=(3306 1301 100 auto - - "money"  'sst-pass-1' 'max-pass-1')
INSTANCE_2=(3307 1302 200 auto - - "report" 'sst-pass-2' 'max-pass-2')

# dr / dr-cluster  -> bat buoc PRIMARY_NODES
PRIMARY_NODES="192.168.98.18 192.168.98.19"
# cluster / dr-cluster -> bat buoc CLUSTER_NODES
CLUSTER_NODES="10.0.0.1 10.0.0.2 10.0.0.3"
NODE_ROLE="bootstrap"            # bootstrap | joiner
```

Moi instance chi can mot dong `INSTANCE_<ID>=(...)`; script tu tim ID, khong can
danh sach rieng. Wizard `setup.sh` an noi dung mat khau khi nhap. Format cu
`INSTANCES_TABLE` va cac bien global/per-ID cu van duoc ho tro de tuong thich.

## Sau deploy theo tung topology

| TOPOLOGY | Buoc tay sau deploy |
|---|---|
| `single` | `systemctl start mariadb_<ID>` → set root pass / tao app user |
| `dr` | start → login → `CHANGE MASTER TO ... MASTER_USE_GTID=slave_pos; START SLAVE;` |
| `cluster` | bootstrap: `galera_new_cluster --defaults-file=/etc/my_<ID>.cnf`; joiner: `systemctl start` |
| `dr-cluster` | bootstrap cluster nhu tren, roi setup `CHANGE MASTER` tren 1 node (Galera tu replicate sang node con lai) |

deploy.sh in san cac lenh nay o cuoi (kem goi y CHANGE MASTER khi replica).

## Tinh nang mo rong (tu bat/tat theo topology)

| Script | Dung khi | Rang buoc topology |
|---|---|---|
| `06_initialize_database.sh` | import users/schema + set root pass | replica nen `EMPTY_CLUSTER=true` (canh bao neu khong) |
| `07_maxscale_install.sh` | proxy read/write split | **chi** cluster / dr-cluster (die neu standalone) |
| `08_install_db_jobs.sh` | cron backup/partition/analyze | moi topology |
| `09_install_vector.sh` | log shipping -> Kafka/ELS | moi topology |

Script 08 khong cai DB job vao root crontab. Backup, innodb_stat va rotate log co
script rieng cho tung instance, chay bang MariaDB OS user tuong ung; partition va
analyze chay bang system user `mariadb_jobs`. Backup dung `flock` de tranh chay
dong thoi. Script 09 chay Vector bang `vector_mariadb`, chi doc log qua group
`mariadb_log_readers` va tu ghi checkpoint cua no.

Script 07 sinh lenh `maxctrl<ID>` gan san REST port cua tung instance, vi du
`maxctrl1 list servers`, `maxctrl2 list servers`. ID=0 tiep tuc dung
`maxctrl list servers`. Neu tu truyen `-h/--hosts`, wrapper se ton trong gia tri do.

## Tham khao chi tiet pipeline

Xem `scripts/README.txt` cho mo ta tung script 01..09, expand mode, va vi du
Galera 3-server. Tai lieu nay (`README.md`) la nguon chuan cho mo hinh 4 topology.

## Migration tu ban cu

- Project cu `MariaDBDRAuto` (DR single, template) -> tuong duong `TOPOLOGY=dr`.
- Project cu `mariadb-galera-auto-multi-instance` standalone -> `TOPOLOGY=single`;
  galera -> `TOPOLOGY=cluster`.
- DR tren Galera (moi) -> `TOPOLOGY=dr-cluster`.
