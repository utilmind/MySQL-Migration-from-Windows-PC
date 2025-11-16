#!/usr/bin/env bash
# ======================================================================
#  dump-users-and-grants.sh - Export MySQL / MariaDB users and grants
#
#  Part of: MySQL Migration Tools
#  Copyright (c) 2025 utilmind
#  https://github.com/utilmind/MySQL-migration-tools
#
#  Description:
#    Helper script for exporting MySQL / MariaDB users and privileges
#    into a standalone SQL file.
#
#    Features:
#      - Connects to the server using the configured client binary
#        (mysql or mariadb).
#      - Reads connection settings from:
#          * CLI options,
#          * .credentials.sh or .<config>.credentials.sh,
#          * built-in defaults (fallback).
#      - Queries mysql.user to obtain the list of non-system accounts.
#      - Skips internal / system users (root, mysql.sys, etc.) by default.
#      - Optional filter by user name prefix (User LIKE 'prefix%').
#      - For each user, generates SQL statements that:
#          * create the user on the target server (IF NOT EXISTS),
#          * re-apply all privileges using SHOW GRANTS output.
#      - Writes everything into the specified SQL file so that it can be
#        imported before or together with database dumps.
#
#  Credentials:
#    This script can load connection settings from files located in the
#    same directory as this script:
#      - .credentials.sh
#      - .<config-name>.credentials.sh
#
#    Expected variables in credentials file:
#      dbHost="localhost"
#      dbPort="3306"
#      dbUser="silkcards_dump"
#      dbPass="secret"
#      # optional:
#      # dbSqlBin="/usr/bin"   # path to mysql/mariadb client bin dir
#
#  Usage:
#    dump-users-and-grants.sh [options] /path/to/users-and-grants.sql
#
#    The first non-option argument is treated as the output SQL file path.
#
#  License: MIT
###############################################################################

# --------------------------- DEFAULTS ----------------------------------
# Configuration profile name (maps to .<config>.credentials.sh)
CONFIG_NAME=""

# Path to bin folder (MariaDB or MySQL).
SQLBIN=""

# Client binary name; can be overridden via environment (export SQLCLI=...)
SQLCLI="${SQLCLI:-mysql}"

# Connection params (may be overridden by credentials and/or CLI)
HOST="localhost"
PORT="3306"
USER="root"
PASS=""

# Remember what was set explicitly via CLI options
HOST_FROM_CLI=0
PORT_FROM_CLI=0
USER_FROM_CLI=0
PASS_FROM_CLI=0

# Output SQL file (required; can be set via --outfile or first positional arg)
USERDUMP=""

# Log and temporary files (derived from USERDUMP directory)
LOG=""
USERLIST=""
TMPGRANTS=""

# Skip system users by default
INCLUDE_SYSTEM_USERS=0

# Optional user name prefix filter (User LIKE 'PREFIX%')
USER_PREFIX=""

# System users list (SQL fragment inside NOT IN (...))
SYSTEM_USERS_LIST="'root','mysql.sys','mysql.session','mysql.infoschema',"\
"'mariadb.sys','mariadb.session','debian-sys-maint','healthchecker','rdsadmin'"

# --------------------------- HELP --------------------------------------
print_help() {
  cat <<EOF
dump-users-and-grants.sh - Export MySQL / MariaDB users and grants

Usage:
  dump-users-and-grants.sh [options] /path/to/users-and-grants.sql

Options:
  --config NAME        Use .NAME.credentials.sh instead of .credentials.sh
                       for connection settings (dbHost, dbPort, dbUser, dbPass).
  --sqlbin PATH        Path to directory with mysql/mariadb client binary.
  --host HOST          Database host (default: ${HOST})
  --port PORT          Database port (default: ${PORT})
  --user USER          Database user (default: ${USER})
  --password PASS      Database password (use with care; if omitted, you will be prompted).
  --outfile FILE       Output SQL file (alternative to positional FILE argument).
  --user-prefix PREFIX Export only users whose *name* starts with PREFIX
                       (User LIKE 'PREFIX%'; host is not filtered).
  --include-system-users
                       Also export system / internal users
                       (root, mysql.sys, mariadb.sys, etc.).
  -h, --help           Show this help and exit.

Notes:
  - The first non-option argument is treated as the output SQL file path.
  - Connection precedence:
      CLI options > .<config>.credentials.sh > built-in defaults.
  - Import the generated file before or together with your database dumps.
EOF
}

# ANSI colors (disabled if NO_COLOR is set or output is not a TTY)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_ERR=$'\033[1;31m'
  C_WARN=$'\033[1;33m'
  C_INFO=$'\033[1;36m'
  C_OK=$'\033[1;32m'
else
  C_RESET='' C_ERR='' C_WARN='' C_INFO='' C_OK=''
fi

log_info() { printf "%s[INFO]%s %s\n" "$C_INFO" "$C_RESET" "$*"; }
log_ok()   { printf "%s[ OK ]%s %s\n" "$C_OK"   "$C_RESET" "$*"; }
log_warn() { printf "%s[WARN]%s %s\n" "$C_WARN" "$C_RESET" "$*"; }
log_err()  { printf "%s[FAIL]%s %s\n" "$C_ERR"  "$C_RESET" "$*"; }

# ------------------------- ARG PARSING ---------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG_NAME="$2"; shift 2 ;;
      --sqlbin)
        SQLBIN="$2"; shift 2 ;;
      --host)
        HOST="$2"; HOST_FROM_CLI=1; shift 2 ;;
      --port)
        PORT="$2"; PORT_FROM_CLI=1; shift 2 ;;
      --user)
        USER="$2"; USER_FROM_CLI=1; shift 2 ;;
      --password)
        PASS="$2"; PASS_FROM_CLI=1; shift 2 ;;
      --outfile)
        USERDUMP="$2"; shift 2 ;;
      --user-prefix)
        USER_PREFIX="$2"; shift 2 ;;
      --include-system-users)
        INCLUDE_SYSTEM_USERS=1; shift ;;
      -h|--help)
        print_help
        exit 0 ;;
      --)
        shift
        break ;;
      -*)
        log_err "Unknown option: $1"
        echo
        print_help
        exit 1 ;;
      *)
        # First non-option argument is the output file
        if [[ -z "$USERDUMP" ]]; then
          USERDUMP="$1"
          shift
        else
          log_err "Unexpected extra positional argument: $1"
          echo
          print_help
          exit 1
        fi
        ;;
    esac
  done

  # Handle any remaining args after "--"
  while [[ $# -gt 0 ]]; do
    if [[ -z "$USERDUMP" ]]; then
      USERDUMP="$1"
    else
      log_err "Unexpected extra positional argument: $1"
      echo
      print_help
      exit 1
    fi
    shift
  done
}

# -------------------- CREDENTIALS LOADING ------------------------------
load_credentials() {
  # Determine script directory (where this .sh file lives)
  local base_dir cred_file
  base_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

  if [[ -n "$CONFIG_NAME" ]]; then
    cred_file="${base_dir}/.${CONFIG_NAME}.credentials.sh"
  else
    cred_file="${base_dir}/.credentials.sh"
  fi

  if [[ -f "$cred_file" ]]; then
    log_info "Loading credentials from: ${cred_file}"
    # shellcheck disable=SC1090
    . "$cred_file"
  else
    if [[ -n "$CONFIG_NAME" ]]; then
      log_warn "Credentials file not found: ${cred_file}"
    fi
  fi

  # Apply credentials → internal HOST/PORT/USER/PASS (if not overridden by CLI)
  if [[ ${HOST_FROM_CLI:-0} -ne 1 && -n "${dbHost:-}" ]]; then HOST="$dbHost"; fi
  if [[ ${PORT_FROM_CLI:-0} -ne 1 && -n "${dbPort:-}" ]]; then PORT="$dbPort"; fi
  if [[ ${USER_FROM_CLI:-0} -ne 1 && -n "${dbUser:-}" ]]; then USER="$dbUser"; fi
  if [[ ${PASS_FROM_CLI:-0} -ne 1 && -n "${dbPass:-}" ]]; then PASS="$dbPass"; fi

  # Optional: allow credentials to define SQLBIN via dbSqlBin
  if [[ -z "$SQLBIN" && -n "${dbSqlBin:-}" ]]; then
    SQLBIN="$dbSqlBin"
  fi
}

# ------------------------- MYSQL WRAPPER -------------------------------
run_mysql() {
  "${SQLBIN}${SQLCLI}" "$@"
}

# ------------------------- MAIN LOGIC ----------------------------------
main() {
  parse_args "$@"
  load_credentials

  # Require output file
  if [[ -z "$USERDUMP" ]]; then
    log_err "Output SQL file is required. Pass it as the first positional argument or use --outfile FILE."
    echo
    print_help
    exit 1
  fi

  # Normalize SQLBIN: add trailing slash if non-empty
  if [[ -n "$SQLBIN" ]]; then
    case "$SQLBIN" in
      */) : ;;
      *)  SQLBIN="${SQLBIN}/" ;;
    esac
    if [[ ! -x "${SQLBIN}${SQLCLI}" ]]; then
      log_err "Client '${SQLCLI}' not found at '${SQLBIN}${SQLCLI}'."
      printf 'Please edit %s and adjust the SQLBIN / SQLCLI variables.\n' "$(basename "$0")" >&2
      exit 1
    fi
  fi

  # Derive directory for logs / temp from USERDUMP
  local OUTDIR_INTERNAL
  OUTDIR_INTERNAL="$(dirname -- "$USERDUMP")"

  mkdir -p "$OUTDIR_INTERNAL" || {
    log_err "Failed to create directory for output file: ${OUTDIR_INTERNAL}"
    exit 1
  }

  LOG="${OUTDIR_INTERNAL}/_users_errors.log"
  USERLIST="${OUTDIR_INTERNAL}/__user-list.txt"
  TMPGRANTS="${OUTDIR_INTERNAL}/__grants_tmp.txt"

  # Ask for password if still empty
  if [[ -z "$PASS" ]]; then
    printf "Enter password for %s@%s (input will be hidden): " "$USER" "$HOST"
    read -r -s PASS
    echo
  fi

  # Clean previous files
  rm -f "$LOG" "$USERLIST" "$TMPGRANTS" "$USERDUMP"

  log_info "Exporting users and grants from ${HOST}:${PORT} using ${SQLCLI}..."
  log_info "Output file: ${USERDUMP}"

  # Build SQL to get user list
  local sql_userlist
  sql_userlist="SELECT CONCAT(\"'\",User,\"'@'\",Host,\"'\") FROM mysql.user WHERE User <> ''"

  # Exclude system users if flag is not set
  if [[ "$INCLUDE_SYSTEM_USERS" -ne 1 ]]; then
    sql_userlist+=" AND User NOT IN (${SYSTEM_USERS_LIST})"
  fi

  # Apply prefix filter if provided: User LIKE 'prefix%'
  if [[ -n "$USER_PREFIX" ]]; then
    local escaped_prefix
    escaped_prefix=$(printf "%s" "$USER_PREFIX" | sed "s/'/''/g")
    sql_userlist+=" AND User LIKE '${escaped_prefix}%'"
  fi

  sql_userlist+=" ORDER BY User, Host;"

  # Retrieve user list
  if ! run_mysql -h "$HOST" -P "$PORT" -u "$USER" -p"$PASS" -N -B \
       -e "$sql_userlist" >"$USERLIST" 2>>"$LOG"; then
    log_err "Could not retrieve user list. See '${LOG}' for details."
    exit 1
  fi

  if ! [[ -s "$USERLIST" ]]; then
    if [[ -n "$USER_PREFIX" ]]; then
      log_warn "User list is empty (no users matching prefix '${USER_PREFIX}'). Nothing to export."
    else
      log_warn "User list is empty. Nothing to export."
    fi
    exit 0
  fi

  # Write header to USERDUMP
  {
    printf -- "-- Users and grants exported from %s:%s on %s\n" \
      "$HOST" "$PORT" "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "SET sql_log_bin=0;"
    echo
  } >"$USERDUMP"

  # Loop through users and dump grants
  while IFS= read -r USER_IDENT; do
    [[ -z "$USER_IDENT" ]] && continue

    {
      printf -- "-- User and grants for %s\n" "$USER_IDENT"
      printf "CREATE USER IF NOT EXISTS %s;\n" "$USER_IDENT"
    } >>"$USERDUMP"

    # SHOW GRANTS for each user, then append ';'
    if ! run_mysql -h "$HOST" -P "$PORT" -u "$USER" -p"$PASS" -N -B \
         -e "SHOW GRANTS FOR ${USER_IDENT}" >"$TMPGRANTS" 2>>"$LOG"; then
      log_warn "Failed to get grants for ${USER_IDENT}. See '${LOG}' for details."
      echo >>"$USERDUMP"
      continue
    fi

    while IFS= read -r GRANT_LINE; do
      [[ -z "$GRANT_LINE" ]] && continue
      printf "%s;\n" "$GRANT_LINE" >>"$USERDUMP"
    done <"$TMPGRANTS"

    echo >>"$USERDUMP"
  done <"$USERLIST"

  echo "SET sql_log_bin=1;" >>"$USERDUMP"

  # Cleanup temp files
  rm -f "$USERLIST" "$TMPGRANTS"

  log_ok "Users and grants saved to: ${USERDUMP}"

  if [[ -f "$LOG" && ! -s "$LOG" ]]; then
    rm -f "$LOG"
  fi

  if [[ -f "$LOG" ]]; then
    log_warn "Some errors/warnings were recorded in: ${LOG}"
  fi
}

main "$@"
