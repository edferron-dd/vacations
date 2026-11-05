# Registers the chatbot as a scheduled task that starts at boot and restarts on failure.
# Runs uvicorn on 127.0.0.1 only - IIS is the public entry point and proxies /chat/* to it.
# Run on the server as Administrator after the venv and .env exist (infra/deploy-app.ps1 does this).
param(
    [string]$AppDir = 'C:\apps\chatbot',
    [int]$Port = 8001,
    [string]$TaskName = 'VacationsChatbot'
)
$ErrorActionPreference = 'Stop'

$python = Join-Path $AppDir '.venv\Scripts\python.exe'
if (-not (Test-Path $python)) { throw "Python venv not found at $python" }
if (-not (Test-Path (Join-Path $AppDir '.env'))) { throw "Missing $AppDir\.env (copy .env.example and set ANTHROPIC_API_KEY)" }

# Runs as the low-privilege LOCAL SERVICE account; it needs read on the app (inherited from Users)
# and the .env file (granted by deploy-app.ps1), and write on the log folder.
$logDir = Join-Path $AppDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
& icacls $logDir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null   # S-1-5-19 = NT AUTHORITY\LOCAL SERVICE

$command = "`"$python`" -m uvicorn app:app --host 127.0.0.1 --port $Port >> `"$logDir\chatbot.log`" 2>&1"
# Outer quotes are required: with more than two quotes, cmd /c strips the first and last one, breaking the paths.
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$command`"" -WorkingDirectory $AppDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCALSERVICE' -LogonType ServiceAccount

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
# Stopping the task doesn't always stop the python child, so free the port explicitly.
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Scheduled task '$TaskName' registered and started (uvicorn on 127.0.0.1:$Port, log: $logDir\chatbot.log)"
