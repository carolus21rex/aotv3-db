@echo off
:: AoTv3 Database Delta Generator
:: Run this after making changes to your working database (peq).
:: It will compare peq against the last committed state, generate a migration
:: file for the difference, push it to git, and advance the reference database.
::
:: To override the database connection, set environment variables before running:
::   set DB_HOST=192.168.0.93
::   set DB_PORT=3306
::   set DB_USER=eqemu
::   set DB_PASS=papa123
::   set DB_NAME=peq
::   aot_delta.bat

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0aot_delta.ps1"
