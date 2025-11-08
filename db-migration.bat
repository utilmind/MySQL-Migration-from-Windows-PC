@echo off
REM ================== CONFIG ==================
REM Path to MariaDB folder
set "MDBBIN=C:\Program Files\MariaDB 10.5\bin"

REM Output folder for dumps (will be created if missing)
set "OUTDIR=D:\4\db_dumps4"

REM Connection params (leave HOST/PORT default if local)
set "HOST=localhost"
set "PORT=3306"
set "USER=root"
set "PASS=MY_PASSWORD"

rem echo Enter password for %USER%@%HOST% (input will be visible):
rem set /p "PASS=> "
rem echo.

REM Dump options common for all databases
set "COMMON_OPTS=--single-transaction --routines --events --triggers --hex-blob --default-character-set=utf8mb4 --skip-extended-insert --add-drop-database --force"

REM ============================================

chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

if not exist "%MDBBIN%\mariadb.exe" (
  echo ERROR: mariadb.exe not found at "%MDBBIN%".
  goto :eof
)
if not exist "%MDBBIN%\mariadb-dump.exe" (
  echo ERROR: mariadb-dump.exe not found at "%MDBBIN%".
  goto :eof
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"
set "LOG=%OUTDIR%\_dump_errors.log"
del "%LOG%" 2>nul

echo === Getting database list from %HOST%:%PORT% ...
set "DBLIST=%OUTDIR%\_dblist.txt"
REM Write databases to a file to avoid quoting issues
"%MDBBIN%\mariadb.exe" -h %HOST% -P %PORT% -u %USER% -p%PASS% -N -B -e "SHOW DATABASES" > "%DBLIST%"
if errorlevel 1 (
  echo ERROR: Could not retrieve database list.
  goto :eof
)

for /f "usebackq delims=" %%D in ("%DBLIST%") do (
  set "DB=%%D"
  REM Skip system schemas except mysql (we dump mysql after the loop)
  if /I not "!DB!"=="information_schema" if /I not "!DB!"=="performance_schema" if /I not "!DB!"=="sys" if /I not "!DB!"=="mysql" (
    set "OUTFILE=%OUTDIR%\!DB!.sql"
    echo.
    echo --- Dumping database: !DB!  ^> "!OUTFILE!"
    "%MDBBIN%\mariadb-dump.exe" -h %HOST% -P %PORT% -u %USER% -p%PASS% --databases "!DB!" %COMMON_OPTS% --result-file="!OUTFILE!"
    if errorlevel 1 (
      echo [%DATE% %TIME%] ERROR dumping !DB! >> "%LOG%"
      echo     ^- See "%LOG%" for details.
    ) else (
      echo     OK
    )
  )
)

echo.
echo --- Dumping system grants/users database: mysql
"%MDBBIN%\mariadb-dump.exe" -h %HOST% -P %PORT% -u %USER% -p%PASS% --databases mysql %COMMON_OPTS% --result-file="%OUTDIR%\mysql.sql"
if errorlevel 1 (
  echo [%DATE% %TIME%] ERROR dumping mysql >> "%LOG%"
  echo     ^- See "%LOG%" for details.
) else (
  echo     OK
)

echo.
echo === Done. Dumps are in: %OUTDIR%
if exist "%LOG%" (
  echo Some errors were recorded in: %LOG%
) else (
  echo No errors recorded.
)
endlocal
