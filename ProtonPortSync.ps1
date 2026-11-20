#Requires -Version 5.1
<#
.SYNOPSIS
    ProtonVPN -> qBittorrent port synchronizer.

.DESCRIPTION
    ProtonVPN reserves exactly ONE externally reachable port per VPN session.
    That port is not freely choosable: asking NAT-PMP for any other port returns
    a mapping that ProtonVPN does not actually forward. So the port must be
    DISCOVERED, then pushed into qBittorrent's listen_port via the WebAPI.

    Discovery order:
      1. ProtonVPN client log  ("Port pair <external>-><internal>")
      2. NAT-PMP confirmation against the VPN gateway (10.2.0.1:5351)
         The NAT-PMP map request also refreshes the lease for both TCP and UDP.

.PARAMETER Once
    Run a single detection/sync cycle and exit (useful for testing).

.PARAMETER Status
    Print current status (detected port, qBittorrent port, VPN state) and exit.

.PARAMETER IntervalSeconds
    Poll interval for the background loop. Default 20.

.EXAMPLE
    .\ProtonPortSync.ps1 -Once
.EXAMPLE
    .\ProtonPortSync.ps1 -Status
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'ProtonPortSync\config.json'),
    [int]$IntervalSeconds = 20,
    [switch]$Once,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Get-DefaultConfig {
    [pscustomobject]@{
        WebUiUrl          = 'http://127.0.0.1:8080'
        Username          = 'admin'
        PasswordProtected = ''            # base64 DPAPI blob, never plaintext
        LogDirectory      = ''            # empty = auto-detect
        NatPmpGateway     = '10.2.0.1'
        NatPmpPort        = 5351
        IntervalSeconds   = 20
        LastAppliedPort   = 0
    }
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config not found: $ConfigPath. Run ProtonPortSync.Setup.ps1 first."
    }
    $raw = Get-Content -LiteralPath $ConfigPath -Raw
    $cfg = $raw | ConvertFrom-Json
    $def = Get-DefaultConfig
    foreach ($p in $def.PSObject.Properties) {
        if ($null -eq $cfg.PSObject.Properties[$p.Name]) {
            $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
    }
    return $cfg
}

function Save-Config {
    param($Config)
    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Protect-String {
    param([string]$Plain)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Plain)
    $blob  = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'CurrentUser')
    return [Convert]::ToBase64String($blob)
}

function Unprotect-String {
    param([string]$Blob)
    if ([string]::IsNullOrWhiteSpace($Blob)) { return '' }
    $bytes = [Convert]::FromBase64String($Blob)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser')
    return [Text.Encoding]::UTF8.GetString($plain)
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$script:LogFile = Join-Path (Split-Path -Parent $ConfigPath) 'ProtonPortSync.log'
$script:Quiet   = $false   # background loop sets this so it never spams a console
$script:QbtSession = $null # cached WebAPI session, re-created only when it expires

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO',
        [switch]$Force
    )
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # Suppress identical consecutive messages so a steady state does not flood the log.
    $key = "$Level|$Message"
    if (-not $Force -and ($key -eq $script:LastLogKey)) { return }
    $script:LastLogKey = $key
    if (-not $script:Quiet) { Write-Host $line }
    try {
        $dir = Split-Path -Parent $script:LogFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $script:LogFile) -and
            (Get-Item -LiteralPath $script:LogFile).Length -gt 1MB) {
            Move-Item -LiteralPath $script:LogFile -Destination "$script:LogFile.old" -Force
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
# ProtonVPN log parsing
# ---------------------------------------------------------------------------

function Get-ProtonLogDirectory {
    param($Config)
    if ($Config.LogDirectory -and (Test-Path -LiteralPath $Config.LogDirectory)) {
        return $Config.LogDirectory
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Proton\Proton VPN\Logs'),
        (Join-Path $env:APPDATA      'Proton\Proton VPN\Logs'),
        (Join-Path $env:LOCALAPPDATA 'ProtonVPN\Logs')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    # Last resort: search under the user profile for a folder named "Proton VPN\Logs".
    $hit = Get-ChildItem -Path $env:LOCALAPPDATA -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -like '*Proton VPN\Logs' } |
           Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function ConvertFrom-ProtonTimestamp {
    param([string]$Value)
    # e.g. 2026-11-20T16:27:37.103Z  -> UTC DateTime
    $clean = $Value.Trim()
    if ($clean -match '\.(\d{1,7})Z$') {
        # .NET accepts max 7 fractional digits; Proton logs 3, keep it safe anyway
        $clean = $clean -replace '\.(\d{1,7})Z$', '.$1Z'
    }
    return [datetime]::Parse($clean, [Globalization.CultureInfo]::InvariantCulture,
                             [Globalization.DateTimeStyles]'AdjustToUniversal,AssumeUniversal')
}

function Get-ProtonReservedPort {
    <#
        Returns the most recent port pair ProtonVPN announced, or $null.
        Object: Port (external), InternalPort, TimestampUtc, SourceFile
    #>
    param($Config)

    $dir = Get-ProtonLogDirectory -Config $Config
    if (-not $dir) {
        Write-Log 'ProtonVPN log directory not found.' 'WARN'
        return $null
    }

    $files = Get-ChildItem -LiteralPath $dir -Filter 'client-logs*.txt' -File -ErrorAction SilentlyContinue
    if (-not $files) {
        Write-Log "No client-logs*.txt in '$dir'." 'WARN'
        return $null
    }

    $best = $null
    foreach ($f in $files) {
        # Tail is enough: the newest announcement is always near the end.
        $lines = Get-Content -LiteralPath $f.FullName -Tail 800 -ErrorAction SilentlyContinue
        if (-not $lines) { continue }

        foreach ($line in $lines) {
            $m = [regex]::Match($line, '^(\d{4}-\d{2}-\d{2}T[0-9:.]+Z).*Port pair (\d+)->(\d+)')
            if (-not $m.Success) { continue }

            try { $ts = ConvertFrom-ProtonTimestamp $m.Groups[1].Value } catch { continue }
            $ext = [int]$m.Groups[2].Value
            $int = [int]$m.Groups[3].Value
            if ($ext -lt 1 -or $ext -gt 65535) { continue }

            if (-not $best -or $ts -gt $best.TimestampUtc) {
                $best = [pscustomobject]@{
                    Port         = $ext
                    InternalPort = $int
                    TimestampUtc = $ts
                    SourceFile   = $f.FullName
                }
            }
        }
    }

    return $best
}

# ---------------------------------------------------------------------------
# NAT-PMP (RFC 6886) - ProtonVPN gateway
# ---------------------------------------------------------------------------

function Send-NatPmpRequest {
    <#
        Opcode 0 = external address, 1 = map TCP, 2 = map UDP.
        Returns $null on timeout / error / non-zero result code.
    #>
    param(
        [ValidateSet(0,1,2)][int]$Opcode,
        [int]$InternalPort = 0,
        [int]$SuggestedPort = 0,
        [int]$Lifetime = 60,
        [int]$TimeoutMs = 2500,
        [string]$Gateway,
        [int]$GatewayPort
    )

    $req = New-Object byte[] 12
    $req[0] = 0
    $req[1] = [byte]$Opcode
    $req[2] = 0; $req[3] = 0
    $req[4] = [byte](($InternalPort  -shr 8) -band 0xFF)
    $req[5] = [byte]($InternalPort   -band 0xFF)
    $req[6] = [byte](($SuggestedPort -shr 8) -band 0xFF)
    $req[7] = [byte]($SuggestedPort  -band 0xFF)
    $req[8]  = [byte](($Lifetime -shr 24) -band 0xFF)
    $req[9]  = [byte](($Lifetime -shr 16) -band 0xFF)
    $req[10] = [byte](($Lifetime -shr 8)  -band 0xFF)
    $req[11] = [byte]($Lifetime -band 0xFF)

    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Gateway, $GatewayPort)
        [void]$udp.Send($req, $req.Length)

        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
    }
    catch {
        return $null          # gateway unreachable => VPN down or NAT-PMP blocked
    }
    finally {
        if ($udp) { $udp.Dispose() }
    }

    if (-not $resp -or $resp.Length -lt 12) { return $null }

    $result = ([int]$resp[2] -shl 8) -bor [int]$resp[3]
    if ($result -ne 0) { return $null }

    $out = [pscustomobject]@{
        ResultCode = $result
        ExternalIp = $null
        InternalPort = 0
        ExternalPort = 0
        Lifetime = 0
    }

    if ($Opcode -eq 0) {
        $out.ExternalIp = '{0}.{1}.{2}.{3}' -f $resp[8], $resp[9], $resp[10], $resp[11]
    }
    elseif ($resp.Length -ge 16) {
        $out.InternalPort = ([int]$resp[8]  -shl 8) -bor [int]$resp[9]
        $out.ExternalPort = ([int]$resp[10] -shl 8) -bor [int]$resp[11]
        $out.Lifetime     = ([int]$resp[12] -shl 24) -bor ([int]$resp[13] -shl 16) -bor
                            ([int]$resp[14] -shl 8)  -bor [int]$resp[15]
    }
    return $out
}

function Test-PortForwarded {
    <#
        Confirms (and refreshes) the mapping for $Port on both TCP and UDP.
        Returns $true only when the gateway echoes back the SAME external port,
        which is the signature of ProtonVPN's real forwarded port.
    #>
    param($Config, [int]$Port)

    $tcp = Send-NatPmpRequest -Opcode 1 -InternalPort $Port -SuggestedPort $Port -Lifetime 60 `
                              -Gateway $Config.NatPmpGateway -GatewayPort ([int]$Config.NatPmpPort)
    $udp = Send-NatPmpRequest -Opcode 2 -InternalPort $Port -SuggestedPort $Port -Lifetime 60 `
                              -Gateway $Config.NatPmpGateway -GatewayPort ([int]$Config.NatPmpPort)

    $tcpOk = ($tcp -and $tcp.ExternalPort -eq $Port)
    $udpOk = ($udp -and $udp.ExternalPort -eq $Port)
    return [pscustomobject]@{ Tcp = $tcpOk; Udp = $udpOk; Ok = ($tcpOk -and $udpOk) }
}

function Get-VpnPublicIp {
    param($Config)
    $r = Send-NatPmpRequest -Opcode 0 -Gateway $Config.NatPmpGateway -GatewayPort ([int]$Config.NatPmpPort)
    if ($r) { return $r.ExternalIp }
    return $null
}

# ---------------------------------------------------------------------------
# qBittorrent WebAPI
# ---------------------------------------------------------------------------

function New-QbtSession {
    <#
        Authentication notes (verified against qBittorrent 5.2.3 source):

        * CSRF: WebApplication::isCrossOriginRequest() returns false when BOTH the
          Origin and Referer headers are absent ("lets be permissive here"), which is
          the supported path for Web API clients. Sending a header risks a mismatch.
        * Login success: AuthController::loginAction() calls setStatus(Ok) with no
          result, so modern qBittorrent replies HTTP 200 with an EMPTY body. Older
          versions replied "Ok." - both are accepted here.
        * Wrong password: HTTP 401. Too many failures: HTTP 403 "banned".
    #>
    param($Config)
    $base = $Config.WebUiUrl.TrimEnd('/')
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $password = Unprotect-String $Config.PasswordProtected

    try {
        $resp = Invoke-WebRequest -Uri "$base/api/v2/auth/login" -Method Post `
                    -Body @{ username = $Config.Username; password = $password } `
                    -WebSession $session -UseBasicParsing -TimeoutSec 8
    }
    catch [System.Net.WebException] {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }

        if ($code -eq 401) {
            throw 'qBittorrent rejected the username/password (401 Unauthorized).'
        }
        if ($code -eq 403) {
            $text = ''
            try {
                $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $text = $sr.ReadToEnd()
            } catch { }
            if ($text -match 'banned') {
                throw 'qBittorrent has banned this IP after repeated failed logins. Restart qBittorrent (clears the in-memory ban) or wait for the ban to expire.'
            }
            throw "qBittorrent refused the request (403). $text"
        }
        throw "qBittorrent WebAPI unreachable: $($_.Exception.Message)"
    }

    if ($resp.Content -and ($resp.Content -notmatch '^Ok\.')) {
        throw "Unexpected login response from qBittorrent: '$($resp.Content)'"
    }

    # Definitive check: an authenticated endpoint must answer with this session.
    $verify = Invoke-WebRequest -Uri "$base/api/v2/app/version" -WebSession $session `
                                -UseBasicParsing -TimeoutSec 8
    if ($verify.StatusCode -ne 200) {
        throw 'Login did not establish an authenticated session.'
    }

    return [pscustomobject]@{ Base = $base; Session = $session }
}

function Get-QbtConnection {
    <#
        Returns a cached authenticated session. qBittorrent keeps sessions alive for
        about an hour, so reusing one avoids a login every poll (and keeps the
        qBittorrent log clean). Callers re-authenticate on 401/403.
    #>
    param($Config, [switch]$ForceRefresh)
    if ($ForceRefresh -or -not $script:QbtSession) {
        $script:QbtSession = New-QbtSession -Config $Config
    }
    return $script:QbtSession
}

function Get-QbtListenPort {
    param($Qbt)
    $r = Invoke-WebRequest -Uri "$($Qbt.Base)/api/v2/app/preferences" -WebSession $Qbt.Session `
                           -UseBasicParsing -TimeoutSec 8
    $prefs = $r.Content | ConvertFrom-Json
    return [pscustomobject]@{
        ListenPort = [int]$prefs.listen_port
        RandomPort = [bool]$prefs.random_port
        Upnp       = [bool]$prefs.upnp
        NatPmp     = ([bool]$prefs.PSObject.Properties['natpmp'] -and [bool]$prefs.natpmp)
    }
}

function Set-QbtListenPort {
    param($Qbt, [int]$Port)
    $json = ConvertTo-Json @{ listen_port = $Port } -Compress
    $body = @{ json = $json }
    Invoke-WebRequest -Uri "$($Qbt.Base)/api/v2/app/setPreferences" -Method Post -Body $body `
                      -WebSession $Qbt.Session -UseBasicParsing -TimeoutSec 8 | Out-Null
}

# ---------------------------------------------------------------------------
# Sync cycle
# ---------------------------------------------------------------------------

function Invoke-SyncCycle {
    param($Config)

    $found = Get-ProtonReservedPort -Config $Config
    if (-not $found) {
        Write-Log 'No ProtonVPN port announcement found - is the VPN connected?' 'WARN'
        return $false
    }

    $age = [int](([datetime]::UtcNow) - $found.TimestampUtc).TotalSeconds
    $fresh = ($age -ge -120 -and $age -le 300)   # Proton re-announces every ~60s

    $verify = Test-PortForwarded -Config $Config -Port $found.Port
    $vpnIp  = Get-VpnPublicIp -Config $Config

    if (-not $verify.Ok) {
        if (-not $fresh) {
            Write-Log ("Port {0} could not be verified (TCP={1} UDP={2}) and the log entry is {3}s old. Skipping." -f
                       $found.Port, $verify.Tcp, $verify.Udp, $age) 'WARN'
            return $false
        }
        Write-Log ("Port {0} not confirmed by NAT-PMP (TCP={1} UDP={2}); log entry is fresh ({3}s). Proceeding." -f
                   $found.Port, $verify.Tcp, $verify.Udp, $age) 'WARN'
    }

    if ($script:LastDetectedPort -ne $found.Port) {
        $script:LastDetectedPort = $found.Port
        Write-Log ("Detected ProtonVPN port {0} (internal {1}, VPN IP {2})" -f
                   $found.Port, $found.InternalPort, $(if ($vpnIp) { $vpnIp } else { 'unknown' }))
    }

    # --- qBittorrent -------------------------------------------------------
    $qbt = $null
    try {
        $qbt = Get-QbtConnection -Config $Config
        try {
            $current = Get-QbtListenPort -Qbt $qbt
        }
        catch {
            # Session expired, or qBittorrent was restarted: re-authenticate once.
            $script:QbtSession = $null
            $qbt = Get-QbtConnection -Config $Config
            $current = Get-QbtListenPort -Qbt $qbt
        }

        if ($current.RandomPort) {
            Write-Log 'qBittorrent has "random_port" enabled - it may override this sync. Consider disabling it.' 'WARN'
        }

        if ($current.ListenPort -eq $found.Port) {
            Write-Log ("qBittorrent already listens on {0}; nothing to do." -f $found.Port) 'OK'
        }
        else {
            Set-QbtListenPort -Qbt $qbt -Port $found.Port
            Start-Sleep -Milliseconds 400
            $after = Get-QbtListenPort -Qbt $qbt
            if ($after.ListenPort -eq $found.Port) {
                Write-Log ("Updated qBittorrent listen_port {0} -> {1}" -f $current.ListenPort, $found.Port) 'OK'
            }
            else {
                Write-Log ("qBittorrent did not accept the new port (still {0})." -f $after.ListenPort) 'ERROR'
                return $false
            }
        }

        if ($Config.LastAppliedPort -ne $found.Port) {
            $Config.LastAppliedPort = $found.Port
            Save-Config -Config $Config
        }
        return $true
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'banned') {
            # Do not hammer the endpoint: stay away for 5 minutes.
            $script:BanBackoffUntil = (Get-Date).AddMinutes(5)
            Write-Log $msg 'ERROR'
        }
        elseif ($msg -match 'rejected the username|Unexpected login') {
            Write-Log $msg 'ERROR'
        }
        elseif ($msg -match 'unreachable|Unable to connect|refused|timed out') {
            Write-Log $msg 'WARN'
        }
        else {
            Write-Log "qBittorrent sync failed: $msg" 'ERROR'
        }
        return $false
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function Show-Status {
    param($Config)
    $found = Get-ProtonReservedPort -Config $Config
    $vpnIp = Get-VpnPublicIp -Config $Config

    Write-Host ''
    Write-Host '  ProtonVPN -> qBittorrent status' -ForegroundColor Cyan
    Write-Host '  --------------------------------'
    Write-Host ("  VPN reachable      : {0}" -f $(if ($vpnIp) { "yes ($vpnIp)" } else { 'no' }))
    if ($found) {
        $age = [int](([datetime]::UtcNow) - $found.TimestampUtc).TotalSeconds
        $verify = Test-PortForwarded -Config $Config -Port $found.Port
        Write-Host ("  VPN forwarded port : {0} (log age {1}s, internal {2})" -f $found.Port, $age, $found.InternalPort)
        Write-Host ("  NAT-PMP confirm    : TCP={0} UDP={1}" -f $verify.Tcp, $verify.Udp)
    } else {
        Write-Host '  VPN forwarded port : not found'
    }
    try {
        $qbt = New-QbtSession -Config $Config
        $cur = Get-QbtListenPort -Qbt $qbt
        Write-Host ("  qBittorrent port   : {0}" -f $cur.ListenPort)
        if ($found -and $cur.ListenPort -eq $found.Port) {
            Write-Host '  Sync               : IN SYNC' -ForegroundColor Green
        } else {
            Write-Host '  Sync               : OUT OF SYNC' -ForegroundColor Yellow
        }
    } catch {
        Write-Host ("  qBittorrent        : error - {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host ''
}

function Invoke-Main {
    try {
        $config = Get-Config

        if ($Status) {
            Show-Status -Config $config
            return
        }

        if ($Once) {
            Write-Log 'Running single sync cycle.'
            return (Invoke-SyncCycle -Config $config)
        }

        # --- background loop -----------------------------------------------
        $mutex = New-Object System.Threading.Mutex($false, 'Global\ProtonPortSync')
        if (-not $mutex.WaitOne(0)) {
            Write-Log 'Another instance is already running. Exiting.' 'WARN'
            return
        }

        $interval = if ($IntervalSeconds -gt 0) { $IntervalSeconds } else { [int]$config.IntervalSeconds }
        if ($interval -lt 5) { $interval = 5 }

        Write-Log "ProtonPortSync started (interval ${interval}s, WebUI $($config.WebUiUrl))."

        $script:Quiet = $true   # from here on, log to file only

        $lastHeartbeat = Get-Date
        while ($true) {
            $inSync = Invoke-SyncCycle -Config $config

            # Heartbeat every 30 minutes so "no log output" never looks like a dead service.
            if (((Get-Date) - $lastHeartbeat).TotalMinutes -ge 30) {
                $lastHeartbeat = Get-Date
                $state = if ($inSync) { 'in sync' } else { 'NOT in sync' }
                Write-Log ("Heartbeat: service alive, {0} (port {1})" -f $state, $config.LastAppliedPort) -Force
            }

            $wait = $interval
            if ($script:BanBackoffUntil -and (Get-Date) -lt $script:BanBackoffUntil) {
                $wait = [int](([datetime]$script:BanBackoffUntil - (Get-Date)).TotalSeconds)
                if ($wait -lt 30) { $wait = 30 }
            }
            Start-Sleep -Seconds $wait
        }
    }
    catch {
        Write-Log "Fatal: $($_.Exception.Message)" 'ERROR'
        Write-Host "Fatal: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Only start when executed directly; dot-sourcing loads the functions for tests.
if ($MyInvocation.InvocationName -ne '.') {
    $mainResult = Invoke-Main
    if ($mainResult -eq $false) { exit 1 }
}
