@echo off
REM ============ DEFAULT CONFIG (used if no args are passed) ============
REM Path to bin folder (MariaDB or MySQL)
set "SQLBIN=C:\Program Files\MariaDB 10.5\bin"
REM Client executable name: mysql.exe or mariadb.exe
set "SQLCLI=mysql.exe"
REM Output folder for users_and_grants.sql
set "OUTDIR=D:\_db-dumps"
REM Connection params
set "HOST=localhost"
set "PORT=3306"
set "USER=root"
REM Password: put real password here, or leave empty to be prompted
set "PASS="
REM ================================

REM Check client exists
if not exist "%SQLBIN%\%SQLCLI%" (
  echo ERROR: %SQLCLI% not found at "%SQLBIN%".
  goto :end
)

REM Run PowerShell script (export-users-and-grants.ps1 in same folder)
powershell -ExecutionPolicy Bypass -File "%~dp0export-users-and-grants.ps1" ^
  -SqlBin "%SQLBIN%" ^
  -SqlCli "%SQLCLI%" ^
  -Host "%HOST%" ^
  -Port %PORT% ^
  -User "%USER%" ^
  -Password "%PASS%" ^
  -OutDir "%OUTDIR%"

:end
