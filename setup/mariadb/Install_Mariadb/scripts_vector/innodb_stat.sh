#!/bin/bash
#Script get innodb log
IP=10.207.56.51
PORT=3306
USER="monitor"
PASS="thonon"
DATE=`date +%Y%m%d_%H%M`
COMMAND_MYSQL="/bin/mysql"
DIR_LOG="/log/mysql_log"
echo "TIME "`date +%Y-%m-%d' '%H:%M:%S` >> $DIR_LOG/log_innodb/innodb_stat_$DATE.txt
echo "SERVER "$IP >> $DIR_LOG/log_innodb/innodb_stat_$DATE.txt
$COMMAND_MYSQL -u "$USER" -p"$PASS" -h $IP -P $PORT -Bse "SHOW ENGINE INNODB STATUS\G" >> $DIR_LOG/log_innodb/innodb_stat_$DATE.txt

cat $DIR_LOG/log_innodb/innodb_stat_$DATE.txt | grep -v ", not started" | grep -v "lock struct(s)" | grep -v "waiting for completed aio requests" | grep -v "node heap has" >> $DIR_LOG/innodb_stat.log
