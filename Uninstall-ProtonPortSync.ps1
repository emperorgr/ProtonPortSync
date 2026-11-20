#Requires -Version 5.1
<#
.SYNOPSIS
    Stops ProtonPortSync and removes its logon task and launcher.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

Unregister-ScheduledTask -TaskName 'ProtonPortSync' -Confirm:$false
Write-Host 'Removed scheduled task (if it existed).'

# Kill any running background instance started from this folder.
$root = $PSScriptRoot
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$root\ProtonPortSync.ps1*" } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
        Write-Host "Stopped PID $($_.ProcessId)"
    }

$launcher = Join-Path $PSScriptRoot 'ProtonPortSync.vbs'
if (Test-Path -LiteralPath $launcher) { Remove-Item -LiteralPath $launcher -Force }

Write-Host 'Done. Configuration in %LOCALAPPDATA%\ProtonPortSync was left untouched.'
