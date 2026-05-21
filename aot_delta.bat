@echo off
:: AoTv3 Database Delta Generator
:: Run this after making changes to your working database (peq).
:: It will compare peq against the last committed state, generate a migration
:: file for the difference, push it to git, and advance the reference database.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0aot_delta.ps1"
