#Requires -Version 5.1
<#
.SYNOPSIS
    AoTv3 database delta generator.
    Compares your working database (peq) against the committed live state (aot_current),
    generates a migration file for the difference, pushes it to git, then advances
    aot_current to match peq.

    Run after making database changes you want to commit.
    Double-click aot_delta.bat, or: powershell -ExecutionPolicy Bypass -File aot_delta.ps1
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ── Tracked tables ────────────────────────────────────────────────────────────
# Add tables here as your content expands.
$TRACKED_TABLES = @(
    "npc_types",
    "npc_spells",
    "npc_spells_entries",
    "spawngroup",
    "spawnentry",
    "spawn2",
    "loottable",
    "loottable_entries",
    "lootdrop",
    "lootdrop_entries"
)

$DB_WORK = "peq"          # your working database
$DB_LIVE = "aot_current"  # committed-state reference database

# ── Output helpers ────────────────────────────────────────────────────────────

function Write-Status { param($msg) Write-Host "[delta] $msg" -ForegroundColor Cyan }
function Write-Ok     { param($msg) Write-Host "[delta] $msg" -ForegroundColor Green }
function Write-Warn   { param($msg) Write-Host "[delta] WARNING: $msg" -ForegroundColor Yellow }
function Write-Err    { param($msg) Write-Host "[delta] ERROR: $msg" -ForegroundColor Red }

function Exit-Script {
    param([int]$code = 0)
    Write-Host ""
    Write-Host "Press Enter to close..." -ForegroundColor DarkGray
    $null = Read-Host
    exit $code
}

function Die { param($msg) Write-Err $msg; Exit-Script 1 }

# ── Credentials (same search logic as aot_migrate.ps1) ───────────────────────

$DB_HOST = "127.0.0.1"
$DB_PORT = "3306"
$DB_USER = "peq"
$DB_PASS = "peqpass"

$configFile = $null
$searchBase = $scriptDir
for ($i = 0; $i -lt 5; $i++) {
    $candidate = Join-Path $searchBase "eqemu_config.json"
    if (Test-Path $candidate) { $configFile = (Resolve-Path $candidate).Path; break }
    $searchBase = Split-Path -Parent $searchBase
}

if ($configFile) {
    try {
        $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
        $db = $cfg.server.database
        if ($db.host)     { $DB_HOST = [string]$db.host }
        if ($db.port)     { $DB_PORT = [string]$db.port }
        if ($db.username) { $DB_USER = [string]$db.username }
        if ($db.password) { $DB_PASS = [string]$db.password }
    } catch { Write-Warn "Could not parse eqemu_config.json, using defaults" }
} else {
    Write-Warn "eqemu_config.json not found, using defaults"
}

if ($env:DB_HOST) { $DB_HOST = $env:DB_HOST }
if ($env:DB_PORT) { $DB_PORT = $env:DB_PORT }
if ($env:DB_USER) { $DB_USER = $env:DB_USER }
if ($env:DB_PASS) { $DB_PASS = $env:DB_PASS }

# ── Find mysql + mysqldump ────────────────────────────────────────────────────

function Find-Exe {
    param([string[]]$names, [string[]]$extraPaths)
    foreach ($name in $names) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
    }
    foreach ($pattern in $extraPaths) {
        $found = Get-Item $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

$commonPaths = @(
    "${env:ProgramFiles}\MariaDB*\bin\mysql.exe",
    "${env:ProgramFiles(x86)}\MariaDB*\bin\mysql.exe",
    "${env:ProgramFiles}\MySQL\MySQL Server*\bin\mysql.exe",
    "C:\xampp\mysql\bin\mysql.exe"
)
$mysqlExe    = Find-Exe @("mysql","mariadb") $commonPaths
$mysqldumpExe = Find-Exe @("mysqldump") ($commonPaths -replace 'mysql\.exe','mysqldump.exe')

if (-not $mysqlExe)     { Die "mysql not found. Add MySQL/MariaDB to PATH or set MYSQL_EXE." }
if (-not $mysqldumpExe) { Die "mysqldump not found. It should be in the same folder as mysql." }

$mysqlArgs = @("-h$DB_HOST", "-P$DB_PORT", "-u$DB_USER", "-p$DB_PASS")

# ── MySQL helpers ─────────────────────────────────────────────────────────────

function Invoke-SQL {
    param([string]$db, [string]$query, [switch]$Scalar)
    $args = $mysqlArgs + @("--database=$db")
    if ($Scalar) { $args += "-sN" }
    $out = & $mysqlExe @args -e $query
    return @{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n").Trim() }
}

function Invoke-SQLFile {
    param([string]$db, [string]$filePath)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $mysqlExe `
            -ArgumentList ($mysqlArgs + @("--database=$db")) `
            -RedirectStandardInput $filePath `
            -RedirectStandardError $errFile `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            $errText = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
            if ($errText) { Write-Host $errText.Trim() -ForegroundColor DarkRed }
        }
        return $proc.ExitCode
    } finally {
        Remove-Item $errFile -ErrorAction SilentlyContinue
    }
}

# ── Migrations repo location ──────────────────────────────────────────────────

$repoRoot      = $scriptDir
$migrationsDir = Join-Path $scriptDir "migrations"

# ── Step 1: Pull latest migrations ───────────────────────────────────────────

Write-Status "Pulling latest migrations from git..."
$gitOut = & git -C $repoRoot pull 2>&1
if ($LASTEXITCODE -ne 0) {
    Die "git pull failed. Resolve any conflicts before generating a delta.`n$gitOut"
}
Write-Ok ($gitOut | Select-Object -Last 1)

# ── Step 2: Ensure aot_current exists and has all tracked tables ──────────────

Write-Status "Checking $DB_LIVE database..."

$r = Invoke-SQL "information_schema" "CREATE DATABASE IF NOT EXISTS ``$DB_LIVE``;"
if ($r.ExitCode -ne 0) { Die "Could not create $DB_LIVE database: $($r.Output)" }

foreach ($table in $TRACKED_TABLES) {
    $r = Invoke-SQL $DB_LIVE "CREATE TABLE IF NOT EXISTS ``$DB_LIVE``.``$table`` LIKE ``$DB_WORK``.``$table``;"
    if ($r.ExitCode -ne 0) { Die "Could not create $DB_LIVE.$table`: $($r.Output)" }
}

# ── Step 3: Apply any pending migrations to aot_current ──────────────────────

Write-Status "Syncing $DB_LIVE with committed migrations..."

$trackQ = "CREATE TABLE IF NOT EXISTS db_migrations (id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY, filename VARCHAR(255) NOT NULL UNIQUE, applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
$r = Invoke-SQL $DB_LIVE $trackQ
if ($r.ExitCode -ne 0) { Die "Could not create tracking table in $DB_LIVE`: $($r.Output)" }

$sqlFiles = Get-ChildItem -Path $migrationsDir -Filter "*.sql" -ErrorAction SilentlyContinue | Sort-Object Name
$synced = 0
foreach ($file in $sqlFiles) {
    $check = Invoke-SQL $DB_LIVE "SELECT COUNT(*) FROM db_migrations WHERE filename='$($file.Name)';" -Scalar
    if (([int]$check.Output) -gt 0) { continue }

    Write-Host "  sync  $($file.Name) ..."
    $code = Invoke-SQLFile $DB_LIVE $file.FullName
    if ($code -ne 0) { Die "Failed to apply $($file.Name) to $DB_LIVE" }
    $null = Invoke-SQL $DB_LIVE "INSERT IGNORE INTO db_migrations (filename) VALUES ('$($file.Name)');"
    $synced++
}
if ($synced -gt 0) { Write-Ok "Synced $synced migration(s) to $DB_LIVE" } else { Write-Ok "$DB_LIVE is up to date" }

# ── Step 4: Compute delta ─────────────────────────────────────────────────────

Write-Status "Comparing $DB_WORK vs $DB_LIVE..."

function Get-TableColumns {
    param([string]$tableName)
    $q = "SELECT column_name, IF(column_key='PRI',1,0) FROM information_schema.columns WHERE table_schema='$DB_WORK' AND table_name='$tableName' ORDER BY ordinal_position;"
    $out = (Invoke-SQL "information_schema" $q -Scalar).Output
    $cols = @(); $pkCols = @()
    foreach ($line in ($out -split "`n" | Where-Object { $_ -ne '' })) {
        $parts = $line -split '\t'
        if ($parts.Count -ge 2) {
            $cols += $parts[0].Trim()
            if ($parts[1].Trim() -eq '1') { $pkCols += $parts[0].Trim() }
        }
    }
    return @{ All = $cols; PK = $pkCols }
}

function Build-CRC {
    param([string[]]$cols, [string]$alias)
    $exprs = $cols | ForEach-Object { "COALESCE($alias.``$_``, '\\0')" }
    return "CRC32(CONCAT_WS('\\x01', $($exprs -join ', ')))"
}

function Get-DumpLines {
    param([string]$tableName, [string]$whereClause)
    $args = $mysqlArgs + @(
        "--replace", "--no-create-info", "--compact",
        "--skip-lock-tables", "--skip-add-locks", "--skip-comments",
        "--where=$whereClause",
        $DB_WORK, $tableName
    )
    $out = & $mysqldumpExe @args
    return ($out | Where-Object { $_ -match '^REPLACE INTO' })
}

$deltaLines = [System.Collections.Generic.List[string]]::new()
$changedTables = [System.Collections.Generic.List[string]]::new()

foreach ($table in $TRACKED_TABLES) {
    $info = Get-TableColumns $table
    if ($info.PK.Count -eq 0) { Write-Warn "No PK on $table, skipping"; continue }

    $tableDelta = [System.Collections.Generic.List[string]]::new()
    $joinCond = ($info.PK | ForEach-Object { "a.``$_`` = p.``$_``" }) -join " AND "
    $pCRC = Build-CRC $info.All "p"
    $aCRC = Build-CRC $info.All "a"

    if ($info.PK.Count -eq 1) {
        $pk = $info.PK[0]

        # New or modified rows
        $changedQ = "SELECT GROUP_CONCAT(DISTINCT p.``$pk`` ORDER BY p.``$pk`` SEPARATOR ',') FROM ``$DB_WORK``.``$table`` p LEFT JOIN ``$DB_LIVE``.``$table`` a ON a.``$pk`` = p.``$pk`` WHERE a.``$pk`` IS NULL OR ($pCRC != $aCRC);"
        $changedIDs = (Invoke-SQL $DB_WORK $changedQ -Scalar).Output.Trim()

        if ($changedIDs -and $changedIDs -ne 'NULL') {
            $lines = Get-DumpLines $table "$pk IN ($changedIDs)"
            if ($lines) { $tableDelta.AddRange([string[]]$lines) }
        }

        # Deleted rows
        $deletedQ = "SELECT GROUP_CONCAT(a.``$pk`` ORDER BY a.``$pk`` SEPARATOR ',') FROM ``$DB_LIVE``.``$table`` a LEFT JOIN ``$DB_WORK``.``$table`` p ON p.``$pk`` = a.``$pk`` WHERE p.``$pk`` IS NULL;"
        $deletedIDs = (Invoke-SQL $DB_WORK $deletedQ -Scalar).Output.Trim()

        if ($deletedIDs -and $deletedIDs -ne 'NULL') {
            $tableDelta.Add("DELETE FROM ``$table`` WHERE ``$pk`` IN ($deletedIDs);")
        }

    } else {
        # Composite PK: check if anything differs, then do full table REPLACE
        $diffQ = "SELECT COUNT(*) FROM ``$DB_WORK``.``$table`` p LEFT JOIN ``$DB_LIVE``.``$table`` a ON $joinCond WHERE a.$($info.PK[0]) IS NULL OR ($pCRC != $aCRC);"
        $diffCount = [int](Invoke-SQL $DB_WORK $diffQ -Scalar).Output.Trim()

        $delQ = "SELECT COUNT(*) FROM ``$DB_LIVE``.``$table`` a LEFT JOIN ``$DB_WORK``.``$table`` p ON $joinCond WHERE p.$($info.PK[0]) IS NULL;"
        $delCount = [int](Invoke-SQL $DB_WORK $delQ -Scalar).Output.Trim()

        if ($diffCount -gt 0 -or $delCount -gt 0) {
            $tableDelta.Add("DELETE FROM ``$table``;")
            $lines = Get-DumpLines $table "1=1"
            if ($lines) { $tableDelta.AddRange([string[]]$lines) }
        }
    }

    if ($tableDelta.Count -gt 0) {
        $deltaLines.Add("")
        $deltaLines.Add("-- ── $table " + ("-" * (60 - $table.Length)))
        $deltaLines.AddRange($tableDelta)
        $changedTables.Add($table)
    }
}

if ($deltaLines.Count -eq 0) {
    Write-Ok "No changes detected — $DB_WORK matches $DB_LIVE"
    Exit-Script 0
}

Write-Ok "Changes detected in: $($changedTables -join ', ')"

# ── Step 5: Write migration file ──────────────────────────────────────────────

$timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$tableSlug   = ($changedTables | Select-Object -First 3) -join "_"
$filename    = "${timestamp}_content_delta_${tableSlug}.sql"
$filePath    = Join-Path $migrationsDir $filename

$header = @(
    "-- AoTv3 content delta",
    "-- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "-- Changed tables: $($changedTables -join ', ')",
    ""
)

$content = ($header + $deltaLines) -join "`n"
[System.IO.File]::WriteAllText($filePath, $content, [System.Text.Encoding]::UTF8)
Write-Status "Wrote: $filename"

# ── Step 6: Commit and push ───────────────────────────────────────────────────

Write-Status "Committing and pushing..."

& git -C $repoRoot add "migrations/$filename"
if ($LASTEXITCODE -ne 0) { Die "git add failed" }

$commitMsg = "Content delta: $($changedTables -join ', ')"
& git -C $repoRoot commit -m $commitMsg
if ($LASTEXITCODE -ne 0) { Die "git commit failed" }

& git -C $repoRoot push
if ($LASTEXITCODE -ne 0) {
    Write-Err "git push failed — another commit may have landed since your pull."
    Write-Host "Run: git -C `"$repoRoot`" pull --rebase && git -C `"$repoRoot`" push" -ForegroundColor Yellow
    Exit-Script 1
}

Write-Ok "Pushed to git"

# ── Step 7: Advance aot_current ───────────────────────────────────────────────

Write-Status "Advancing $DB_LIVE to match $DB_WORK..."
$code = Invoke-SQLFile $DB_LIVE $filePath
if ($code -ne 0) { Die "Failed to apply delta to $DB_LIVE — manual sync may be needed" }
$null = Invoke-SQL $DB_LIVE "INSERT IGNORE INTO db_migrations (filename) VALUES ('$filename');"

Write-Host ""
Write-Ok "Done. Delta committed and $DB_LIVE is up to date."
Exit-Script 0
