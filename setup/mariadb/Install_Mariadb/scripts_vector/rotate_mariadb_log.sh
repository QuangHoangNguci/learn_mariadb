#!/bin/bash
DIR_LOG="/log/mysql_log"
MARIADB_ERROR_LOG="/log/mysql_log/mysqld.error.log"
MARIADB_SLOW_LOG="/log/mysql_log/mysqld.slow.log"
MARIADB_INNODB_LOG="/log/mysql_log/innodb_stat.log"
SERVICE=vector
DIR_BIN="/log/scripts"
temp_dir="/log/mysql_log/log_innodb.$DATE"
mkdir $temp_dir

#Rotate_mariadb_innodb_log
#Backup file innodb log
cd $DIR_LOG
pwd
find $DIR_LOG/log_innodb/innodb_stat_* -mmin +1 -type f -exec mv "{}" $temp_dir \;
tar cfz $temp_dir.tgz $temp_dir/*

#Xóa các innodb log cũ
rm -rf $temp_dir
find $DIR_LOG/innodb_stat.* -mtime +30 -type f -exec rm -f {} \;
echo > $MARIADB_INNODB_LOG

#Rotate_mariadb_error_log
cp $MARIADB_ERROR_LOG $MARIADB_ERROR_LOG.$DATE
echo > $MARIADB_ERROR_LOG
gzip $MARIADB_ERROR_LOG.$DATE
find $MARIADB_ERROR_LOG.* -mtime +180 -type f -exec rm -f {} \;


#Rotate_mariadb_slow_log
cp $MARIADB_SLOW_LOG $MARIADB_SLOW_LOG.$DATE
echo > $MARIADB_SLOW_LOG
gzip $MARIADB_SLOW_LOG.$DATE
find $MARIADB_SLOW_LOG.* -mtime +180 -type f -exec rm -f {} \;


#Reset vector-dev
echo > $DIR_BIN/vector-check-points/mariadb_error_log_file/checkpoints.json
echo > $DIR_BIN/vector-check-points/mariadb_innodb_log_file/checkpoints.json
echo > $DIR_BIN/vector-check-points/mariadb_slow_log_file/checkpoints.json

if P=$(pgrep $SERVICE)
then
    echo "$SERVICE is running, PID is $P"
    kill -HUP $P
    echo "$SERVICE have been reload"
else
    echo "$SERVICE is not running, starting..."
    # start service if not running
    $DIR_BIN/vector -c $DIR_BIN/vector.yaml &
fi

