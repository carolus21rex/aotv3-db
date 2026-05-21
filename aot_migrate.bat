@echo off
:: AoTv3 Database Migration Runner
:: Double-click this file to apply any pending database migrations.
::
:: Requirements:
::   - MySQL or MariaDB client installed (in PATH or common install location)
::   - aotv3-db migrations repo cloned as a sibling of this repo:
::       git clone <repo-url> ..\aotv3-db
::
:: To override the database connection, set environment variables before running:
::   set DB_HOST=192.168.1.100
::   set DB_USER=myuser
::   set DB_PASS=mypassword
::   aot_migrate.bat

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0aot_migrate.ps1"
