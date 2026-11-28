# ProtonPortSync.Tools.ps1
#
# Helpers used by ProtonPortSync.ps1 (dot-sourced; the engine also works without this file):
#   - status.json            machine-readable state for scripts, widgets, monitoring
#   - OnPortChange hook      run your own script when the forwarded port changes
#   - port reachability      optional "is the port really open from the internet?" check
#   - health checks          plain-language problems with a fix hint for each
#   - support bundle         one zip with logs/settings (secrets and public IPs removed)
#
# These functions use Write-Log and $script:Version from the main script.

# ---------------------------------------------------------------------------
# status.json
# ---------------------------------------------------------------------------

function Get-StatusFilePath {
    param([string]$ConfigPath)
    return (Join-Path (Split-Path -Parent $ConfigPath) 'status.json')
}

function Write-StatusFile {
    <#
        Writes the current state as JSON. To avoid needless disk writes it only rewrites the
        file when something other than the timestamp changed, or every 5 minutes.
    #>
    param($Config, $Cycle, [string]$Path, [switch]$Force)

    if ($null -ne $Config.PSObject.Properties['StatusFile'] -and -not $Config.StatusFile) { return }
    if (-not $Cycle) { return }

    $data = [ordered]@{
        version           = [string]$script:Version
        state             = [string]$Cycle.State
        inSync            = [bool]$Cycle.InSync
        vpnConnected      = [bool]$Cycle.VpnConnected
        forwardedPort     = $Cycle.VpnPort
        qbittorrentPort   = $Cycle.QbtPort
        lastPortChangeUtc = $script:LastPortChangeUtc
        lastError         = $Cycle.Error
        portReachable     = $script:PortReachable
        portCheckedUtc    = $script:PortCheckedUtc
    }
    $signature = ($data | ConvertTo-Json -Compress)
    $now = [datetime]::UtcNow
    if (-not $Force -and $signature -eq $script:StatusSignature -and $script:StatusWrittenAt -and
        (($now - $script:StatusWrittenAt).TotalMinutes -lt 5)) { return }

    $data['updatedUtc'] = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    try {
        $tmp = "$Path.tmp"
        ($data | ConvertTo-Json) | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        $script:StatusSignature = $signature
        $script:StatusWrittenAt = $now
    } catch { }
}

# ---------------------------------------------------------------------------
# OnPortChange hook
# ---------------------------------------------------------------------------

function Get-HookCommandLine {
    <# Maps a hook file to the program + arguments that run it. Returns $null if unsupported. #>
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.ps1' { return [pscustomobject]@{ File = 'powershell.exe'
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Path`"" } }
        '.cmd' { return [pscustomobject]@{ File = 'cmd.exe'; Arguments = "/d /c `"`"$Path`"`"" } }
        '.bat' { return [pscustomobject]@{ File = 'cmd.exe'; Arguments = "/d /c `"`"$Path`"`"" } }
        '.exe' { return [pscustomobject]@{ File = $Path; Arguments = '' } }
        default { return $null }
    }
}

function Start-HookProcess {
    <# Runs the hook hidden and waits up to $TimeoutMs. Returns the exit code, or $null on timeout. #>
    param([string]$File, [string]$Arguments, [int]$TimeoutMs = 15000)
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    if ($p.WaitForExit($TimeoutMs)) { return $p.ExitCode }
    try { $p.Kill() } catch { }
    return $null
}

function Invoke-PortChangeHook {
    <#
        Runs the program named in the OnPortChange setting after qBittorrent has been given a new
        port. Information is passed in environment variables (no command-line parsing):
            PPS_EVENT=port_changed  PPS_NEW_PORT  PPS_OLD_PORT  PPS_VERSION
    #>
    param($Config, [int]$OldPort, [int]$NewPort)

    $raw = $null
    if ($null -ne $Config.PSObject.Properties['OnPortChange']) { $raw = [string]$Config.OnPortChange }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $path = $raw.Trim().Trim('"')

    if (-not [IO.Path]::IsPathRooted($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Log "OnPortChange: file not found: $path (give the full path to a .ps1, .cmd, .bat or .exe file)." 'WARN'
        return
    }
    $cmd = Get-HookCommandLine -Path $path
    if (-not $cmd) {
        Write-Log "OnPortChange: unsupported file type: $path (use .ps1, .cmd, .bat or .exe)." 'WARN'
        return
    }

    $names = 'PPS_EVENT', 'PPS_NEW_PORT', 'PPS_OLD_PORT', 'PPS_VERSION'
    $values = 'port_changed', "$NewPort", "$OldPort", "$script:Version"
    try {
        for ($i = 0; $i -lt $names.Count; $i++) {
            [Environment]::SetEnvironmentVariable($names[$i], $values[$i], 'Process')
        }
        $code = Start-HookProcess -File $cmd.File -Arguments $cmd.Arguments
        if ($null -eq $code) { Write-Log "OnPortChange: $path did not finish within 15 seconds and was stopped." 'WARN' }
        elseif ($code -ne 0) { Write-Log "OnPortChange: $path exited with code $code." 'WARN' }
        else { Write-Log "OnPortChange: ran $path." 'INFO' }
    }
    catch {
        Write-Log "OnPortChange: could not run $path - $($_.Exception.Message)" 'WARN'
    }
    finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
    }
}

# ---------------------------------------------------------------------------
# Port reachability (optional, off by default)
# ---------------------------------------------------------------------------

function Get-PortCheckText {
    param([string]$Url)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
        $c = $r.Content
        if ($c -is [byte[]]) { $c = [Text.Encoding]::ASCII.GetString($c) }
        return [string]$c
    } catch { return $null }
}

function Test-PortReachable {
    <# $true = open, $false = closed, $null = unknown (service unavailable or odd answer). #>
    param($Config, [int]$Port)
    $template = 'https://portcheck.transmissionbt.com/{port}'
    if ($null -ne $Config.PSObject.Properties['PortCheckUrl'] -and $Config.PortCheckUrl) {
        $template = [string]$Config.PortCheckUrl
    }
    $url = $template -replace '\{port\}', [string]$Port
    $text = Get-PortCheckText -Url $url
    if ($null -eq $text) { return $null }
    switch ($text.Trim()) {
        '1' { return $true }
        '0' { return $false }
        default { return $null }
    }
}

function Invoke-PortCheckIfDue {
    <#
        Checks every PortCheckMinutes (default 30), starting 2 minutes after a port change so the
        mapping can settle. Only warns, never changes anything. "Closed" is reported after two
        closed results in a row; an unreachable check service is never reported as closed.
    #>
    param($Config, $Cycle, [datetime]$Now = [datetime]::UtcNow)

    if ($null -eq $Config.PSObject.Properties['PortCheck'] -or -not $Config.PortCheck) { return }
    if (-not $Cycle -or -not $Cycle.InSync -or -not $Cycle.VpnPort) {
        $script:PortCheckClosedCount = 0
        return
    }
    $port = [int]$Cycle.VpnPort
    if ($script:PortCheckedPort -ne $port) {            # new port: look again soon
        $script:PortCheckedPort = $port
        $script:PortReachable = $null
        $script:PortCheckClosedCount = 0
        $script:NextPortCheck = $Now.AddMinutes(2)
    }
    if (-not $script:NextPortCheck) { $script:NextPortCheck = $Now.AddMinutes(2) }
    if ($Now -lt $script:NextPortCheck) { return }

    $minutes = 30
    if ($null -ne $Config.PSObject.Properties['PortCheckMinutes'] -and [int]$Config.PortCheckMinutes -gt 0) {
        $minutes = [Math]::Max(5, [int]$Config.PortCheckMinutes)
    }
    $script:NextPortCheck = $Now.AddMinutes($minutes)

    $result = Test-PortReachable -Config $Config -Port $port
    $script:PortCheckedUtc = $Now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    if ($result -eq $true) {
        $script:PortCheckClosedCount = 0
        $script:PortReachable = $true
        Write-Log "Port $port is reachable from the internet." 'OK'
    }
    elseif ($result -eq $false) {
        $script:PortCheckClosedCount++
        if ($script:PortCheckClosedCount -ge 2) {
            $script:PortReachable = $false
            Write-Log ("Port {0} looks CLOSED from the internet. Check that qBittorrent is running and allowed " +
                       "through the Windows Firewall, and that you are on a P2P server with port forwarding on." -f $port) 'WARN'
            # Re-check sooner so the status recovers quickly once it is fixed.
            $script:NextPortCheck = $Now.AddMinutes(5)
        }
        else {
            $script:NextPortCheck = $Now.AddMinutes(2)
        }
    }
    else {
        Write-Log 'Port check service gave no usable answer; will try again later.' 'INFO'
    }
}

# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------

function New-HealthItem {
    param([string]$Level, [string]$Message, [string]$Hint = '')
    return [pscustomobject]@{ Level = $Level; Message = $Message; Hint = $Hint }
}

function Get-HealthChecks {
    <#
        Turns a status snapshot into plain-language findings, each with a fix hint.
        Pure function: it only reads the snapshot, never touches the network.
    #>
    param($Snap, $Config)

    $items = New-Object System.Collections.Generic.List[object]
    $webUi = if ($Config -and $Config.WebUiUrl) { [string]$Config.WebUiUrl } else { 'the configured address' }

    # --- VPN ---------------------------------------------------------------
    if (-not $Snap.VpnIp -and -not $Snap.Found) {
        $items.Add((New-HealthItem 'ERROR' 'ProtonVPN does not appear to be connected.' `
            'Open the Proton VPN app and connect to a P2P server.'))
    }
    elseif ($Snap.VpnIp -and -not $Snap.Found) {
        $items.Add((New-HealthItem 'WARN' 'The VPN is connected, but Proton has not announced a forwarded port.' `
            'In the Proton VPN app turn on Port Forwarding (Settings > Advanced) and reconnect to a P2P-capable server.'))
    }
    elseif (-not $Snap.VpnIp -and $Snap.Found) {
        $items.Add((New-HealthItem 'WARN' 'A port was announced but the VPN gateway does not answer (old log entry, or the VPN just dropped).' `
            'Wait a minute. If it stays like this, disconnect and reconnect the VPN.'))
    }
    elseif ($Snap.Verify -and -not $Snap.Verify.Ok) {
        $items.Add((New-HealthItem 'WARN' ("The gateway did not confirm port {0} (TCP={1}, UDP={2})." -f $Snap.Found.Port, $Snap.Verify.Tcp, $Snap.Verify.Udp) `
            'Reconnect the VPN to get a fresh port.'))
    }

    # --- qBittorrent -------------------------------------------------------
    if (-not $Snap.QbtOk) {
        $msg = [string]$Snap.QbtError
        if ($msg -match 'rejected the username|401') {
            $items.Add((New-HealthItem 'ERROR' 'qBittorrent rejected the username or password.' `
                'Run ProtonPortSync.Setup.ps1 again and enter the Web UI password (Tools > Options > Web UI).'))
        }
        elseif ($msg -match 'banned|403') {
            $items.Add((New-HealthItem 'ERROR' 'qBittorrent has banned this computer after too many failed logins.' `
                'Restart qBittorrent (this clears the ban), then check the password with Setup.'))
        }
        elseif ($msg -match 'unreachable|Unable to connect|refused|timed out|No connection') {
            $items.Add((New-HealthItem 'ERROR' "Cannot reach qBittorrent at $webUi." `
                'Start qBittorrent and turn on the Web UI (Tools > Options > Web UI). Portable copies have it off by default.'))
        }
        else {
            $items.Add((New-HealthItem 'ERROR' "qBittorrent check failed: $msg" `
                'Run .\ProtonPortSync.ps1 -Once and read the log.'))
        }
    }
    else {
        if ($Snap.Found -and $Snap.QbtPort -eq $Snap.Found.Port) {
            $items.Add((New-HealthItem 'OK' ("qBittorrent listens on the forwarded port ({0})." -f $Snap.Found.Port)))
        }
        elseif ($Snap.Found) {
            $items.Add((New-HealthItem 'WARN' ("qBittorrent listens on {0} but the VPN forwards {1}." -f $Snap.QbtPort, $Snap.Found.Port) `
                'The background service corrects this within a cycle. If it does not, check that the service is running and read the log.'))
        }
        if ($Snap.RandomPort) {
            $items.Add((New-HealthItem 'WARN' 'qBittorrent has "random port" turned on, which overrides the synced port.' `
                'Tools > Options > Connection: untick "Use random port on each start".'))
        }
        if ($Snap.Upnp) {
            $items.Add((New-HealthItem 'WARN' 'qBittorrent has UPnP / NAT-PMP port forwarding turned on.' `
                'Tools > Options > Connection: untick "Use UPnP / NAT-PMP port forwarding from my router" (Proton advises against it).'))
        }
        if ([string]::IsNullOrWhiteSpace([string]$Snap.Iface)) {
            $items.Add((New-HealthItem 'WARN' 'qBittorrent is not bound to a network interface.' `
                'Tools > Options > Advanced > Network Interface: pick the Proton VPN adapter. Otherwise, if the VPN drops, torrents continue over your normal connection.'))
        }
        else {
            $items.Add((New-HealthItem 'OK' ("qBittorrent is bound to the network interface ""{0}""." -f $Snap.Iface)))
        }
    }

    # --- reachability ------------------------------------------------------
    if ($Snap.PortReachable -eq $true) {
        $items.Add((New-HealthItem 'OK' 'The port is reachable from the internet.'))
    }
    elseif ($Snap.PortReachable -eq $false) {
        $items.Add((New-HealthItem 'WARN' 'The port looks closed from the internet.' `
            'Make sure qBittorrent is running and allowed through Windows Firewall, and that you are on a P2P server with port forwarding on.'))
    }

    $bad = @($items | Where-Object { $_.Level -eq 'WARN' -or $_.Level -eq 'ERROR' })
    if ($bad.Count -eq 0) {
        $items.Add((New-HealthItem 'OK' 'Everything looks fine.'))
    }
    return $items.ToArray()
}

# ---------------------------------------------------------------------------
# Support bundle
# ---------------------------------------------------------------------------

function ConvertTo-MaskedText {
    <# Removes public IPv4 addresses and the user's profile path from text that may be shared. #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $private = '^(127\.|10\.|192\.168\.|169\.254\.|0\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)'
    $Text = [regex]::Replace($Text, '\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b', {
        param($m)
        if ($m.Value -match $private) { return $m.Value }
        return 'x.x.x.x'
    })
    foreach ($p in @($env:USERPROFILE, $env:LOCALAPPDATA)) {
        if ($p -and $p.Length -gt 3) {
            $Text = $Text.Replace($p, $(if ($p -eq $env:USERPROFILE) { '%USERPROFILE%' } else { '%LOCALAPPDATA%' }))
        }
    }
    return $Text
}

function Get-MaskedConfigJson {
    param($Config)
    # Placeholders avoid < and > because Windows PowerShell 5.1 would write them as \u003c / \u003e.
    $copy = [ordered]@{}
    foreach ($p in $Config.PSObject.Properties) { $copy[$p.Name] = $p.Value }
    if ($copy.Contains('PasswordProtected')) {
        $copy['PasswordProtected'] = if ($copy['PasswordProtected']) { '(removed)' } else { '' }
    }
    if ($copy.Contains('Username') -and $copy['Username']) { $copy['Username'] = '(set)' }
    if ($copy.Contains('WebUiUrl') -and $copy['WebUiUrl']) {
        try {
            $u = [uri][string]$copy['WebUiUrl']
            if ($u.Host -notin @('127.0.0.1', 'localhost', '::1', '[::1]')) {
                $copy['WebUiUrl'] = '{0}://(remote-host):{1}' -f $u.Scheme, $u.Port
            }
        } catch { }
    }
    return (ConvertTo-MaskedText -Text ($copy | ConvertTo-Json -Depth 5))
}

function Get-HealthReportText {
    param($Snap, $Config, $Items)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("ProtonPortSync support report - $([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC")
    $lines.Add("Version        : $($Snap.Version)")
    $lines.Add("PowerShell     : $($PSVersionTable.PSVersion)")
    $lines.Add("Windows        : $([Environment]::OSVersion.VersionString)")
    $lines.Add("VPN reachable  : $(if ($Snap.VpnIp) { 'yes' } else { 'no' })")
    $lines.Add("Forwarded port : $(if ($Snap.Found) { $Snap.Found.Port } else { 'not found' })")
    $lines.Add("qBittorrent    : $(if ($Snap.QbtOk) { 'port ' + $Snap.QbtPort } else { 'error - ' + $Snap.QbtError })")
    $lines.Add("In sync        : $($Snap.InSync)")
    $lines.Add('')
    $lines.Add('Checks')
    foreach ($i in $Items) {
        $lines.Add(('  [{0}] {1}' -f $i.Level, $i.Message))
        if ($i.Hint) { $lines.Add("         -> $($i.Hint)") }
    }
    return (ConvertTo-MaskedText -Text ($lines -join "`r`n"))
}

function New-SupportBundle {
    <#
        Builds ProtonPortSync-support-<time>.zip with: report.txt (health checks), config.json (secrets
        removed), status.json, the last 1000 log lines, update-state.json. Public IP addresses and
        your profile path are replaced. Returns the path of the zip.
    #>
    param($Config, $Snap, [string]$ConfigPath, [string]$OutDir)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dataDir = Split-Path -Parent $ConfigPath
    $stamp = [datetime]::Now.ToString('yyyyMMdd-HHmmss')
    $work = Join-Path ([IO.Path]::GetTempPath()) "pps-bundle-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,6))"
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $items = Get-HealthChecks -Snap $Snap -Config $Config
        Set-Content -LiteralPath (Join-Path $work 'report.txt') -Value (Get-HealthReportText -Snap $Snap -Config $Config -Items $items) -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $work 'config.json') -Value (Get-MaskedConfigJson -Config $Config) -Encoding UTF8

        foreach ($name in 'status.json', 'update-state.json') {
            $src = Join-Path $dataDir $name
            if (Test-Path -LiteralPath $src) {
                Set-Content -LiteralPath (Join-Path $work $name) -Encoding UTF8 `
                    -Value (ConvertTo-MaskedText -Text (Get-Content -LiteralPath $src -Raw))
            }
        }
        foreach ($name in 'ProtonPortSync.log', 'ProtonPortSync.log.old') {
            $src = Join-Path $dataDir $name
            if (Test-Path -LiteralPath $src) {
                $tail = @(Get-Content -LiteralPath $src -Tail 1000)
                Set-Content -LiteralPath (Join-Path $work $name) -Encoding UTF8 `
                    -Value (ConvertTo-MaskedText -Text ($tail -join "`r`n"))
            }
        }

        if (-not $OutDir -or -not (Test-Path -LiteralPath $OutDir)) { $OutDir = $dataDir }
        $zip = Join-Path $OutDir "ProtonPortSync-support-$stamp.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($work, $zip)
        return $zip
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
