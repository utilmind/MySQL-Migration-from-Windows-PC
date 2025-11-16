#!/bin/bash
set -euo pipefail

# CONFIGURATION
# Optionally specify table prefixes to process for optimization/analyze.
# Can also be overridden in ".configuration-name.credentials.sh".
#dbTablePrefix=('table_prefix1_' 'table_prefix2_' 'bot_' 'email_' 'user_')


print_help() {
  scriptName=$(basename "$0")
  cat << EOF
Usage: $scriptName [configuration-name] ["table1 table2 table3"]

configuration-name (Optional)
    Used to locate credentials file with name ".configuration-name.credentials.sh"
    placed in the same directory as this script.
    If not provided, then ".credentials.sh" will be used.

explicit tables list (Optional, second parameter)
    Quoted space-separated list of tables to process.
    If provided, dbTablePrefix is ignored and only these tables are optimized/analyzed.

Examples:
    $scriptName
        # use .credentials.sh, optimize/analyze tables based on dbTablePrefix

    $scriptName my-config
        # use .my-config.credentials.sh, optimize/analyze tables based on dbTablePrefix

    $scriptName my-config "table1 table2 stats"
        # use .my-config.credentials.sh, optimize/analyze only the listed tables

EOF
}


# ---------------- PARAMETER PARSING ----------------

while [[ "${1-}" == -* ]] ; do
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

confName="${1:-}"       # configuration-name (may be empty)
tablesListRaw="${2:-}"  # optional explicit table list (quoted)


# ---------------- BASIC PATHS ----------------

thisScript=$(readlink -f "$0")
scriptDir=$(dirname "$thisScript")

# Temporary directory for helper files.
tempDir="$scriptDir/_temp"
mkdir -p "$tempDir"

myisamTablesFilename="$tempDir/_${confName}-optimize_tables.txt"
innoDBTablesFilename="$tempDir/_${confName}-analyze_tables.txt"


# ---------------- LOAD CREDENTIALS ----------------

if [ -n "$confName" ]; then
    credentialsFile="$scriptDir/.${confName}.credentials.sh"
else
    credentialsFile="$scriptDir/.credentials.sh"
fi

if [ ! -r "$credentialsFile" ]; then
    echo "ERROR: Credentials file '$credentialsFile' not found or not readable."
    echo "Please create it with DB connection settings:"
    echo "  dbHost, dbPort, dbName, dbUsername, [dbPassword], [dbTablePrefix]"
    exit 1
fi

. "$credentialsFile"

# If dbName is not defined in credentials, we can fall back to confName (if set).
if [ -z "${dbName:-}" ]; then
    if [ -n "$confName" ]; then
        dbName="$confName"
    else
        echo "ERROR: 'dbName' is not defined in credentials file '$credentialsFile' and no configuration-name argument was provided."
        exit 1
    fi
fi

# Ask for password if it is not defined or empty
if [ -z "${dbPassword:-}" ]; then
    read -s -p "Enter password for MySQL user '$dbUsername' (database '$dbName'): " dbPassword
    echo
fi

mysqlConnOpts=(
    --host="$dbHost"
    --port="$dbPort"
    --user="$dbUsername"
    --password="$dbPassword"
)


# ---------------- BUILD TABLE SELECTION CONDITIONS ----------------

tablesListInClause=""
declare -a explicitTables=()

if [ -n "$tablesListRaw" ]; then
    # Explicit tables mode: ignore dbTablePrefix
    read -r -a explicitTables <<< "$tablesListRaw"

    if [ ${#explicitTables[@]} -eq 0 ]; then
        echo "ERROR: Explicit table list (second parameter) is empty after parsing." >&2
        exit 1
    fi

    for t in "${explicitTables[@]}"; do
        esc=${t//\'/\'\'}   # escape single quotes
        if [ -z "$tablesListInClause" ]; then
            tablesListInClause="'$esc'"
        else
            tablesListInClause="$tablesListInClause, '$esc'"
        fi
    done

    myisamWhere="TABLE_SCHEMA='$dbName' AND table_type='BASE TABLE' AND ENGINE='MyISAM' AND TABLE_NAME IN (${tablesListInClause})"
    innoDBWhere="TABLE_SCHEMA='$dbName' AND table_type='BASE TABLE' AND ENGINE='InnoDB' AND TABLE_NAME IN (${tablesListInClause})"

else
    # Prefix mode: use dbTablePrefix to select tables.
    if [ -z "${dbTablePrefix+x}" ]; then
        echo "ERROR: dbTablePrefix is not defined in configuration and no explicit table list was provided." >&2
        echo "Either define dbTablePrefix in the credentials file or pass explicit tables as the second parameter." >&2
        exit 1
    fi

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
    like_clause="(${like_clause})"

    myisamWhere="TABLE_SCHEMA='$dbName' AND table_type='BASE TABLE' AND ENGINE='MyISAM' AND ${like_clause} AND table_name NOT LIKE '%_backup_%'"
    innoDBWhere="TABLE_SCHEMA='$dbName' AND table_type='BASE TABLE' AND ENGINE='InnoDB' AND ${like_clause} AND table_name NOT LIKE '%_backup_%'"
fi


# ---------------- PREPARE TABLE LISTS ----------------

# Get MyISAM tables for OPTIMIZE
mysql "${mysqlConnOpts[@]}" -N \
    -e "SELECT table_name
        FROM INFORMATION_SCHEMA.TABLES
        WHERE ${myisamWhere}
        ORDER BY table_name" > "$myisamTablesFilename"

# Get InnoDB tables for ANALYZE
mysql "${mysqlConnOpts[@]}" -N \
    -e "SELECT table_name
        FROM INFORMATION_SCHEMA.TABLES
        WHERE ${innoDBWhere}
        ORDER BY table_name" > "$innoDBTablesFilename"


# ---------------- RUN OPTIMIZE / ANALYZE ----------------

# Optimize MyISAM tables, to improve physical layout.
if [ -s "$myisamTablesFilename" ]; then
    echo "Optimizing MyISAM tables in '$dbName'..."
    mysqlcheck --optimize --verbose \
        "${mysqlConnOpts[@]}" \
        --databases "$dbName" \
        --tables $(cat "$myisamTablesFilename" | xargs) \
    || echo "WARNING: Failed to optimize MyISAM tables (probably insufficient privileges). Continuing without optimization." >&2
else
    echo "No MyISAM tables selected for optimization in '$dbName'."
fi

# Analyze InnoDB tables to refresh statistics used by the optimizer.
if [ -s "$innoDBTablesFilename" ]; then
    echo "Analyzing InnoDB tables in '$dbName'..."
    mysqlcheck --analyze --verbose \
        "${mysqlConnOpts[@]}" \
        --databases "$dbName" \
        --tables $(cat "$innoDBTablesFilename" | xargs) \
    || echo "WARNING: Failed to analyze InnoDB tables (probably insufficient privileges). Continuing without analyze." >&2
else
    echo "No InnoDB tables selected for analyze in '$dbName'."
fi
