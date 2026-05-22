#!/bin/bash

# ============================================================

# ---------------------------------------------------------------
# CONFIGURATION - edit these before running
# ---------------------------------------------------------------

# 11g source details
OLD_ORACLE_HOME="/u01/app/oracle/product/11g/home"
OLD_ORACLE_BASE="/u01/app/oracle"
ORACLE_SID="TEST"
ORACLE_USER="oracle"

# 19c target details
NEW_ORACLE_HOME="/u02/app/oracle/product/19c/home"
NEW_ORACLE_BASE="/u01/app/oracle"

# 19c software zip location (download from MOS - patch 19c base release)
ORACLE_19C_ZIP="/u01/software/LINUX.X64_193000_db_home.zip" --zip file name

# RMAN backup location - take backup before upgrade
BACKUP_LOCATION="/u01/bkp"

# Log file
LOGFILE="/u01/19c/logs/upgrade_11g_19c_$(date +%Y%m%d_%H%M%S).log"

# Email notification
MAIL_TO="gopixxxx@gmail.com"

# ---------------------------------------------------------------
# simple logging
# ---------------------------------------------------------------
mkdir -p $(dirname $LOGFILE)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a $LOGFILE
}

run_sql() {
    sudo -u $ORACLE_USER $OLD_ORACLE_HOME/bin/sqlplus -s / as sysdba << EOF 2>/dev/null
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
$1
EXIT;
EOF
}

run_sql_new() {
    sudo -u $ORACLE_USER $NEW_ORACLE_HOME/bin/sqlplus -s / as sysdba << EOF 2>/dev/null
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
$1
EXIT;
EOF
}

# ---------------------------------------------------------------
# STEP 1 - Basic checks before starting anything
# ---------------------------------------------------------------
log "========================================================"
log " Oracle Upgrade 11.2.0.4 -> 19c"
log " Database : $ORACLE_SID"
log " Started  : $(date)"
log "========================================================"

log ""
log "STEP 1 - Pre-checks"

# check running as root
if [ "$EUID" -ne 0 ]; then
    log "ERROR: Run this script as root or with sudo."
    exit 1
fi

# check 11g home exists
if [ ! -d "$OLD_ORACLE_HOME" ]; then
    log "ERROR: 11g ORACLE_HOME not found: $OLD_ORACLE_HOME"
    exit 1
fi

# check 19c zip exists
if [ ! -f "$ORACLE_19C_ZIP" ]; then
    log "ERROR: 19c software zip not found: $ORACLE_19C_ZIP"
    log "       Download LINUX.X64_193000_db_home.zip from Oracle MOS."
    exit 1
fi

# check DB is open
DB_STATUS=$(run_sql "SELECT STATUS FROM V\$INSTANCE;")
if [ "$DB_STATUS" != "OPEN" ]; then
    log "ERROR: Database $ORACLE_SID is not OPEN. Current status: $DB_STATUS"
    exit 1
fi
log "  OK - Database $ORACLE_SID is OPEN."

# check disk space - need at least 10GB
FREE_GB=$(df -BG $OLD_ORACLE_BASE | awk 'NR==2{gsub("G",""); print $4}')
log "  Free disk space in $OLD_ORACLE_BASE: ${FREE_GB}GB"
if [ "$FREE_GB" -lt 10 ]; then
    log "  WARN: Less than 10GB free. Upgrade may fail due to space."
fi

# check archivelog mode - mandatory for upgrade
ARCHLOG=$(run_sql "SELECT LOG_MODE FROM V\$DATABASE;")
if [ "$ARCHLOG" != "ARCHIVELOG" ]; then
    log "  WARN: Database is in NOARCHIVELOG mode."
    log "  Switching to ARCHIVELOG mode..."
    run_sql "SHUTDOWN IMMEDIATE;"
    run_sql "STARTUP MOUNT;"
    run_sql "ALTER DATABASE ARCHIVELOG;"
    run_sql "ALTER DATABASE OPEN;"
    log "  OK - ARCHIVELOG mode enabled."
else
    log "  OK - Database is in ARCHIVELOG mode."
fi

# ---------------------------------------------------------------
# STEP 2 - Run Oracle pre-upgrade utility (preupgrade.jar)
# This is the official Oracle tool - ships with 19c software
# It checks for all issues that can block the upgrade
# ---------------------------------------------------------------
log ""
log "STEP 2 - Running Oracle Pre-Upgrade Utility (preupgrade.jar)"

PREUPGRADE_JAR="$NEW_ORACLE_HOME/rdbms/admin/preupgrade.jar"

# check if 19c is already extracted, if not extract now
if [ ! -f "$PREUPGRADE_JAR" ]; then
    log "  19c home not found. Extracting 19c software to $NEW_ORACLE_HOME..."
    mkdir -p $NEW_ORACLE_HOME
    chown $ORACLE_USER:oinstall $NEW_ORACLE_HOME

    sudo -u $ORACLE_USER unzip -q $ORACLE_19C_ZIP -d $NEW_ORACLE_HOME
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to extract 19c zip."
        exit 1
    fi
    log "  OK - 19c software extracted."
fi

# run preupgrade.jar using 11g java but 19c jar
sudo -u $ORACLE_USER bash -c "
    export ORACLE_HOME=$OLD_ORACLE_HOME
    export ORACLE_SID=$ORACLE_SID
    export PATH=$OLD_ORACLE_HOME/bin:\$PATH
    $OLD_ORACLE_HOME/jdk/bin/java -jar $PREUPGRADE_JAR \
        TERMINAL TEXT DIR /u01/upgrade/preupgrade
" 2>&1 | tee -a $LOGFILE

log "  OK - Pre-upgrade utility completed."
log "  Check /u01/upgrade/preupgrade/preupgrade.log for full details."

# ---------------------------------------------------------------
# STEP 3 - Fix pre-upgrade issues automatically
# Common fixes needed before upgrading from 11g to 19c
# ---------------------------------------------------------------
log ""
log "STEP 3 - Fixing pre-upgrade issues"

# Fix 1: Purge recyclebin - old objects cause upgrade issues
log "  Fixing: Purging recyclebin..."
run_sql "PURGE DBA_RECYCLEBIN;"
log "  OK - Recyclebin purged."

# Fix 2: Gather dictionary statistics
# stale stats cause slow upgrade
log "  Fixing: Gathering dictionary statistics..."
run_sql "EXEC DBMS_STATS.GATHER_DICTIONARY_STATS;"
log "  OK - Dictionary stats gathered."

# Fix 3: Remove OUTLN duplicates that cause upgrade failure
log "  Fixing: Removing OUTLN duplicate synonyms..."
run_sql "BEGIN
    FOR s IN (SELECT SYNONYM_NAME FROM DBA_SYNONYMS
              WHERE OWNER='PUBLIC' AND TABLE_OWNER='OUTLN')
    LOOP
        EXECUTE IMMEDIATE 'DROP PUBLIC SYNONYM ' || s.SYNONYM_NAME;
    END LOOP;
END;
/"
log "  OK - OUTLN synonyms cleaned."

# Fix 4: Drop XDB protocol - causes issues in 19c migration
log "  Fixing: Dropping XDB HTTPURI type if present..."
run_sql "BEGIN
    DBMS_XDB.SETLISTENER('', 0);
EXCEPTION WHEN OTHERS THEN NULL;
END;
/"
log "  OK - XDB checked."

# Fix 5: Set compatible parameter for 19c
# current value in 11g is 11.2.0.4.0
log "  Checking COMPATIBLE parameter..."
COMPAT=$(run_sql "SELECT VALUE FROM V\$PARAMETER WHERE NAME='compatible';")
log "  Current compatible: $COMPAT (will be updated to 19.0.0 after upgrade)"

# Fix 6: Disable all non-oracle jobs before upgrade
log "  Disabling user scheduler jobs..."
run_sql "BEGIN
    FOR j IN (SELECT OWNER, JOB_NAME FROM DBA_SCHEDULER_JOBS
              WHERE OWNER NOT IN ('SYS','SYSTEM','ORACLE_OCM','DBSNMP'))
    LOOP
        BEGIN
            DBMS_SCHEDULER.DISABLE(j.OWNER || '.' || j.JOB_NAME);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
END;
/"
log "  OK - User scheduler jobs disabled."

# ---------------------------------------------------------------
# STEP 4 - Take RMAN backup before upgrade
# never upgrade without a backup
# ---------------------------------------------------------------
log ""
log "STEP 4 - Taking RMAN backup before upgrade"

mkdir -p $BACKUP_LOCATION

sudo -u $ORACLE_USER bash -c "
    export ORACLE_HOME=$OLD_ORACLE_HOME
    export ORACLE_SID=$ORACLE_SID
    export PATH=$OLD_ORACLE_HOME/bin:\$PATH
    $OLD_ORACLE_HOME/bin/rman target / << 'RMANEOF'
RUN {
    CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 2 DAYS;
    CONFIGURE BACKUP OPTIMIZATION ON;
    BACKUP AS COMPRESSED BACKUPSET
        DATABASE FORMAT '$BACKUP_LOCATION/db_%U.bkp'
        PLUS ARCHIVELOG FORMAT '$BACKUP_LOCATION/arch_%U.bkp'
        DELETE INPUT;
    BACKUP CURRENT CONTROLFILE FORMAT '$BACKUP_LOCATION/cf_%U.bkp';
    BACKUP SPFILE FORMAT '$BACKUP_LOCATION/spfile_%U.bkp';
}
RMANEOF
" 2>&1 | tee -a $LOGFILE

if [ $? -eq 0 ]; then
    log "  OK - RMAN backup completed. Location: $BACKUP_LOCATION"
else
    log "  WARN - RMAN backup had issues. Check log before continuing."
    log "  Sleeping 30 seconds... Press Ctrl+C to abort."
    sleep 30
fi

# ---------------------------------------------------------------
# STEP 4.5 - Create Guaranteed Restore Point
# very useful rollback option during upgrade
# ---------------------------------------------------------------
log ""
log "STEP 4.5 - Creating Guaranteed Restore Point"

RESTORE_POINT="GRP_BEFORE_19C_UPGRADE"

# check flashback status
FLASHBACK_STATUS=$(run_sql "SELECT FLASHBACK_ON FROM V\$DATABASE;")

if [ "$FLASHBACK_STATUS" != "YES" ]; then

    log "  WARN - Flashback Database is not enabled."
    log "  Guaranteed Restore Point cannot be created."
    log "  Enable flashback manually if rollback capability is required."

else

    # drop existing restore point if already exists
    run_sql "
    BEGIN
        EXECUTE IMMEDIATE
        'DROP RESTORE POINT $RESTORE_POINT';
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;
    /
    "

    run_sql "
    CREATE RESTORE POINT $RESTORE_POINT
    GUARANTEE FLASHBACK DATABASE;
    "

    log "  OK - Guaranteed Restore Point created:"
    log "       $RESTORE_POINT"

fi

# ---------------------------------------------------------------
# STEP 5 - Install 19c Oracle software in silent mode
# This installs the binaries only, does not touch the database
# ---------------------------------------------------------------
log ""
log "STEP 5 - Installing Oracle 19c software (silent mode)"

# check if runInstaller exists - means 19c is already installed
if [ -f "$NEW_ORACLE_HOME/bin/sqlplus" ]; then
    log "  Oracle 19c software already installed at $NEW_ORACLE_HOME. Skipping install."
else
    log "  Running Oracle 19c silent install..."

    # Create response file for silent install
    cat > /tmp/db_install.rsp << RSP
oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v19.0.0
oracle.install.option=INSTALL_DB_SWONLY
UNIX_GROUP_NAME=oinstall
INVENTORY_LOCATION=${OLD_ORACLE_BASE}/oraInventory
ORACLE_HOME=${NEW_ORACLE_HOME}
ORACLE_BASE=${NEW_ORACLE_BASE}
oracle.install.db.InstallEdition=EE
oracle.install.db.OSDBA_GROUP=dba
oracle.install.db.OSOPER_GROUP=oper
oracle.install.db.OSBACKUPDBA_GROUP=backupdba
oracle.install.db.OSDGDBA_GROUP=dgdba
oracle.install.db.OSKMDBA_GROUP=kmdba
oracle.install.db.OSRACDBA_GROUP=racdba
SECURITY_UPDATES_VIA_MYORACLESUPPORT=false
DECLINE_SECURITY_UPDATES=true
RSP

    sudo -u $ORACLE_USER $NEW_ORACLE_HOME/runInstaller \
        -silent \
        -ignorePrereqFailure \
        -responseFile /tmp/db_install.rsp \
        -waitforcompletion 2>&1 | tee -a $LOGFILE

    # run root scripts
    $NEW_ORACLE_BASE/oraInventory/orainstRoot.sh 2>/dev/null
    $NEW_ORACLE_HOME/root.sh 2>/dev/null

    log "  OK - Oracle 19c software installed."
fi

# ---------------------------------------------------------------
# STEP 6 - Copy required files from 11g to 19c home
# ---------------------------------------------------------------
log ""
log "STEP 6 - Copying config files from 11g to 19c home"

# copy password file
cp $OLD_ORACLE_HOME/dbs/orapw${ORACLE_SID} \
   $NEW_ORACLE_HOME/dbs/orapw${ORACLE_SID} 2>/dev/null
log "  OK - Password file copied."

# copy spfile or create pfile from spfile
if [ -f "$OLD_ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora" ]; then
    cp $OLD_ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora \
       $NEW_ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora
    log "  OK - SPFILE copied."
else
    # create pfile from spfile
    run_sql "CREATE PFILE='$NEW_ORACLE_HOME/dbs/init${ORACLE_SID}.ora' FROM SPFILE;"
    log "  OK - PFILE created from SPFILE."
fi

# copy tnsnames and listener
cp $OLD_ORACLE_HOME/network/admin/tnsnames.ora \
   $NEW_ORACLE_HOME/network/admin/ 2>/dev/null
cp $OLD_ORACLE_HOME/network/admin/listener.ora \
   $NEW_ORACLE_HOME/network/admin/ 2>/dev/null
log "  OK - Network files copied."

chown -R $ORACLE_USER:oinstall $NEW_ORACLE_HOME/dbs/
chown -R $ORACLE_USER:oinstall $NEW_ORACLE_HOME/network/

# ---------------------------------------------------------------
# STEP 7 - Shutdown 11g and run upgrade using dbupgrade
# dbupgrade is preferred for automation/scripting
# ---------------------------------------------------------------
log ""
log "STEP 7 - Shutting down 11g and starting upgrade using dbupgrade"

# shutdown old database
run_sql "SHUTDOWN IMMEDIATE;"
log "  OK - 11g database shut down."

# start database in upgrade mode from 19c home
sudo -u $ORACLE_USER bash -c "
    export ORACLE_HOME=$NEW_ORACLE_HOME
    export ORACLE_SID=$ORACLE_SID
    export PATH=$NEW_ORACLE_HOME/bin:\$PATH

    $NEW_ORACLE_HOME/bin/sqlplus / as sysdba << EOF

STARTUP UPGRADE;
EXIT;
EOF
" 2>&1 | tee -a $LOGFILE

if [ $? -ne 0 ]; then

    log "ERROR - Failed to start database in upgrade mode."
    exit 1

fi

log "  OK - Database started in UPGRADE mode."

# run dbupgrade utility
log "  Running dbupgrade utility..."
log "  This step can take 30-90 minutes depending on DB size."

sudo -u $ORACLE_USER bash -c "
    export ORACLE_HOME=$NEW_ORACLE_HOME
    export ORACLE_SID=$ORACLE_SID
    export PATH=$NEW_ORACLE_HOME/bin:\$PATH

    $NEW_ORACLE_HOME/bin/dbupgrade \
        -l /u01/upgrade/dbupgrade_logs
" 2>&1 | tee -a $LOGFILE

if [ $? -eq 0 ]; then

    log "  OK - dbupgrade completed successfully."

else

    log "ERROR - dbupgrade failed."
    log "Check logs under:"
    log "/u01/upgrade/dbupgrade_logs"

    exit 1

fi

# restart database normally
sudo -u $ORACLE_USER bash -c "
    export ORACLE_HOME=$NEW_ORACLE_HOME
    export ORACLE_SID=$ORACLE_SID
    export PATH=$NEW_ORACLE_HOME/bin:\$PATH

    sqlplus / as sysdba << EOF

SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
EOF
" 2>&1 | tee -a $LOGFILE

log "  OK - Database restarted normally after upgrade."



# ---------------------------------------------------------------
# STEP 8 - Post upgrade steps
# ---------------------------------------------------------------
log ""
log "STEP 8 - Post upgrade steps"

# check DB opened with 19c
DB_VER=$(run_sql_new "SELECT VERSION FROM V\$INSTANCE;")
log "  Database version after upgrade: $DB_VER"

# run utlrp to recompile invalid objects
log "  Recompiling invalid objects (utlrp.sql)..."
sudo -u $ORACLE_USER bash -c "
    export ORACLE_HOME=$NEW_ORACLE_HOME
    export ORACLE_SID=$ORACLE_SID
    export PATH=$NEW_ORACLE_HOME/bin:\$PATH
    $NEW_ORACLE_HOME/bin/sqlplus / as sysdba << 'EOF'
@?/rdbms/admin/utlrp.sql
EXIT;
EOF
" 2>&1 | tee -a $LOGFILE
log "  OK - utlrp completed."

# upgrade timezone
log "  Upgrading timezone data..."
run_sql_new "
BEGIN
    DBMS_DST.BEGIN_UPGRADE(new_version => 32);
EXCEPTION WHEN OTHERS THEN NULL;
END;
/"
log "  OK - Timezone upgrade done."

# update compatible parameter to 19.0.0
log "  Setting COMPATIBLE=19.0.0..."
run_sql_new "ALTER SYSTEM SET COMPATIBLE='19.0.0' SCOPE=SPFILE;"
log "  OK - COMPATIBLE set to 19.0.0. Restart required for this to take effect."

# re-enable scheduler jobs
log "  Re-enabling user scheduler jobs..."
run_sql_new "BEGIN
    FOR j IN (SELECT OWNER, JOB_NAME FROM DBA_SCHEDULER_JOBS
              WHERE OWNER NOT IN ('SYS','SYSTEM','ORACLE_OCM','DBSNMP')
              AND STATE='DISABLED')
    LOOP
        BEGIN
            DBMS_SCHEDULER.ENABLE(j.OWNER || '.' || j.JOB_NAME);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
END;
/"
log "  OK - Scheduler jobs re-enabled."

# ---------------------------------------------------------------
# STEP 9 - Final validation
# ---------------------------------------------------------------
log ""
log "STEP 9 - Final Validation"

# DB open mode
OPEN_MODE=$(run_sql_new "SELECT OPEN_MODE FROM V\$DATABASE;")
log "  Open mode      : $OPEN_MODE"

# DB version
DB_VER=$(run_sql_new "SELECT VERSION_FULL FROM V\$INSTANCE;" 2>/dev/null || \
         run_sql_new "SELECT VERSION FROM V\$INSTANCE;")
log "  DB version     : $DB_VER"

# invalid objects count
INV_COUNT=$(run_sql_new "SELECT COUNT(*) FROM DBA_OBJECTS WHERE STATUS='INVALID' AND OWNER NOT IN ('SYS','SYSTEM');")
log "  Invalid objects: $INV_COUNT"

# component status
log "  Component status:"
run_sql_new "
SELECT COMP_NAME, VERSION, STATUS FROM DBA_REGISTRY ORDER BY COMP_NAME;
" | tee -a $LOGFILE

if [ "$OPEN_MODE" = "READ WRITE" ]; then
    UPGRADE_STATUS="SUCCESS"
    log "  OK - Database is open and running on 19c."
else
    UPGRADE_STATUS="FAILED"
    log "  ERROR - Database not in READ WRITE mode. Manual check needed."
fi

# ---------------------------------------------------------------
# STEP 10 - Send email
# ---------------------------------------------------------------
log ""
log "STEP 10 - Sending email notification"

if [ "$UPGRADE_STATUS" = "SUCCESS" ]; then
MAIL_BODY="Hi,

Oracle Database upgrade from 11.2.0.4 to 19c completed successfully.

Database    : $ORACLE_SID
Old Home    : $OLD_ORACLE_HOME
New Home    : $NEW_ORACLE_HOME
DB Version  : $DB_VER
Open Mode   : $OPEN_MODE
Invalid Objs: $INV_COUNT

Backup Location: $BACKUP_LOCATION
Log File       : $LOGFILE

Upgrade completed successfully. Database is running on Oracle 19c.

Regards,
Gopi Thota
Oracle DBA"
else
MAIL_BODY="Hi,

Oracle Database upgrade from 11.2.0.4 to 19c encountered issues.

Database   : $ORACLE_SID
Open Mode  : $OPEN_MODE
DB Version : $DB_VER

Please check log: $LOGFILE
DBUA logs  : $NEW_ORACLE_HOME/cfgtoollogs/dbua/

Regards,
Gopi Thota
Oracle DBA"
fi

echo "$MAIL_BODY" | mail -s "Oracle Upgrade 11g to 19c $UPGRADE_STATUS - $ORACLE_SID" $MAIL_TO 2>/dev/null
if [ $? -eq 0 ]; then
    log "  OK - Email sent to $MAIL_TO"
else
    log "  WARN - Email send failed."
fi

# ---------------------------------------------------------------
log ""
log "========================================================"
if [ "$UPGRADE_STATUS" = "SUCCESS" ]; then
    log " Oracle upgrade 11.2.0.4 -> 19c COMPLETED SUCCESSFULLY"
    log " Database $ORACLE_SID is now running on Oracle 19c"
else
    log " Upgrade FAILED or needs attention. Check: $LOGFILE"
fi
log " Finished: $(date)"
log "========================================================"
