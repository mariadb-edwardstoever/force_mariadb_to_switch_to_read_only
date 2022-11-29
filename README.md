# Force Mariadb to Switch to read_only
Database tool to allow you to switch MariaDB to read_only even when there are locks on objects that prevent it.
The schema switch_to_read_only is created by Edward Stoever for MariaDB Support.
MariaDB Corporation is not responsible for your use of this code.
```
Version 1.0 - July 21, 2022
Version 1.1 - July 22, 2022 - roles look like users. Exclude roles from this process.
```
---
**Scenario:** You want to use Maxscale to switchover primary and replica for maintenance,
however maxscale fails with an error:
```
[mariadbmon] Failed to enable read_only on server2:
Query SET STATEMENT max_statement_time=10 FOR SET GLOBAL read_only=1;
failed on server2: Query execution was interrupted (max_statement_time exceeded) (1969).
```

This occurs either because the database is very active with many simultaneous transactions
  or because one or more sessions have write locks on tables.

Database Objects in the schema switch_to_read_only:
```V_ALL_ACCOUNTS              View
V_ALL_CONNECTIONS           View
killed_connection_log       Base Table
locked_accounts             Base Table
never_lock_or_kill          Base Table
previously_locked_accounts  Base Table
read_me                     Base Table
P_KILL_CONNECTIONS          Procedure
P_LOCK_ACCOUNTS             Procedure
P_UNLOCK_ACCOUNTS           Procedure
```

**Preparation:**
   This process *requires account locking* which was introduced in MariaDB 10.4.2. If you are running 10.3 or lower you cannot use this process.
   Import the schema with the provided sql script. Run the script on the primary/master so that objects and DML are replicated.
   Populate the table never_lock_or_kill with all of the accounts that should exempt from this process.
   *Maxscale and replica user accounts should be inserted into never_lock_or_kill.* Use the account definitions as seen on mysql.user.
   Accounts with username "root" will be exempt from this process and do not need to be listed on never_lock_or_kill.
   `Select * from V_ALL_ACCOUNTS;` to review the exempt accounts.
   The user account that runs the procedure will be exempt at runtime if the user has execute privilege on the procedures.
   If an account has select, execute on switch_to_read_only.* then the user can run everything. The user that runs this process
   does not need to have SUPER privilege. The creator of the procedures must be `root@localhost` and must have SUPER privilege.
   Once the schema is created, it can be run by `root@localhost` or a new user account can be created just to run the process:
```
GRANT SELECT, EXECUTE ON `switch_to_read_only`.* TO `read_only_switcher`@`%` identified by 'thepassword';
```
Any account that is locked prior to calling P_LOCK_ACCOUNTS will not be exempt, however it will be ignored 
   by this process and will remain locked after running P_UNLOCK_ACCOUNTS. 
   
Procedures in this solution will ensure that binary logging is turned off at the session level.
   This means that any DML done by this process is not replicated. Because of this it is *important* to run the procedures connected directly to the Primary/Master only. Do not connect through maxscale to run the procedures.

**Solution steps:**
  1) Connect directly to the primary/master with mariadb client.
  2) Review the current account status at any time: "select * from switch_to_read_only.V_ALL_ACCOUNTS;"
  3) Lock accounts to prevent new logins: call switch_to_read_only.P_LOCK_ACCOUNTS();
     Locking accounts will prevent new logins on the primary/master so that you can complete the switchover.
  4) Review the current connection status at any time: select * from switch_to_read_only.V_ALL_CONNECTIONS;
  5) Kill existing connections for accounts that have been locked: call switch_to_read_only.P_KILL_CONNECTIONS();
  6) Run commands to complete the maxscale switchover. Upon completion, the database server that was the primary/master is now a replica/slave.
  7) Connecting directly to the same server where P_LOCK_ACCOUNTS was run: call switch_to_read_only.P_UNLOCK_ACCOUNTS();

Command Summary, all database commands must be run directly on same server:

```  select * from switch_to_read_only.V_ALL_ACCOUNTS;
  call switch_to_read_only.P_LOCK_ACCOUNTS();
  select * from switch_to_read_only.V_ALL_CONNECTIONS;
  call switch_to_read_only.P_KILL_CONNECTIONS();
--   # maxscale commands, modify monitor name and host names
--   maxctrl call command mariadbmon switchover MariaDB-Monitor e2.edw.ee e1.edw.ee
--   maxctrl list servers
  call switch_to_read_only.P_UNLOCK_ACCOUNTS();
  select * from switch_to_read_only.V_ALL_ACCOUNTS;
```

**Hint:** This process works best when run in exactly the order shown here. 
The process may get stuck for a while if you attempt to run a switchover through maxscale before locking accounts and killing connections. 
Even if that happens, if you complete the lock and kill process, maxscale should switchover on a subsequent attempt without a problem.


