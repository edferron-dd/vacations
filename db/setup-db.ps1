# Creates the VACATION schema in XEPDB1 and loads demo data. Run on the server as Administrator.
#   .\setup-db.ps1            # create user + tables + seed (skips tables/seed if they already exist)
#   .\setup-db.ps1 -Reset     # drop and recreate tables, then reseed
# Passwords never go on a command line: they are read from files and piped to sqlplus on stdin.
param(
    [string]$SysPasswordFile = 'C:\setup\secrets\oracle-xe-sys-password.txt',
    [string]$AppPasswordFile = 'C:\setup\secrets\oracle-vacation-password.txt',
    [string]$Service = 'localhost:1521/XEPDB1',
    [switch]$Reset
)
$ErrorActionPreference = 'Stop'

$sqlplus = (Get-Command sqlplus.exe -ErrorAction SilentlyContinue).Source
if (-not $sqlplus) {
    $sqlplus = Get-ChildItem 'C:\app\*\product\21c\dbhomeXE\bin\sqlplus.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $sqlplus) { throw 'sqlplus.exe not found - is Oracle XE installed?' }

function Invoke-Sql([string]$Connect, [string]$Body) {
    $script = "WHENEVER OSERROR EXIT FAILURE`nWHENEVER SQLERROR EXIT SQL.SQLCODE`nCONNECT $Connect`n$Body`nEXIT`n"
    $out = $script | & $sqlplus -s -L /nolog
    $text = ($out | Out-String).Trim()
    # CONNECT failures are SQL*Plus errors, not SQL errors, so also check the output.
    if ($LASTEXITCODE -ne 0 -or $text -match '(ORA|SP2)-\d{4,5}') { throw "sqlplus failed (exit $LASTEXITCODE):`n$text" }
    $text
}

if (-not (Test-Path $SysPasswordFile)) { throw "SYS password file not found: $SysPasswordFile" }
$sysPw = (Get-Content $SysPasswordFile -Raw).Trim()

if (-not (Test-Path $AppPasswordFile)) {
    # Oracle passwords must start with a letter; alphanumeric avoids quoting issues in connection strings.
    $chars = [char[]]'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $generated = 'V' + (-join (1..19 | ForEach-Object { $chars | Get-Random })) + '3'
    Set-Content -Path $AppPasswordFile -Value $generated -NoNewline
    Write-Host "Generated VACATION password in $AppPasswordFile"
}
$appPw = (Get-Content $AppPasswordFile -Raw).Trim()

$sysConnect = "sys/`"$sysPw`"@//$Service AS SYSDBA"
$appConnect = "vacation/`"$appPw`"@//$Service"

Write-Host 'Creating/updating VACATION user...'
Invoke-Sql $sysConnect "DEFINE app_password = '$appPw'`n@`"$PSScriptRoot\01_create_user.sql`"" | Out-Null

if ($Reset) {
    Write-Host 'Dropping existing tables...'
    Invoke-Sql $appConnect "@`"$PSScriptRoot\03_drop.sql`"" | Out-Null
}

$tableCount = Invoke-Sql $appConnect "SET HEADING OFF FEEDBACK OFF PAGESIZE 0`nSELECT COUNT(*) FROM user_tables WHERE table_name IN ('DESTINATIONS', 'RESERVATIONS');"
if ([int]$tableCount -eq 0) {
    Write-Host 'Creating tables...'
    Invoke-Sql $appConnect "@`"$PSScriptRoot\02_schema.sql`"" | Out-Null
    Write-Host 'Loading demo data...'
    Invoke-Sql $appConnect "@`"$PSScriptRoot\04_seed.sql`"" | Out-Null
} else {
    Write-Host 'Tables already exist - skipping schema and seed (use -Reset to recreate).'
}
Write-Host 'Ensuring chat history table...'
Invoke-Sql $appConnect "@`"$PSScriptRoot\05_chat.sql`"" | Out-Null
Write-Host 'Ensuring destination coordinates...'
Invoke-Sql $appConnect "@`"$PSScriptRoot\06_geo.sql`"" | Out-Null

$summary = Invoke-Sql $appConnect "SET HEADING OFF FEEDBACK OFF PAGESIZE 0`nSELECT (SELECT COUNT(*) FROM destinations) || ' destinations, ' || (SELECT COUNT(*) FROM reservations) || ' reservations' FROM dual;"
Write-Host "Done: $summary"
Write-Host "Connection string: User Id=vacation;Password=<see $AppPasswordFile>;Data Source=$Service"
