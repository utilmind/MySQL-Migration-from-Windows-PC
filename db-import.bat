@echo off
REM Check if first argument is provided
if "%~1"=="" (
    echo Error: no path to the MySQL dump provided.
    echo Usage: %~nx0 "C:\path\to\mysql-dump.sql"
    exit /b 1
)

REM Save first argument as file path
set "FILE=%~1"

REM Check if file exists
if not exist "%FILE%" (
    echo Error: file not found: "%FILE%"
    exit /b 1
)

echo Importing "%FILE%" into MySQL...

REM Run MySQL client:
REM   -u root -p        -> ask for password
REM   --verbose         -> show what is being executed (some progress)
REM   --force           -> continue import even in case of error. You can review all errors together in the log.
REM   < "%FILE%"        -> read SQL commands from dump file
REM   2> "_errors.log"  -> send ONLY errors (stderr) to _errors.log
mysql -u root -p --verbose --force < "%FILE%" 2> "_errors.log"

REM Check exit code. (This doesn't works if --force option is used for import, se we'll check "_errors.log" additionally. The next line is good w/o --force, don't remove it.)
if errorlevel 1 (
    echo Import FAILED. See "_errors.log" for details.
    exit /b 1
) else (
    echo Import completed successfully.
    exit /b 0
)