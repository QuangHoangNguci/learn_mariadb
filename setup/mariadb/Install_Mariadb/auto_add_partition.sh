#Script auto create partition
#2 months and 1 run add partitions
IP=127.0.0.1
port_1=3306
port_2=3307
port_2=3308
USER="auto_add_partition"
PASS="XXXX"
COMMAND_MYSQL="/usr/local/mysql/bin/mariadb"

$COMMAND_MYSQL -u "$USER" -p"$PASS" -h $IP -P $port_1 -Bse "call vsystem.auto_add_partition(2,1);";
echo 'finished add partition on instance 1'

$COMMAND_MYSQL -u "$USER" -p"$PASS" -h $IP -P $port_2 -Bse "call vsystem.auto_add_partition(2,1);";
echo 'finished add partition on instance 2'

$COMMAND_MYSQL -u "$USER" -p"$PASS" -h $IP -P $port_3 -Bse "call vsystem.auto_add_partition(2,1);";
echo 'finished add partition on instance 3'