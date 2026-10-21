#!/bin/bash
USER="tdht"
PASS="xxx"
COMMAND_MYSQL="/bin/mysql"
VIP=10.254.158.109
VIPP=3306
cmariadb=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -h "$VIP" -P $VIPP -Bse "show VARIABLES LIKE '%version_comment%';" | grep "MariaDB" | wc -l`;
cstat=`$COMMAND_MYSQL -u "$USER" -p"$PASS" -h "$VIP" -P $VIPP -Bse "SHOW variables LIKE 'use_stat_tables';" | grep -vi "NEVER" | wc -l`;
if [ $cmariadb -eq 1 ] && [ $cstat -eq 1 ];
then $COMMAND_MYSQL -u "$USER" -p"$PASS" -h "$VIP" -P $VIPP -Bse "CALL vsystem.auto_daily_analyze(1);";
else $COMMAND_MYSQL -u "$USER" -p"$PASS" -h "$VIP" -P $VIPP -Bse "CALL vsystem.auto_daily_analyze(0);";
fi

