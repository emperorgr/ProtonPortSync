#Requires -Version 5.1
# End-to-end test: engine -> mock qBittorrent WebAPI -> verified port change.
$ErrorActionPreference = 'Stop'

$port      = 18080
$stateFile = Join-Path $env:TEMP 'pps-mock-state.json'
$cfgFile   = Join-Path $env:TEMP 'pps-e2e-config.json'
$engine    = Join-Path $PSScriptRoot 'ProtonPortSync.ps1'

if (Test-Path $stateFile) { Remove-Item $stateFile -Force }

$mock = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $PSScriptRoot 'Test-MockQbtServer.ps1'),
    '-Port', $port, '-StateFile', $stateFile
)

try {
    # wait for mock to listen
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        try {
            $null = Invoke-WebRequest "http://127.0.0.1:$port/api/v2/app/version" -UseBasicParsing -TimeoutSec 1
            $ready = $true; break
        } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) { throw 'Mock server did not start' }
    Write-Host 'Mock qBittorrent is up.' -ForegroundColor Green

    # password "secret" protected with DPAPI for this user
    Add-Type -AssemblyName System.Security
    $blob = [Security.Cryptography.ProtectedData]::Protect(
                [Text.Encoding]::UTF8.GetBytes('secret'), $null, 'CurrentUser')

    $cfg = [pscustomobject]@{
        WebUiUrl          = "http://127.0.0.1:$port"
        Username          = 'admin'
        PasswordProtected = [Convert]::ToBase64String($blob)
        LogDirectory      = ''
        NatPmpGateway     = '10.2.0.1'
        NatPmpPort        = 5351
        IntervalSeconds   = 20
        LastAppliedPort   = 0
    }
    $cfg | ConvertTo-Json | Set-Content -LiteralPath $cfgFile -Encoding UTF8

    Write-Host "`n--- Running engine -Once ---" -ForegroundColor Cyan
    & $engine -ConfigPath $cfgFile -Once

    Start-Sleep -Milliseconds 500
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json

    Write-Host "`n--- Results ---" -ForegroundColor Cyan
    Write-Host ("logins performed      : {0}" -f $state.logins)
    Write-Host ("last setPreferences   : {0}" -f $state.last_body)
    Write-Host ("listen_port now      : {0}" -f $state.listen_port)

    # Ask the detection layer directly (Write-Host output is not pipeline-capturable).
    . $engine -ConfigPath $cfgFile
    $cfgo = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json
    $found = Get-ProtonReservedPort -Config $cfgo
    $expectPort = if ($found) { $found.Port } else { 0 }

    $ok = ($state.logins -ge 1) -and ($state.listen_port -eq $expectPort) -and ($expectPort -gt 0)
    if ($ok) {
        Write-Host "`nPASS: qBittorrent port synced to $expectPort" -ForegroundColor Green
    } else {
        Write-Host "`nFAIL: expected $expectPort, got $($state.listen_port)" -ForegroundColor Red
        exit 1
    }

    # idempotency: second run must not rewrite the port
    $before = $state.last_body
    & $engine -ConfigPath $cfgFile -Once | Out-Null
    Start-Sleep -Milliseconds 400
    $state2 = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if ($state2.last_body -eq $before) {
        Write-Host 'PASS: second run was a no-op (idempotent)' -ForegroundColor Green
    } else {
        Write-Host "FAIL: second run rewrote prefs: $($state2.last_body)" -ForegroundColor Red
        exit 1
    }
}
finally {
    if ($mock -and -not $mock.HasExited) { Stop-Process -Id $mock.Id -Force }
    Write-Host 'Mock server stopped.'
}
