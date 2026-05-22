#Requires -Version 5.1
<#
.SYNOPSIS
    AoTv3 database migration runner for Windows.
    Double-click aot_migrate.bat, or run:
        powershell -ExecutionPolicy Bypass -File aot_migrate.ps1
.DESCRIPTION
    1. Reads DB credentials from eqemu_config.json (searched relative to this script).
    2. Pulls latest migrations from this git repo.
    3. Creates a db_migrations tracking table if it does not exist.
    4. Applies any .sql files that have not been applied yet, in sorted order.

    Environment overrides: DB_HOST, DB_PORT, DB_USER, DB_PASS, DB_NAME, MIGRATIONS_DIR, MYSQL_EXE
#>
$scriptDir = "/home/papa/aotv3-db"
$searchBase = "/home/papa/aotv3-db"


$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Write-Status { param($msg) Write-Host "[migrate] $msg" -ForegroundColor Cyan }
function Write-Ok     { param($msg) Write-Host "[migrate] $msg" -ForegroundColor Green }
function Write-Warn   { param($msg) Write-Host "[migrate] WARNING: $msg" -ForegroundColor Yellow }
function Write-Err    { param($msg) Write-Host "[migrate] ERROR: $msg" -ForegroundColor Red }

function Exit-Script {
    param([int]$code = 0)
    Write-Host ""
    Write-Host "Press Enter to close..." -ForegroundColor DarkGray
    $null = Read-Host
    exit $code
}

function Die { param($msg) Write-Err $msg; Exit-Script 1 }

# ── DB credentials (defaults match EQEmu devcontainer) ──────────────────────

$DB_HOST = "192.168.0.93"
$DB_PORT = "3306"
$DB_USER = "eqemu"
$DB_PASS = "papa123"
$DB_NAME = "peq"

# Search for eqemu_config.json starting from script directory and walking up
$configFile = $null
$searchBase = $scriptDir
for ($i = 0; $i -lt 5; $i++) {
    if (-not $searchBase) { break }
    $candidate = Join-Path $searchBase "eqemu_config.json"
    if (Test-Path $candidate) {
        $configFile = (Resolve-Path $candidate).Path
        break
    }
    $parent = Split-Path -Parent $searchBase
    if ($parent -eq $searchBase) { break }
    $searchBase = $parent
}

if ($configFile) {
    Write-Status "Reading credentials from: $configFile"
    try {
        $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
        $db = $cfg.server.database
        if ($db.host)     { $DB_HOST = [string]$db.host }
        if ($db.port)     { $DB_PORT = [string]$db.port }
        if ($db.username) { $DB_USER = [string]$db.username }
        if ($db.password) { $DB_PASS = [string]$db.password }
        if ($db.db)       { $DB_NAME = [string]$db.db }
    } catch {
        Write-Warn "Could not parse eqemu_config.json ($_) -- using defaults"
    }
} else {
    Write-Warn "eqemu_config.json not found -- using defaults (peq/peqpass@127.0.0.1/peq)"
}

# Environment variable overrides
if ($env:DB_HOST) { $DB_HOST = $env:DB_HOST }
if ($env:DB_PORT) { $DB_PORT = $env:DB_PORT }
if ($env:DB_USER) { $DB_USER = $env:DB_USER }
if ($env:DB_PASS) { $DB_PASS = $env:DB_PASS }
if ($env:DB_NAME) { $DB_NAME = $env:DB_NAME }

# ── Find mysql/mariadb executable ────────────────────────────────────────────

$mysqlExe = $null

if ($env:MYSQL_EXE -and (Test-Path $env:MYSQL_EXE)) {
    $mysqlExe = $env:MYSQL_EXE
}

if (-not $mysqlExe) {
    foreach ($cmd in @("mysql", "mariadb")) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { $mysqlExe = $found.Source; break }
    }
}

if (-not $mysqlExe) {
    $candidates = @(
        "${env:ProgramFiles}\MariaDB*\bin\mysql.exe",
        "${env:ProgramFiles(x86)}\MariaDB*\bin\mysql.exe",
        "${env:ProgramFiles}\MySQL\MySQL Server*\bin\mysql.exe",
        "C:\xampp\mysql\bin\mysql.exe",
        "C:\wamp64\bin\mysql\mysql*\bin\mysql.exe"
    )
    foreach ($pattern in $candidates) {
        $found = Get-Item $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $mysqlExe = $found.FullName; break }
    }
}

if (-not $mysqlExe) {
    Die @"
mysql/mariadb client not found in PATH or common install locations.

Options:
  1. Add your MySQL/MariaDB bin directory to your system PATH, or
  2. Set MYSQL_EXE=C:\path\to\mysql.exe before running this script.

MariaDB download: https://mariadb.org/download/
"@
}

Write-Status "MySQL client  : $mysqlExe"
Write-Status "Target        : $DB_USER@$DB_HOST`:$DB_PORT/$DB_NAME"

# ── Helper functions ─────────────────────────────────────────────────────────

$mysqlBaseArgs = @("-h$DB_HOST", "-P$DB_PORT", "-u$DB_USER", "-p$DB_PASS", "--database=$DB_NAME")

function Invoke-MySQLQuery {
    param([string]$query, [switch]$ScalarResult)
    $args = $mysqlBaseArgs.Clone()
    if ($ScalarResult) { $args += "-sN" }
    $args += @("-e", $query)
    $output = & $mysqlExe @args
    return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n").Trim() }
}

function Invoke-MySQLFile {
    param([string]$filePath)
    # Start-Process with stdin redirect is the most reliable way in PowerShell 5.1
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $mysqlExe `
            -ArgumentList $mysqlBaseArgs `
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

# ── Test connection ───────────────────────────────────────────────────────────

Write-Status "Testing connection..."
$test = Invoke-MySQLQuery -query "SELECT 1;" -ScalarResult
if ($test.ExitCode -ne 0) {
    Die "Cannot connect to database.`n$($test.Output)"
}
Write-Ok "Connection OK"

# ── Find migrations directory ─────────────────────────────────────────────────

$migrationsDir = if ($env:MIGRATIONS_DIR) { $env:MIGRATIONS_DIR } else { Join-Path $scriptDir "migrations" }
$repoRoot      = Split-Path -Parent $migrationsDir

# ── Pull latest ───────────────────────────────────────────────────────────────

Write-Status "Pulling latest migrations..."
$gitOutput = & git -C $repoRoot pull 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "git pull failed (offline or auth issue?)"
    Write-Warn "Continuing with local copy..."
} else {
    Write-Ok "git pull: $($gitOutput | Select-Object -Last 1)"
}

# ── Ensure tracking table ─────────────────────────────────────────────────────

$createTable = @"
CREATE TABLE IF NOT EXISTS db_migrations (
    id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    filename    VARCHAR(255) NOT NULL UNIQUE,
    applied_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
"@
$r = Invoke-MySQLQuery -query $createTable
if ($r.ExitCode -ne 0) {
    Die "Failed to ensure db_migrations table: $($r.Output)"
}

# ── Apply pending migrations ──────────────────────────────────────────────────

$sqlFiles = Get-ChildItem -Path $migrationsDir -Filter "*.sql" -ErrorAction SilentlyContinue |
            Sort-Object Name

if (-not $sqlFiles -or $sqlFiles.Count -eq 0) {
    Write-Warn "No .sql files found in: $migrationsDir"
    Exit-Script 0
}

Write-Status "Found $($sqlFiles.Count) migration file(s) in repo"
Write-Host ""

$applied = 0
$skipped = 0
$failed  = 0

foreach ($file in $sqlFiles) {
    $filename = $file.Name

    $check = Invoke-MySQLQuery `
        -query "SELECT COUNT(*) FROM db_migrations WHERE filename='$filename';" `
        -ScalarResult
    $alreadyApplied = ([int]($check.Output) -gt 0)

    if ($alreadyApplied) {
        Write-Host "  skip   $filename" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    Write-Host -NoNewline "  apply  $filename ... "
    $exitCode = Invoke-MySQLFile -filePath $file.FullName

    if ($exitCode -eq 0) {
        $record = Invoke-MySQLQuery `
            -query "INSERT IGNORE INTO db_migrations (filename) VALUES ('$filename');"
        Write-Host "OK" -ForegroundColor Green
        $applied++
    } else {
        Write-Host "FAILED" -ForegroundColor Red
        $failed++
        Write-Err "Migration failed: $filename"
        Write-Host "  Fix the .sql file and re-run." -ForegroundColor Yellow
        Exit-Script 1
    }
}

Write-Host ""
Write-Ok "Done.  Applied: $applied   Skipped: $skipped   Failed: $failed"
Exit-Script 0
