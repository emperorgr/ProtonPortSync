#Requires -Version 5.1
<#
.SYNOPSIS
    Offline tests for ProtonPortSync.Tools.ps1 (status.json, OnPortChange hook, port check,
    health checks, support bundle) and for how the main script drives them.
    Nothing here touches the network, your real settings or qBittorrent.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:pass = 0
$script:fail = 0
function Assert-That {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:pass++; Write-Host "  ok   $Message" }
    else            { $script:fail++; Write-Host "  FAIL $Message" -ForegroundColor Red }
}

$isWindowsHost = ($PSVersionTable.PSEdition -ne 'Core') -or ($null -ne (Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -and $IsWindows)

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("pps-tools-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$savedLocal = $env:LOCALAPPDATA
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = $tmp }   # the main script's parameter default needs it

try {
    # --- stand-ins for what the main script provides ---------------------------
    $script:LogLines = New-Object System.Collections.ArrayList
    function Write-Log { param([string]$Message, [string]$Level = 'INFO', [switch]$Force) [void]$script:LogLines.Add("$Level $Message") }
    function Test-LogHas { param([string]$Pattern) return (@($script:LogLines | Where-Object { $_ -match $Pattern }).Count -gt 0) }
    $script:Version = '9.9.9'

    . (Join-Path $PSScriptRoot 'ProtonPortSync.Tools.ps1')

    function New-Cycle { param($State = 'in_sync', $InSync = $true, $VpnPort = 51820, $QbtPort = 51820, $Err = $null)
        [pscustomobject]@{ State = $State; InSync = $InSync; VpnConnected = $true; VpnPort = $VpnPort; QbtPort = $QbtPort; Error = $Err } }
    $cfgBase = [pscustomobject]@{ WebUiUrl = 'http://127.0.0.1:8080'; Username = 'admin'; PasswordProtected = 'AAAASECRETBLOB'
        StatusFile = $true; OnPortChange = ''; PortCheck = $false; PortCheckUrl = 'https://check.example/{port}'; PortCheckMinutes = 30 }

    # =========================================================================
    Write-Host 'status.json'
    $sf = Join-Path $tmp 'status.json'
    $script:LastPortChangeUtc = '2026-01-01T00:00:00Z'; $script:PortReachable = $null; $script:PortCheckedUtc = $null
    Write-StatusFile -Config $cfgBase -Cycle (New-Cycle) -Path $sf
    Assert-That (Test-Path -LiteralPath $sf) 'file is written'
    $j = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json
    Assert-That ($j.state -eq 'in_sync' -and $j.inSync -eq $true -and $j.forwardedPort -eq 51820 -and $j.qbittorrentPort -eq 51820) 'state, ports and sync flag are present'
    # (read the raw text: PowerShell 7 would turn ISO date strings into dates, 5.1 would not)
    $raw1 = Get-Content -LiteralPath $sf -Raw
    Assert-That ($j.version -eq '9.9.9' -and $raw1 -match '"updatedUtc":\s*"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"') 'version and ISO timestamp are present'
    Assert-That ($raw1 -match '"lastPortChangeUtc":\s*"2026-01-01T00:00:00Z"') 'last port change is present'
    Assert-That (-not (Test-Path -LiteralPath "$sf.tmp")) 'no temp file left behind'
    Start-Sleep -Milliseconds 1100
    Write-StatusFile -Config $cfgBase -Cycle (New-Cycle) -Path $sf
    Assert-That ((Get-Content -LiteralPath $sf -Raw) -eq $raw1) 'unchanged state is not rewritten'
    Write-StatusFile -Config $cfgBase -Cycle (New-Cycle -State 'qbt_unreachable' -InSync $false -QbtPort $null -Err 'refused') -Path $sf
    $j = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json
    Assert-That ($j.state -eq 'qbt_unreachable' -and $j.inSync -eq $false -and $j.lastError -eq 'refused') 'a state change is written at once'
    $off = [pscustomobject]@{ StatusFile = $false }
    $sf2 = Join-Path $tmp 'off.json'
    Write-StatusFile -Config $off -Cycle (New-Cycle) -Path $sf2
    Assert-That (-not (Test-Path -LiteralPath $sf2)) 'StatusFile=false writes nothing'
    Assert-That ((Get-StatusFilePath -ConfigPath (Join-Path $tmp 'config.json')) -eq (Join-Path $tmp 'status.json')) 'status.json sits next to config.json'

    # =========================================================================
    Write-Host 'OnPortChange hook'
    $script:HookCalls = New-Object System.Collections.ArrayList
    $script:HookExit = 0
    $script:HookEnv = $null
    function Start-HookProcess {
        param([string]$File, [string]$Arguments, [int]$TimeoutMs = 15000)
        $script:HookEnv = @{ Event = $env:PPS_EVENT; New = $env:PPS_NEW_PORT; Old = $env:PPS_OLD_PORT; Ver = $env:PPS_VERSION }
        [void]$script:HookCalls.Add("$File|$Arguments")
        return $script:HookExit
    }
    $hookDir = Join-Path $tmp 'hooks'; New-Item -ItemType Directory -Path $hookDir | Out-Null
    $hookPs1 = Join-Path $hookDir 'notify.ps1'; Set-Content -LiteralPath $hookPs1 -Value 'exit 0'
    $hookCmd = Join-Path $hookDir 'notify.cmd'; Set-Content -LiteralPath $hookCmd -Value '@echo off'
    $hookTxt = Join-Path $hookDir 'notes.txt';  Set-Content -LiteralPath $hookTxt -Value 'x'

    function New-HookCfg { param($Path) [pscustomobject]@{ OnPortChange = $Path } }
    Invoke-PortChangeHook -Config (New-HookCfg '') -OldPort 1 -NewPort 2
    Assert-That ($script:HookCalls.Count -eq 0) 'empty setting runs nothing'
    Invoke-PortChangeHook -Config (New-HookCfg (Join-Path $hookDir 'missing.cmd')) -OldPort 1 -NewPort 2
    Assert-That ($script:HookCalls.Count -eq 0 -and (Test-LogHas 'OnPortChange: file not found')) 'missing file is reported, nothing runs'
    Invoke-PortChangeHook -Config (New-HookCfg 'notify.cmd') -OldPort 1 -NewPort 2
    Assert-That ($script:HookCalls.Count -eq 0 -and (Test-LogHas 'not found')) 'relative path is refused'
    Invoke-PortChangeHook -Config (New-HookCfg $hookTxt) -OldPort 1 -NewPort 2
    Assert-That ($script:HookCalls.Count -eq 0 -and (Test-LogHas 'unsupported file type')) 'unsupported file type is refused'

    Invoke-PortChangeHook -Config (New-HookCfg ('"' + $hookCmd + '"')) -OldPort 40000 -NewPort 51820
    Assert-That ($script:HookCalls.Count -eq 1 -and $script:HookCalls[0] -like 'cmd.exe|/d /c*notify.cmd*') 'a quoted .cmd path runs through cmd.exe'
    Assert-That ($script:HookEnv.Event -eq 'port_changed' -and $script:HookEnv.New -eq '51820' -and $script:HookEnv.Old -eq '40000' -and $script:HookEnv.Ver -eq '9.9.9') 'port information is passed in environment variables'
    Assert-That (-not $env:PPS_NEW_PORT -and -not $env:PPS_EVENT) 'environment variables are removed afterwards'
    Assert-That (Test-LogHas 'OnPortChange: ran') 'success is logged'

    $script:HookCalls.Clear(); $script:LogLines.Clear()
    Invoke-PortChangeHook -Config (New-HookCfg $hookPs1) -OldPort 1 -NewPort 2
    Assert-That ($script:HookCalls[0] -like 'powershell.exe|-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "*notify.ps1"') 'a .ps1 hook runs hidden in a fresh PowerShell'
    $script:HookExit = 3; $script:LogLines.Clear()
    Invoke-PortChangeHook -Config (New-HookCfg $hookCmd) -OldPort 1 -NewPort 2
    Assert-That (Test-LogHas 'exited with code 3') 'a failing hook is reported'
    $script:HookExit = $null; $script:LogLines.Clear()
    Invoke-PortChangeHook -Config (New-HookCfg $hookCmd) -OldPort 1 -NewPort 2
    Assert-That (Test-LogHas 'did not finish within 15 seconds') 'a hung hook is reported'
    Assert-That ((Get-HookCommandLine -Path 'C:\x\tool.exe').File -eq 'C:\x\tool.exe') '.exe runs directly'
    Assert-That ($null -eq (Get-HookCommandLine -Path 'C:\x\tool.vbs')) 'other types are unsupported'

    if ($isWindowsHost) {
        Remove-Item Function:\Start-HookProcess
        . (Join-Path $PSScriptRoot 'ProtonPortSync.Tools.ps1')       # restore the real Start-HookProcess
        $out = Join-Path $tmp 'hook-out.txt'
        $real = Join-Path $hookDir 'real.cmd'
        Set-Content -LiteralPath $real -Encoding ASCII -Value ('@echo off', "echo %PPS_EVENT% %PPS_OLD_PORT% %PPS_NEW_PORT% > `"$out`"")
        $script:LogLines.Clear()
        Invoke-PortChangeHook -Config (New-HookCfg $real) -OldPort 11111 -NewPort 22222
        $txt = if (Test-Path -LiteralPath $out) { (Get-Content -LiteralPath $out -Raw).Trim() } else { '' }
        Assert-That ($txt -eq 'port_changed 11111 22222') "a real .cmd hook runs and sees the variables (got '$txt')"
    }

    # =========================================================================
    Write-Host 'Port reachability check'
    $script:FakeAnswer = '1'; $script:CheckedUrls = New-Object System.Collections.ArrayList
    function Get-PortCheckText { param([string]$Url) [void]$script:CheckedUrls.Add($Url); return $script:FakeAnswer }
    $pc = $cfgBase.PSObject.Copy(); $pc.PortCheck = $true
    Assert-That ((Test-PortReachable -Config $pc -Port 51820) -eq $true) 'answer 1 = open'
    Assert-That ($script:CheckedUrls[0] -eq 'https://check.example/51820') 'the port is substituted into the URL'
    $script:FakeAnswer = " 0`n"; Assert-That ((Test-PortReachable -Config $pc -Port 1) -eq $false) 'answer 0 = closed (whitespace ignored)'
    $script:FakeAnswer = '<html>oops</html>'; Assert-That ($null -eq (Test-PortReachable -Config $pc -Port 1)) 'an odd answer = unknown'
    $script:FakeAnswer = $null; Assert-That ($null -eq (Test-PortReachable -Config $pc -Port 1)) 'no answer = unknown'

    $script:CheckedUrls.Clear(); $script:LogLines.Clear()
    $script:NextPortCheck = $null; $script:PortCheckedPort = $null; $script:PortReachable = $null; $script:PortCheckClosedCount = 0
    $t0 = [datetime]'2026-06-01T12:00:00Z'
    $cyc = New-Cycle
    Invoke-PortCheckIfDue -Config $cfgBase -Cycle $cyc -Now $t0
    Assert-That ($script:CheckedUrls.Count -eq 0) 'PortCheck=false never contacts the service'
    $script:FakeAnswer = '1'
    Invoke-PortCheckIfDue -Config $pc -Cycle $cyc -Now $t0
    Assert-That ($script:CheckedUrls.Count -eq 0) 'no check right after a (new) port: the mapping gets 2 minutes to settle'
    Invoke-PortCheckIfDue -Config $pc -Cycle $cyc -Now $t0.AddMinutes(2.1)
    Assert-That ($script:CheckedUrls.Count -eq 1 -and $script:PortReachable -eq $true) 'checked after 2 minutes: reachable'
    Invoke-PortCheckIfDue -Config $pc -Cycle $cyc -Now $t0.AddMinutes(10)
    Assert-That ($script:CheckedUrls.Count -eq 1) 'not checked again before PortCheckMinutes'
    $script:FakeAnswer = '0'
    Invoke-PortCheckIfDue -Config $pc -Cycle $cyc -Now $t0.AddMinutes(33)
    Assert-That ($script:CheckedUrls.Count -eq 2 -and $script:PortReachable -eq $true -and -not (Test-LogHas 'CLOSED')) 'one closed result alone is not reported'
    Invoke-PortCheckIfDue -Config $pc -Cycle $cyc -Now $t0.AddMinutes(36)
    Assert-That ($script:PortReachable -eq $false -and (Test-LogHas 'looks CLOSED')) 'two closed results in a row are reported'
    $script:FakeAnswer = $null; $before = $script:PortReachable
    Invoke-PortCheckIfDue -Config $pc -Cycle $cyc -Now $t0.AddMinutes(60)
    Assert-That ($script:PortReachable -eq $before) 'an unreachable check service never changes the result'
    $script:FakeAnswer = '1'
    Invoke-PortCheckIfDue -Config $pc -Cycle (New-Cycle -VpnPort 40404 -QbtPort 40404) -Now $t0.AddMinutes(61)
    Assert-That ($null -eq $script:PortReachable) 'a new port resets the result until it is checked again'
    $n = $script:CheckedUrls.Count
    Invoke-PortCheckIfDue -Config $pc -Cycle (New-Cycle -InSync $false) -Now $t0.AddMinutes(200)
    Assert-That ($script:CheckedUrls.Count -eq $n) 'nothing is checked while not in sync'

    # =========================================================================
    Write-Host 'Health checks'
    function New-Snap { param([hashtable]$Over = @{})
        $s = [pscustomobject]@{ Version = '9.9.9'; VpnIp = '203.0.113.5'
            Found = [pscustomobject]@{ Port = 51820 }; Verify = [pscustomobject]@{ Ok = $true; Tcp = $true; Udp = $true }
            QbtOk = $true; QbtError = $null; QbtPort = 51820; RandomPort = $false; Upnp = $false; Iface = 'ProtonVPN'
            PortReachable = $null; InSync = $true }
        foreach ($k in $Over.Keys) { $s.$k = $Over[$k] }
        return $s }
    function Levels { param($Items) return (@($Items | ForEach-Object { $_.Level }) -join ',') }
    function Has { param($Items, $Level, $Pattern) return (@($Items | Where-Object { $_.Level -eq $Level -and $_.Message -match $Pattern }).Count -gt 0) }
    function HintOf { param($Items, $Pattern) return (@($Items | Where-Object { $_.Message -match $Pattern } | ForEach-Object { $_.Hint }) -join ' ') }

    $r = Get-HealthChecks -Snap (New-Snap) -Config $cfgBase
    Assert-That (-not (@($r | Where-Object { $_.Level -in 'WARN', 'ERROR' }).Count) -and (Has $r 'OK' 'Everything looks fine')) 'a healthy setup reports no problems'
    $r = Get-HealthChecks -Snap (New-Snap @{ VpnIp = $null; Found = $null; InSync = $false; QbtPort = 40000 }) -Config $cfgBase
    Assert-That ((Has $r 'ERROR' 'does not appear to be connected') -and (HintOf $r 'does not appear' ) -match 'P2P server') 'VPN not connected: error with hint'
    $r = Get-HealthChecks -Snap (New-Snap @{ Found = $null; InSync = $false }) -Config $cfgBase
    Assert-That ((Has $r 'WARN' 'has not announced a forwarded port') -and (HintOf $r 'not announced') -match 'Port Forwarding') 'VPN up but no port: tells you to turn on Port Forwarding'
    $r = Get-HealthChecks -Snap (New-Snap @{ VpnIp = $null }) -Config $cfgBase
    Assert-That (Has $r 'WARN' 'gateway does not answer') 'port announced but gateway silent: warning'
    $r = Get-HealthChecks -Snap (New-Snap @{ Verify = [pscustomobject]@{ Ok = $false; Tcp = $true; Udp = $false } }) -Config $cfgBase
    Assert-That (Has $r 'WARN' 'did not confirm port 51820') 'unconfirmed port: warning'
    $r = Get-HealthChecks -Snap (New-Snap @{ QbtOk = $false; QbtPort = $null; InSync = $false; QbtError = 'qBittorrent WebAPI unreachable: refused' }) -Config $cfgBase
    Assert-That ((Has $r 'ERROR' 'Cannot reach qBittorrent at http://127.0.0.1:8080') -and (HintOf $r 'Cannot reach') -match 'Web UI') 'qBittorrent down: error mentions the address and the Web UI'
    $r = Get-HealthChecks -Snap (New-Snap @{ QbtOk = $false; QbtPort = $null; InSync = $false; QbtError = 'qBittorrent rejected the username/password (401)' }) -Config $cfgBase
    Assert-That ((Has $r 'ERROR' 'rejected the username') -and (HintOf $r 'rejected') -match 'Setup') 'wrong password: points to Setup'
    $r = Get-HealthChecks -Snap (New-Snap @{ QbtOk = $false; QbtPort = $null; InSync = $false; QbtError = 'qBittorrent has banned this IP (403)' }) -Config $cfgBase
    Assert-That ((Has $r 'ERROR' 'banned') -and (HintOf $r 'banned') -match 'Restart qBittorrent') 'banned: restart qBittorrent'
    $r = Get-HealthChecks -Snap (New-Snap @{ QbtOk = $false; QbtPort = $null; InSync = $false; QbtError = 'weird failure' }) -Config $cfgBase
    Assert-That (Has $r 'ERROR' 'weird failure') 'unknown error is passed through'
    $r = Get-HealthChecks -Snap (New-Snap @{ RandomPort = $true }) -Config $cfgBase
    Assert-That ((Has $r 'WARN' 'random port') -and (HintOf $r 'random port') -match 'untick') 'random port: warning with the exact option'
    $r = Get-HealthChecks -Snap (New-Snap @{ Upnp = $true }) -Config $cfgBase
    Assert-That (Has $r 'WARN' 'UPnP') 'UPnP: warning'
    $r = Get-HealthChecks -Snap (New-Snap @{ Iface = '' }) -Config $cfgBase
    Assert-That ((Has $r 'WARN' 'not bound to a network interface') -and (HintOf $r 'not bound') -match 'Network Interface') 'unbound interface: leak warning'
    $r = Get-HealthChecks -Snap (New-Snap @{ QbtPort = 40000; InSync = $false }) -Config $cfgBase
    Assert-That (Has $r 'WARN' 'listens on 40000 but the VPN forwards 51820') 'out of sync: both ports are named'
    $r = Get-HealthChecks -Snap (New-Snap @{ PortReachable = $false }) -Config $cfgBase
    Assert-That ((Has $r 'WARN' 'looks closed') -and (HintOf $r 'looks closed') -match 'Firewall') 'closed port: firewall hint'
    $r = Get-HealthChecks -Snap (New-Snap @{ PortReachable = $true }) -Config $cfgBase
    Assert-That (Has $r 'OK' 'reachable from the internet') 'open port: ok'

    # =========================================================================
    Write-Host 'Masking and support bundle'
    $m = ConvertTo-MaskedText -Text 'VPN IP 185.107.44.9 gateway 10.2.0.1 lan 192.168.1.20 loop 127.0.0.1 ranged 172.20.1.1 public 172.32.0.1 ok'
    Assert-That ($m -notmatch '185\.107\.44\.9' -and $m -notmatch '172\.32\.0\.1') 'public IPv4 addresses are masked'
    Assert-That ($m -match '10\.2\.0\.1' -and $m -match '192\.168\.1\.20' -and $m -match '127\.0\.0\.1' -and $m -match '172\.20\.1\.1') 'private addresses (incl. the Proton gateway) stay readable'
    $fakeProfile = Join-Path $tmp 'userprofile'
    $savedProfile = $env:USERPROFILE; $env:USERPROFILE = $fakeProfile
    Assert-That ((ConvertTo-MaskedText -Text "$fakeProfile\Scripts\hook.cmd") -eq '%USERPROFILE%\Scripts\hook.cmd') 'the profile path is replaced'
    $env:USERPROFILE = $savedProfile

    $remote = $cfgBase.PSObject.Copy(); $remote.WebUiUrl = 'http://nas.home.example:9090'; $remote.Username = 'alex'
    $mj = Get-MaskedConfigJson -Config $remote
    Assert-That ($mj -notmatch 'SECRETBLOB' -and $mj -match '\(removed\)') 'password blob is removed from the config copy'
    Assert-That ($mj -notmatch 'alex' -and $mj -match '\(set\)') 'user name is hidden'
    Assert-That ($mj -notmatch 'nas\.home\.example' -and $mj -match '\(remote-host\):9090') 'a remote Web UI host is hidden'
    Assert-That ((Get-MaskedConfigJson -Config $cfgBase) -match '127\.0\.0\.1:8080') 'a local Web UI address stays readable'

    $data = Join-Path $tmp 'data'; New-Item -ItemType Directory -Path $data | Out-Null
    $cfgPath = Join-Path $data 'config.json'
    Set-Content -LiteralPath $cfgPath -Value '{}'
    $logLines = 1..1500 | ForEach-Object { "2026-06-01 12:00:00 [INFO] line $_ VPN IP 185.107.44.9" }
    Set-Content -LiteralPath (Join-Path $data 'ProtonPortSync.log') -Value $logLines
    Set-Content -LiteralPath (Join-Path $data 'status.json') -Value '{"state":"in_sync"}'
    $out = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $out | Out-Null
    $zip = New-SupportBundle -Config $remote -Snap (New-Snap) -ConfigPath $cfgPath -OutDir $out
    Assert-That ((Test-Path -LiteralPath $zip) -and ($zip -like '*ProtonPortSync-support-*.zip')) 'a zip is created in the output folder'
    $x = Join-Path $tmp 'unzipped'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $x)
    $names = @(Get-ChildItem -LiteralPath $x -File | ForEach-Object { $_.Name } | Sort-Object)
    Assert-That (($names -contains 'report.txt') -and ($names -contains 'config.json') -and ($names -contains 'ProtonPortSync.log') -and ($names -contains 'status.json')) "expected files are inside ($($names -join ', '))"
    $all = (Get-ChildItem -LiteralPath $x -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    Assert-That ($all -notmatch '185\.107\.44\.9') 'no public IP address anywhere in the bundle'
    Assert-That ($all -notmatch 'SECRETBLOB') 'no password material in the bundle'
    $logCopy = @(Get-Content -LiteralPath (Join-Path $x 'ProtonPortSync.log'))
    Assert-That ($logCopy.Count -eq 1000 -and $logCopy[-1] -match 'line 1500') 'only the last 1000 log lines are included'
    Assert-That ((Get-Content -LiteralPath (Join-Path $x 'report.txt') -Raw) -match 'Everything looks fine') 'the report contains the health checks'
    $fallback = New-SupportBundle -Config $remote -Snap (New-Snap) -ConfigPath $cfgPath -OutDir (Join-Path $tmp 'does-not-exist')
    Assert-That ((Split-Path -Parent $fallback) -eq $data) 'a missing output folder falls back to the data folder'

    # =========================================================================
    Write-Host 'Main script integration'
    . (Join-Path $PSScriptRoot 'ProtonPortSync.ps1') -ConfigPath $cfgPath -Once
    # (dot-sourcing replaced the stand-ins above with the real ones: re-create the test doubles)
    $script:LogLines = New-Object System.Collections.ArrayList
    function Write-Log { param([string]$Message, [string]$Level = 'INFO', [switch]$Force) [void]$script:LogLines.Add("$Level $Message") }
    Assert-That ($script:ToolsLoaded) 'the main script loads ProtonPortSync.Tools.ps1'
    Assert-That ($script:Version -match '^\d+\.\d+\.\d+$') "main script version is $script:Version"

    $script:Port = 51820; $script:QbtListen = 40000; $script:QbtThrows = $null; $script:SetCalls = 0; $script:Hooked = $null
    function Get-ProtonReservedPort { param($Config) if ($null -eq $script:Port) { return $null }
        [pscustomobject]@{ Port = $script:Port; InternalPort = $script:Port; TimestampUtc = [datetime]::UtcNow; SourceFile = 'x' } }
    function Test-PortForwarded { param($Config, [int]$Port) [pscustomobject]@{ Tcp = $true; Udp = $true; Ok = $true } }
    function Get-VpnPublicIp { param($Config) '203.0.113.5' }
    function Get-QbtConnection { param($Config, [switch]$ForceRefresh) if ($script:QbtThrows) { throw $script:QbtThrows }; [pscustomobject]@{ Base = 'x'; Session = $null } }
    function Get-QbtListenPort { param($Qbt) [pscustomobject]@{ ListenPort = $script:QbtListen; RandomPort = $false; Upnp = $false; NatPmp = $false; Interface = 'ProtonVPN' } }
    function Set-QbtListenPort { param($Qbt, [int]$Port) $script:SetCalls++; $script:QbtListen = $Port }
    function Save-Config { param($Config) }
    function Invoke-PortChangeHook { param($Config, [int]$OldPort, [int]$NewPort) $script:Hooked = "$OldPort->$NewPort" }
    $script:LastDetectedPort = $null; $script:AuthFailedStamp = $null
    $live = [pscustomobject]@{ WebUiUrl = 'http://127.0.0.1:8080'; Username = 'a'; LastAppliedPort = 0 }

    $ok = Invoke-SyncCycle -Config $live
    Assert-That ($ok -eq $true -and $script:Cycle.State -eq 'in_sync' -and $script:Cycle.InSync -and $script:Cycle.VpnPort -eq 51820 -and $script:Cycle.QbtPort -eq 51820) 'a port change ends in_sync with both ports recorded'
    Assert-That ($script:Hooked -eq '40000->51820') 'the hook is called with old and new port after a change'
    Assert-That ($script:LastPortChangeUtc -match '^\d{4}-') 'the time of the change is remembered'
    $script:Hooked = $null
    $ok = Invoke-SyncCycle -Config $live
    Assert-That ($ok -eq $true -and $null -eq $script:Hooked -and $script:SetCalls -eq 1) 'no hook and no write when nothing changed'

    $script:Port = $null
    $ok = Invoke-SyncCycle -Config $live
    Assert-That ($ok -eq $false -and $script:Cycle.State -eq 'vpn_down' -and -not $script:Cycle.VpnConnected) 'no announcement -> vpn_down'
    $script:Port = 51820
    $script:QbtThrows = 'qBittorrent WebAPI unreachable: refused'
    $ok = Invoke-SyncCycle -Config $live
    Assert-That ($ok -eq $false -and $script:Cycle.State -eq 'qbt_unreachable' -and $script:Cycle.Error -match 'unreachable') 'qBittorrent down -> qbt_unreachable with the message'
    $script:QbtThrows = 'qBittorrent rejected the username/password (401).'
    $ok = Invoke-SyncCycle -Config $live
    Assert-That ($ok -eq $false -and $script:Cycle.State -eq 'auth_failed') 'wrong password -> auth_failed'
    $script:QbtThrows = 'qBittorrent has banned this IP (403).'
    $script:AuthFailedStamp = $null
    $ok = Invoke-SyncCycle -Config $live
    Assert-That ($ok -eq $false -and $script:Cycle.State -eq 'qbt_banned') 'banned -> qbt_banned'

    $script:QbtThrows = $null
    $cfgForSnap = $cfgBase.PSObject.Copy()
    function New-QbtSession { param($Config) [pscustomobject]@{ Base = 'x'; Session = $null } }
    $snap = Get-StatusSnapshot -Config $cfgForSnap
    Assert-That ($snap.QbtOk -and $snap.InSync -and $snap.Iface -eq 'ProtonVPN' -and $snap.Found.Port -eq 51820) 'the status snapshot gathers VPN and qBittorrent state'
    Assert-That (@(Get-HealthChecks -Snap $snap -Config $cfgForSnap | Where-Object { $_.Level -in 'WARN', 'ERROR' }).Count -eq 0) '... and a healthy snapshot has no problems'
}
finally {
    $env:LOCALAPPDATA = $savedLocal
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
