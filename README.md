Windows batch (.bat) script to make a dump for single or multiple databases separately into different .SQL-files OR ALL databases including ALL users.

The goal is to make a dump that can be easily imported into MySQL/MariaDB database, with all stored producedures, functions, triggers and users (definers).

# Usage
* `db-migration.bat`               -> dump all databases separately (+ mysql.sql)
* `db-migration.bat ALL`           -> dump all databases into one file all_databases.sql (just add `all`, case insensitive)
* `db-migration.bat db1 db2 db3`   -> dump only listed databases separately

# Compatibility notes
* Some used commands are compatible with very old versions of MySQL. For example, `CREATE USER IF NOT EXISTS` appeared in syntax starting from MySQL 5.7.
So if you need to migrate very old data, replace it to just `CREATE USER` and remove `IF NOT EXISTS`.
* Google about more incompatibilities between MySQL and MariaDB. If there is something important, please pull your fix to this repo.
