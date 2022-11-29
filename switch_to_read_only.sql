/*
The schema switch_to_read_only is created by Edward Stoever for MariaDB Support.
MariaDB Corporation is not responsible for your use of this code.
Version 1.0 - July 21, 2022
Version 1.1 - July 22, 2022 - roles look like users. Exclude roles from this process.
=====================================================================================
Scenario: You want to use Maxscale to switchover primary and replica for maintenance,
however maxscale fails with an error:
      [mariadbmon] Failed to enable read_only on server2:
      Query SET STATEMENT max_statement_time=10 FOR SET GLOBAL read_only=1;
      failed on server2: Query execution was interrupted (max_statement_time exceeded) (1969).

This occurs either because the database is very active with many simultaneous transactions
  or because one or more sessions have write locks on tables.

Database Objects in the schema switch_to_read_only:
V_ALL_ACCOUNTS              View
V_ALL_CONNECTIONS           View
killed_connection_log       Base Table
locked_accounts             Base Table
never_lock_or_kill          Base Table
previously_locked_accounts  Base Table
read_me                     Base Table
P_KILL_CONNECTIONS          Procedure
P_LOCK_ACCOUNTS             Procedure
P_UNLOCK_ACCOUNTS           Procedure

Preparation:
   This process requires Account Locking which was introduced in MariaDB 10.4.2. If you are running 10.3 or lower you cannot use this process.
   Import the schema with the provided sql script. Run the script on the primary/master so that objects and DML are replicated.
   Populate the table never_lock_or_kill with all of the accounts that should exempt from this process.
   Maxscale and replica user accounts should be inserted into never_lock_or_kill. Use the account definitions as seen on mysql.user.
   Accounts with username "root" will be exempt from this process and do not need to be listed on never_lock_or_kill.
   Select * from V_ALL_ACCOUNTS to review the exempt accounts.
   The user account that runs the procedure will be exempt at runtime if the user has execute privilege on the procedures.
   If an account has select, execute on switch_to_read_only.* then the user can run everything. The user that runs this process
   does not need to have SUPER privilege. The creator of the procedures must be `root`@`localhost` and must have SUPER privilege.
   Once the schema is created, it can be run by root@localhost or a new user account can be created just to run the process:
      GRANT SELECT, EXECUTE ON `switch_to_read_only`.* TO `read_only_switcher`@`%` identified by 'thepassword';

Any account that is locked prior to calling P_LOCK_ACCOUNTS will not be exempt, however it will be ignored 
   by this process and will remain locked after running P_UNLOCK_ACCOUNTS. 
   
Procedures in this solution will ensure that binary logging is turned off at the session level.
   This means that any DML done by this process is not replicated. Because of this it is IMPORTANT to:
   Run the procedures connected directly to the Primary/Master only. Do not connect through maxscale to run the procedures.

Solution steps:
  1) Connect directly to the primary/master with mariadb client.
  2) Review the current account status at any time: "select * from switch_to_read_only.V_ALL_ACCOUNTS;"
  3) Lock accounts to prevent new logins: call switch_to_read_only.P_LOCK_ACCOUNTS();
     Locking accounts will prevent new logins on the primary/master so that you can complete the switchover.
  4) Review the current connection status at any time: select * from switch_to_read_only.V_ALL_CONNECTIONS;
  5) Kill existing connections for accounts that have been locked: call switch_to_read_only.P_KILL_CONNECTIONS();
  6) Run commands to complete the maxscale switchover. Upon completion, the database server that was the primary/master is now a replica/slave.
  7) Connecting directly to the same server where P_LOCK_ACCOUNTS was run: call switch_to_read_only.P_UNLOCK_ACCOUNTS();

Command Summary, all database commands must be run directly on same server:
  select * from switch_to_read_only.V_ALL_ACCOUNTS;
  call switch_to_read_only.P_LOCK_ACCOUNTS();
  select * from switch_to_read_only.V_ALL_CONNECTIONS;
  call switch_to_read_only.P_KILL_CONNECTIONS();
--   # maxscale commands, modify monitor name and host names
--   maxctrl call command mariadbmon switchover MariaDB-Monitor e2.edw.ee e1.edw.ee
--   maxctrl list servers
  call switch_to_read_only.P_UNLOCK_ACCOUNTS();
  select * from switch_to_read_only.V_ALL_ACCOUNTS;
  
Hint: This process works best when run in exactly the order shown here. 
      The process may get stuck for a while if you attempt to run a switchover through maxscale before locking accounts and killing connections. 
      Even if that happens, if you complete the lock and kill process, maxscale should switchover on a subsequent attempt without a problem.
*/

drop schema if exists switch_to_read_only;
create schema switch_to_read_only;
use switch_to_read_only;

-- MariaDB dump 10.19  Distrib 10.6.8-4-MariaDB, for debian-linux-gnu (x86_64)
--
-- Host: localhost    Database: switch_to_read_only
-- ------------------------------------------------------
-- Server version	10.6.8-4-MariaDB-enterprise-log

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
-- Temporary table structure for view `V_ALL_ACCOUNTS`
--

DROP TABLE IF EXISTS `V_ALL_ACCOUNTS`;
/*!50001 DROP VIEW IF EXISTS `V_ALL_ACCOUNTS`*/;
SET @saved_cs_client     = @@character_set_client;
SET character_set_client = utf8;
/*!50001 CREATE TABLE `V_ALL_ACCOUNTS` (
  `username` tinyint NOT NULL,
  `hostname` tinyint NOT NULL,
  `fullname` tinyint NOT NULL,
  `locked` tinyint NOT NULL,
  `previously_locked` tinyint NOT NULL,
  `exempt` tinyint NOT NULL
) ENGINE=MyISAM */;
SET character_set_client = @saved_cs_client;

--
-- Temporary table structure for view `V_ALL_CONNECTIONS`
--

DROP TABLE IF EXISTS `V_ALL_CONNECTIONS`;
/*!50001 DROP VIEW IF EXISTS `V_ALL_CONNECTIONS`*/;
SET @saved_cs_client     = @@character_set_client;
SET character_set_client = utf8;
/*!50001 CREATE TABLE `V_ALL_CONNECTIONS` (
  `id` tinyint NOT NULL,
  `username` tinyint NOT NULL,
  `hostname` tinyint NOT NULL,
  `fullname` tinyint NOT NULL,
  `connection_will_be_killed` tinyint NOT NULL
) ENGINE=MyISAM */;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `killed_connection_log`
--

DROP TABLE IF EXISTS `killed_connection_log`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `killed_connection_log` (
  `username` varchar(100) DEFAULT NULL,
  `hostname` varchar(100) DEFAULT NULL,
  `tstamp` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Accounts that have had their connections killed by the procedure P_KILL_CONNECTIONS.';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `killed_connection_log`
--

LOCK TABLES `killed_connection_log` WRITE;
/*!40000 ALTER TABLE `killed_connection_log` DISABLE KEYS */;
/*!40000 ALTER TABLE `killed_connection_log` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `locked_accounts`
--

DROP TABLE IF EXISTS `locked_accounts`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `locked_accounts` (
  `username` varchar(100) DEFAULT NULL,
  `hostname` varchar(100) DEFAULT NULL,
  `tstamp` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='This table should be empty unless the process of locking accounts and killing connections in is progress.';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `locked_accounts`
--

LOCK TABLES `locked_accounts` WRITE;
/*!40000 ALTER TABLE `locked_accounts` DISABLE KEYS */;
/*!40000 ALTER TABLE `locked_accounts` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `never_lock_or_kill`
--

DROP TABLE IF EXISTS `never_lock_or_kill`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `never_lock_or_kill` (
  `username` varchar(100) DEFAULT NULL,
  `hostname` varchar(100) DEFAULT NULL,
  `tstamp` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Accounts that should be exempt from locking and killing. Replication user and maxscale user accounts should be listed here permanently.';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `never_lock_or_kill`
--

LOCK TABLES `never_lock_or_kill` WRITE;
/*!40000 ALTER TABLE `never_lock_or_kill` DISABLE KEYS */;
/*!40000 ALTER TABLE `never_lock_or_kill` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `previously_locked_accounts`
--

DROP TABLE IF EXISTS `previously_locked_accounts`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `previously_locked_accounts` (
  `username` varchar(100) DEFAULT NULL,
  `hostname` varchar(100) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='This table should be empty unless the process of locking accounts and killing connections in is progress. If an account is locked before the process is started, it will be ignored and will not be unlocked by the process..';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `previously_locked_accounts`
--

LOCK TABLES `previously_locked_accounts` WRITE;
/*!40000 ALTER TABLE `previously_locked_accounts` DISABLE KEYS */;
/*!40000 ALTER TABLE `previously_locked_accounts` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `read_me`
--

DROP TABLE IF EXISTS `read_me`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `read_me` (
  `read_this` varchar(10000) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Notes';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `read_me`
--

LOCK TABLES `read_me` WRITE;
/*!40000 ALTER TABLE `read_me` DISABLE KEYS */;
INSERT INTO `read_me` VALUES ('The schema switch_to_read_only is created by Edward Stoever for MariaDB Support.\r\nMariaDB Corporation is not responsible for your use of this code.\r\n\r\nScenario: You want to use Maxscale to switchover primary and replica for maintenance,\r\nhowever maxscale fails with an error:\r\n      [mariadbmon] Failed to enable read_only on server2:\r\n      Query SET STATEMENT max_statement_time=10 FOR SET GLOBAL read_only=1;\r\n      failed on server2: Query execution was interrupted (max_statement_time exceeded) (1969).\r\n\r\nThis occurs either because the database is very active with many simultaneous transactions\r\n  or because one or more sessions have write locks on tables.\r\n\r\nDatabase Objects in the schema switch_to_read_only:\r\nV_ALL_ACCOUNTS              View\r\nV_ALL_CONNECTIONS           View\r\nkilled_connection_log       Base Table\r\nlocked_accounts             Base Table\r\nnever_lock_or_kill          Base Table\r\npreviously_locked_accounts  Base Table\r\nread_me                     Base Table\r\nP_KILL_CONNECTIONS          Procedure\r\nP_LOCK_ACCOUNTS             Procedure\r\nP_UNLOCK_ACCOUNTS           Procedure\r\n\r\nPreparation:\r\n   This process requires Account Locking which was introduced in MariaDB 10.4.2. If you are running 10.3 or lower you cannot use this process.\r\n   Import the schema with the provided sql script. Run the script on the primary/master so that objects and DML are replicated.\r\n   Populate the table never_lock_or_kill with all of the accounts that should exempt from this process.\r\n   Maxscale and replica user accounts should be inserted into never_lock_or_kill. Use the account definitions as seen on mysql.user.\r\n   Accounts with username \"root\" will be exempt from this process and do not need to be listed on never_lock_or_kill.\r\n   Select * from V_ALL_ACCOUNTS to review the exempt accounts.\r\n   The user account that runs the procedure will be exempt at runtime if the user has execute privilege on the procedures.\r\n   If an account has select, execute on switch_to_read_only.* then the user can run everything. The user that runs this process\r\n   does not need to have SUPER privilege. The creator of the procedures must be `root`@`localhost` and must have SUPER privilege.\r\n   Once the schema is created, it can be run by root@localhost or a new user account can be created just to run the process:\r\n      GRANT SELECT, EXECUTE ON `switch_to_read_only`.* TO `read_only_switcher`@`%` identified by \'thepassword\';\r\n\r\nAny account that is locked prior to calling P_LOCK_ACCOUNTS will not be exempt, however it will be ignored \r\n   by this process and will remain locked after running P_UNLOCK_ACCOUNTS. \r\n   \r\nProcedures in this solution will ensure that binary logging is turned off at the session level.\r\n   This means that any DML done by this process is not replicated. Because of this it is IMPORTANT to:\r\n   Run the procedures connected directly to the Primary/Master only. Do not connect through maxscale to run the procedures.\r\n\r\nSolution steps:\r\n  1) Connect directly to the primary/master with mariadb client.\r\n  2) Review the current account status at any time: \"select * from switch_to_read_only.V_ALL_ACCOUNTS;\"\r\n  3) Lock accounts to prevent new logins: call switch_to_read_only.P_LOCK_ACCOUNTS();\r\n     Locking accounts will prevent new logins on the primary/master so that you can complete the switchover.\r\n  4) Review the current connection status at any time: select * from switch_to_read_only.V_ALL_CONNECTIONS;\r\n  5) Kill existing connections for accounts that have been locked: call switch_to_read_only.P_KILL_CONNECTIONS();\r\n  6) Run commands to complete the maxscale switchover. Upon completion, the database server that was the primary/master is now a replica/slave.\r\n  7) Connecting directly to the same server where P_LOCK_ACCOUNTS was run: call switch_to_read_only.P_UNLOCK_ACCOUNTS();\r\n\r\nCommand Summary, all database commands must be run directly on same server:\r\n  select * from switch_to_read_only.V_ALL_ACCOUNTS;\r\n  call switch_to_read_only.P_LOCK_ACCOUNTS();\r\n  select * from switch_to_read_only.V_ALL_CONNECTIONS;\r\n  call switch_to_read_only.P_KILL_CONNECTIONS();\r\n--   # maxscale commands, modify monitor name and host names\r\n--   maxctrl call command mariadbmon switchover MariaDB-Monitor e2.edw.ee e1.edw.ee\r\n--   maxctrl list servers\r\n  call switch_to_read_only.P_UNLOCK_ACCOUNTS();\r\n  select * from switch_to_read_only.V_ALL_ACCOUNTS;\r\n  \r\nHint: This process works best when run in exactly the order shown here. \r\n      The process may get stuck for a while if you attempt to run a switchover through maxscale before locking accounts and killing connections. \r\n      Even if that happens, if you complete the lock and kill process, maxscale should switchover on a subsequent attempt without a problem.');
/*!40000 ALTER TABLE `read_me` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Dumping routines for database 'switch_to_read_only'
--
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
/*!50003 DROP PROCEDURE IF EXISTS `P_KILL_CONNECTIONS` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `P_KILL_CONNECTIONS`()
    COMMENT 'Code by Edward Stoever for MariaDB Support. MariaDB Corporation does not take responsibility for the use of this code.'
`KILL_CONNS`: BEGIN
  DECLARE done INT DEFAULT FALSE;
  DECLARE  v_user, v_host, v_account, v_sql, v_msg varchar(500);
  DECLARE  v_pid, v_ct integer;
  DECLARE c_kill_list CURSOR FOR
    select DISTINCT PROCESSLIST.ID, PROCESSLIST.`USER`,PROCESSLIST.`HOST` from information_schema.PROCESSLIST
       inner join locked_accounts ON ( PROCESSLIST.`USER`=locked_accounts.username);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

  select count(*) into v_ct from information_schema.user_privileges
       where replace(grantee,'''','')=current_user() and PRIVILEGE_TYPE='SUPER';
  if v_ct = 0 then
      set v_msg='This procedure should be created by a user with SUPER privilege and run with sql security definer.';
      SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO=30001, MESSAGE_TEXT=v_msg;
  LEAVE `KILL_CONNS`;
  end if;

   
  SELECT count(*) into v_ct from mysql.global_priv
    WHERE (CONCAT(`user`, '@', `host`)) NOT IN
      ((select CONCAT(`username`, '@', `hostname`) from previously_locked_accounts))
    AND (CONCAT(`user`, '@', `host`)) NOT IN
      ((select CONCAT(`username`, '@', `hostname`) from never_lock_or_kill))
    AND (CONCAT(`user`, '@', `host`)) NOT IN
      ((select CONCAT(`username`, '@', `hostname`) from locked_accounts))
    AND `user`<>'root'
    AND `user`<>SUBSTRING_INDEX(session_user(),'@',1)
    AND `user` not in (select `user` from mysql.`user` where is_role='y');

   if v_ct <> 0 then
      set v_msg='Lock accounts before killing connections.';
      SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO=30001, MESSAGE_TEXT=v_msg;
  LEAVE `KILL_CONNS`;
   end if;

   SET SESSION sql_log_bin = 0;
   SET SESSION max_statement_time=15;

  OPEN c_kill_list;
   read_loop: LOOP
     fetch c_kill_list into v_pid, v_user, v_host;
     IF done THEN LEAVE read_loop; end if;
  SET v_sql=concat('kill hard connection ',v_pid);
  PREPARE sExec FROM v_sql; EXECUTE sExec; DEALLOCATE PREPARE sExec;
  INSERT INTO killed_connection_log (username, hostname, tstamp) VALUES (v_user,v_host,now());
   end LOOP;
  CLOSE c_kill_list;
END `KILL_CONNS` ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
/*!50003 DROP PROCEDURE IF EXISTS `P_LOCK_ACCOUNTS` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `P_LOCK_ACCOUNTS`()
    COMMENT 'Code by Edward Stoever for MariaDB Support. MariaDB Corporation does not take responsibility for the use of this code.'
`LOCK_ACCTS`: BEGIN 
  DECLARE done INT DEFAULT FALSE;
  DECLARE  v_user, v_host, v_account, v_sql, v_msg varchar(500);
  DECLARE  v_ct integer;
  DECLARE c_accts CURSOR FOR 
  SELECT `user` as u, `host` as h, CONCAT('`',`user`, '`@`', `host`,'`') as a from mysql.global_priv
    WHERE (CONCAT(`user`, '@', `host`)) NOT IN 
      ((select CONCAT(`username`, '@', `hostname`) from previously_locked_accounts))
    AND (CONCAT(`user`, '@', `host`)) NOT IN
      ((select CONCAT(`username`, '@', `hostname`) from never_lock_or_kill))
    AND (CONCAT(`user`, '@', `host`)) NOT IN 
      ((select CONCAT(`username`, '@', `hostname`) from locked_accounts))
    AND `user`<>'root'
    AND `user`<>SUBSTRING_INDEX(session_user(),'@',1)
    AND `user` not in (select `user` from mysql.`user` where is_role='y'); 

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

   select count(*) into v_ct from information_schema.user_privileges 
       where replace(grantee,'''','')=current_user() and PRIVILEGE_TYPE='SUPER';
   if v_ct = 0 then
      set v_msg='This procedure should be created by a user with SUPER privilege and run with sql security definer.';
      SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO=30001, MESSAGE_TEXT=v_msg;
  LEAVE `LOCK_ACCTS`;
   end if;

   DELETE from locked_accounts where concat('`',username,'`@`',hostname,'`') not in 
   (select concat('`',`global_priv`.`USER`,'`@`',`global_priv`.`host`,'`') 
      from `mysql`.`global_priv` 
  where Json_extract(`mysql`.`global_priv`.`priv`,'$.account_locked') = 'true');

  SELECT count(*) into v_ct from mysql.global_priv
    WHERE (CONCAT(`user`, '@', `host`)) NOT IN 
      ((select CONCAT(`username`, '@', `hostname`) from previously_locked_accounts))
    AND (CONCAT(`user`, '@', `host`)) NOT IN
      ((select CONCAT(`username`, '@', `hostname`) from never_lock_or_kill))
    AND (CONCAT(`user`, '@', `host`)) NOT IN 
      ((select CONCAT(`username`, '@', `hostname`) from locked_accounts))
    AND `user`<>'root'
    AND `user`<>SUBSTRING_INDEX(session_user(),'@',1)
    AND `user` not in (select `user` from mysql.`user` where is_role='y');
   if v_ct = 0 then
      set v_msg='No more accounts to lock.';
      SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO=30001, MESSAGE_TEXT=v_msg;
      LEAVE `LOCK_ACCTS`;
   end if;
   
   SET SESSION sql_log_bin = 0;
   SET SESSION max_statement_time=15;
   
   SELECT count(*) into v_ct from locked_accounts;   
   IF v_ct = 0 then  
     truncate table previously_locked_accounts;
     insert into previously_locked_accounts
       select `user`,`host` from mysql.global_priv where JSON_EXTRACT(priv,'$.account_locked')='true';
   END IF;
   
   OPEN c_accts;
   read_loop: LOOP
   fetch c_accts into v_user, v_host, v_account;
   IF done THEN LEAVE read_loop; end if;
  insert into locked_accounts(username, hostname, tstamp) values(v_user,v_host,now());
  SET v_sql=concat('alter user ',v_account,' account lock');
  PREPARE sExec FROM v_sql; EXECUTE sExec; DEALLOCATE PREPARE sExec;
   end LOOP;   
  CLOSE c_accts;

end `LOCK_ACCTS` ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
/*!50003 DROP PROCEDURE IF EXISTS `P_UNLOCK_ACCOUNTS` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb3 */ ;
/*!50003 SET character_set_results = utf8mb3 */ ;
/*!50003 SET collation_connection  = utf8mb3_general_ci */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `P_UNLOCK_ACCOUNTS`()
    COMMENT 'Code by Edward Stoever for MariaDB Support. MariaDB Corporation does not take responsibility for the use of this code.'
`UNLOCK_ACCTS`: BEGIN 
  DECLARE done INT DEFAULT FALSE;
  DECLARE  v_user, v_host, v_account, v_sql, v_msg  varchar(500);
  DECLARE  v_ct integer;
  DECLARE c_accts CURSOR FOR 
  SELECT `username` as u, `hostname` as h, CONCAT('`',`username`, '`@`', `hostname`,'`') as a from locked_accounts;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
  
   select count(*) into v_ct from information_schema.user_privileges 
       where replace(grantee,'''','')=current_user() and PRIVILEGE_TYPE='SUPER';
   if v_ct = 0 then
      set v_msg='This procedure should be created by a user with SUPER privilege and run with sql security definer.';
      SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO=30001, MESSAGE_TEXT=v_msg;
  LEAVE `UNLOCK_ACCTS`;
   end if;
   
   SET SESSION sql_log_bin = 0;
   SET SESSION max_statement_time=15;

  OPEN c_accts;
   read_loop: LOOP
   fetch c_accts into v_user, v_host, v_account;
   IF done THEN LEAVE read_loop; end if;
  SET v_sql=concat('alter user ',v_account,' account unlock');
  PREPARE sExec FROM v_sql; EXECUTE sExec; DEALLOCATE PREPARE sExec;
  delete from locked_accounts where `username`=v_user and `hostname`=v_host;
   end LOOP;   
  CLOSE c_accts;

   select count(*) into v_ct from locked_accounts;
   if v_ct > 0 then
      set v_msg='Accounts have unlocked but there are still acounts on locked_accounts table. Something went wrong.';
      SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO=30001, MESSAGE_TEXT=v_msg;
      leave `UNLOCK_ACCTS`;
   end if;
   
   truncate table previously_locked_accounts;
END `UNLOCK_ACCTS` ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;

--
-- Final view structure for view `V_ALL_ACCOUNTS`
--

/*!50001 DROP TABLE IF EXISTS `V_ALL_ACCOUNTS`*/;
/*!50001 DROP VIEW IF EXISTS `V_ALL_ACCOUNTS`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */
/*!50001 VIEW `V_ALL_ACCOUNTS` AS select `user`.`User` AS `username`,`user`.`Host` AS `hostname`,concat('`',`user`.`User`,'`@`',`user`.`Host`,'`') AS `fullname`,if(json_extract(`mysql`.`global_priv`.`Priv`,'$.account_locked') = 'true','yes','no') AS `locked`,if(`switch_to_read_only`.`locked_accounts`.`tstamp` is null and json_extract(`mysql`.`global_priv`.`Priv`,'$.account_locked') = 'true','yes','no') AS `previously_locked`,if(`user`.`User` = 'root' or `switch_to_read_only`.`never_lock_or_kill`.`tstamp` is not null or `user`.`User` = substring_index(user(),'@',1),'yes','no') AS `exempt` from (((`mysql`.`user` left join `mysql`.`global_priv` on(`user`.`User` = `mysql`.`global_priv`.`User` and `user`.`Host` = `mysql`.`global_priv`.`Host`)) left join `switch_to_read_only`.`locked_accounts` on(`user`.`User` = `switch_to_read_only`.`locked_accounts`.`username` and `user`.`Host` = `switch_to_read_only`.`locked_accounts`.`hostname`)) left join `switch_to_read_only`.`never_lock_or_kill` on(`user`.`User` = `switch_to_read_only`.`never_lock_or_kill`.`username` and `user`.`Host` = `switch_to_read_only`.`never_lock_or_kill`.`hostname`)) where mysql.user.is_role<>'y' */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `V_ALL_CONNECTIONS`
--

/*!50001 DROP TABLE IF EXISTS `V_ALL_CONNECTIONS`*/;
/*!50001 DROP VIEW IF EXISTS `V_ALL_CONNECTIONS`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */
/*!50001 VIEW `V_ALL_CONNECTIONS` AS select `information_schema`.`processlist`.`ID` AS `id`,`information_schema`.`processlist`.`USER` AS `username`,`information_schema`.`processlist`.`HOST` AS `hostname`,concat('`',`information_schema`.`processlist`.`USER`,'`@`',`information_schema`.`processlist`.`HOST`,'`') AS `fullname`,if(`switch_to_read_only`.`locked_accounts`.`tstamp` is null,'no','yes') AS `connection_will_be_killed` from (`information_schema`.`processlist` left join `switch_to_read_only`.`locked_accounts` on(`information_schema`.`processlist`.`USER` = `switch_to_read_only`.`locked_accounts`.`username`)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2022-07-20 23:34:39
