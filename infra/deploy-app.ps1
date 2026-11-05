# Deploys the reservations app on the Windows server. Run as Administrator from a copy of this repo on the box
# (how the repo gets there - git clone, S3 + SSM, zip over Fleet Manager - is still to be decided).
#
#   .\infra\deploy-app.ps1                       # API + web UI to IIS, chatbot service
#   .\infra\deploy-app.ps1 -SkipChatbot          # IIS site only
#
# Prerequisites: infra/provision-ec2.ps1 (IIS, URL Rewrite, ARR, .NET, Python) and db/setup-db.ps1 (schema + password file).
param(
    [string]$SiteName = 'Vacations',
    [int]$Port = 80,
    [string]$SitePath = 'C:\inetpub\vacations',
    [string]$ChatbotDir = 'C:\apps\chatbot',
    [string]$PythonExe = 'C:\Python314\python.exe',
    [string]$AppPasswordFile = 'C:\setup\secrets\oracle-vacation-password.txt',
    [string]$OracleService = 'localhost:1521/XEPDB1',
    # Written by infra/azure/deploy-forecast.sh; without them the trip-forecast feature answers 503.
    [string]$ForecastUrlFile = 'C:\setup\secrets\forecast-function-url.txt',
    [string]$ForecastKeyFile = 'C:\setup\secrets\forecast-function-key.txt',
    # Datadog .NET tracer for APM; installed only when the Datadog Agent is on the box (it receives traces on :8126).
    [string]$DatadogTracerVersion = '3.57.0',
    [SecureString]$AnthropicApiKey,   # only needed the first time, when C:\apps\chatbot\.env doesn't exist yet
    [switch]$SkipChatbot
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Step($msg) { Write-Host "`n=== $msg ===" }

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET SDK not found - run infra/provision-ec2.ps1 first.' }
if (-not (Test-Path $AppPasswordFile)) { throw "Missing $AppPasswordFile - run db/setup-db.ps1 first." }
Import-Module WebAdministration

# ---------------------------------------------------------------- API + web UI
Step 'Publishing Vacations.Api'
$staging = Join-Path $env:TEMP 'vacations-publish'
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
& dotnet publish "$repo\src\Vacations.Api\Vacations.Api.csproj" -c Release -o $staging --nologo
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

Step "IIS site '$SiteName' on port $Port"
if (-not (Test-Path "IIS:\AppPools\$SiteName")) {
    New-WebAppPool -Name $SiteName | Out-Null
}
# ASP.NET Core runs its own runtime, so the pool uses "No Managed Code".
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name managedRuntimeVersion -Value ''
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name startMode -Value 'AlwaysRunning'

# Free the port from the IIS default site (stopped, not deleted, so it can be restored).
$default = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
if ($default -and $SiteName -ne 'Default Web Site' -and ($default.bindings.Collection.bindingInformation -match ":$Port`:")) {
    Stop-Website -Name 'Default Web Site'
    Set-ItemProperty 'IIS:\Sites\Default Web Site' -Name serverAutoStart -Value $false
    Write-Host 'Stopped Default Web Site (it was bound to the same port).'
}

if ((Get-WebAppPoolState -Name $SiteName).Value -ne 'Stopped') { Stop-WebAppPool -Name $SiteName }
# Wait for the worker process to exit so published DLLs aren't locked.
for ($i = 0; $i -lt 30 -and (Get-WebAppPoolState -Name $SiteName).Value -ne 'Stopped'; $i++) { Start-Sleep -Seconds 1 }

New-Item -ItemType Directory -Force -Path $SitePath | Out-Null
& robocopy $staging $SitePath /MIR /XD logs /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
New-Item -ItemType Directory -Force -Path "$SitePath\logs" | Out-Null
& icacls "$SitePath\logs" /grant "IIS AppPool\$($SiteName):(OI)(CI)M" | Out-Null

if (-not (Get-Website -Name $SiteName -ErrorAction SilentlyContinue)) {
    New-Website -Name $SiteName -Port $Port -PhysicalPath $SitePath -ApplicationPool $SiteName | Out-Null
} else {
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $SitePath
}

# ---------------------------------------------------------------- Datadog APM (.NET tracer)
$datadogApm = [bool](Get-Service datadogagent -ErrorAction SilentlyContinue)
if ($datadogApm) {
    $tracer = Get-ChildItem 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall' | Get-ItemProperty |
        Where-Object DisplayName -like 'Datadog .NET Tracer*' | Select-Object -First 1
    if (-not $tracer -or -not $tracer.DisplayVersion.StartsWith($DatadogTracerVersion)) {
        Step "Datadog .NET tracer $DatadogTracerVersion"
        $msi = Join-Path $env:TEMP "datadog-dotnet-apm-$DatadogTracerVersion-x64.msi"
        Invoke-WebRequest -UseBasicParsing -OutFile $msi `
            -Uri "https://github.com/DataDog/dd-trace-dotnet/releases/download/v$DatadogTracerVersion/datadog-dotnet-apm-$DatadogTracerVersion-x64.msi"
        $install = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
        if ($install.ExitCode -notin 0, 3010) { throw "Datadog .NET tracer install failed (msiexec exit $($install.ExitCode))" }
        # The MSI sets the profiler variables on the WAS/W3SVC services; IIS only reads them when those services restart.
        & net stop /y was | Out-Null
        & net start w3svc | Out-Null
        Stop-WebAppPool -Name $SiteName -ErrorAction SilentlyContinue  # WAS restart may have started it again
        Write-Host "Installed Datadog .NET tracer $DatadogTracerVersion and restarted IIS."
    }
}

# Secrets live in applicationHost.config (Administrators-only) as app pool environment variables, not in the site folder.
$poolFilter = "system.applicationHost/applicationPools/add[@name='$SiteName']/environmentVariables"
function Set-PoolVariable([string]$Name, [string]$Value) {
    try {
        Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $poolFilter -Name '.' -AtElement @{ name = $Name } -WarningAction SilentlyContinue
    } catch { } # not set yet on first deploy
    if ($Value) {
        Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $poolFilter -Name '.' -Value @{ name = $Name; value = $Value }
    }
}
$appPw = (Get-Content $AppPasswordFile -Raw).Trim()
Set-PoolVariable 'ConnectionStrings__Oracle' "User Id=vacation;Password=$appPw;Data Source=$OracleService"

if ((Test-Path $ForecastUrlFile) -and (Test-Path $ForecastKeyFile)) {
    Set-PoolVariable 'Forecast__BaseUrl' (Get-Content $ForecastUrlFile -Raw).Trim()
    Set-PoolVariable 'Forecast__FunctionKey' (Get-Content $ForecastKeyFile -Raw).Trim()
    Write-Host 'Trip forecasts: configured.'
} else {
    Set-PoolVariable 'Forecast__BaseUrl' ''
    Set-PoolVariable 'Forecast__FunctionKey' ''
    Write-Host "Trip forecasts: not configured ($ForecastUrlFile / $ForecastKeyFile missing)."
}

# Unified service tagging for the tracer; RUM (wwwroot/datadog-rum.js) uses env 'demo' too, so traces line up.
$ddSettings = [ordered]@{ DD_SERVICE = 'vacations-api'; DD_ENV = 'demo'; DD_LOGS_INJECTION = 'true'; DD_RUNTIME_METRICS_ENABLED = 'true' }
foreach ($name in $ddSettings.Keys) { Set-PoolVariable $name ($(if ($datadogApm) { $ddSettings[$name] } else { '' })) }
Write-Host "Datadog APM: $(if ($datadogApm) { 'enabled (service vacations-api, env demo)' } else { 'skipped - no Datadog Agent on this host' })."

Start-WebAppPool -Name $SiteName
Start-Website -Name $SiteName

# ---------------------------------------------------------------- Chatbot
if (-not $SkipChatbot) {
    Step "Chatbot in $ChatbotDir"
    New-Item -ItemType Directory -Force -Path $ChatbotDir | Out-Null
    Copy-Item "$repo\chatbot\*.py", "$repo\chatbot\requirements.txt", "$repo\chatbot\install-service.ps1", "$repo\chatbot\.env.example" `
        -Destination $ChatbotDir -Force

    $venvPy = "$ChatbotDir\.venv\Scripts\python.exe"
    if (-not (Test-Path $venvPy)) { & $PythonExe -m venv "$ChatbotDir\.venv" }
    & $venvPy -m pip install --quiet --upgrade pip
    & $venvPy -m pip install --quiet --upgrade -r "$ChatbotDir\requirements.txt"
    if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }

    $envFile = "$ChatbotDir\.env"
    if (-not (Test-Path $envFile)) {
        if (-not $AnthropicApiKey) { $AnthropicApiKey = Read-Host 'Anthropic API key' -AsSecureString }
        $key = [Net.NetworkCredential]::new('', $AnthropicApiKey).Password
        $apiUrl = if ($Port -eq 80) { 'http://127.0.0.1' } else { "http://127.0.0.1:$Port" }
        Set-Content -Path $envFile -Encoding ASCII -Value @(
            "ANTHROPIC_API_KEY=$key",
            "VACATIONS_API_URL=$apiUrl"
        )
        Write-Host "Wrote $envFile"
    } else {
        Write-Host "$envFile already exists - keeping its API key."
    }
    # Chat history lives in Oracle; refresh its connection settings on every deploy (password may have been rotated).
    # @() matters: a one-line file comes back as a string, and string + array would concatenate onto that line.
    $kept = @(Get-Content $envFile | Where-Object { $_ -notmatch '^ORACLE_(USER|PASSWORD|DSN)=' })
    Set-Content -Path $envFile -Encoding ASCII -Value ($kept + @(
        'ORACLE_USER=vacation',
        "ORACLE_PASSWORD=$appPw",
        "ORACLE_DSN=$OracleService"
    ))
    # Readable only by admins, SYSTEM and the LOCAL SERVICE account the chatbot runs as (also when .env was created by hand).
    & icacls $envFile /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' '*S-1-5-19:R' | Out-Null

    & "$ChatbotDir\install-service.ps1" -AppDir $ChatbotDir
}

# ---------------------------------------------------------------- Smoke test
Step 'Smoke test'
Start-Sleep -Seconds 5
$base = if ($Port -eq 80) { 'http://localhost' } else { "http://localhost:$Port" }
$checks = @("$base/api/health", "$base/") + $(if (-not $SkipChatbot) { "$base/chat/health" } else { @() })
foreach ($url in $checks) {
    try {
        $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 30
        Write-Host "OK   $($r.StatusCode) $url"
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Warning "FAIL $status $url - $($_.ErrorDetails.Message)"
    }
}
Write-Host "`nSite: $base/"
