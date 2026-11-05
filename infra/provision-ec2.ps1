# Provisions a Windows Server EC2 host for the vacation reservations demo:
#   IIS (+ URL Rewrite / ARR for proxying the chatbot), latest .NET (SDK + ASP.NET Core Hosting Bundle),
#   Oracle Database 21c Express Edition, Python + Anthropic SDK in a venv.
# Idempotent: each step is skipped if already installed, so it is safe to re-run.
# Runs as SYSTEM via SSM (AWS-RunPowerShellScript). Log: C:\setup\provision.log

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root      = 'C:\setup'
$Downloads = "$Root\downloads"
$Secrets   = "$Root\secrets"
$PythonMinor = '3.14'
$PythonDir   = 'C:\Python314'
$ChatbotDir  = 'C:\apps\chatbot'

New-Item -ItemType Directory -Force -Path $Root, $Downloads, $Secrets, $ChatbotDir | Out-Null
# SSM sessions can start with a stale PATH; reload it so already-installed tools (dotnet) are detected.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
Start-Transcript -Path "$Root\provision.log" -Append | Out-Null

function Step($msg) { Write-Host "`n=== $msg ===  [$(Get-Date -Format s)]" }

function Get-File($url, $name) {
    $out = Join-Path $Downloads $name
    if (-not (Test-Path $out)) {
        Write-Host "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    }
    $out
}

function Invoke-Installer($exe, $arguments) {
    Write-Host "Running $exe $arguments"
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -notin 0, 3010, 1641) { throw "$exe exited with code $($p.ExitCode)" }
}

# ---------------------------------------------------------------- IIS
# Must be installed before the .NET Hosting Bundle so the ASP.NET Core Module registers with IIS.
Step 'IIS'
Install-WindowsFeature -IncludeManagementTools -Name `
    Web-Server, Web-Default-Doc, Web-Static-Content, Web-Http-Errors, Web-Http-Redirect, `
    Web-Http-Logging, Web-Request-Monitor, Web-Stat-Compression, Web-Filtering, `
    Web-WebSockets, Web-Mgmt-Console | Select-Object Success, RestartNeeded, ExitCode | Format-List

Step 'IIS URL Rewrite + Application Request Routing (reverse proxy to the Python chatbot)'
if (-not (Test-Path "$env:windir\System32\inetsrv\rewrite.dll")) {
    $msi = Get-File 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi' 'rewrite_amd64.msi'
    Invoke-Installer 'msiexec.exe' "/i `"$msi`" /qn /norestart"
} else { Write-Host 'URL Rewrite already installed' }
if (-not (Test-Path "$env:ProgramFiles\IIS\Application Request Routing")) {
    $msi = Get-File 'https://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi' 'requestRouter_amd64.msi'
    Invoke-Installer 'msiexec.exe' "/i `"$msi`" /qn /norestart"
} else { Write-Host 'ARR already installed' }
Import-Module WebAdministration
Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/proxy' -Name enabled -Value $true

# ---------------------------------------------------------------- .NET
# Resolve the newest GA (active-support) channel from Microsoft's release metadata.
Step '.NET (latest GA SDK + ASP.NET Core Hosting Bundle)'
$index   = Invoke-RestMethod 'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json'
$channel = $index.'releases-index' |
    Where-Object { $_.'support-phase' -eq 'active' } |
    Sort-Object { [version]$_.'channel-version' } -Descending | Select-Object -First 1
$release = (Invoke-RestMethod $channel.'releases.json').releases |
    Where-Object { $_.'release-version' -eq $channel.'latest-release' } | Select-Object -First 1
Write-Host ".NET channel $($channel.'channel-version') ($($channel.'release-type')), release $($release.'release-version')"

$hostingUrl = ($release.'aspnetcore-runtime'.files | Where-Object name -eq 'dotnet-hosting-win.exe').url
$sdkUrl     = ($release.sdk.files | Where-Object name -eq 'dotnet-sdk-win-x64.exe').url
$installedRuntimes = if (Get-Command dotnet -ErrorAction SilentlyContinue) { & dotnet --list-runtimes } else { @() }

if (-not ($installedRuntimes -match "AspNetCore.App $([regex]::Escape($release.'aspnetcore-runtime'.version))")) {
    Invoke-Installer (Get-File $hostingUrl 'dotnet-hosting-win.exe') '/install /quiet /norestart'
    Invoke-Installer (Get-File $sdkUrl 'dotnet-sdk-win-x64.exe') '/install /quiet /norestart'
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    # Restart IIS so it picks up the ASP.NET Core Module.
    & net stop was /y | Out-Null
    & net start w3svc | Out-Null
} else { Write-Host '.NET already at latest' }

# ---------------------------------------------------------------- Python + Anthropic SDK
Step "Python $PythonMinor (latest patch) + chatbot venv"
if (-not (Test-Path "$PythonDir\python.exe")) {
    $listing  = (Invoke-WebRequest 'https://www.python.org/ftp/python/' -UseBasicParsing).Content
    $versions = [regex]::Matches($listing, "href=`"($([regex]::Escape($PythonMinor))\.\d+)/`"") |
        ForEach-Object { [version]$_.Groups[1].Value } | Sort-Object -Descending
    $pyUrl = $null
    foreach ($v in $versions) {
        $candidate = "https://www.python.org/ftp/python/$v/python-$v-amd64.exe"
        try { Invoke-WebRequest $candidate -Method Head -UseBasicParsing | Out-Null; $pyUrl = $candidate; break } catch {}
    }
    if (-not $pyUrl) { throw "No Windows installer found for Python $PythonMinor" }
    Invoke-Installer (Get-File $pyUrl 'python-amd64.exe') "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 TargetDir=$PythonDir"
} else { Write-Host 'Python already installed' }

if (-not (Test-Path "$ChatbotDir\.venv\Scripts\python.exe")) {
    & "$PythonDir\python.exe" -m venv "$ChatbotDir\.venv"
}
$venvPy = "$ChatbotDir\.venv\Scripts\python.exe"
& $venvPy -m pip install --upgrade --quiet pip
# anthropic: Claude SDK | oracledb: thin-mode Oracle driver (no Instant Client needed)
# fastapi/uvicorn: chatbot HTTP API that IIS reverse-proxies to | httpx: calls the .NET booking API
& $venvPy -m pip install --upgrade --quiet anthropic oracledb fastapi "uvicorn[standard]" httpx pydantic python-dotenv
if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }

# ---------------------------------------------------------------- Oracle XE
Step 'Oracle Database 21c Express Edition'
if (-not (Get-Service -Name 'OracleServiceXE' -ErrorAction SilentlyContinue)) {
    # A previous run can leave the software installed without a database; remove it so setup starts clean.
    $xeProduct = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object DisplayName -like 'Oracle Database 21c Express Edition*' | Select-Object -First 1
    if ($xeProduct) {
        Write-Host "Removing partial Oracle XE install $($xeProduct.PSChildName)"
        Invoke-Installer 'msiexec.exe' "/x $($xeProduct.PSChildName) /qn /norestart /L*v $Root\oracle-xe-uninstall.log"
        Get-Service Oracle* -ErrorAction SilentlyContinue | ForEach-Object { Stop-Service $_.Name -Force -ErrorAction SilentlyContinue; & sc.exe delete $_.Name | Out-Null }
        Get-Process tnslsnr, oracle -ErrorAction SilentlyContinue | Stop-Process -Force
        # The installer's pre-check fails if the old listener still holds 1521.
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-NetTCPConnection -LocalPort 1521 -State Listen -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
        Remove-Item 'C:\app\oracle' -Recurse -Force -ErrorAction SilentlyContinue
    }

    $zip =Get-File 'https://download.oracle.com/otn-pub/otn_software/db-express/OracleXE213_Win64.zip' 'OracleXE213_Win64.zip'
    $xeDir = "$Downloads\xe"
    if (-not (Test-Path "$xeDir\setup.exe")) { Expand-Archive -Path $zip -DestinationPath $xeDir -Force }

    # Oracle passwords must start with a letter; keep it alphanumeric to avoid quoting issues.
    $chars = [char[]]'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $pw = 'X' + (-join (1..15 | ForEach-Object { $chars | Get-Random })) + '7'
    $pwFile = "$Secrets\oracle-xe-sys-password.txt"
    Set-Content -Path $pwFile -Value $pw -NoNewline
    & icacls $Secrets /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null

    # DB_DOMAIN must be set explicitly: when it is empty or omitted, the silent installer passes an
    # uninitialized value to DBCA (e.g. "XE.?`o}") and database creation fails with DBT-10316.
    # Consequence: PDB service name is XEPDB1.localdomain.
    $rsp = "$Root\XEInstall.rsp"
    @"
INSTALLDIR=C:\app\oracle\product\21c\
PASSWORD=$pw
LISTENER_PORT=1521
EMEXPRESS_PORT=5550
CHAR_SET=AL32UTF8
DB_DOMAIN=localdomain
"@ | Set-Content -Path $rsp -Encoding ASCII
    # The XE installer can't resolve SYSTEM's group memberships (what SSM runs as) and fails with
    # "User must have administrator privileges", so run it as a local admin via a one-off scheduled task.
    $installUser = 'oracleinstall'
    $installPw = 'Ai' + (-join (1..20 | ForEach-Object { $chars | Get-Random })) + '#9'
    $securePw = ConvertTo-SecureString $installPw -AsPlainText -Force
    if (Get-LocalUser -Name $installUser -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $installUser -Password $securePw
        Enable-LocalUser -Name $installUser
    } else {
        New-LocalUser -Name $installUser -Password $securePw -PasswordNeverExpires -Description 'Runs the Oracle XE installer' | Out-Null
    }
    if (-not (Get-LocalGroupMember -Group 'Administrators' -Member $installUser -ErrorAction SilentlyContinue)) {
        Add-LocalGroupMember -Group 'Administrators' -Member $installUser
    }

    $exitFile = "$Root\oracle-xe-exitcode.txt"
    Remove-Item $exitFile -ErrorAction SilentlyContinue
    $wrapper = "$Root\install-oracle-xe.cmd"
    @"
"$xeDir\setup.exe" /s /v"RSP_FILE=$rsp" /v"/L*v $Root\oracle-xe-install.log" /v"/qn"
echo %ERRORLEVEL% > "$exitFile"
"@ | Set-Content -Path $wrapper -Encoding ASCII
    $taskName = 'InstallOracleXE'
    try {
        $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$wrapper`""
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -RunLevel Highest `
            -User "$env:COMPUTERNAME\$installUser" -Password $installPw -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Write-Host "Oracle XE installer started as $installUser (takes 15-40 minutes)"
        do {
            Start-Sleep -Seconds 30
            $state = (Get-ScheduledTask -TaskName $taskName).State
        } while ($state -eq 'Running' -and -not (Test-Path $exitFile))
        if (-not (Test-Path $exitFile)) { throw "Oracle XE installer did not report an exit code (task result $((Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult))" }
        $code = [int](Get-Content $exitFile).Trim()
        if ($code -notin 0, 3010) { throw "Oracle XE setup.exe exited with code $code - see $Root\oracle-xe-install.log" }
        # setup.exe reports success even when database creation (DBCA) fails, so check the DB service exists.
        if (-not (Get-Service -Name 'OracleServiceXE' -ErrorAction SilentlyContinue)) {
            throw "Oracle XE software installed but database creation failed - see SEVERE lines in $Root\oracle-xe-install.log"
        }
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Disable-LocalUser -Name $installUser -ErrorAction SilentlyContinue
        Remove-Item $rsp, $wrapper -Force -ErrorAction SilentlyContinue
    }
    Write-Host "SYS/SYSTEM/PDBADMIN password saved to $pwFile (Administrators only)"
} else { Write-Host 'Oracle XE already installed' }

# ---------------------------------------------------------------- Firewall
# Only HTTP/HTTPS are exposed; Oracle (1521) and the chatbot stay local to the host.
Step 'Windows Firewall'
foreach ($port in 80, 443) {
    if (-not (Get-NetFirewallRule -DisplayName "Demo HTTP $port" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Demo HTTP $port" -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null
    }
}

# ---------------------------------------------------------------- Summary
Step 'Summary'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
Write-Host "IIS:        $((Get-Service W3SVC).Status)"
Write-Host ".NET SDKs:  $((& dotnet --list-sdks) -join '; ')"
Write-Host ".NET RTs:   $((& dotnet --list-runtimes | Select-String 'AspNetCore') -join '; ')"
Write-Host "Python:     $(& $venvPy --version)"
Write-Host "anthropic:  $(& $venvPy -c 'import anthropic; print(anthropic.__version__)')"
Write-Host "oracledb:   $(& $venvPy -c 'import oracledb; print(oracledb.__version__)')"
Write-Host "Oracle XE:  $((Get-Service OracleServiceXE).Status), listener $((Get-Service OracleOraDB21Home1TNSListener -ErrorAction SilentlyContinue).Status)"
Write-Host 'PROVISIONING COMPLETE'
Stop-Transcript | Out-Null
