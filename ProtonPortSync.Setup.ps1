#Requires -Version 5.1
<#
.SYNOPSIS
    One-time configuration for ProtonPortSync.

.DESCRIPTION
    Prompts for qBittorrent WebUI connection details, verifies them against the
    live WebAPI, stores the password encrypted with Windows DPAPI (current user
    only) and optionally registers a hidden background task at logon.

.EXAMPLE
    .\ProtonPortSync.Setup.ps1
.EXAMPLE
    .\ProtonPortSync.Setup.ps1 -RegisterStartup
#>
[CmdletBinding()]
param(
    [string]$WebUiUrl = 'http://127.0.0.1:8080',
    [string]$Username = 'admin',
    [string]$Password,
    [string]$LogDirectory,
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'ProtonPortSync\config.json'),
    [switch]$RegisterStartup,
    [switch]$SkipTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function Write-Step { param($t) Write-Host "`n== $t" -ForegroundColor Cyan }

# --- collect settings -------------------------------------------------------
Write-Step 'qBittorrent WebUI'

if (-not $PSBoundParameters.ContainsKey('WebUiUrl')) {
    $answer = Read-Host "WebUI URL [$WebUiUrl]"
    if ($answer) { $WebUiUrl = $answer }
}
$WebUiUrl = $WebUiUrl.TrimEnd('/')
if ($WebUiUrl -match '^http://' -and $WebUiUrl -notmatch '^http://(127\.0\.0\.1|localhost|\[::1\])([:/]|$)') {
    Write-Host 'Warning: this WebUI URL is plain HTTP on a non-local address; the password will be sent unencrypted.' -ForegroundColor Yellow
}

if (-not $PSBoundParameters.ContainsKey('Username')) {
    $answer = Read-Host "Username [$Username]"
    if ($answer) { $Username = $answer }
}

if (-not $PSBoundParameters.ContainsKey('Password') -and $env:PROTONPORTSYNC_PASSWORD) {
    $Password = $env:PROTONPORTSYNC_PASSWORD   # keeps the password out of the command line / history
}
elseif ($PSBoundParameters.ContainsKey('Password')) {
    Write-Host 'Note: -Password on the command line can end up in shell history. Prefer the prompt or $env:PROTONPORTSYNC_PASSWORD.' -ForegroundColor Yellow
}

if (-not $Password) {
    $secure = Read-Host 'Password' -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if (-not $LogDirectory) {
    $auto = @(
        (Join-Path $env:LOCALAPPDATA 'Proton\Proton VPN\Logs'),
        (Join-Path $env:APPDATA      'Proton\Proton VPN\Logs')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if ($auto) {
        Write-Host "ProtonVPN logs found: $auto" -ForegroundColor Green
        $LogDirectory = $auto
    } else {
        Write-Host 'ProtonVPN log directory NOT found automatically.' -ForegroundColor Yellow
        $LogDirectory = Read-Host 'Enter the ProtonVPN Logs folder (or leave blank to auto-detect later)'
    }
}

# --- verify against the live API -------------------------------------------
if (-not $SkipTest) {
    Write-Step 'Testing connection'
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    try {
        # No Origin/Referer headers: qBittorrent's CSRF check explicitly permits
        # header-less Web API clients. Success is HTTP 200 (body may be empty).
        $resp = Invoke-WebRequest -Uri "$WebUiUrl/api/v2/auth/login" -Method Post `
                    -Body @{ username = $Username; password = $Password } `
                    -WebSession $session -UseBasicParsing -TimeoutSec 8

        if ($resp.Content -and ($resp.Content -notmatch '^Ok\.')) {
            throw "Unexpected login response: '$($resp.Content)'"
        }

        $prefs = (Invoke-WebRequest -Uri "$WebUiUrl/api/v2/app/preferences" -WebSession $session `
                    -UseBasicParsing -TimeoutSec 8).Content | ConvertFrom-Json
        Write-Host ("Login OK. qBittorrent listen_port is {0}." -f $prefs.listen_port) -ForegroundColor Green
    }
    catch {
        $msg  = $_.Exception.Message
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 401) {
            $msg = 'Wrong username or password (401 Unauthorized).'
        }
        elseif ($code -eq 403) {
            $msg = 'This IP is banned by qBittorrent after repeated failed logins. Restart qBittorrent or wait for the ban to expire.'
        }
        Write-Host "Connection test FAILED: $msg" -ForegroundColor Red
        $go = Read-Host 'Save the configuration anyway? (y/N)'
        if ($go -notmatch '^(y|yes)$') { throw 'Aborted by user.' }
    }
}

# --- persist ---------------------------------------------------------------
Write-Step 'Saving configuration'
$blob = [Security.Cryptography.ProtectedData]::Protect(
            [Text.Encoding]::UTF8.GetBytes($Password), $null, 'CurrentUser')

$config = [pscustomobject]@{
    WebUiUrl          = $WebUiUrl
    Username          = $Username
    PasswordProtected = [Convert]::ToBase64String($blob)
    LogDirectory      = $LogDirectory
    NatPmpGateway     = '10.2.0.1'
    NatPmpPort        = 5351
    IntervalSeconds   = 20
    LastAppliedPort   = 0
}

$dir = Split-Path -Parent $ConfigPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Host "Saved to $ConfigPath" -ForegroundColor Green

# --- first sync ------------------------------------------------------------
Write-Step 'First sync'
$enginePath = Join-Path $PSScriptRoot 'ProtonPortSync.ps1'
# Run in a child process so the engine's exit code cannot terminate this setup.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enginePath -ConfigPath $ConfigPath -Once
if ($LASTEXITCODE -ne 0) {
    Write-Host 'First sync did not complete. Fix the above, then run: .\ProtonPortSync.ps1 -Status' -ForegroundColor Yellow
}

# --- startup ---------------------------------------------------------------
if ($RegisterStartup) {
    Write-Step 'Registering logon task'
    $launcher = Join-Path $PSScriptRoot 'ProtonPortSync.vbs'
    $target   = Join-Path $PSScriptRoot 'ProtonPortSync.ps1'
    $vbs = @"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$target""", 0, False
"@
    Set-Content -LiteralPath $launcher -Value $vbs -Encoding ASCII

    $action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$launcher`""
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    # Watchdog: every 10 minutes, re-launch. The script's global mutex makes a
    # duplicate instance exit immediately, so this only revives a dead service.
    $watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date) `
                    -RepetitionInterval (New-TimeSpan -Minutes 10)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'ProtonPortSync' -Action $action -Trigger @($trigger, $watchdog) `
        -Settings $settings -Description 'Keeps qBittorrent listening port in sync with ProtonVPN' -Force | Out-Null

    Start-ScheduledTask -TaskName 'ProtonPortSync'
    Write-Host 'Logon task "ProtonPortSync" registered and started.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host '  Status : .\ProtonPortSync.ps1 -Status'
Write-Host '  Log    : ' -NoNewline; Write-Host (Join-Path $dir 'ProtonPortSync.log')
