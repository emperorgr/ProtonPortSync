#Requires -Version 5.1
<#
.SYNOPSIS
    Live test: corrupts the real qBittorrent listen port, then proves the engine fixes it.

.DESCRIPTION
    This is DESTRUCTIVE in a small way: it moves the live qBittorrent instance to
    port 40000 for a few seconds (torrents are briefly unreachable), then runs one
    sync cycle and verifies the port was restored to the ProtonVPN port.

    Requires a configured ProtonPortSync (run ProtonPortSync.Setup.ps1 first) and a
    running qBittorrent instance.

.PARAMETER Yes
    Skip the confirmation prompt.

.EXAMPLE
    .\Test-RealClient.ps1
#>
[CmdletBinding()]
param([switch]$Yes)

$ErrorActionPreference = 'Stop'

$enginePath = Join-Path $PSScriptRoot 'ProtonPortSync.ps1'
$configPath = Join-Path $env:LOCALAPPDATA 'ProtonPortSync\config.json'

if (-not (Test-Path -LiteralPath $configPath)) {
    throw "No configuration found at $configPath. Run ProtonPortSync.Setup.ps1 first."
}

if (-not $Yes) {
    Write-Host 'This temporarily changes the listen port of the LIVE qBittorrent instance.' -ForegroundColor Yellow
    $answer = Read-Host 'Continue? (y/N)'
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
}

. $enginePath -ConfigPath $configPath

$cfg = Get-Config
$qbt = New-QbtSession -Config $cfg
$original = (Get-QbtListenPort -Qbt $qbt).ListenPort
Write-Host ("Authenticated OK. Current listen_port = {0}" -f $original) -ForegroundColor Green

$bogus = if ($original -ne 40000) { 40000 } else { 40001 }
Write-Host ("Setting a deliberately wrong port ({0})..." -f $bogus)
Set-QbtListenPort -Qbt $qbt -Port $bogus
Start-Sleep -Milliseconds 600
$wrong = (Get-QbtListenPort -Qbt $qbt).ListenPort
Write-Host ("Now listen_port = {0} (expected {1})" -f $wrong, $bogus)

Write-Host 'Running the sync cycle...' -ForegroundColor Cyan
$ok = Invoke-SyncCycle -Config $cfg
$fixed = (Get-QbtListenPort -Qbt $qbt).ListenPort
Write-Host ("After sync: listen_port = {0}, cycle returned {1}" -f $fixed, $ok)

if ($wrong -eq $bogus -and $fixed -eq $original -and $ok) {
    Write-Host ("PASS: real qBittorrent port was corrected {0} -> {1}" -f $bogus, $original) -ForegroundColor Green
} else {
    Write-Host 'FAIL' -ForegroundColor Red
    exit 1
}
