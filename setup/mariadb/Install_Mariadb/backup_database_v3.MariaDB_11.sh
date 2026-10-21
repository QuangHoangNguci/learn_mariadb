/usr/local/mysql/bin/mariabackup --galera-info --compress --backup --target-dir=/u01/backup/ --user=user_backup --password=pass_user_backup >> /u01/backup/log_backup.txt 2>&1;

------------------backup V3
#!/bin/bash
DATETIME=`date +%Y%m%d%H%M`
START_TIME=`date +'%F %T'`
SYSNAME=financial-platform
DB_NAME=--all-databases
IP=10.10.10.1
VIP=10.10.10.111
VIPP=3306
USER="mbackup"
PASS="XXXX"
COMMAND_MYSQL="/usr/local/mysql/bin/mariadb"
##mariabackup for mariadb, xtrabackup for mysql
##COMMAND_BACKUP="/usr/bin/xtrabackup"
COMMAND_BACKUP="/usr/local/mysql/bin/mariabackup"
b=_
DAYS=3
##mariabackup for mariadb, xtrabackup for mysql
##TYPE_BACKUP=xtrabackup
TYPE_BACKUP=mariabackup
BACKUP_DIR=/backup/backup_mariadb
mkdir -p ${BACKUP_DIR}/logs;
mkdir -p $BACKUP_DIR/backup$b$VIP$b$SYSNAME$b$DATETIME;
LOG_FILE=${BACKUP_DIR}/logs/full_backup$b$VIP$b$DATETIME.log
FTP_LOG_FILE=${BACKUP_DIR}/logs/ftp_backup$b$VIP$b$DATETIME.log
status_run_backup='NOK'
ihostname=`hostname`;
status_master=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -P $VIPP -Bse "call vsystem.check_master('$ihostname','$IP');"`;
echo $status_master > $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/ismaster.info;

START_TIME=`date +'%F %T'`
START=$(date +%s)
INPUT_SIZE=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "SELECT concat(round((SUM(DATA_LENGTH) + SUM(INDEX_LENGTH))/1024/1024/1024,3),'G') FROM information_schema.tables;"`;
cd $BACKUP_DIR
$COMMAND_BACKUP --galera-info --compress --backup --target-dir=$BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/database --user=$USER --password=$PASS >> $LOG_FILE 2>&1;
END=$(date +%s)
DURATION=$(( $END - $START ))
END_TIME=`date +'%F %T'`

STATUS=`grep "completed OK!" $LOG_FILE | wc -l`;
if [ $STATUS -eq 1 ]
then
        binlogfile=`qpress -do $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/database/mariadb_backup_info.qp | grep binlog_pos | cut -d"'" -f2`;
        binlogpos=`qpress -do $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/database/mariadb_backup_info.qp | grep binlog_pos | cut -d"'" -f4`;
        GTID=`qpress -do $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/database/mariadb_backup_info.qp | grep binlog_pos | cut -d"'" -f6`;
        mkdir -p $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/binlog;
        last_binlogfile=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "select if(binlog_file = NULL,'NULL',binlog_file) from vsystem.backup_history where STATUS = CONVERT('OK' USING utf8) and binlog_file is not null and ip = CONVERT('$IP' USING utf8) order by start_time desc limit 1;"`;
        clast_binlogfile=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "select count(*) from vsystem.backup_history where STATUS = CONVERT('OK' USING utf8) and binlog_file is not null and ip = CONVERT('$IP' USING utf8) order by start_time desc limit 1;"`;
        lindex_binlog=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "show variables like '%log_bin_index%';"`;
        index_binlog=`echo $lindex_binlog | cut -d" " -f 2`;
        lbase_binlog=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "show variables like '%log_bin_basename%';"`;
        base_binlog=`echo $lbase_binlog | cut -d" " -f 2`;
        if [ $clast_binlogfile -eq 0 ]
        then
                last_binlogfile=NULL
        fi
        if [ $last_binlogfile == NULL ]
        then
                cp $index_binlog $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/binlog/mysql-bin.index;
        else
                startp=`grep -n $last_binlogfile $index_binlog | cut -d":" -f1`;
                totalp=`more $index_binlog | wc -l`;
                list=$(($totalp-$startp+2));
                tail -$list $index_binlog > $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/binlog/mysql-bin.index;
        fi
        while read line
        do
                nbinlog=${line:$((${#line}-6)):6};
                qpress $base_binlog.$nbinlog $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/binlog/binlog.$nbinlog.qp;
        done < $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/binlog/mysql-bin.index;
        status_run_backup='OK';
        OUTPUT_SIZE=`du -sh $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/database | awk '{print $1}'`;
        cd $BACKUP_DIR;
        a=`ls -lt | grep backup$b$IP | wc -l`;
        while [ $a -gt $DAYS ]
        do
                backupdel=`ls -lt | grep backup$b$IP | tail -1`;
                rm -rf $backupdel;
                a=$(($a-1));
        done
fi

#Backup to remote server by RSYNC
FTP_STATUS='NOK'
FSTART_TIME=`date +'%F %T'`
remote_backup_user=rsync
remote_backup_password=xxxx
REMOTE_BACKUP_SERVER=10.255.64.6
#FILE_BACKUP=/backup/backup_mariadb/campaign_noti_outbound.231207.sql
FILE_BACKUP=$BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME
echo $FILE_BACKUP

#sshpass -p "xxxx" rsync -avzh /backup/backup_mariadb/campaign_noti_outbound.231207.sql  rsync@10.255.64.66:10.254.150.27 > /tmp/rsync.status 2>&1

/bin/sshpass -p $remote_backup_password rsync -e "ssh -o StrictHostKeyChecking=no" -avzh $FILE_BACKUP  $remote_backup_user@$REMOTE_BACKUP_SERVER:$IP/ > /tmp/rsync.status 2>&1

rsync_error=`cat /tmp/rsync.status | grep -i "rsync error" | wc -l`
rsync_fail=`cat /tmp/rsync.status | grep -i " Failed" | wc -l`

FEND_TIME=`date +'%F %T'`
echo FTP from $FSTART_TIME to $FEND_TIME >> $FTP_LOG_FILE

if [ "$rsync_error" -eq 0 ] && [ "$rsync_fail" -eq 0 ]
then
        echo 'Sync data success' > /tmp/backup_data.status;
        /bin/sshpass -p $remote_backup_password rsync -e "ssh -o StrictHostKeyChecking=no" -avzh /tmp/backup_data.status  $remote_backup_user@$REMOTE_BACKUP_SERVER:$IP >> /tmp/rsync.status 2>&1;
        FTP_STATUS='OK';
else
        echo 'Sync data wrong' > /tmp/backup_data.status;
        /bin/sshpass -p $remote_backup_password rsync -e "ssh -o StrictHostKeyChecking=no" -avzh /tmp/backup_data.status  $remote_backup_user@$REMOTE_BACKUP_SERVER:$IP >> /tmp/rsync.status 2>&1;
        FTP_STATUS='NOK';
fi

#WRITE BACKUP INFO INTO DB
$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "insert into vsystem.backup_history (type, ip, ismaster, database_backup, status, start_time, end_time,duration, input_size, output_size, backup_dir, server_ftp, ftp_dir, ftp_status, number_backup, binlog_file, binlog_position, GTID) VALUES ('$TYPE_BACKUP', '$IP', '$status_master', '$DB_NAME', '$status_run_backup', '$START_TIME', '$END_TIME', '$DURATION', '$INPUT_SIZE', '$OUTPUT_SIZE', '$BACKUP_DIR', '$REMOTE_BACKUP_SERVER', '$FTP_DIR', '$FTP_STATUS', '$DAYS', '$binlogfile', '$binlogpos', '$GTID');"

echo "insert into monitor.backup_history (type, ip, ismaster, database_backup, status, start_time, end_time,duration, input_size, output_size, backup_dir, server_ftp, ftp_dir, ftp_status, number_backup, binlog_file, binlog_position, GTID) VALUES ('$TYPE_BACKUP', '$IP', '$status_master', '$DB_NAME', '$status_run_backup', '$START_TIME', '$END_TIME', '$DURATION', '$INPUT_SIZE', '$OUTPUT_SIZE', '$BACKUP_DIR', '$REMOTE_BACKUP_SERVER', '$FTP_DIR', '$FTP_STATUS', '$DAYS', '$binlogfile', '$binlogpos', '$GTID');"


echo "update monitor.backup_status set `status`=$status, updated_time='$END_TIME' where IP='$IP'"

------------------


------------------Backup V2
#!/bin/bash
DATETIME=`date +%Y%m%d%H%M`
START_TIME=`date +'%F %T'`
SYSNAME=financial-platform
DB_NAME=--all-databases
IP=10.211.87.1
VIP=10.211.87.1
VIPP=3306
USER="mbackup"
PASS="Viettel6996"
COMMAND_MYSQL="/usr/local/mysql/bin/mariadb"
##mariabackup for mariadb, xtrabackup for mysql
##COMMAND_BACKUP="/usr/bin/xtrabackup"
COMMAND_BACKUP="/usr/local/mysql/bin/mariabackup"
b=_
DAYS=3
##mariabackup for mariadb, xtrabackup for mysql
##TYPE_BACKUP=xtrabackup
TYPE_BACKUP=mariabackup
BACKUP_DIR=/backup/backup_mariadb
mkdir -p ${BACKUP_DIR}/logs;
mkdir -p $BACKUP_DIR/backup$b$VIP$b$SYSNAME$b$DATETIME;
LOG_FILE=${BACKUP_DIR}/logs/full_backup$b$VIP$b$DATETIME.log
FTP_LOG_FILE=${BACKUP_DIR}/logs/ftp_backup$b$VIP$b$DATETIME.log
status_run_backup='NOK'
ihostname=`hostname`;
status_master=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -P $VIPP -Bse "call vsystem.check_master('$ihostname','$IP');"`;
echo $status_master > $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/ismaster.info;

START_TIME=`date +'%F %T'`
START=$(date +%s)
INPUT_SIZE=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "SELECT concat(round((SUM(DATA_LENGTH) + SUM(INDEX_LENGTH))/1024/1024/1024,3),'G') FROM information_schema.tables;"`;
cd $BACKUP_DIR
$COMMAND_BACKUP --galera-info --compress --backup --target-dir=$BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/database --user=$USER --password=$PASS >> $LOG_FILE 2>&1;
END=$(date +%s)
DURATION=$(( $END - $START ))
END_TIME=`date +'%F %T'`

STATUS=`grep "completed OK!" $LOG_FILE | wc -l`;
if [ $STATUS -eq 1 ]
then
        binlogfile=`qpress -do $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/database/mariadb_backup_info.qp | grep binlog_pos | cut -d"'" -f2`;
        binlogpos=`qpress -do $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/database/mariadb_backup_info.qp | grep binlog_pos | cut -d"'" -f4`;
        GTID=`qpress -do $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/database/mariadb_backup_info.qp | grep binlog_pos | cut -d"'" -f6`;
        mkdir -p $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/binlog;
        last_binlogfile=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "select if(binlog_file = NULL,'NULL',binlog_file) from vsystem.backup_history where STATUS = CONVERT('OK' USING utf8) and binlog_file is not null and ip = CONVERT('$IP' USING utf8) order by start_time desc limit 1;"`;
        clast_binlogfile=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "select count(*) from vsystem.backup_history where STATUS = CONVERT('OK' USING utf8) and binlog_file is not null and ip = CONVERT('$IP' USING utf8) order by start_time desc limit 1;"`;
        lindex_binlog=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "show variables like '%log_bin_index%';"`;
        index_binlog=`echo $lindex_binlog | cut -d" " -f 2`;
        lbase_binlog=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "show variables like '%log_bin_basename%';"`;
        base_binlog=`echo $lbase_binlog | cut -d" " -f 2`;
        if [ $clast_binlogfile -eq 0 ]
        then
                last_binlogfile=NULL
        fi
        if [ $last_binlogfile == NULL ]
        then
                cp $index_binlog $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/binlog/mysql-bin.index;
        else
                startp=`grep -n $last_binlogfile $index_binlog | cut -d":" -f1`;
                totalp=`more $index_binlog | wc -l`;
                list=$(($totalp-$startp+2));
                tail -$list $index_binlog > $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/binlog/mysql-bin.index;
        fi
        while read line
        do
                nbinlog=${line:$((${#line}-6)):6};
                qpress $base_binlog.$nbinlog $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/binlog/binlog.$nbinlog.qp;
        done < $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/binlog/mysql-bin.index;
        status_run_backup='OK';
        OUTPUT_SIZE=`du -sh $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/database | awk '{print $1}'`;
        cd $BACKUP_DIR;
        a=`ls -lt | grep backup$b$IP | wc -l`;
        while [ $a -gt $DAYS ]
        do
                backupdel=`ls -lt | grep backup$b$IP | tail -1`;
                rm -rf $backupdel;
                a=$(($a-1));
        done
fi

#Backup to FTP server
FTP_SERVER=10.10.10.12
FTP_DIR=/backup_ftp_05
FTP_STATUS='NOK'
FTP_USER="ftp_bak"
FTP_PASS="Bak@FTP#143"
OLD=OLD
SUB_DIR_NEW=$FTP_DIR/BACKUP$b$IP$b$SYSNAME
SUB_DIR_OLD=$FTP_DIR/BACKUP$b$IP$b$SYSNAME$b$OLD

FSTART_TIME=`date +'%F %T'`
#lftp -e "set net:max-retries 3;rm -rf $SUB_DIR_OLD;mv $SUB_DIR_NEW $SUB_DIR_OLD;mkdir $SUB_DIR_NEW;mirror -R $BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME/ $SUB_DIR_NEW/ --log=$FTP_LOG_FILE;quit" -u $FTP_USER,$FTP_PASS ftp://$FTP_SERVER  >> $FTP_LOG_FILE
FEND_TIME=`date +'%F %T'`

#FSTATUS=`grep "Total:" $FTP_LOG_FILE | wc -l`;

#if [ $FSTATUS -eq 1 ]
#then
#	FTP_STATUS='OK';
#fi
FTP_STATUS='NOK'

echo FTP from $FSTART_TIME to $FEND_TIME >> $FTP_LOG_FILE

#Backup to remote server by RSYNC
remote_backup_user=rsync
remote_backup_password=xxxx
#IP=10.254.150.27
REMOTE_BACKUP_SERVER=10.255.64.666
#b=_
#FILE_BACKUP=/backup/backup_mariadb/campaign_noti_outbound.231207.sql
FILE_BACKUP=$BACKUP_DIR/backup$b$IP$b$SYSNAME$b$DATETIME
echo $FILE_BACKUP

#sshpass -p "xxxx" rsync -avzh /backup/backup_mariadb/campaign_noti_outbound.231207.sql  rsync@10.255.64.66:10.254.150.27 > /tmp/rsync.status 2>&1

/bin/sshpass -p $remote_backup_password rsync -e "ssh -o StrictHostKeyChecking=no" -avzh $FILE_BACKUP  $remote_backup_user@$REMOTE_BACKUP_SERVER:$IP/ > /tmp/rsync.status 2>&1

rsync_error=`cat /tmp/rsync.status | grep -i "rsync error" | wc -l`
rsync_fail=`cat /tmp/rsync.status | grep -i " Failed" | wc -l`


if [ "$rsync_error" -eq 0 ] && [ "$rsync_fail" -eq 0 ]
then
        echo 'Sync data success' > /tmp/backup_data.status;
        /bin/sshpass -p $remote_backup_password rsync -e "ssh -o StrictHostKeyChecking=no" -avzh /tmp/backup_data.status  $remote_backup_user@$REMOTE_BACKUP_SERVER:$IP >> /tmp/rsync.status 2>&1;
        FTP_STATUS='OK';
else
        echo 'Sync data wrong' > /tmp/backup_data.status;
        /bin/sshpass -p $remote_backup_password rsync -e "ssh -o StrictHostKeyChecking=no" -avzh /tmp/backup_data.status  $remote_backup_user@$REMOTE_BACKUP_SERVER:$IP >> /tmp/rsync.status 2>&1;
        FTP_STATUS='NOK';
fi

#WRITE BACKUP INFO INTO DB
$COMMAND_MYSQL -u "$USER" -p"$PASS" -Bse "insert into vsystem.backup_history (type, ip, ismaster, database_backup, status, start_time, end_time,duration, input_size, output_size, backup_dir, server_ftp, ftp_dir, ftp_status, number_backup, binlog_file, binlog_position, GTID) VALUES ('$TYPE_BACKUP', '$IP', '$status_master', '$DB_NAME', '$status_run_backup', '$START_TIME', '$END_TIME', '$DURATION', '$INPUT_SIZE', '$OUTPUT_SIZE', '$BACKUP_DIR', '$REMOTE_BACKUP_SERVER', '$FTP_DIR', '$FTP_STATUS', '$DAYS', '$binlogfile', '$binlogpos', '$GTID');"

#lftp -e "set net:max-retries 3;cd $SUB_DIR_NEW;mput $LOG_FILE $FTP_LOG_FILE;quit" -u $FTP_USER,$FTP_PASS ftp://$FTP_SERVER > /dev/null 2>&1


echo "insert into monitor.backup_history (type, ip, ismaster, database_backup, status, start_time, end_time,duration, input_size, output_size, backup_dir, server_ftp, ftp_dir, ftp_status, number_backup, binlog_file, binlog_position, GTID) VALUES ('$TYPE_BACKUP', '$IP', '$status_master', '$DB_NAME', '$status_run_backup', '$START_TIME', '$END_TIME', '$DURATION', '$INPUT_SIZE', '$OUTPUT_SIZE', '$BACKUP_DIR', '$REMOTE_BACKUP_SERVER', '$FTP_DIR', '$FTP_STATUS', '$DAYS', '$binlogfile', '$binlogpos', '$GTID');"

> $IP_cmd_insert_status_backup

echo "update monitor.backup_status set `status`=$status, updated_time='$END_TIME' where IP='$IP'"

> $IP_cmd_update_status_backup


status_run_backup='NOK'
END_TIME=`date +'%F %T'`



_______________________________________________________________________________________________

#Script move and rotate backup data
#Nguyen Quang Thuy - Thuynq@viettel.com.vn - 0966996676
#!/bin/bash
DATETIME=`date +%Y%m%d%H%M` ;
dir_store=/u02/STORE
dir_backup=/u02/BACKUP
dir_backup_history=/u02/BACKUP/$DATETIME
mkdir -p $dir_backup_history
mkdir -p $dir_store

echo dir_store $dir_store
echo dir_backup_history $dir_backup_history

cd $dir_backup
ls -lt | grep d > /tmp/list_dir.txt
num_dir=`cat /tmp/list_dir.txt | wc -l`
oldest_dir=`tail -1 /tmp/list_dir.txt | awk '{print $9}'`

if [ "$num_dir" -ge 4 ]
then    
	rm -rf $dir_backup/$oldest_dir
else
    echo 'ERROR';
fi

#get list server
ls -la $dir_store | awk '{print $9}' | grep "10." > /tmp/list_server_database.txt
list_server_database=/tmp/list_server_database.txt

# Read the input file line by line
while read -r LINE
do
    printf server 'server ' "$LINE" ' %s\n' ;

        status_backup_data_file=$dir_store/$LINE/backup_data.status ;
        echo $status_backup_data_file ;
        status_backup_data=`cat $dir_store/$LINE/backup_data.status | grep -i "success" | wc -l` ;
        status_process_rsync=`netstat -natp | grep rsync | grep "$LINE" | wc -l` ;

        echo status_process_rsync $status_process_rsync ;
        echo status_backup_data $status_backup_data ;

        if [ "$status_process_rsync" -eq 0 ] && [ -f "$status_backup_data_file" ]
        then
                mv $dir_store/$LINE $dir_backup_history/ ;
                mkdir $dir_store/$LINE ;
                chown -R rsync:rsync $dir_store/$LINE;
                echo "run success" ;
        else
                echo 'ERROR';
fi
done < "$list_server_database"

##################################
DATETIME2=`date +%Y%m%d%H%M` ;
dir_store2=/backup/STORE
dir_backup2=/backup/BACKUP
dir_backup_history2=/backup/BACKUP/$DATETIME2
mkdir -p $dir_backup_history2
mkdir -p $dir_store2


echo dir_store2 $dir_store2
echo dir_backup_history2 $dir_backup_history2

cd $dir_backup2
ls -lt | grep d > /tmp/list_dir.txt
num_dir=`cat /tmp/list_dir.txt | wc -l`
oldest_dir=`tail -1 /tmp/list_dir.txt | awk '{print $9}'`

if [ "$num_dir" -ge 4 ]
then    
	rm -rf $dir_backup2/$oldest_dir
else
    echo 'ERROR';
fi

#get list server
ls -la $dir_store2 | awk '{print $9}' | grep "10." > /tmp/list_server_database2.txt
list_server_database2=/tmp/list_server_database2.txt

# Read the input file line by line
while read -r LINE
do
    printf server 'server ' "$LINE" ' %s\n' ;

        status_backup_data_file2=$dir_store2/$LINE/backup_data.status ;
        echo $status_backup_data_file2 ;
        status_backup_data2=`cat $dir_store2/$LINE/backup_data.status | grep -i "success" | wc -l` ;
        status_process_rsync2=`netstat -natp | grep rsync | grep "$LINE" | wc -l` ;

        echo status_process_rsync2 $status_process_rsync2 ;
        echo status_backup_data2 $status_backup_data2 ;

        if [ "$status_process_rsync2" -eq 0 ] && [ -f "$status_backup_data_file2" ]
        then
                mv $dir_store2/$LINE $dir_backup_history2/ ;
                mkdir $dir_store2/$LINE ;
                chown -R rsync_2:rsync_2 $dir_store2/$LINE;
                echo "run success" ;
        else
                echo 'ERROR';
fi
done < "$list_server_database2"