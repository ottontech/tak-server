#!/bin/bash

# Script to set up the TAKServer database.
# This is meant to be run as root.
# Since it asks the user for confirmation before obliterating his database,
# it cannot be run by the RPM installer and must be a manual post-install step.
#
# Usage: takserver-db-setup.sh [db-name]
#

#if [ "$EUID" -ne 0 ]
#  then echo "$0 must be run as root."
#  exit 1
#fi
# DB_NAME=cot
# DB_EXISTS=`su postgres -c "psql -l 2>/dev/null" | grep ^[[:blank:]]*$DB_NAME`
# if [ "x$DB_EXISTS" != "x" ]; then
#   sed -i 's/127.0.0.1\/32/0.0.0.0\/0/g' /opt/tak/db-utils/pg_hba.conf
#   cp /opt/tak/db-utils/pg_hba.conf /var/lib/postgresql/data/pg_hba.conf
#   su - postgres -c "/usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/data -l logfile restart -o '-c max_connections=2100 -c shared_buffers=2560MB'"
#   exit 0
# fi

username='martiuser'
password=""
# try to get password from /opt/tak/CoreConfig.xml
if [ -f "/opt/tak/CoreConfig.xml" ]; then
  password=$(echo $(grep -m 1 "<connection" /opt/tak/CoreConfig.xml)  | sed 's/.*password="//; s/".*//')
fi
# try to get password from /opt/tak/CoreConfig.example.xml
if [ -z "$password" ]; then
  if [ -f "/opt/tak/CoreConfig.example.xml" ]; then
    password=$(echo $(grep -m 1 "<connection" /opt/tak/CoreConfig.example.xml)  | sed 's/.*password="//; s/".*//')
  fi
fi
# cant find password - request one from user
if [ -z "$password" ]; then
  : ${1?' Could not find a password in /opt/tak/CoreConfig.xml or /opt/tak/CoreConfig.example.xml. Please supply a plaintext database password as the first parameter'}
  password=$1
fi

md5pass=$(echo -n "md5" && echo -n "$password$username" | md5sum | tr -dc "a-zA-Z0-9\n")

# switch CWD to the location where this script resides
cd `dirname $0`

DB_NAME=$1
if [ $# -lt 1 ]; then
  DB_NAME=cot
fi

DB_INIT=""
# Ensure PostgreSQL is initialized.

if [ -x /usr/lib/postgresql/15/bin/pg_ctl ]; then
    DB_INIT="/usr/lib/postgresql/15/bin/pg_ctl initdb"
elif [ -x /usr/bin/postgresql-setup ]; then
    DB_INIT="/usr/bin/postgresql-setup initdb"
else
    echo "WARNING: Unable to automatically initialize PostgreSQL database."
fi

echo -n "Database initialization: " 
$DB_INIT 
if [ $? -eq 0 ]; then
    echo "PostgreSQL database initialized."
else
    echo "WARNING: Failed to initialize PostgreSQL database."
    echo "This could simply mean your database has already been initialized."
fi
      
# Figure out where the system keeps the PostgreSQL data

if [ -z ${PGDATA+x} ]; then
   if [ -d /var/lib/postgresql/data ]; then
        export PGDATA=/var/lib/postgresql/data
        POSTGRES_CMD="service postgresql restart"
   elif [ -x /usr/bin/systemctl ]; then
       export PGDATA=`/usr/bin/systemctl show postgresql.service -p Environment | sed 's/.*PGDATA\=\([a-zA-Z0-9]*\)/\1/'`
       POSTGRES_CMD="/bin/systemctl restart postgresql.service"
   else
       echo "PGDATA not set and unable to find PostgreSQL data directory automatically."
       echo "Please set PGDATA and re-run this script."
       exit 1
   fi
fi

if [ ! -d $PGDATA ]; then
  echo "ERROR: Cannot find PostgreSQL data directory. Please set PGDATA manually and re-run."
  exit 1
fi

su postgres -c "psql --command='drop database if exists $DB_NAME;'"
 

if [ -e pg_hba.conf ]; then
  IS_DOCKER='true'
fi

# Install our version of pg_hba.conf
echo "Installing TAKServer's version of PostgreSQL access-control policy."
# Back up pg_hba.conf
BACKUP_SUFFIX=`date --rfc-3339='seconds' | sed 's/ /-/'`
HBA_BACKUP=$PGDATA/pg_hba.conf.backup-$BACKUP_SUFFIX
if [ -e /opt/tak/db-utils/pg_hba.conf ] || [ -e pg_hba.conf ]; then
  if [ -e $PGDATA/pg_hba.conf ]; then
    mv $PGDATA/pg_hba.conf $HBA_BACKUP
    echo "Copied existing PostgreSQL access-control policy to $HBA_BACKUP."
  fi

   # for docker install
  if [ IS_DOCKER ]; then
    cp pg_hba.conf $PGDATA
  else
    # for RPM install
    echo "RPM db install"
      cp /opt/tak/db-utils/pg_hba.conf $PGDATA
  fi

  chown postgres:postgres $PGDATA/pg_hba.conf
  chmod 600 $PGDATA/pg_hba.conf
  echo "Installed TAKServer's PostgreSQL access-control policy to $PGDATA/pg_hba.conf."
  echo "Restarting PostgreSQL service."
  $POSTGRES_CMD
else
  echo "ERROR: Unable to find pg_hba.conf!"
  exit 1
fi

CONF_BACKUP=$PGDATA/postgresql.conf.backup-$BACKUP_SUFFIX
if [ -e /opt/tak/db-utils/postgresql.conf ] || [ -e postgresql.conf ];  then
  if [ -e $PGDATA/postgresql.conf ]; then
    mv $PGDATA/postgresql.conf $CONF_BACKUP
    echo "Copied existing PostgreSQL configuration to $CONF_BACKUP."
  fi

   # for docker install
  if [ IS_DOCKER ]; then
    cp postgresql.conf $PGDATA
  else
    # for RPM install
    echo "RPM db install"
      cp /opt/tak/db-utils/postgresql.conf $PGDATA
  fi

  chown postgres:postgres $PGDATA/postgresql.conf
  chmod 600 $PGDATA/postgresql.conf
  echo "Installed TAKServer's PostgreSQL configuration to $PGDATA/postgresql.conf."
  echo "Restarting PostgreSQL service."
  $POSTGRES_CMD
fi

DB_NAME=cot
if [ $# -eq 1 ] ; then
    DB_NAME=$1
fi

# Create the user "martiuser" if it does not exist.
echo "Creating user \"martiuser\" ..."
su - postgres -c "psql -U postgres -c \"CREATE ROLE martiuser LOGIN ENCRYPTED PASSWORD '$md5pass' SUPERUSER INHERIT CREATEDB NOCREATEROLE;\""

# create the database
echo "Creating database $DB_NAME"
su - postgres -c "createdb -U postgres --owner=martiuser $DB_NAME"
if [ $? -ne 0 ]; then
    exit 1
fi

echo "Database $DB_NAME created."

if [ ! -x /usr/bin/systemctl ]; then
  echo "Systemctl was not found. Skipping Systemd configuration."
  exit 1
fi

# Set PostgreSQL to run automatically at boot time
if [ -d /var/lib/postgresql/data ]; then
    START_INIT="chkconfig --level 345 postgresql on"
elif [ -x /usr/bin/systemctl ]; then
    /usr/bin/systemctl enable postgresql.service
else
  echo "ERROR: unable to detect postgres version to start on boot"
  exit 1
fi
    
$START_INIT
echo "set postgres to start on boot"

