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
  scriptName=`basename "$0"`
  cat << EOF
Usage: $scriptName database-name dump-name.sql

The exported filename can automatically contain current date. If filename contains '@', it will be replaced with current date YYYYMMDD.
Example: $scriptName exported_data_@.sql
(So this tool can be executed by the crontab to produce daily files with unique names.)

Table prefixes are taken ONLY from array 'dbTablePrefix' in .db_credentials.sh, e.g.:
  dbTablePrefix=("silk_" "3dproofer_") or single prefix dbTablePrefix=("silk_")

(c) utilmind@gmail.com, 2012-2025
    15.10.2024: Each dump have date, don't overwrite past days backups. Old backups can be deleted by garbage collector.
    26.08.2025: Multiple table prefixes.
    15.11.2025: Request password if not specified in configuration or configuration not found;
                Process dump to remove MySQL compatibility comments
                + provide missing details (server defaults) to the `CREATE TABLE` statements (to solve issues with collations on import).
                (These features require Python3+ installed.)

EOF
}

. "$(dirname "$BASH_SOURCE")/.$DATABASE_NAME.credentials.sh"

# parse_parameters:
if [ $# -eq 0 ]; then
    print_help
    exit 1
fi

while [[ "$1" == -* ]] ; do
	case "$1" in
		-?|-h|-help|--help)
			print_help
			exit
			;;
		--)
			echo "-- found"
			shift
			break
			;;
		*)
			echo "Invalid parameter: '$1'"
			exit 1
			;;
	esac
done


# GO!
thisScript=$(readlink -f "$0") # alternative is $(realpath $0), if "realpath" installed
scriptDir=$(dirname $thisScript)
myisamTablesFilename=$scriptDir/$myisamTablesFilename
allTablesFilename=$scriptDir/$allTablesFilename
current_date=$(date +"%Y%m%d")
targetFilename=$(echo "$1" | sed "s/@/${current_date}/g")

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
mysql --host=$dbHost --port=$dbPort --user=$dbUsername --password=$dbPassword -N $dbName \
    -e "SELECT table_name
        FROM INFORMATION_SCHEMA.TABLES
        WHERE table_schema='$dbName'
            AND table_type='BASE TABLE'
            AND ENGINE <> 'InnoDB'
            AND ${like_clause}
            AND table_name NOT LIKE '%_backup_%'
        ORDER BY table_name" > $myisamTablesFilename

# Get all kinds of tables: BASE TABLEs and VIEWS for export.
mysql --host=$dbHost --port=$dbPort --user=$dbUsername --password=$dbPassword -N $dbName \
    -e "SELECT table_name
        FROM INFORMATION_SCHEMA.TABLES
        WHERE table_schema='$dbName'
            AND ${like_clause}
            AND table_name NOT LIKE '%_backup_%'
        ORDER BY table_name" > $allTablesFilename

# optimize mySQL tables, to export data faster
# AK 2025-10-04: we don't need to optimize InnoDB tables. And we mostly have InnoDB.
mysqlcheck --optimize --verbose --host=$dbHost --port=$dbPort --user=$dbUsername --password=$dbPassword --databases $dbName \
  --tables `cat $myisamTablesFilename | xargs`

# Export (ATTN! --skip-tz-utc used to not change time. Remove this option if needed.)
# Recommended options which could not be present in legacy mySQL versions:
#    --set-gtid-purged=OFF \
#    --column-statistics=0 \
# AK 2025-09-06 was attempt to:
#    --skip-add-locks = do NOT emit LOCK/UNLOCK TABLES in the dump (to avoid conflicts in triggers)
#    --skip-disable-keys = skip ALTER TABLE ... DISABLE/ENABLE KEYS for MyISAM speed (AK: actually this one, ALTER with DISABLE/ENABLE KEYS seems makes a conflict with trigger)
# ...the attempt in general was successful, but import was TOO SLOW when keys are disabled. Later this issue was fixed itself somehow. I'm not sure how. Maybe temporary glitch.
mysqldump $dbName --host=$dbHost --port=$dbPort --user=$dbUsername --password=$dbPassword \
    --set-gtid-purged=OFF \
    --column-statistics=0 \
    --skip-tz-utc --no-tablespaces \
    --triggers --routines --events \
    `cat $allTablesFilename | xargs` \
    > $targetFilename

# BTW, alternative syntax to export everything by databases:
# mysqldump -h [host] -u [user] -p --databases [database names] --set-gtid-purged=OFF --column-statistics=0 --no-tablespaces --triggers --routines --events > FILENAME.sql


# -- MAINTENANCE after dumping --

# first of all -- backup previous file, if it exists. Okay if it will overwrite previous file
[ -f $targetFilename.rar ] && mv $targetFilename.rar $targetFilename.previous.rar


# compress with gzip (compression level from 1 to 9, from fast to best)
# Use 9 (best) for automatic, scheduled backups and 5 (normal) for manual backups, when you need db now.
#gzip -9 -f $1

# compress with rar (compression level from 1 to 5, from fast to best)
# -ma4 = legacy RAR version, but easily readable by all client programs, including FAR2. UPD. Actually -ma5 okay, let's extract it in command line.
# UPD 2024-09-30. New version of RAR doesn't supports -ma[4|5] anymore. It store only to -ma5 version.
# -ep = don't preserve file path
# -df = delete file after archiving
rar a -m5 -ep -df $targetFilename.rar $targetFilename
sudo chown 660 $targetFilename.rar
