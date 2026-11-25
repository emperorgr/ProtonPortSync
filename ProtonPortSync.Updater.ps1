#Requires -Version 5.1
<#
.SYNOPSIS
    Self-updater for ProtonPortSync (dot-sourced by ProtonPortSync.ps1).

.DESCRIPTION
    Checks the GitHub releases of emperorgr/ProtonPortSync and installs a newer
    stable version (tags of the form vX.Y.Z only) without any user interaction.

    Safety measures:
      * Only plain vX.Y.Z tags count: pre-releases (v1.3.0-beta.1) and other
        products' tags (macos-v...) are ignored.
      * Only a fixed list of top-level file names is ever extracted from the
        archive; paths inside the zip are never used (no zip-slip).
      * Every downloaded .ps1 must parse, and the version inside the downloaded
        ProtonPortSync.ps1 must equal the release tag, BEFORE anything is replaced.
      * The current files are backed up first; if the new version cannot start
        three times in a row it is rolled back automatically and skipped.
      * A git checkout is never touched (update it with "git pull").
      * Settings, Keychain/DPAPI password and logs live outside the install
        folder and are never modified.

    Set "AutoUpdate": false in config.json to disable it.
#>

# --- overridable for tests --------------------------------------------------
if (-not $script:UpdateRepo)    { $script:UpdateRepo    = 'emperorgr/ProtonPortSync' }
if (-not $script:UpdateWebBase) { $script:UpdateWebBase = 'https://github.com' }
if (-not $script:UpdateApiBase) { $script:UpdateApiBase = 'https://api.github.com' }

# Top-level files an update may create or replace. (ProtonPortSync.vbs is generated
# by Setup on each machine and is deliberately not listed.)
$script:UpdateAllowedFiles = @(
    'ProtonPortSync*.ps1', 'Uninstall-ProtonPortSync.ps1', 'Test-*.ps1',
    '*.cmd', 'README.md', 'CHANGELOG.md', 'LICENSE'
)

# ---------------------------------------------------------------------------
# Paths and state
# ---------------------------------------------------------------------------

function Get-UpdateInstallDir {
    if ($script:InstallDir) { return $script:InstallDir }
    return $PSScriptRoot
}

function Get-UpdateStateDir {
    if ($script:UpdateStateDir) { return $script:UpdateStateDir }
    return (Split-Path -Parent $ConfigPath)
}

function Get-UpdateState {
    $path = Join-Path (Get-UpdateStateDir) 'update-state.json'
    $state = [pscustomobject]@{
        LastCheckUtc    = ''
        SkipVersions    = @()
        PendingFrom     = ''
        PendingTo       = ''
        PendingAttempts = 0
        PendingBackup   = ''
    }
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($p in $state.PSObject.Properties) {
                if ($null -ne $raw.PSObject.Properties[$p.Name]) { $state.($p.Name) = $raw.($p.Name) }
            }
        } catch { }
    }
    $state.SkipVersions = @($state.SkipVersions | Where-Object { $_ })
    return $state
}

function Save-UpdateState {
    param($State)
    $dir = Get-UpdateStateDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $State | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $dir 'update-state.json') -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Finding the newest release
# ---------------------------------------------------------------------------

function ConvertTo-UpdateVersion {
    param([string]$Text)
    if ($Text -match '^v?(\d+)\.(\d+)\.(\d+)$') {
        return [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3])
    }
    return $null
}

function Initialize-UpdateTls {
    # Windows PowerShell 5.1 may default to TLS 1.0/1.1, which GitHub refuses.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}

# Network primitives are separate functions so tests can replace them.
function Get-UpdateWebText {
    param([string]$Uri)
    Initialize-UpdateTls
    $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 20 `
                -Headers @{ 'User-Agent' = "ProtonPortSync/$script:Version" }
    if ($resp.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($resp.Content) }
    return [string]$resp.Content
}

function Save-UpdateFile {
    param([string]$Uri, [string]$OutFile)
    Initialize-UpdateTls
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 120 `
        -Headers @{ 'User-Agent' = "ProtonPortSync/$script:Version" }
}

function Select-LatestFromFeed {
    param([string]$FeedText)
    $xml = [xml]$FeedText
    $best = $null
    foreach ($entry in @($xml.feed.entry)) {
        if (-not $entry) { continue }
        $href = [string]@($entry.link)[0].href
        if ($href -notmatch '/releases/tag/([^/?#]+)$') { continue }
        $tag = [uri]::UnescapeDataString($Matches[1])
        $ver = ConvertTo-UpdateVersion $tag
        if (-not $ver) { continue }
        if ((-not $best) -or ($ver -gt $best.Version)) {
            $best = [pscustomobject]@{ Tag = $tag; Version = $ver }
        }
    }
    return $best
}

function Select-LatestFromApi {
    param([string]$Json)
    $best = $null
    # Assign first: Windows PowerShell 5.1 emits a JSON array as ONE object, so piping or
    # wrapping it straight into foreach would iterate once over the whole array.
    $items = $Json | ConvertFrom-Json
    foreach ($rel in @($items)) {
        if (-not $rel -or $rel.draft -or $rel.prerelease) { continue }
        $ver = ConvertTo-UpdateVersion ([string]$rel.tag_name)
        if (-not $ver) { continue }
        if ((-not $best) -or ($ver -gt $best.Version)) {
            $best = [pscustomobject]@{ Tag = [string]$rel.tag_name; Version = $ver }
        }
    }
    return $best
}

function Get-LatestRelease {
    <# The public Atom feed first (not subject to the API's 60 requests/hour per IP, which
       matters on shared VPN exit addresses), the REST API as a fallback. #>
    $best = $null
    $feedError = ''
    try {
        $best = Select-LatestFromFeed -FeedText (Get-UpdateWebText -Uri "$script:UpdateWebBase/$script:UpdateRepo/releases.atom")
    } catch { $feedError = $_.Exception.Message }
    if (-not $best) {
        try {
            $best = Select-LatestFromApi -Json (Get-UpdateWebText -Uri "$script:UpdateApiBase/repos/$script:UpdateRepo/releases?per_page=30")
        } catch {
            throw "could not read the release list from GitHub (feed: $feedError; api: $($_.Exception.Message))"
        }
    }
    return $best
}

# ---------------------------------------------------------------------------
# Installing
# ---------------------------------------------------------------------------

function Get-UpdateBlockReason {
    $dir = Get-UpdateInstallDir
    if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
        return 'this folder is a git checkout - update it with "git pull"'
    }
    $probe = Join-Path $dir ('.pps-write-test-' + [guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch {
        return 'the install folder is not writable'
    }
    return $null
}

function Test-UpdateFileName {
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { return $false }
    foreach ($pattern in $script:UpdateAllowedFiles) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Expand-UpdateArchive {
    <# Extracts ONLY <root>/<file> entries whose file name is on the allow-list.
       Entry paths are never used to build a destination, so '..' tricks do nothing. #>
    param([string]$Zip, [string]$StageDir)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            $parts = $entry.FullName -split '[\\/]'
            if ($parts.Count -ne 2) { continue }
            if (($parts[0] -in @('', '.', '..')) -or [string]::IsNullOrEmpty($parts[1])) { continue }
            if (-not (Test-UpdateFileName $parts[1])) { continue }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $StageDir $parts[1]), $true)
        }
    } finally {
        $archive.Dispose()
    }
}

function Test-StagedUpdate {
    <# Returns $null when the staged files look sane, otherwise the reason they do not. #>
    param([string]$StageDir, [version]$ExpectedVersion)

    foreach ($required in @('ProtonPortSync.ps1', 'ProtonPortSync.Setup.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $StageDir $required))) {
            return "the archive has no $required"
        }
    }
    foreach ($file in (Get-ChildItem -LiteralPath $StageDir -Filter '*.ps1' -File)) {
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            return "$($file.Name) has a syntax error (line $($parseErrors[0].Extent.StartLineNumber))"
        }
    }
    $main = Get-Content -LiteralPath (Join-Path $StageDir 'ProtonPortSync.ps1') -Raw
    if ($main -notmatch '\$script:Version\s*=\s*''(\d+\.\d+\.\d+)''') {
        return 'cannot read the version inside ProtonPortSync.ps1'
    }
    if ([version]$Matches[1] -ne $ExpectedVersion) {
        return "the archive contains version $($Matches[1]), not $ExpectedVersion"
    }
    return $null
}

function Backup-CurrentInstall {
    $dir  = Get-UpdateInstallDir
    $root = Join-Path (Get-UpdateStateDir) 'backup'
    $dest = Join-Path $root $script:Version
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($file in (Get-ChildItem -LiteralPath $dir -File)) {
        if (Test-UpdateFileName $file.Name) { Copy-Item -LiteralPath $file.FullName -Destination $dest -Force }
    }
    # keep only the three newest backups
    Get-ChildItem -LiteralPath $root -Directory | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 3 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    return $dest
}

function Restore-UpdateBackup {
    param([string]$BackupDir)
    $dir = Get-UpdateInstallDir
    foreach ($file in (Get-ChildItem -LiteralPath $BackupDir -File)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dir $file.Name) -Force
    }
}

function Copy-StagedFiles {
    param([string]$StageDir)
    $dir = Get-UpdateInstallDir
    # The main script is replaced last, so an interrupted update never leaves a new
    # engine next to old helpers.
    $files = Get-ChildItem -LiteralPath $StageDir -File | Sort-Object { $_.Name -eq 'ProtonPortSync.ps1' }
    foreach ($file in $files) {
        $dest = Join-Path $dir $file.Name
        $tmp  = "$dest.new"
        Copy-Item -LiteralPath $file.FullName -Destination $tmp -Force
        Move-Item -LiteralPath $tmp -Destination $dest -Force
    }
}

function Install-Update {
    param($Release)
    $work = Join-Path ([IO.Path]::GetTempPath()) ('pps-update-' + [guid]::NewGuid().ToString('N'))
    try {
        $stage = Join-Path $work 'stage'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $zip = Join-Path $work 'release.zip'

        Save-UpdateFile -Uri "$script:UpdateWebBase/$script:UpdateRepo/archive/refs/tags/$($Release.Tag).zip" -OutFile $zip
        $length = (Get-Item -LiteralPath $zip).Length
        if ($length -lt 1KB -or $length -gt 20MB) { throw "downloaded archive has an unexpected size ($length bytes)" }

        Expand-UpdateArchive -Zip $zip -StageDir $stage
        $problem = Test-StagedUpdate -StageDir $stage -ExpectedVersion $Release.Version
        if ($problem) { throw "update rejected: $problem" }

        $backup = Backup-CurrentInstall
        try {
            Copy-StagedFiles -StageDir $stage
        } catch {
            $why = $_.Exception.Message
            Restore-UpdateBackup -BackupDir $backup
            throw "could not replace the files ($why); the previous version was restored"
        }

        $state = Get-UpdateState
        $state.PendingFrom     = $script:Version
        $state.PendingTo       = $Release.Version.ToString()
        $state.PendingAttempts = 0
        $state.PendingBackup   = $backup
        Save-UpdateState $state
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AutoUpdate {
    <# Returns an object: Result = uptodate | available | updated | skipped | error. #>
    param($Config, [switch]$CheckOnly)
    $result = [pscustomobject]@{ Result = 'error'; Message = ''; Release = $null }
    try {
        $current = ConvertTo-UpdateVersion $script:Version
        if (-not $current) { $current = [version]'0.0.0' }

        $latest = Get-LatestRelease

        $state = Get-UpdateState
        $state.LastCheckUtc = [datetime]::UtcNow.ToString('o')
        Save-UpdateState $state

        if ((-not $latest) -or ($latest.Version -le $current)) {
            $result.Result  = 'uptodate'
            $result.Message = "ProtonPortSync $script:Version is up to date."
            return $result
        }
        $result.Release = $latest
        if ($state.SkipVersions -contains $latest.Tag) {
            $result.Result  = 'skipped'
            $result.Message = "Version $($latest.Version) is skipped because it failed to start on this PC earlier."
            return $result
        }
        if ($CheckOnly) {
            $result.Result  = 'available'
            $result.Message = "Version $($latest.Version) is available (installed: $script:Version). Run .\ProtonPortSync.ps1 -Update to install it."
            return $result
        }
        $block = Get-UpdateBlockReason
        if ($block) {
            $result.Result  = 'skipped'
            $result.Message = "Version $($latest.Version) is available but was not installed automatically: $block."
            return $result
        }

        Install-Update -Release $latest
        $result.Result  = 'updated'
        $result.Message = "Updated ProtonPortSync $script:Version -> $($latest.Version)."
    } catch {
        $result.Result  = 'error'
        $result.Message = "Update failed: $($_.Exception.Message)"
    }
    return $result
}

# ---------------------------------------------------------------------------
# Start-up bookkeeping: confirm a new version works, or roll it back
# ---------------------------------------------------------------------------

function Resolve-PendingUpdate {
    <# Call once when the background service starts.
       Returns 'none', 'pending' (new version is on probation) or 'rollback' (the
       previous version was restored: the caller must relaunch and exit). #>
    $state = Get-UpdateState
    if (-not $state.PendingTo) { return 'none' }

    if ($state.PendingTo -ne $script:Version) {
        # A different version is running than the one the marker was made for.
        $state.PendingTo = ''; $state.PendingFrom = ''; $state.PendingAttempts = 0; $state.PendingBackup = ''
        Save-UpdateState $state
        return 'none'
    }

    $state.PendingAttempts = [int]$state.PendingAttempts + 1
    if ($state.PendingAttempts -le 3) {
        Save-UpdateState $state
        return 'pending'
    }

    Write-Log "Version $script:Version failed to stay running 3 times; rolling back to $($state.PendingFrom)." 'ERROR'
    if ($state.PendingBackup -and (Test-Path -LiteralPath $state.PendingBackup)) {
        Restore-UpdateBackup -BackupDir $state.PendingBackup
    } else {
        Write-Log 'No backup found to restore.' 'ERROR'
    }
    $state.SkipVersions = @($state.SkipVersions) + ('v' + $state.PendingTo)
    $state.PendingTo = ''; $state.PendingFrom = ''; $state.PendingAttempts = 0; $state.PendingBackup = ''
    Save-UpdateState $state
    return 'rollback'
}

function Confirm-UpdateHealthy {
    $state = Get-UpdateState
    if ($state.PendingTo -and ($state.PendingTo -eq $script:Version)) {
        $state.PendingTo = ''; $state.PendingFrom = ''; $state.PendingAttempts = 0; $state.PendingBackup = ''
        Save-UpdateState $state
        Write-Log "ProtonPortSync $script:Version is running normally; update confirmed." 'OK'
    }
}

# ---------------------------------------------------------------------------
# Scheduling and restarting
# ---------------------------------------------------------------------------

function Get-UpdateCheckHours {
    param($Config)
    $hours = 6.0
    try { if ($Config.UpdateCheckHours) { $hours = [double]$Config.UpdateCheckHours } } catch { }
    if ($hours -lt 1)   { $hours = 1 }
    if ($hours -gt 168) { $hours = 168 }
    return $hours
}

function Get-NextUpdateCheck {
    <# When to check next. Persisted: restarting the service does not trigger a new check. #>
    param($Config, [switch]$AfterError)
    $now = Get-Date
    if ($AfterError) { return $now.AddHours([math]::Min(1, (Get-UpdateCheckHours -Config $Config))) }
    $due = $now
    $state = Get-UpdateState
    if ($state.LastCheckUtc) {
        try {
            $raw = $state.LastCheckUtc
            if ($raw -is [datetime]) {
                $last = $raw.ToLocalTime()
            } else {
                $last = [datetime]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture,
                                          [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
            }
            $due = $last.AddHours((Get-UpdateCheckHours -Config $Config))
        } catch { }
    }
    $earliest = $now.AddMinutes(2)       # let the service settle first
    if ($due -gt $earliest) { return $due }
    return $earliest
}

function Start-ServiceRelaunch {
    <# Starts a new, hidden copy of the service the same way the logon task does
       (wscript.exe + ProtonPortSync.vbs), so it keeps the user's normal environment
       and outlives this process. #>
    $dir = Get-UpdateInstallDir
    $vbs = Join-Path $dir 'ProtonPortSync.vbs'
    $ps1 = Join-Path $dir 'ProtonPortSync.ps1'
    try {
        if (Test-Path -LiteralPath $vbs) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList @("`"$vbs`"") -WorkingDirectory $dir
        } else {
            Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -WorkingDirectory $dir -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$ps1`"")
        }
        return $true
    } catch {
        # The 10-minute watchdog task (if registered) will bring the service back.
        Write-Log "Could not relaunch the service automatically: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Restart-RunningService {
    <# Used by a manual -Update: stop the old background copy and start the new one. #>
    $stopped = 0
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'ProtonPortSync\.ps1' -and
                       $_.CommandLine -notmatch '-(Once|Status|CheckUpdate|Update)\b' })
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { }
    }
    if ($stopped -gt 0) {
        Start-Sleep -Seconds 1
        [void](Start-ServiceRelaunch)
    }
    return $stopped
}
