#Requires -Version 5.1
# TEST COMMIT: verifying git push authentication
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

$DB_HOST = "192.168.0.93"
$DB_PORT = "3306"
$DB_USER = "eqemu"
$DB_PASS = "papa123"
$DB_WORK = "peq"
$DB_LIVE = "aot_current"
# ...these are now set at the top of the script with the correct values...

function Die { param($msg) Write-Host $msg -ForegroundColor Red; exit 1 }

# --- All function definitions ---
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

# --- Config/environment variable setup ---
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

# ...already set at the top of the script...
$DB_WORK = "peq"
$DB_LIVE = "aot_current"

$mysqlArgs = @("-h$DB_HOST", "-P$DB_PORT", "-u$DB_USER", "-p$DB_PASS")

$repoRoot      = $scriptDir
$migrationsDir = Join-Path $scriptDir "migrations"

# --- DYNAMIC TABLE FETCHING ---
Write-Host "Fetching all tables from $DB_WORK..."
$getTablesQuery = "SHOW TABLES FROM ``$DB_WORK``;"
$tableListResult = Invoke-SQL -db $DB_WORK -query $getTablesQuery -Scalar
$dbWorkVal = $DB_WORK
if ($tableListResult.ExitCode -ne 0 -or !$tableListResult.Output) {
    Die ('Failed to fetch table list from ' + $dbWorkVal + ': ' + $tableListResult.Output)
}
$TRACKED_TABLES = $tableListResult.Output -split "`n" |
    Where-Object {
        $_ -and $_ -notmatch "^db_migrations$" `
        -and $_ -notmatch "^account" `
        -and $_ -notmatch "^character_" `
        -and $_ -notmatch "^inventory" `
        -and $_ -notmatch "^friends$" `
        -and $_ -notmatch "^guild_" `
        -and $_ -notmatch "^sharedbank$" `
        -and $_ -notmatch "^buyer" `
        -and $_ -notmatch "^trader" `
        -and $_ -notmatch "^mail$" `
        -and $_ -notmatch "^petitions$" `
        -and $_ -notmatch "^login_" `
        -and $_ -notmatch "^player_" `
        -and $_ -notmatch "^completed_" `
        -and $_ -notmatch "^chatchannel" `
        -and $_ -notmatch "^chatchannels$" `
        -and $_ -notmatch "^raid_" `
        -and $_ -notmatch "^group_" `
        -and $_ -notmatch "^veteran_reward_templates$" `
        -and $_ -notmatch "^keyring$" `
        -and $_ -notmatch "^progressive_dungeon_" `
        -and $_ -notmatch "^completed_tasks$" `
        -and $_ -notmatch "^completed_shared_tasks$" `
        -and $_ -notmatch "^completed_shared_task_" `
        -and $_ -notmatch "^character_stats_record$" `
        -and $_ -notmatch "^character_expedition_lockouts$" `
        -and $_ -notmatch "^character_enabledtasks$" `
        -and $_ -notmatch "^character_task_timers$" `
        -and $_ -notmatch "^character_tasks$" `
        -and $_ -notmatch "^character_tribute$" `
        -and $_ -notmatch "^character_alt_currency$" `
        -and $_ -notmatch "^character_alternate_abilities$" `
        -and $_ -notmatch "^character_auras$" `
        -and $_ -notmatch "^character_bandolier$" `
        -and $_ -notmatch "^character_bind$" `
        -and $_ -notmatch "^character_buffs$" `
        -and $_ -notmatch "^character_corpse_items$" `
        -and $_ -notmatch "^character_corpses$" `
        -and $_ -notmatch "^character_currency$" `
        -and $_ -notmatch "^character_data$" `
        -and $_ -notmatch "^character_disciplines$" `
        -and $_ -notmatch "^character_evolving_items$" `
        -and $_ -notmatch "^character_inspect_messages$" `
        -and $_ -notmatch "^character_instance_safereturns$" `
        -and $_ -notmatch "^character_item_recast$" `
        -and $_ -notmatch "^character_languages$" `
        -and $_ -notmatch "^character_leadership_abilities$" `
        -and $_ -notmatch "^character_material$" `
        -and $_ -notmatch "^character_memmed_spells$" `
        -and $_ -notmatch "^character_parcels$" `
        -and $_ -notmatch "^character_parcels_containers$" `
        -and $_ -notmatch "^character_peqzone_flags$" `
        -and $_ -notmatch "^character_pet_buffs$" `
        -and $_ -notmatch "^character_pet_info$" `
        -and $_ -notmatch "^character_pet_inventory$" `
        -and $_ -notmatch "^character_pet_name$" `
        -and $_ -notmatch "^character_potionbelt$" `
        -and $_ -notmatch "^character_skills$" `
        -and $_ -notmatch "^character_spells$" `
    }
Write-Host ("Tracking tables: " + ($TRACKED_TABLES -join ", "))

# --- The rest of your script follows, using $TRACKED_TABLES ---
