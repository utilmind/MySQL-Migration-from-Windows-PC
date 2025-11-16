#!/bin/bash
set -euo pipefail

# CONFIGURATION
# ----------------
myisamTablesFilename='_optimize_tables_.txt'
allTablesFilename='_export_tables_.txt'

# Specify as bash array, even if only 1 prefix is used. Strings are not accepted. Only array is ok.
dbTablePrefix=('silk_' 'silkx_' '3dproofer_' 'bot_' 'email_')


# ================================  !! INSTALLATION !!  ================================
#   - Set up on crontab: crontab -e
#
#     Daily crontab, to make daily backups at 5 AM
#       min     hour    day     month   weekday
#       0       5       *       *       *
#
#   - Also check out the server timezone to set up correct hours for
#     the crontab: $> cat /etc/timezone
#       BTW...
#           - Check current server time: $> date
#           - List of available timezones: $> timedatectl list-timezones
#           - Change the timezone: $> sudo timedatectl set-timezone America/New_York
#               (or $> sudo timedatectl set-timezone America/Los_Angeles)
#               Or, better, just keep default UTC timezone to avoid confusions
#               and asynchronization of server instance time with database server time.
# ======================================================================================


# FUNCTIONS
# ------------
print_help() {
  scriptName=$(basename "$0")
  cat << EOF
Usage: $scriptName dump-name.sql [database-name]

dump-name.sql (Required)
    The exported filename can automatically contain current date. If filename contains '@',
    it will be replaced with current date YYYYMMDD.
    Example: $scriptName silkcards exported_data_@.sql
    (So this tool can be executed by the crontab to produce daily files with unique names.)

database-name (Optional)
    Used to locate credentials file with name ".database-name.credentials.sh"
    placed in the same directory as this script.
    (If not provided, then ".credentials.sh" will be used.)

    DB credentials file example (.credentials.sh)
        dbHost='localhost'
        dbPort=3306
        dbName='your-database-name'
        dbUsername='your-database-user'
        dbPassword='your-password'
        # dbPassword can be omitted; in this case the script will ask for it interactively.
        # Optional: you can override default table prefixes for this DB:
        # dbTablePrefix=('table_prefix_' 'table_prefix2_')

(c) utilmind@gmail.com, 2012-2025
    15.10.2024: Each dump have date, don't overwrite past days backups. Old backups can be deleted by garbage collector.
    26.08.2025: Multiple table prefixes.
    15.11.2025: Request password if not specified in configuration;
                Process dump to remove MySQL compatibility comments
                + provide missing details (server defaults) to the 'CREATE TABLE' statements
                  (to solve issues with collations on import).
                (These features require Python3+ installed.)

EOF
}

# parse_parameters:
if [ $# -eq 0 ]; then
    print_help
    exit 1
fi

# Parse optional flags (like -h / --help)
while [[ "$1" == -* ]] ; do
    case "$1" in
        -?|-h|-help|--help)
            print_help
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "ERROR: Invalid parameter: '$1'"
            exit 1
            ;;
    esac
done

# Now we expect one mandatory and one optional positional arguments:
#   1) dump-name.sql (output filename template, may contain '@' for date)
#   2) database-name (used to build credentials file name)
if [ $# -lt 2 ]; then
    scriptName=$(basename "$0")
    echo "ERROR: Missing required parameters."
    echo "Usage: $scriptName database-name dump-name.sql"
    exit 1
fi

dumpTemplate="$1"
dbConfigName="$2"


# GO!
thisScript=$(readlink -f "$0") # alternative is $(realpath $0), if "realpath" installed
scriptDir=$(dirname "$thisScript")
myisamTablesFilename="$scriptDir/$myisamTablesFilename"
allTablesFilename="$scriptDir/$allTablesFilename"

# Resolve credentials file path for this database key
credentialsFile="$scriptDir/.${dbConfigName}.credentials.sh"

# Check credentials file presence
if [ ! -r "$credentialsFile" ]; then
    echo "ERROR: Credentials file '$credentialsFile' not found or not readable."
    echo "Please create it with DB connection settings:"
    echo "  dbHost, dbPort, dbName, dbUsername, [dbPassword], [dbTablePrefix]" 
    exit 1
fi

# Load DB credentials (and optional dbTablePrefix override)
# Expected variables:
#   dbHost, dbPort, dbName, dbUsername, optional dbPassword, optional dbTablePrefix
. "$credentialsFile"

# If dbName is not defined in credentials, fall back to dbConfigName
dbName="${dbName:-$dbConfigName}"

# Ask for password if it is not defined or empty
if [ -z "${dbPassword:-}" ]; then
    read -s -p "Enter password for MySQL user '$dbUsername' (database '$dbName'): " dbPassword
    echo
fi

current_date=$(date +"%Y%m%d")
targetFilename=$(echo "$dumpTemplate" | sed "s/@/${current_date}/g")

# Build SQL WHERE for multiple prefixes
# Example result: (table_name LIKE 'silk\_%' OR table_name LIKE 'beta\_%')
like_clause=""
for p in "${dbTablePrefix[@]}"; do
    esc=${p//\'/\'\'}     # escape single quotes
    esc=${esc//_/\\_}     # make '_' literal in LIKE
    if [ -z "$like_clause" ]; then
        like_clause="(table_name LIKE '${esc}%')"
    else
        like_clause="$like_clause OR (table_name LIKE '${esc}%')"
    fi
done
like_clause="($like_clause)"

# Get tables. Only BASE TABLEs with non-InnoDB engine can be optimized.
mysql --host="$dbHost" --port="$dbPort" --user="$dbUsername" --password="$dbPassword" -N "$dbName" \
    -e "SELECT table_name
        FROM INFORMATION_SCHEMA.TABLES
        WHERE table_schema='$dbName'
            AND table_type='BASE TABLE'
            AND ENGINE <> 'InnoDB'
            AND ${like_clause}
            AND table_name NOT LIKE '%_backup_%'
        ORDER BY table_name" > "$myisamTablesFilename"

# Get all kinds of tables: BASE TABLEs and VIEWS for export.
mysql --host="$dbHost" --port="$dbPort" --user="$dbUsername" --password="$dbPassword" -N "$dbName" \
    -e "SELECT table_name
        FROM INFORMATION_SCHEMA.TABLES
        WHERE table_schema='$dbName'
            AND ${like_clause}
            AND table_name NOT LIKE '%_backup_%'
        ORDER BY table_name" > "$allTablesFilename"

# optimize mySQL tables, to export data faster
# AK 2025-10-04: we don't need to optimize InnoDB tables. And we mostly have InnoDB.
mysqlcheck --optimize --verbose --host="$dbHost" --port="$dbPort" --user="$dbUsername" --password="$dbPassword" --databases "$dbName" \
    --tables $(cat "$myisamTablesFilename" | xargs)

# Export (ATTN! --skip-tz-utc used to not change time. Remove this option if needed.)
# Recommended options which could not be present in legacy mySQL versions:
#    --set-gtid-purged=OFF
#    --column-statistics=0
mysqldump "$dbName" --host="$dbHost" --port="$dbPort" --user="$dbUsername" --password="$dbPassword" \
    --set-gtid-purged=OFF \
    --column-statistics=0 \
    --skip-tz-utc --no-tablespaces \
    --triggers --routines --events \
    $(cat "$allTablesFilename" | xargs) \
    > "$targetFilename"

# BTW, alternative syntax to export everything by databases:
# mysqldump -h [host] -u [user] -p --databases [database names] --set-gtid-purged=OFF --column-statistics=0 --no-tablespaces --triggers --routines --events > FILENAME.sql


# -- MAINTENANCE after dumping --

# first of all -- backup previous file, if it exists. Okay if it will overwrite previous file
[ -f "$targetFilename.rar" ] && mv "$targetFilename.rar" "$targetFilename.previous.rar"


# compress with gzip (compression level from 1 to 9, from fast to best)
# Use 9 (best) for automatic, scheduled backups and 5 (normal) for manual backups, when you need db now.
#gzip -9 -f $1


# compress with rar (compression level from 1 to 5, from fast to best)
# -ep = don't preserve file path
# -df = delete file after archiving
rar a -m5 -ep -df "$targetFilename.rar" "$targetFilename"
sudo chown 660 "$targetFilename.rar"
