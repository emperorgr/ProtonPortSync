#Requires -Version 5.1
# Offline validation of the detection layer (no qBittorrent credentials needed).
$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot 'ProtonPortSync.ps1'
. $engine -ConfigPath (Join-Path $env:TEMP 'pps-test-config.json') -Once

$cfg = [pscustomobject]@{
    WebUiUrl          = 'http://127.0.0.1:8080'
    Username          = 'admin'
    PasswordProtected = ''
    LogDirectory      = ''
    NatPmpGateway     = '10.2.0.1'
    NatPmpPort        = 5351
    IntervalSeconds   = 20
    LastAppliedPort   = 0
}

Write-Host "`n--- 1. Log discovery ---" -ForegroundColor Cyan
$found = Get-ProtonReservedPort -Config $cfg
if (-not $found) { throw 'FAIL: no port discovered from logs' }
$age = [int](([datetime]::UtcNow) - $found.TimestampUtc).TotalSeconds
Write-Host ("PASS: port={0} internal={1} age={2}s file={3}" -f $found.Port, $found.InternalPort, $age, (Split-Path -Leaf $found.SourceFile)) -ForegroundColor Green

Write-Host "`n--- 2. NAT-PMP verification ---" -ForegroundColor Cyan
$v = Test-PortForwarded -Config $cfg -Port $found.Port
Write-Host ("TCP={0} UDP={1} OK={2}" -f $v.Tcp, $v.Udp, $v.Ok)
if (-not $v.Ok) { Write-Host 'WARN: NAT-PMP did not confirm (VPN may be reconnecting)' -ForegroundColor Yellow }

Write-Host "`n--- 3. VPN public IP (via NAT-PMP) ---" -ForegroundColor Cyan
$ip = Get-VpnPublicIp -Config $cfg
if ($ip) { Write-Host "PASS: $ip" -ForegroundColor Green } else { Write-Host 'WARN: no external IP returned' -ForegroundColor Yellow }

Write-Host "`n--- 4. Rejecting a non-reserved port ---" -ForegroundColor Cyan
$bogus = if ($found.Port -ne 51274) { 51274 } else { 40000 }
$b = Test-PortForwarded -Config $cfg -Port $bogus
Write-Host ("port {0} -> TCP={1} UDP={2} OK={3} (expected False)" -f $bogus, $b.Tcp, $b.Udp, $b.Ok)
if ($b.Ok) { Write-Host 'WARN: unexpected confirmation' -ForegroundColor Yellow } else { Write-Host 'PASS: correctly rejected' -ForegroundColor Green }

Write-Host "`n--- 5. Status command against live qBittorrent ---" -ForegroundColor Cyan
$tmpCfg = Join-Path $env:TEMP 'pps-status-config.json'
$cfg | Add-Member -NotePropertyName PasswordProtected -NotePropertyValue '' -Force
$cfg | ConvertTo-Json | Set-Content -LiteralPath $tmpCfg -Encoding UTF8
& $engine -ConfigPath $tmpCfg -Status
