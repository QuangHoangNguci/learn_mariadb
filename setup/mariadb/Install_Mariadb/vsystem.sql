-- MariaDB dump 10.19  Distrib 10.6.4-1-MariaDB, for Linux (x86_64)
--
-- Host: 127.0.0.1    Database: vsystem
-- ------------------------------------------------------
-- Server version	10.6.4-1-MariaDB-enterprise-log

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `add_partition_history`
--
CREATE DATABASE IF NOT EXISTS vsystem;
USE vsystem;
DROP TABLE IF EXISTS `add_partition_history`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `add_partition_history` (
  `pid` int(11) NOT NULL AUTO_INCREMENT,
  `table_schema` varchar(100) NOT NULL COMMENT 'ten owner',
  `table_name` varchar(100) NOT NULL COMMENT 'ten bang',
  `partition_name` varchar(100) NOT NULL COMMENT 'ten partition',
  `partition_method` mediumtext DEFAULT NULL COMMENT 'partition method',
  `partition_expression` mediumtext DEFAULT NULL COMMENT 'partition expression',
  `partition_description` mediumtext DEFAULT NULL COMMENT 'partition description',
  `engine` varchar(100) DEFAULT NULL COMMENT 'ten engine',
  `start_time` datetime DEFAULT NULL COMMENT 'thoi gian bat sau add',
  `end_time` datetime DEFAULT NULL COMMENT 'thoi gian ket thuc add',
  `duration` time DEFAULT NULL COMMENT 'thoi gian thuc thi',
  `sid` int(11) DEFAULT NULL COMMENT 'schedule id',
  PRIMARY KEY (`pid`),
  KEY `added_time` (`start_time`),
  KEY `sid` (`sid`),
  KEY ` table_schema_ name` (`table_schema`,`table_name`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb3 COMMENT='thong tin chi tiet partition duoc add';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `backup_history`
--

DROP TABLE IF EXISTS `backup_history`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `backup_history` (
  `bid` int(11) NOT NULL AUTO_INCREMENT,
  `type` varchar(50) NOT NULL COMMENT 'Kieu backup: xtrabackup, mysqldump, mariabackup,...',
  `ip` varchar(50) NOT NULL COMMENT 'IP node backup',
  `ismaster` varchar(10) DEFAULT NULL COMMENT 'La node master',
  `database_backup` varchar(50) NOT NULL COMMENT 'Ten database backup full',
  `status` varchar(50) NOT NULL COMMENT 'Trang thai backup',
  `start_time` datetime NOT NULL COMMENT 'Thoi gian bat dau backup',
  `end_time` datetime NOT NULL COMMENT 'Thoi gian ket thuc backup',
  `duration` varchar(50) NOT NULL COMMENT 'Tong thoi gian thuc hien backup (s)',
  `input_size` varchar(50) NOT NULL COMMENT 'Dung luong database',
  `output_size` varchar(50) NOT NULL COMMENT 'Dung luong file backup',
  `backup_dir` varchar(300) NOT NULL COMMENT 'Thu muc de backup',
  `server_ftp` varchar(90) DEFAULT NULL COMMENT 'IP FTP',
  `ftp_dir` varchar(300) DEFAULT NULL COMMENT 'Thu muc FTP backup',
  `ftp_status` varchar(90) DEFAULT NULL COMMENT 'Tinh trang FTP',
  `number_backup` varchar(10) NOT NULL COMMENT 'So luong ban backup',
  `binlog_file` varchar(50) DEFAULT NULL COMMENT 'Binlog file name',
  `binlog_position` varchar(30) DEFAULT NULL COMMENT 'Binlog position',
  `GTID` varchar(100) DEFAULT NULL COMMENT 'Global transaction id',
  PRIMARY KEY (`bid`),
  KEY `start_time` (`start_time`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb3 COMMENT='Thong tin trang thai backup database';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `daily_analyze_history`
--

DROP TABLE IF EXISTS `daily_analyze_history`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `daily_analyze_history` (
  `aid` int(32) NOT NULL AUTO_INCREMENT,
  `table_schema` varchar(100) NOT NULL COMMENT 'ten owner',
  `table_name` varchar(100) NOT NULL COMMENT 'ten bang',
  `partition_name` varchar(100) DEFAULT NULL COMMENT 'ten partition',
  `engine` varchar(100) DEFAULT NULL COMMENT 'ten engine',
  `start_time` datetime NOT NULL COMMENT 'thoi diem bat dau analyze',
  `end_time` datetime DEFAULT NULL COMMENT 'thoi diem ket thuc analyze',
  `duration` time DEFAULT NULL COMMENT 'thoi gian thuc thi',
  `status` varchar(50) DEFAULT NULL COMMENT 'trang thai run',
  `sid` int(11) DEFAULT NULL COMMENT 'schedule id',
  PRIMARY KEY (`aid`,`start_time`),
  KEY `start_time` (`start_time`),
  KEY `sid` (`sid`),
  KEY `table_name` (`table_name`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb3 COMMENT='Thong tin chi tiet analyze cac table va partition'
 PARTITION BY RANGE  COLUMNS(`start_time`)
(PARTITION `DATA202210` VALUES LESS THAN ('2022-11-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202211` VALUES LESS THAN ('2022-12-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202212` VALUES LESS THAN ('2023-01-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202301` VALUES LESS THAN ('2023-02-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202302` VALUES LESS THAN ('2023-03-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202303` VALUES LESS THAN ('2023-04-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202304` VALUES LESS THAN ('2023-05-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202305` VALUES LESS THAN ('2023-06-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202306` VALUES LESS THAN ('2023-07-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202307` VALUES LESS THAN ('2023-08-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202308` VALUES LESS THAN ('2023-09-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATAMAX` VALUES LESS THAN (MAXVALUE) ENGINE = InnoDB);
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `ismaster`
--

DROP TABLE IF EXISTS `ismaster`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `ismaster` (
  `mid` int(11) NOT NULL AUTO_INCREMENT,
  `master_host` varchar(100) NOT NULL COMMENT 'Hostname cua master',
  `master_ip` varchar(50) DEFAULT NULL COMMENT 'IP cua master',
  `checked_host` varchar(100) NOT NULL COMMENT 'Hostname cua node check',
  `checked_ip` varchar(50) NOT NULL COMMENT 'IP cua node check',
  `checked_time` datetime NOT NULL COMMENT 'Thoi gian check',
  PRIMARY KEY (`mid`,`checked_time`),
  KEY `check_time` (`checked_time`)
) ENGINE=InnoDB AUTO_INCREMENT=2433 DEFAULT CHARSET=utf8mb3 COMMENT='Thong tin trang thai backup database'
 PARTITION BY RANGE  COLUMNS(`checked_time`)
(PARTITION `DATA202210` VALUES LESS THAN ('2022-11-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202211` VALUES LESS THAN ('2022-12-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202212` VALUES LESS THAN ('2023-01-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202301` VALUES LESS THAN ('2023-02-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202302` VALUES LESS THAN ('2023-03-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202303` VALUES LESS THAN ('2023-04-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202304` VALUES LESS THAN ('2023-05-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202305` VALUES LESS THAN ('2023-06-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202306` VALUES LESS THAN ('2023-07-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202307` VALUES LESS THAN ('2023-08-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATA202308` VALUES LESS THAN ('2023-09-01 00:00:00') ENGINE = InnoDB,
 PARTITION `DATAMAX` VALUES LESS THAN (MAXVALUE) ENGINE = InnoDB);
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `schedule_history`
--

DROP TABLE IF EXISTS `schedule_history`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `schedule_history` (
  `sid` int(11) NOT NULL AUTO_INCREMENT,
  `schedule_name` varchar(50) NOT NULL COMMENT 'ten schedule',
  `start_time` datetime DEFAULT NULL COMMENT 'thoi diem bat dau schedule',
  `end_time` datetime DEFAULT NULL COMMENT 'thoi diem ket thuc schedule',
  `duration` time DEFAULT NULL COMMENT 'thoi gian thuc thi',
  `status` varchar(50) DEFAULT NULL COMMENT 'trang thai run',
  PRIMARY KEY (`sid`),
  KEY `schedule_name` (`schedule_name`),
  KEY `start_time` (`start_time`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb3 COMMENT='thong tin thuc hien schedule';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `tmp_add_tables_partitions`
--

DROP TABLE IF EXISTS `tmp_add_tables_partitions`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `tmp_add_tables_partitions` (
  `ID` int(11) NOT NULL AUTO_INCREMENT,
  `TABLE_SCHEMA` varchar(64) NOT NULL COMMENT 'ten owner',
  `TABLE_NAME` varchar(64) NOT NULL COMMENT 'ten bang',
  `PARTITION_NAME` varchar(64) DEFAULT NULL COMMENT 'ten partition',
  `PARTITION_METHOD` varchar(18) DEFAULT NULL COMMENT 'partition method',
  `PARTITION_EXPRESSION` mediumtext DEFAULT NULL COMMENT 'partition expression',
  `PARTITION_DESCRIPTION` mediumtext DEFAULT NULL COMMENT 'partition description',
  `ENGINE` varchar(64) DEFAULT NULL COMMENT 'ten engine',
  PRIMARY KEY (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `tmp_list_tables_partitions`
--

DROP TABLE IF EXISTS `tmp_list_tables_partitions`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `tmp_list_tables_partitions` (
  `ID` int(11) NOT NULL AUTO_INCREMENT,
  `TABLE_SCHEMA` varchar(64) NOT NULL COMMENT 'ten owner',
  `TABLE_NAME` varchar(64) NOT NULL COMMENT 'ten bang',
  `PARTITION_NAME` varchar(64) DEFAULT NULL COMMENT 'ten partition',
  `PARTITION_METHOD` varchar(18) DEFAULT NULL COMMENT 'partition method',
  `PARTITION_EXPRESSION` mediumtext DEFAULT NULL COMMENT 'partition expression',
  `PARTITION_DESCRIPTION` mediumtext DEFAULT NULL COMMENT 'partition description',
  `ENGINE` varchar(64) DEFAULT NULL COMMENT 'ten enginer',
  PRIMARY KEY (`ID`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping routines for database 'vsystem'
--
/*!50003 DROP FUNCTION IF EXISTS `convert_date` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`tdht`@`127.0.0.1` FUNCTION `convert_date`(indate VARCHAR(100)) RETURNS date
    DETERMINISTIC
BEGIN
  DECLARE ris_check int;
  DECLARE icheck int;
  DECLARE routdate date;
    CASE  LENGTH(indate)
      WHEN 4 THEN
        SELECT indate REGEXP '20[0-9][0-9]' INTO icheck;
        IF icheck = 1 THEN
          SET ris_check = 1;
    SELECT STR_TO_DATE(CONCAT(indate,'0101'),'%Y%m%d') INTO routdate;
    ELSE
    SET ris_check = 0;
          SET routdate = DATE_ADD(NOW(),INTERVAL -1 DAY);
    END IF;
      WHEN 6 THEN
        SELECT indate REGEXP '20[0-9][0-9]([0][0-9]|[1][0-2])' INTO icheck;
        IF icheck = 1 THEN
          SET ris_check = 2;
          SELECT STR_TO_DATE(CONCAT(indate,'01'),'%Y%m%d') INTO routdate; 
        ELSEIF CAST(indate AS UNSIGNED INTEGER) > 730485 THEN
          SET ris_check = 3;
          SET routdate = FROM_DAYS(CAST(indate AS UNSIGNED INTEGER));          
        ELSE
    SET ris_check = 0;
          SET routdate = DATE_ADD(NOW(),INTERVAL -1 DAY);
        END IF;      
      WHEN 8 THEN
        SELECT indate REGEXP '20[0-9][0-9]([0][0-9]|[1][0-2])([0-2][0-9]|[3][0-1])' INTO icheck;
        IF icheck = 1 THEN
          SET ris_check = 4;
    SELECT STR_TO_DATE(indate,'%Y%m%d') INTO routdate;
    ELSE
    SET ris_check = 0;
          SET routdate = DATE_ADD(NOW(),INTERVAL -1 DAY);
    END IF;
      WHEN 10 THEN
        SELECT indate REGEXP '^[0-2]' INTO icheck;
        IF icheck = 1 THEN
          SET ris_check = 5;
    SELECT FROM_UNIXTIME(FLOOR(indate)) INTO routdate;
    ELSE
    SET ris_check = 0;
          SET routdate = DATE_ADD(NOW(),INTERVAL -1 DAY);
    END IF;
      WHEN 14 THEN
        SELECT indate REGEXP '20[0-9][0-9]([0][0-9]|[1][0-2])([0-2][0-9]|[3][0-1])[0-5][0-9][0-5][0-9][0-5][0-9]' INTO icheck;        
        IF icheck = 1 THEN
          SET ris_check = 6;
    SELECT STR_TO_DATE(indate,'%Y%m%d%H%i%s') INTO routdate;
    ELSE
    SET ris_check = 0;
          SET routdate = DATE_ADD(NOW(),INTERVAL -1 DAY);
    END IF;
      ELSE
        SET ris_check = 0;
        SET routdate = DATE_ADD(NOW(),INTERVAL -1 DAY);
      END CASE;
  RETURN routdate;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP FUNCTION IF EXISTS `replace_azn` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`tdht`@`127.0.0.1` FUNCTION `replace_azn`(s VARCHAR(64),fn int) RETURNS varchar(64) CHARSET latin1
    DETERMINISTIC
BEGIN
  DECLARE ostring VARCHAR(64);
  DECLARE i int;
  SET ostring = s;  
  IF fn = 1 THEN
    SET i=65;
    WHILE i < 91 DO
      SET ostring = REPLACE(ostring,char(i),'');
      SET ostring = REPLACE(ostring,LOWER(char(i)),'');
      SET i=i+1;
    END WHILE;
    SET i=97;
    WHILE i < 123 DO
      SET ostring = REPLACE(ostring,char(i),'');
      SET i=i+1;
    END WHILE;
    SET ostring = REPLACE(ostring,'\'','');
    SET ostring = REPLACE(ostring,':','');
    SET ostring = REPLACE(ostring,' ','');
    SET ostring = REPLACE(ostring,'-',''); 
  ELSEIF fn = 2 THEN
    SET i=0;
    WHILE i < 10 DO
      SET ostring = REPLACE(ostring,i,'');
      SET i=i+1;
    END WHILE;
  END IF;
  RETURN ostring;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `action_add_partition` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `action_add_partition`(sid int(11))
BEGIN
  DECLARE done INT DEFAULT FALSE;
  DECLARE ctable_schema VARCHAR(64);
  DECLARE ctable_name VARCHAR(64);
  DECLARE cpartition_name VARCHAR(64);
  DECLARE cpartition_method varchar(18);
  DECLARE cpartition_expression MEDIUMTEXT;
  DECLARE cpartition_description MEDIUMTEXT;
  DECLARE cengine VARCHAR(64);
  DECLARE ostringout mediumtext;
  DECLARE starttime datetime;
  DECLARE endtime datetime;  
  DECLARE cur CURSOR FOR SELECT TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE FROM vsystem.tmp_list_tables_partitions;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done=TRUE;
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO ctable_schema,ctable_name,cpartition_name,cpartition_method,cpartition_expression,cpartition_description,cengine;
    IF done THEN
      LEAVE read_loop;
    END IF;
    CALL vsystem.print_one_table(ctable_schema,ctable_name,cpartition_name,cpartition_method,cpartition_expression,cpartition_description,cengine,ostringout);
    IF ostringout IS NOT NULL THEN
  SET starttime = NOW();
      SET @sql = ostringout;
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
  SET endtime = NOW();
      INSERT INTO vsystem.add_partition_history(table_schema,table_name,partition_name,partition_method,partition_expression,partition_description,engine,start_time,end_time,duration,sid)
        SELECT table_schema,table_name,partition_name,partition_method,partition_expression,partition_description,engine,starttime,endtime,TIMEDIFF(endtime,starttime),sid FROM tmp_add_tables_partitions
          WHERE table_schema = CONVERT(ctable_schema USING utf8) AND table_name = CONVERT(ctable_name USING utf8) AND UPPER(partition_description) !=  'MAXVALUE'
          ORDER BY id;
    END IF;
  END LOOP;
  CLOSE cur;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `auto_add_partition` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `auto_add_partition`(smonth INT,action INT)
BEGIN
  DECLARE starttime datetime;
  DECLARE endtime datetime;
  DECLARE ssid int(11);
  IF ACTION = 1 THEN
    SET starttime = NOW();
    INSERT INTO vsystem.schedule_history(schedule_name,start_time,end_time,status) VALUES('vsystem.auto_add_partition',starttime,starttime,'NOK');
  END IF;
  CALL vsystem.init_add_partition();
  CALL vsystem.prepare_add_partition(smonth);
  IF action = 1 THEN
select sid INTO ssid FROM vsystem.schedule_history    
    WHERE start_time = starttime AND schedule_name = 'vsystem.auto_add_partition';
    CALL vsystem.action_add_partition(ssid);
    SET endtime = NOW();
    update vsystem.schedule_history
    SET end_time=endtime,status='OK',duration=TIMEDIFF(endtime,starttime)
    WHERE start_time = starttime AND schedule_name = 'vsystem.auto_add_partition';
  ELSE
    CALL vsystem.print_add_partition();
  END IF;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `auto_daily_analyze` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `auto_daily_analyze`(IN atype INT)
BEGIN
DECLARE starttime datetime;
DECLARE endtime datetime;
DECLARE ssid int(11);
DECLARE icheck int;
SET starttime = NOW();
INSERT INTO vsystem.schedule_history(schedule_name,start_time,end_time,duration,status) VALUES('vsystem.auto_daily_analyze',starttime,starttime,TIMEDIFF(starttime,starttime),'NOK');
    SELECT sid INTO ssid FROM vsystem.schedule_history
WHERE start_time = starttime AND schedule_name = CONVERT('vsystem.auto_daily_analyze' USING utf8);
SELECT count(*) INTO icheck FROM vsystem.schedule_history WHERE status = CONVERT('OK' USING utf8);
CALL vsystem.tables_analyze(atype,ssid);
IF icheck = 0 THEN
CALL vsystem.fist_partitons_analyze(ssid);
ELSE
CALL vsystem.partitons_analyze(ssid);
END IF;
SET endtime = NOW();
    UPDATE vsystem.schedule_history
SET end_time=endtime,status='OK',duration=TIMEDIFF(endtime,starttime)
WHERE start_time = starttime AND schedule_name = CONVERT('vsystem.auto_daily_analyze' USING utf8);
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `check_date_add_partition` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `check_date_add_partition`(indate VARCHAR(100),OUT is_check INT,OUT outdate datetime)
BEGIN
  DECLARE ris_check int;
  DECLARE icheck int;
  DECLARE routdate date;
    CASE  LENGTH(indate)
      WHEN 4 THEN
        SELECT indate REGEXP '20[0-9][0-9]' INTO icheck;
        IF icheck = 1 THEN
          SET ris_check = 1;
    SELECT STR_TO_DATE(CONCAT(indate,'0101'),'%Y%m%d') INTO routdate;
    ELSE
    SET ris_check = 0;
          SET routdate = NOW();
    END IF;
      WHEN 6 THEN
        SELECT indate REGEXP '20[0-9][0-9]([0][0-9]|[1][0-2])' INTO icheck;
        IF icheck = 1 THEN
          SET ris_check = 2;
          SELECT STR_TO_DATE(CONCAT(indate,'01'),'%Y%m%d') INTO routdate; 
        ELSEIF CAST(indate AS UNSIGNED INTEGER) > 730485 THEN
          SET ris_check = 3;
          SET routdate = FROM_DAYS(CAST(indate AS UNSIGNED INTEGER));          
        ELSE
    SET ris_check = 0;
          SET routdate = NOW();
        END IF;      
      WHEN 8 THEN
        SELECT indate REGEXP '20[0-9][0-9]([0][0-9]|[1][0-2])([0-2][0-9]|[3][0-1])' INTO icheck;
        IF icheck = 1 THEN
          SET ris_check = 4;
    SELECT STR_TO_DATE(indate,'%Y%m%d') INTO routdate;
    ELSE
    SET ris_check = 0;
          SET routdate = NOW();
    END IF;
      WHEN 10 THEN
        SELECT indate REGEXP '^[0-2]' INTO icheck;
        IF icheck = 1 THEN
          SET ris_check = 5;
    SELECT FROM_UNIXTIME(FLOOR(indate)) INTO routdate;
    ELSE
    SET ris_check = 0;
          SET routdate = NOW();
    END IF;
      WHEN 14 THEN
        SELECT indate REGEXP '20[0-9][0-9]([0][0-9]|[1][0-2])([0-2][0-9]|[3][0-1])[0-5][0-9][0-5][0-9][0-5][0-9]' INTO icheck;        
        IF icheck = 1 THEN
          SET ris_check = 6;
    SELECT STR_TO_DATE(indate,'%Y%m%d%H%i%s') INTO routdate;
    ELSE
    SET ris_check = 0;
          SET routdate = NOW();
    END IF;
      ELSE
        SET ris_check = 0;
        SET routdate = now();
      END CASE;
  SET is_check = ris_check;
  SET outdate = routdate;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `check_master` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `check_master`(lhost VARCHAR(100),lip VARCHAR(50))
BEGIN
DECLARE starttime datetime;
DECLARE mhost VARCHAR(100);
SET starttime=now();
SELECT @@hostname INTO mhost;
INSERT INTO vsystem.ismaster(master_host,checked_host,checked_ip,checked_time) VALUES(mhost,lhost,lip,starttime);
UPDATE vsystem.ismaster SET master_ip = CONVERT(lip USING utf8) WHERE master_host = CONVERT(lhost USING utf8) AND checked_time >= DATE_ADD(starttime,INTERVAL -3 DAY);
IF CONVERT(mhost USING utf8) = CONVERT(lhost USING utf8) THEN
SELECT 'master';
ELSE
SELECT 'slave';
END IF;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `create_add_partition_info` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `create_add_partition_info`(itable_schema VARCHAR(64),itable_name VARCHAR(64),ipartition_name VARCHAR(64),ipartition_method VARCHAR(18)
  ,ipartition_expression mediumtext,ipartition_description mediumtext,iengine VARCHAR(64),smonth INT)
BEGIN
  DECLARE ndone INT DEFAULT FALSE;
  DECLARE ocpartition_name VARCHAR(100);
  DECLARE ocpartition_description mediumtext;
  DECLARE oPREFIXPAR VARCHAR(64);
  DECLARE oPOSFIXPAR VARCHAR(64);
  DECLARE oPARVALUE VARCHAR(64);
  DECLARE tcpartition_name VARCHAR(100);
  DECLARE tcpartition_description mediumtext;
  DECLARE tPREFIXPAR VARCHAR(64);
  DECLARE tPOSFIXPAR VARCHAR(64);
  DECLARE tPARVALUE VARCHAR(64);
  DECLARE nrow int;
  DECLARE ocheck int;
  DECLARE odate datetime;
  DECLARE tcheck int;
  DECLARE tdate datetime;
  DECLARE step int;
  DECLARE sdate datetime;
  DECLARE syear int;
  DECLARE astep int;
  DECLARE ncur CURSOR FOR SELECT PARTITION_NAME,PARTITION_DESCRIPTION
                                  ,vsystem.replace_azn(PARTITION_NAME,2) AS PREFIXPAR
                                  ,vsystem.replace_azn(PARTITION_NAME,1) AS POSFIXPAR
                                  ,vsystem.replace_azn(PARTITION_DESCRIPTION,1) AS PARVALUE
                                              FROM INFORMATION_SCHEMA.PARTITIONS 
                                              WHERE UPPER(PARTITION_DESCRIPTION) !=  'MAXVALUE'
                                                    AND TABLE_SCHEMA = CONVERT(itable_schema USING utf8)
                                                    AND TABLE_NAME = CONVERT(itable_name USING utf8)
                                              ORDER BY PARTITION_ORDINAL_POSITION DESC LIMIT 2;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET ndone=TRUE;
  SELECT COUNT(*) INTO nrow FROM INFORMATION_SCHEMA.PARTITIONS 
                                              WHERE UPPER(PARTITION_DESCRIPTION) !=  'MAXVALUE'
                                                    AND TABLE_SCHEMA = CONVERT(itable_schema USING utf8)
                                                    AND TABLE_NAME = CONVERT(itable_name USING utf8);
    OPEN ncur;
    IF nrow = 1 THEN
      FETCH ncur INTO ocpartition_name,ocpartition_description,oPREFIXPAR,oPOSFIXPAR,oPARVALUE;
      CALL vsystem.check_date_add_partition(oPARVALUE,ocheck,odate);
      IF ocheck = 1 THEN
        SET step = 365;
      ELSE
        SET step = ABS(DATEDIFF(now(),odate));
        IF step = 0 THEN
           SET step = 1;
        END IF;
      END IF;
    ELSEIF nrow >= 2 THEN
      FETCH ncur INTO ocpartition_name,ocpartition_description,oPREFIXPAR,oPOSFIXPAR,oPARVALUE;
      CALL vsystem.check_date_add_partition(oPARVALUE,ocheck,odate);
      FETCH ncur INTO tcpartition_name,tcpartition_description,tPREFIXPAR,tPOSFIXPAR,tPARVALUE;
      CALL vsystem.check_date_add_partition(tPARVALUE,tcheck,tdate);
      SET step = ABS(DATEDIFF(odate,tdate));
    END IF;
    CLOSE ncur;
    IF nrow > 0 THEN
      IF step >= 360 AND ocheck = 1 THEN
          SET astep = CEIL(step/366);
          IF ipartition_description = 'MAXVALUE' THEN
              IF YEAR(odate) <= YEAR(NOW()) THEN
                  SET syear = CAST(DATE_FORMAT(now(),'%Y') AS UNSIGNED INTEGER);
                  WHILE CAST(DATE_FORMAT(DATE_ADD(STR_TO_DATE(CONCAT(DATE_FORMAT(DATE_ADD(now(),INTERVAL astep YEAR),'%Y'),'1231'),'%Y%m%d'),INTERVAL smonth MONTH),'%Y') AS UNSIGNED INTEGER) > syear DO
                    INSERT INTO vsystem.tmp_add_tables_partitions(TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE) VALUES(itable_schema,itable_name,CONCAT(oPREFIXPAR,syear),ipartition_method,ipartition_expression,syear + astep,iengine);
                    set syear = syear + astep;
                  END WHILE;
                  INSERT INTO vsystem.tmp_add_tables_partitions(TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE) VALUES(itable_schema,itable_name,CONCAT(oPREFIXPAR,'MAX'),ipartition_method,ipartition_expression,'MAXVALUE',iengine);
              ELSE
                  SET syear = CAST(DATE_FORMAT(odate,'%Y') AS UNSIGNED INTEGER);
                  WHILE CAST(DATE_FORMAT(DATE_ADD(STR_TO_DATE(CONCAT(DATE_FORMAT(DATE_ADD(now(),INTERVAL astep YEAR),'%Y'),'1231'),'%Y%m%d'),INTERVAL smonth MONTH),'%Y') AS UNSIGNED INTEGER) > syear DO
                    INSERT INTO vsystem.tmp_add_tables_partitions(TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE) VALUES(itable_schema,itable_name,CONCAT(oPREFIXPAR,syear),ipartition_method,ipartition_expression,syear + astep,iengine);
                    set syear = syear + astep;
                  END WHILE;
                  IF CAST(DATE_FORMAT(DATE_ADD(STR_TO_DATE(CONCAT(DATE_FORMAT(DATE_ADD(now(),INTERVAL astep YEAR),'%Y'),'1231'),'%Y%m%d'),INTERVAL smonth MONTH),'%Y') AS UNSIGNED INTEGER) > CAST(DATE_FORMAT(odate,'%Y') AS UNSIGNED INTEGER) THEN
                    INSERT INTO vsystem.tmp_add_tables_partitions(TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE) VALUES(itable_schema,itable_name,CONCAT(oPREFIXPAR,'MAX'),ipartition_method,ipartition_expression,'MAXVALUE',iengine);
                  END IF;
              END IF;
          ELSE
              IF YEAR(odate) > YEAR(NOW()) THEN
                  SET syear = CAST(DATE_FORMAT(odate,'%Y') AS UNSIGNED INTEGER);
                  WHILE CAST(DATE_FORMAT(DATE_ADD(STR_TO_DATE(CONCAT(DATE_FORMAT(DATE_ADD(now(),INTERVAL astep YEAR),'%Y'),'1231'),'%Y%m%d'),INTERVAL smonth MONTH),'%Y') AS UNSIGNED INTEGER) > syear DO
                    INSERT INTO vsystem.tmp_add_tables_partitions(TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE) VALUES(itable_schema,itable_name,CONCAT(oPREFIXPAR,syear),ipartition_method,ipartition_expression,syear + astep,iengine);
                    set syear = syear + astep;
                  END WHILE;
                  INSERT INTO vsystem.tmp_add_tables_partitions(TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE) VALUES(itable_schema,itable_name,CONCAT(oPREFIXPAR,'MAX'),ipartition_method,ipartition_expression,'MAXVALUE',iengine);
              END IF;
          END IF;      
      ELSEIF step >= 28 THEN
        SET astep = CEIL(step / 31);
        IF ipartition_description = 'MAXVALUE' THEN
          IF DATEDIFF(NOW(), odate) >= 0 THEN
            SET sdate = STR_TO_DATE(CONCAT(DATE_FORMAT(NOW(),'%Y%m'), '01'), '%Y%m%d');
            WHILE DATEDIFF(DATE_ADD(LAST_DAY(DATE_ADD(STR_TO_DATE(CONCAT(DATE_FORMAT(NOW(), '%Y%m'), '01'), '%Y%m%d'), INTERVAL smonth MONTH)),INTERVAL 1 DAY), sdate) > 0 DO
              IF ocheck = 5 THEN
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 MONTH),'%Y%m')), ipartition_method, ipartition_expression, UNIX_TIMESTAMP(DATE_ADD(sdate, INTERVAL astep MONTH)), iengine);
              ELSEIF ocheck = 3 THEN
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 MONTH), '%Y%m')), ipartition_method, ipartition_expression, TO_DAYS(DATE_ADD(sdate, INTERVAL astep MONTH)), iengine);
              ELSE
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 MONTH), '%Y%m')), ipartition_method, ipartition_expression, DATE_ADD(sdate, INTERVAL astep MONTH), iengine);
              END IF;
              SET sdate = DATE_ADD(sdate, INTERVAL astep MONTH);
            END WHILE;
            INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
              VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, 'MAX'), ipartition_method, ipartition_expression, 'MAXVALUE', iengine);
          ELSE
            SET sdate = odate;
            WHILE DATEDIFF(DATE_ADD(LAST_DAY(DATE_ADD(STR_TO_DATE(CONCAT(DATE_FORMAT(NOW(), '%Y%m'), '01'), '%Y%m%d'), INTERVAL smonth MONTH)),INTERVAL 1 DAY), sdate) > 0 DO
              IF ocheck = 5 THEN
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 MONTH), '%Y%m')), ipartition_method, ipartition_expression, UNIX_TIMESTAMP(DATE_ADD(sdate, INTERVAL astep MONTH)), iengine);
              ELSEIF ocheck = 3 THEN
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 MONTH), '%Y%m')), ipartition_method, ipartition_expression, TO_DAYS(DATE_ADD(sdate, INTERVAL astep MONTH)), iengine);
              ELSE
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 MONTH), '%Y%m')), ipartition_method, ipartition_expression, DATE_ADD(sdate, INTERVAL astep MONTH), iengine);
              END IF;
              SET sdate = DATE_ADD(sdate, INTERVAL astep MONTH);
            END WHILE;
            IF DATEDIFF(DATE_ADD(LAST_DAY(DATE_ADD(STR_TO_DATE(CONCAT(DATE_FORMAT(NOW(), '%Y%m'), '01'), '%Y%m%d'), INTERVAL smonth MONTH)),INTERVAL 1 DAY), sdate) > 0 THEN
              INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, 'MAX'), ipartition_method, ipartition_expression, 'MAXVALUE', iengine);
            END IF;
          END IF;
        ELSE
          IF DATEDIFF(NOW(), odate) < 0 THEN
            SET sdate = odate;
            WHILE DATEDIFF(DATE_ADD(LAST_DAY(DATE_ADD(STR_TO_DATE(CONCAT(DATE_FORMAT(NOW(), '%Y%m'), '01'), '%Y%m%d'), INTERVAL smonth MONTH)),INTERVAL 1 DAY), sdate) > 0 DO
              IF ocheck = 5 THEN
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 MONTH), '%Y%m')), ipartition_method, ipartition_expression, UNIX_TIMESTAMP(DATE_ADD(sdate, INTERVAL astep MONTH)), iengine);
              ELSEIF ocheck = 3 THEN
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 MONTH), '%Y%m')), ipartition_method, ipartition_expression, TO_DAYS(DATE_ADD(sdate, INTERVAL astep MONTH)), iengine);
              ELSE
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 MONTH), '%Y%m')), ipartition_method, ipartition_expression, DATE_ADD(sdate, INTERVAL astep MONTH), iengine);
              END IF;
              SET sdate = DATE_ADD(sdate, INTERVAL astep MONTH);
            END WHILE;
            INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
              VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, 'MAX'), ipartition_method, ipartition_expression, 'MAXVALUE', iengine);
          END IF;
        END IF;
      ELSEIF step >= 1 THEN
        SET astep = step;
        IF ipartition_description = 'MAXVALUE' THEN
          IF DATEDIFF(NOW(), odate) >= 0 THEN
            SET sdate = DATE_FORMAT(NOW(), '%Y%m%d');
            WHILE DATEDIFF(DATE_ADD(LAST_DAY(DATE_ADD(DATE_FORMAT(NOW(), '%Y%m%d'), INTERVAL smonth MONTH)),INTERVAL 1 DAY), sdate) > 0 DO
              IF ocheck = 5 THEN
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 DAY), '%Y%m%d')), ipartition_method, ipartition_expression, UNIX_TIMESTAMP(DATE_ADD(sdate, INTERVAL astep DAY)), iengine);
              ELSEIF ocheck = 3 THEN
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 DAY), '%Y%m%d')), ipartition_method, ipartition_expression, TO_DAYS(DATE_ADD(sdate, INTERVAL astep DAY)), iengine);
              ELSE
                INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                  VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 DAY), '%Y%m%d')), ipartition_method, ipartition_expression, DATE_ADD(sdate, INTERVAL astep DAY), iengine);
              END IF;
              SET sdate = DATE_ADD(sdate, INTERVAL astep DAY);
            END WHILE;
            INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
              VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR,'MAX'), ipartition_method, ipartition_expression, 'MAXVALUE', iengine);
          ELSE
            SET sdate = odate;
            WHILE DATEDIFF(DATE_ADD(LAST_DAY(DATE_ADD(DATE_FORMAT(NOW(), '%Y%m%d'), INTERVAL smonth MONTH)),INTERVAL 1 DAY), sdate) > 0 DO
                IF ocheck = 5 THEN
                  INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                    VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 DAY), '%Y%m%d')), ipartition_method, ipartition_expression, UNIX_TIMESTAMP(DATE_ADD(sdate, INTERVAL astep DAY)), iengine);
                ELSEIF ocheck = 3 THEN
                  INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                    VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 DAY), '%Y%m%d')), ipartition_method, ipartition_expression, TO_DAYS(DATE_ADD(sdate, INTERVAL astep DAY)), iengine);
                ELSE
                  INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                    VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 DAY), '%Y%m%d')), ipartition_method, ipartition_expression, DATE_ADD(sdate, INTERVAL astep DAY), iengine);
                END IF;
              SET sdate = DATE_ADD(sdate, INTERVAL astep DAY);
            END WHILE;
            IF DATEDIFF(DATE_ADD(LAST_DAY(DATE_ADD(DATE_FORMAT(NOW(), '%Y%m%d'), INTERVAL smonth MONTH)),INTERVAL 1 DAY), sdate) > 0 THEN
              INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, 'MAX'), ipartition_method, ipartition_expression, 'MAXVALUE', iengine);
            END IF;
          END IF;
        ELSE
          IF DATEDIFF(NOW(), odate) < 0 THEN
            SET sdate = odate;
            WHILE DATEDIFF(DATE_ADD(LAST_DAY(DATE_ADD(DATE_FORMAT(NOW(), '%Y%m%d'), INTERVAL smonth MONTH)),INTERVAL 1 DAY), sdate) > 0 DO
                  IF ocheck = 5 THEN
                    INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                      VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 DAY), '%Y%m%d')), ipartition_method, ipartition_expression, UNIX_TIMESTAMP(DATE_ADD(sdate, INTERVAL astep DAY)), iengine);
                  ELSEIF ocheck = 3 THEN
                    INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                      VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 DAY), '%Y%m%d')), ipartition_method, ipartition_expression, TO_DAYS(DATE_ADD(sdate, INTERVAL astep DAY)), iengine);
                  ELSE
                    INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                      VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, DATE_FORMAT(DATE_ADD(sdate, INTERVAL astep-1 DAY), '%Y%m%d')), ipartition_method, ipartition_expression, DATE_ADD(sdate, INTERVAL astep DAY), iengine);
                  END IF;
              SET sdate = DATE_ADD(sdate, INTERVAL astep DAY);
            END WHILE;
              INSERT INTO vsystem.tmp_add_tables_partitions (TABLE_SCHEMA, TABLE_NAME, PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, ENGINE)
                VALUES (itable_schema, itable_name, CONCAT(oPREFIXPAR, 'MAX'), ipartition_method, ipartition_expression, 'MAXVALUE', iengine);
          END IF;
        END IF;      
      END IF;
    END IF;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `fist_partitons_analyze` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `fist_partitons_analyze`(IN ssid int(11))
BEGIN
DECLARE starttime datetime;
DECLARE endtime datetime;
DECLARE iTABLE_SCHEMA VARCHAR(64);
DECLARE iTABLE_NAME VARCHAR(64);
DECLARE iPARTITION_NAME VARCHAR(64);
DECLARE iENGINE VARCHAR(64);
DECLARE istring mediumtext;
DECLARE done INT DEFAULT FALSE;
DECLARE cur CURSOR FOR SELECT DISTINCT p.TABLE_SCHEMA, p.TABLE_NAME, p.PARTITION_NAME,t.ENGINE FROM INFORMATION_SCHEMA.PARTITIONS p JOIN INFORMATION_SCHEMA.tables t 
ON p.TABLE_SCHEMA = t.TABLE_SCHEMA AND p.TABLE_NAME = t.TABLE_NAME WHERE p.TABLE_SCHEMA NOT IN ('information_schema','mysql','performance_schema','sys') AND UPPER(t.ENGINE) IN ('MYISAM','ARIA','INNODB') AND p.PARTITION_NAME IS NOT NULL;
DECLARE CONTINUE HANDLER FOR NOT FOUND SET done=TRUE;
OPEN cur;
read_loop: LOOP
FETCH cur INTO iTABLE_SCHEMA,iTABLE_NAME,iPARTITION_NAME,iENGINE;
IF done THEN
LEAVE read_loop;
END IF;
SET starttime = NOW();
INSERT INTO vsystem.daily_analyze_history(table_schema,table_name,partition_name,engine,start_time,end_time,duration,status,sid) VALUES(iTABLE_SCHEMA,iTABLE_NAME,iPARTITION_NAME,iENGINE,starttime,starttime,TIMEDIFF(starttime,starttime),'NOK',ssid);
SET istring = CONCAT('ALTER TABLE `',iTABLE_SCHEMA,'`.`',iTABLE_NAME,'` ANALYZE PARTITION `',iPARTITION_NAME,'`;');
SET @sql = istring;
PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
SET endtime = NOW();
    UPDATE vsystem.daily_analyze_history
SET end_time=endtime,status='OK',duration=TIMEDIFF(endtime,starttime)
WHERE start_time = starttime AND table_schema = CONVERT(iTABLE_SCHEMA USING utf8) AND table_name = CONVERT(iTABLE_NAME USING utf8) AND partition_name = CONVERT(iPARTITION_NAME USING utf8) AND engine = CONVERT(iENGINE USING utf8);
END LOOP;
CLOSE cur;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `init_add_partition` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `init_add_partition`()
BEGIN
  TRUNCATE TABLE vsystem.tmp_list_tables_partitions;
  TRUNCATE TABLE vsystem.tmp_add_tables_partitions;
  INSERT INTO vsystem.tmp_list_tables_partitions (TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE)
    SELECT p.TABLE_SCHEMA, p.TABLE_NAME, p.PARTITION_NAME, p.PARTITION_METHOD , p.PARTITION_EXPRESSION, p.PARTITION_DESCRIPTION,t.engine
                                              FROM INFORMATION_SCHEMA.PARTITIONS p LEFT JOIN INFORMATION_SCHEMA.TABLES t
                                              ON p.TABLE_SCHEMA = t.TABLE_SCHEMA AND p.TABLE_NAME = t.TABLE_NAME
                                              WHERE (p.TABLE_SCHEMA, p.TABLE_NAME, p.PARTITION_ORDINAL_POSITION) IN  
                                                      (SELECT TABLE_SCHEMA, TABLE_NAME, MAX(PARTITION_ORDINAL_POSITION) FROM INFORMATION_SCHEMA.PARTITIONS
                                                        WHERE PARTITION_NAME IS NOT NULL  AND PARTITION_METHOD LIKE '%RANGE%' and UPPER(PARTITION_EXPRESSION) not like '%OF%' GROUP BY TABLE_SCHEMA, TABLE_NAME); 
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `partitons_analyze` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `partitons_analyze`(IN ssid int(11))
BEGIN
DECLARE starttime datetime;
DECLARE endtime datetime;
DECLARE iTABLE_SCHEMA VARCHAR(64);
DECLARE iTABLE_NAME VARCHAR(64);
DECLARE iPARTITION_NAME VARCHAR(64);
DECLARE iENGINE VARCHAR(64);
DECLARE istring mediumtext;
DECLARE done INT DEFAULT FALSE;
DECLARE cur CURSOR FOR SELECT DISTINCT p.TABLE_SCHEMA, p.TABLE_NAME, p.PARTITION_NAME,t.ENGINE FROM INFORMATION_SCHEMA.PARTITIONS p JOIN INFORMATION_SCHEMA.tables t 
ON p.TABLE_SCHEMA = t.TABLE_SCHEMA AND p.TABLE_NAME = t.TABLE_NAME WHERE p.TABLE_SCHEMA NOT IN ('information_schema','mysql','performance_schema','sys') AND UPPER(t.ENGINE) IN ('MYISAM','ARIA','INNODB') AND ((p.PARTITION_NAME LIKE CONCAT('%',DATE_FORMAT(NOW(),'%Y')) 
OR p.PARTITION_NAME LIKE CONCAT('%',DATE_FORMAT(NOW(),'%Y%m'))
OR p.PARTITION_NAME LIKE CONCAT('%',DATE_FORMAT(NOW(),'%Y%m%d'))
OR p.PARTITION_NAME LIKE CONCAT('%',DATE_FORMAT(DATE_ADD(NOW(),INTERVAL -1 DAY),'%Y')) 
OR p.PARTITION_NAME LIKE CONCAT('%',DATE_FORMAT(DATE_ADD(NOW(),INTERVAL -1 DAY),'%Y%m'))
OR p.PARTITION_NAME LIKE CONCAT('%',DATE_FORMAT(DATE_ADD(NOW(),INTERVAL -1 DAY),'%Y%m%d'))
OR p.PARTITION_NAME LIKE CONCAT('%',DATE_FORMAT(NOW(),'%m%Y'))
OR p.PARTITION_NAME LIKE CONCAT('%',DATE_FORMAT(NOW(),'%d%m%Y'))
OR p.PARTITION_NAME LIKE CONCAT('%',DATE_FORMAT(DATE_ADD(NOW(),INTERVAL -1 DAY),'%m%Y'))
OR p.PARTITION_NAME LIKE CONCAT('%',DATE_FORMAT(DATE_ADD(NOW(),INTERVAL -1 DAY),'%d%m%Y'))
OR p.PARTITION_NAME LIKE '%MAX%')
OR p.PARTITION_EXPRESSION LIKE '%OF%'
OR p.PARTITION_METHOD not like '%RANGE%');
DECLARE CONTINUE HANDLER FOR NOT FOUND SET done=TRUE;
OPEN cur;
read_loop: LOOP
FETCH cur INTO iTABLE_SCHEMA,iTABLE_NAME,iPARTITION_NAME,iENGINE;
IF done THEN
LEAVE read_loop;
END IF;
SET starttime = NOW();
INSERT INTO vsystem.daily_analyze_history(table_schema,table_name,partition_name,engine,start_time,end_time,duration,status,sid) VALUES(iTABLE_SCHEMA,iTABLE_NAME,iPARTITION_NAME,iENGINE,starttime,starttime,TIMEDIFF(starttime,starttime),'NOK',ssid);
SET istring = CONCAT('ALTER TABLE `',iTABLE_SCHEMA,'`.`',iTABLE_NAME,'` ANALYZE PARTITION `',iPARTITION_NAME,'`;');
SET @sql = istring;
PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
SET endtime = NOW();
    UPDATE vsystem.daily_analyze_history
SET end_time=endtime,status='OK',duration=TIMEDIFF(endtime,starttime)
WHERE start_time = starttime AND table_schema = CONVERT(iTABLE_SCHEMA USING utf8) AND table_name = CONVERT(iTABLE_NAME USING utf8) AND partition_name = CONVERT(iPARTITION_NAME USING utf8) AND engine = CONVERT(iENGINE USING utf8);
END LOOP;
CLOSE cur;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `prepare_add_partition` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `prepare_add_partition`(smonth INT)
BEGIN
  DECLARE done INT DEFAULT FALSE;
  DECLARE ctable_schema VARCHAR(64);
  DECLARE ctable_name VARCHAR(64);
  DECLARE cpartition_name VARCHAR(64);
  DECLARE cpartition_method varchar(18);
  DECLARE cpartition_expression MEDIUMTEXT;
  DECLARE cpartition_description MEDIUMTEXT;
  DECLARE cengine VARCHAR(64);
  DECLARE cur CURSOR FOR SELECT TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE FROM vsystem.tmp_list_tables_partitions;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done=TRUE;
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO ctable_schema,ctable_name,cpartition_name,cpartition_method,cpartition_expression,cpartition_description,cengine;
    IF done THEN
      LEAVE read_loop;
    END IF;
    CALL vsystem.create_add_partition_info(ctable_schema,ctable_name,cpartition_name,cpartition_method,cpartition_expression,cpartition_description,cengine,smonth);
  END LOOP;
  CLOSE cur;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `print_add_partition` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `print_add_partition`()
BEGIN
  DECLARE done INT DEFAULT FALSE;
  DECLARE ctable_schema VARCHAR(64);
  DECLARE ctable_name VARCHAR(64);
  DECLARE cpartition_name VARCHAR(64);
  DECLARE cpartition_method varchar(18);
  DECLARE cpartition_expression MEDIUMTEXT;
  DECLARE cpartition_description MEDIUMTEXT;
  DECLARE cengine VARCHAR(64);
  DECLARE stringout mediumtext;
  DECLARE ostringout mediumtext;
  DECLARE cur CURSOR FOR SELECT TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE FROM vsystem.tmp_list_tables_partitions;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done=TRUE;
  SET stringout = '';
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO ctable_schema,ctable_name,cpartition_name,cpartition_method,cpartition_expression,cpartition_description,cengine;
    IF done THEN
      LEAVE read_loop;
    END IF;
    CALL vsystem.print_one_table(ctable_schema,ctable_name,cpartition_name,cpartition_method,cpartition_expression,cpartition_description,cengine,ostringout);
    IF ostringout IS NOT NULL then
      SET stringout = CONCAT(stringout,ostringout);
    END IF;
  END LOOP;
  CLOSE cur;
  SELECT stringout;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `print_one_table` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `print_one_table`(itable_schema VARCHAR(64),itable_name VARCHAR(64),ipartition_name VARCHAR(64),ipartition_method VARCHAR(18)
  ,ipartition_expression mediumtext,ipartition_description mediumtext,iengine VARCHAR(64),OUT stringout MEDIUMTEXT)
BEGIN
  DECLARE done INT DEFAULT FALSE;
  DECLARE ctable_schema VARCHAR(64);
  DECLARE ctable_name VARCHAR(64);
  DECLARE cpartition_name VARCHAR(64);
  DECLARE cpartition_method varchar(18);
  DECLARE cpartition_expression MEDIUMTEXT;
  DECLARE cpartition_description MEDIUMTEXT;
  DECLARE cengine VARCHAR(64);
  DECLARE ncur int;
  DECLARE istrignout mediumtext;
  DECLARE cur CURSOR FOR SELECT TABLE_SCHEMA,TABLE_NAME,PARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,ENGINE FROM vsystem.tmp_add_tables_partitions
                                WHERE TABLE_SCHEMA = CONVERT(itable_schema USING utf8) AND TABLE_NAME = CONVERT(itable_name USING utf8) ORDER BY ID;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done=TRUE;
  SELECT COUNT(*) INTO  ncur FROM vsystem.tmp_add_tables_partitions
                                WHERE TABLE_SCHEMA = CONVERT(itable_schema USING utf8) AND TABLE_NAME = CONVERT(itable_name USING utf8);
  OPEN cur;
  IF ipartition_description = 'MAXVALUE' AND ncur > 0 THEN
    SET istrignout = CONCAT('ALTER TABLE `',itable_schema,'`.`',itable_name,'` REORGANIZE PARTITION  `',ipartition_name,'` INTO (\n');
    read_loop: LOOP
      FETCH cur INTO ctable_schema,ctable_name,cpartition_name,cpartition_method,cpartition_expression,cpartition_description,cengine;
      IF done THEN
        LEAVE read_loop;
      END IF;
      IF cpartition_description != 'MAXVALUE' THEN
        IF LENGTH(cpartition_description) = 4 OR LENGTH(cpartition_description) = 10 OR (LENGTH(cpartition_description) = 6 AND CAST(cpartition_description AS UNSIGNED INTEGER) > 730485) then
          SET istrignout = CONCAT(istrignout,'PARTITION `',cpartition_name,'` VALUES LESS THAN (',cpartition_description,') ENGINE = ',cengine,',\n');  
        ELSE
          SET istrignout = CONCAT(istrignout,'PARTITION `',cpartition_name,'` VALUES LESS THAN (\'',cpartition_description,'\') ENGINE = ',cengine,',\n');  
        END IF;
      END IF;
    END LOOP;
    SET istrignout = CONCAT(istrignout,'PARTITION DATAMAX VALUES LESS THAN (MAXVALUE) ENGINE = ',cengine,');\n');
  ELSEIF ncur > 0 THEN
    SET istrignout = CONCAT('ALTER TABLE `',itable_schema,'`.`',itable_name,'` REORGANIZE PARTITION  `',ipartition_name,'` INTO (\n');
      IF LENGTH(cpartition_description) = 4 OR LENGTH(cpartition_description) = 10 OR (LENGTH(cpartition_description) = 6 AND CAST(cpartition_description AS UNSIGNED INTEGER) > 730485) then
        SET istrignout = CONCAT(istrignout,'PARTITION `',ipartition_name,'` VALUES LESS THAN (',ipartition_description,') ENGINE = ',iengine,',\n'); 
      ELSE
        SET istrignout = CONCAT(istrignout,'PARTITION `',ipartition_name,'` VALUES LESS THAN (',ipartition_description,') ENGINE = ',iengine,',\n');
      END IF;
    read_loop: LOOP
      FETCH cur INTO ctable_schema,ctable_name,cpartition_name,cpartition_method,cpartition_expression,cpartition_description,cengine;
      IF done THEN
        LEAVE read_loop;
      END IF;
      IF cpartition_description != 'MAXVALUE' THEN
        IF LENGTH(cpartition_description) = 4 OR LENGTH(cpartition_description) = 10 OR (LENGTH(cpartition_description) = 6 AND CAST(cpartition_description AS UNSIGNED INTEGER) > 730485) then
          SET istrignout = CONCAT(istrignout,'PARTITION `',cpartition_name,'` VALUES LESS THAN (',cpartition_description,') ENGINE = ',cengine,',\n');  
        ELSE
          SET istrignout = CONCAT(istrignout,'PARTITION `',cpartition_name,'` VALUES LESS THAN (\'',cpartition_description,'\') ENGINE = ',cengine,',\n');  
        END IF;
      END IF;
    END LOOP;
    SET istrignout = CONCAT(istrignout,'PARTITION DATAMAX VALUES LESS THAN (MAXVALUE) ENGINE = ',cengine,');\n');
  END IF;
  CLOSE cur;
  SET stringout = istrignout;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 DROP PROCEDURE IF EXISTS `tables_analyze` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `tables_analyze`(IN atype INT,IN ssid int(11))
BEGIN
DECLARE starttime datetime;
DECLARE endtime datetime;
DECLARE iTABLE_SCHEMA VARCHAR(64);
DECLARE iTABLE_NAME VARCHAR(64);
DECLARE iPARTITION_NAME VARCHAR(64);
DECLARE iENGINE VARCHAR(64);
DECLARE istring mediumtext;
DECLARE done INT DEFAULT FALSE;
DECLARE cur CURSOR FOR SELECT DISTINCT p.TABLE_SCHEMA, p.TABLE_NAME, p.PARTITION_NAME,t.ENGINE FROM INFORMATION_SCHEMA.PARTITIONS p JOIN INFORMATION_SCHEMA.tables t ON p.TABLE_SCHEMA = t.TABLE_SCHEMA AND p.TABLE_NAME = t.TABLE_NAME WHERE p.TABLE_SCHEMA NOT IN ('information_schema','mysql','performance_schema','sys') AND UPPER(t.ENGINE) IN ('MYISAM','ARIA','INNODB') AND p.PARTITION_NAME IS NULL;
DECLARE CONTINUE HANDLER FOR NOT FOUND SET done=TRUE;
OPEN cur;
read_loop: LOOP
FETCH cur INTO iTABLE_SCHEMA,iTABLE_NAME,iPARTITION_NAME,iENGINE;
IF done THEN
LEAVE read_loop;
END IF;
SET starttime = NOW();
INSERT INTO vsystem.daily_analyze_history(table_schema,table_name,partition_name,engine,start_time,end_time,duration,status,sid) VALUES(iTABLE_SCHEMA,iTABLE_NAME,iPARTITION_NAME,iENGINE,starttime,starttime,TIMEDIFF(starttime,starttime),'NOK',ssid);
IF atype = 1 THEN
SET istring = CONCAT('ANALYZE TABLE `',iTABLE_SCHEMA,'`.`',iTABLE_NAME,'` PERSISTENT FOR ALL;');
ELSE
SET istring = CONCAT('ANALYZE TABLE `',iTABLE_SCHEMA,'`.`',iTABLE_NAME,'`;');
END IF;
SET @sql = istring;
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
SET endtime = NOW();
    UPDATE vsystem.daily_analyze_history
SET end_time=endtime,status='OK',duration=TIMEDIFF(endtime,starttime)
WHERE start_time = starttime AND table_schema = CONVERT(iTABLE_SCHEMA USING utf8) AND table_name = CONVERT(iTABLE_NAME USING utf8) AND engine = CONVERT(iENGINE USING utf8);
END LOOP;
CLOSE cur;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2022-08-05 11:53:29
