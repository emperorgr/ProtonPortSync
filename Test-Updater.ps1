#Requires -Version 5.1
<#
.SYNOPSIS
    Tests the self-updater (ProtonPortSync.Updater.ps1) without touching the network
    or your real installation: a fake GitHub (release feed + archives) and a temporary
    install folder are used.

.PARAMETER Live
    Additionally query the real GitHub repository (feed, API and archive download),
    validating the newest real release WITHOUT installing it.
#>
[CmdletBinding()]
param([switch]$Live)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = $PSScriptRoot
$script:pass = 0
$script:fail = 0
function Assert-That {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:pass++; Write-Host "  ok   $Message" }
    else            { $script:fail++; Write-Host "  FAIL $Message" -ForegroundColor Red }
}

# --- minimal stand-ins for what the main script provides -----------------------
$script:LogLines = @()
function Write-Log { param([string]$Message, [string]$Level = 'INFO', [switch]$Force) $script:LogLines += "$Level $Message" }
$script:Version = '1.0.0'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pps-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:InstallDir     = Join-Path $tmp 'install'
$script:UpdateStateDir = Join-Path $tmp 'state'
New-Item -ItemType Directory -Path $script:InstallDir, $script:UpdateStateDir | Out-Null

. (Join-Path $repoRoot 'ProtonPortSync.Updater.ps1')

# --- fixtures --------------------------------------------------------------------
$allowed = @(Get-ChildItem -LiteralPath $repoRoot -File | Where-Object { Test-UpdateFileName $_.Name })
foreach ($f in $allowed) { Copy-Item -LiteralPath $f.FullName -Destination $script:InstallDir }

$fixtures = Join-Path $tmp 'fixtures'
New-Item -ItemType Directory -Path $fixtures | Out-Null

function New-FakeRelease {
    <# Creates fixtures\<tag>.zip shaped like GitHub's source archive. #>
    param([string]$Tag, [string]$VersionInside, [string]$Mutate = '')
    $root = Join-Path $fixtures ("src-$Tag\ProtonPortSync-" + $Tag.TrimStart('v'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($f in $allowed) { Copy-Item -LiteralPath $f.FullName -Destination $root }
    $main = Join-Path $root 'ProtonPortSync.ps1'
    $text = [IO.File]::ReadAllText($main)
    $text = $text -replace "\`$script:Version = '[0-9.]+'", "`$script:Version = '$VersionInside'"
    [IO.File]::WriteAllText($main, $text)
    if ($Mutate -eq 'syntax') { [IO.File]::WriteAllText((Join-Path $root 'Test-Broken.ps1'), 'function { {{ oops') }
    $zip = Join-Path $fixtures "$Tag.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $fixtures "src-$Tag"), $zip)
    if ($Mutate -eq 'slip') {
        $z = [IO.Compression.ZipFile]::Open($zip, 'Update')
        foreach ($name in @('ProtonPortSync-evil/../../evil.ps1', 'ProtonPortSync-evil/..\..\evil.cmd', '../evil.ps1', 'ProtonPortSync-evil/sub/nested.ps1')) {
            $e = $z.CreateEntry($name)
            $w = New-Object IO.StreamWriter($e.Open()); $w.Write('Write-Host evil'); $w.Dispose()
        }
        $z.Dispose()
    }
}
function Get-DirHash { param([string]$Dir)
    (Get-ChildItem -LiteralPath $Dir -File | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ',' }

$script:FeedTags = @()
function Get-FeedText {
    $entries = foreach ($t in $script:FeedTags) {
        "<entry><id>tag:github.com,2008:Repository/1/$t</id><updated>2026-11-25T00:00:00Z</updated>" +
        "<link rel=`"alternate`" type=`"text/html`" href=`"https://github.com/emperorgr/ProtonPortSync/releases/tag/$t`"/>" +
        "<title>$t</title></entry>"
    }
    '<?xml version="1.0" encoding="UTF-8"?><feed xmlns="http://www.w3.org/2005/Atom"><id>x</id><title>Releases</title>' + ($entries -join '') + '</feed>'
}

# Replace the two network primitives with fakes (the real ones are exercised with -Live).
if (-not $Live) {
    $script:FeedFails = $false
    function Get-UpdateWebText {
        param([string]$Uri)
        if ($Uri -like '*releases.atom') { if ($script:FeedFails) { throw 'feed unavailable' }; return (Get-FeedText) }
        if ($Uri -like '*/releases?per_page=*') {
            return '[{"tag_name":"v99.0.0","draft":true,"prerelease":false},{"tag_name":"v50.0.0","draft":false,"prerelease":true},' +
                   '{"tag_name":"macos-v0.1.0-beta.1","draft":false,"prerelease":true},{"tag_name":"v9.10.0","draft":false,"prerelease":false},' +
                   '{"tag_name":"v9.9.0","draft":false,"prerelease":false}]'
        }
        throw "unexpected URI $Uri"
    }
    function Save-UpdateFile {
        param([string]$Uri, [string]$OutFile)
        if ($Uri -notmatch '/archive/refs/tags/(v[0-9.]+)\.zip$') { throw "unexpected URI $Uri" }
        Copy-Item -LiteralPath (Join-Path $fixtures "$($Matches[1]).zip") -Destination $OutFile
    }
}

try {
    if (-not $Live) {
        Write-Host 'Version parsing and release selection'
        Assert-That ((ConvertTo-UpdateVersion 'v1.2.3') -eq [version]'1.2.3') 'v1.2.3 parses'
        Assert-That ($null -eq (ConvertTo-UpdateVersion 'v1.2.3-beta.1')) 'beta suffix is rejected'
        Assert-That ($null -eq (ConvertTo-UpdateVersion 'macos-v0.1.0-beta.1')) 'macOS tag is rejected'
        Assert-That ($null -eq (ConvertTo-UpdateVersion 'v1.2')) 'two-part version is rejected'

        $script:FeedTags = @('macos-v0.1.0-beta.1', 'v1.1.1', 'v9.9.0', 'v9.10.0', 'v10.0.0-beta.1', 'v1.1.0')
        $latest = Get-LatestRelease
        Assert-That ($latest.Tag -eq 'v9.10.0') 'feed: picks v9.10.0 (numeric order, ignores beta and macOS tags)'
        $script:FeedFails = $true
        $latest = Get-LatestRelease
        Assert-That ($latest.Tag -eq 'v9.10.0') 'API fallback: ignores drafts and pre-releases'
        $script:FeedFails = $false
        $script:FeedTags = @('macos-v0.1.0-beta.1')
        Assert-That ((Get-LatestRelease).Tag -eq 'v9.10.0') 'feed without a usable tag falls back to the API'

        Write-Host 'Check only / up to date'
        $script:FeedTags = @('v1.1.1', 'v9.10.0')
        New-FakeRelease -Tag 'v9.10.0' -VersionInside '9.10.0'
        $before = Get-DirHash $script:InstallDir
        $r = Invoke-AutoUpdate -Config $null -CheckOnly
        Assert-That ($r.Result -eq 'available') 'newer release reported as available'
        Assert-That ((Get-DirHash $script:InstallDir) -eq $before) 'check-only changes nothing'
        $script:Version = '9.10.0'
        Assert-That ((Invoke-AutoUpdate -Config $null).Result -eq 'uptodate') 'same version -> up to date'
        $script:Version = '1.0.0'

        Write-Host 'Install'
        $r = Invoke-AutoUpdate -Config $null
        Assert-That ($r.Result -eq 'updated') "update installed ($($r.Message))"
        $main = [IO.File]::ReadAllText((Join-Path $script:InstallDir 'ProtonPortSync.ps1'))
        Assert-That ($main -match "\`$script:Version = '9\.10\.0'") 'main script is the new version'
        Assert-That (-not (Get-ChildItem -LiteralPath $script:InstallDir -Filter '*.new')) 'no .new leftovers'
        $state = Get-UpdateState
        Assert-That ($state.PendingTo -eq '9.10.0' -and $state.PendingFrom -eq '1.0.0') 'pending marker written'
        Assert-That (Test-Path (Join-Path $state.PendingBackup 'ProtonPortSync.ps1')) 'backup of the old files exists'
        $backupMain = [IO.File]::ReadAllText((Join-Path $state.PendingBackup 'ProtonPortSync.ps1'))
        Assert-That ($backupMain -notmatch "Version = '9\.10\.0'") 'backup holds the OLD version'
        Assert-That ($state.LastCheckUtc -ne '') 'last check time recorded'

        Write-Host 'Probation, confirmation and rollback'
        $script:Version = '9.10.0'
        Assert-That ((Resolve-PendingUpdate) -eq 'pending') 'first start of new version -> on probation'
        Confirm-UpdateHealthy
        Assert-That ((Get-UpdateState).PendingTo -eq '') 'healthy start clears the marker'
        Assert-That ((Resolve-PendingUpdate) -eq 'none') 'nothing pending afterwards'

        # simulate a version that cannot stay up
        $script:Version = '1.0.0'
        New-FakeRelease -Tag 'v9.11.0' -VersionInside '9.11.0'
        $script:FeedTags = @('v9.11.0')
        Assert-That ((Invoke-AutoUpdate -Config $null).Result -eq 'updated') 'second update installed'
        $script:Version = '9.11.0'
        $firstHash = Get-DirHash $script:InstallDir
        1..3 | ForEach-Object { $x = Resolve-PendingUpdate; Assert-That ($x -eq 'pending') "start $_ of 3 tolerated" }
        $x = Resolve-PendingUpdate
        Assert-That ($x -eq 'rollback') 'fourth failed start -> rollback'
        $restored = [IO.File]::ReadAllText((Join-Path $script:InstallDir 'ProtonPortSync.ps1'))
        Assert-That ($restored -notmatch "Version = '9\.11\.0'") 'old files restored'
        Assert-That ((Get-UpdateState).SkipVersions -contains 'v9.11.0') 'bad version added to the skip list'
        $script:Version = '1.0.0'
        Assert-That ((Invoke-AutoUpdate -Config $null).Result -eq 'skipped') 'skipped version is not retried'

        Write-Host 'Bad archives are rejected before anything changes'
        New-Item -ItemType Directory -Path $script:UpdateStateDir -Force | Out-Null
        Remove-Item (Join-Path $script:UpdateStateDir 'update-state.json') -Force
        $script:Version = '1.0.0'
        New-FakeRelease -Tag 'v9.12.0' -VersionInside '9.12.0' -Mutate 'syntax'
        $script:FeedTags = @('v9.12.0')
        $before = Get-DirHash $script:InstallDir
        $r = Invoke-AutoUpdate -Config $null
        Assert-That ($r.Result -eq 'error' -and $r.Message -match 'syntax error') "syntax error rejected ($($r.Message))"
        Assert-That ((Get-DirHash $script:InstallDir) -eq $before) 'install folder untouched after syntax error'

        New-FakeRelease -Tag 'v9.13.0' -VersionInside '0.0.1'
        $script:FeedTags = @('v9.13.0')
        $r = Invoke-AutoUpdate -Config $null
        Assert-That ($r.Result -eq 'error' -and $r.Message -match 'not 9\.13\.0') "version mismatch rejected ($($r.Message))"
        Assert-That ((Get-DirHash $script:InstallDir) -eq $before) 'install folder untouched after version mismatch'

        Write-Host 'Zip-slip and unexpected entries'
        New-FakeRelease -Tag 'v9.14.0' -VersionInside '9.14.0' -Mutate 'slip'
        $script:FeedTags = @('v9.14.0')
        $r = Invoke-AutoUpdate -Config $null
        Assert-That ($r.Result -eq 'updated') "valid files still install ($($r.Message))"
        $stray = @(Get-ChildItem -LiteralPath $tmp -Recurse -File -Include 'evil.ps1', 'evil.cmd', 'nested.ps1' -ErrorAction SilentlyContinue)
        Assert-That ($stray.Count -eq 0) 'no file escaped or was extracted from nested paths'
        Assert-That (-not (Test-Path (Join-Path ([IO.Path]::GetTempPath()) 'evil.ps1'))) 'nothing written to the temp folder'

        Write-Host 'Git checkout is never modified'
        $script:Version = '1.0.0'
        New-FakeRelease -Tag 'v9.15.0' -VersionInside '9.15.0'
        $script:FeedTags = @('v9.15.0')
        New-Item -ItemType Directory -Path (Join-Path $script:InstallDir '.git') | Out-Null
        $before = Get-DirHash $script:InstallDir
        $r = Invoke-AutoUpdate -Config $null
        Assert-That ($r.Result -eq 'skipped' -and $r.Message -match 'git checkout') 'git checkout -> skipped'
        Assert-That ((Get-DirHash $script:InstallDir) -eq $before) 'git checkout untouched'
        Remove-Item (Join-Path $script:InstallDir '.git') -Recurse -Force

        Write-Host 'Scheduling'
        $cfg = [pscustomobject]@{ UpdateCheckHours = 6 }
        $next = Get-NextUpdateCheck -Config $cfg
        Assert-That ($next -ge (Get-Date).AddMinutes(1.5)) 'next check is not immediate after a restart'
        $err = Get-NextUpdateCheck -Config $cfg -AfterError
        Assert-That ($err -le (Get-Date).AddMinutes(61)) 'retry after an error within an hour'
        Assert-That ((Get-UpdateCheckHours -Config ([pscustomobject]@{ UpdateCheckHours = 0.2 })) -eq 1) 'interval clamped to >= 1 hour'
        Assert-That ((Get-UpdateCheckHours -Config ([pscustomobject]@{ UpdateCheckHours = 1000 })) -eq 168) 'interval clamped to <= 168 hours'
        Assert-That ((Get-UpdateCheckHours -Config ([pscustomobject]@{ UpdateCheckHours = 0 })) -eq 6) 'unset interval -> 6 hours'
    }
    else {
        Write-Host 'LIVE: real GitHub'
        $script:Version = '0.0.1'
        $latest = Get-LatestRelease
        Assert-That ($null -ne $latest) 'a release is found on GitHub'
        Assert-That ($latest.Tag -match '^v\d+\.\d+\.\d+$') "latest tag looks right ($($latest.Tag))"
        Assert-That ($latest.Version -ge [version]'1.1.1') 'latest is at least 1.1.1'
        $feed = Select-LatestFromFeed -FeedText (Get-UpdateWebText -Uri "$script:UpdateWebBase/$script:UpdateRepo/releases.atom")
        Assert-That ($null -ne $feed) 'the Atom feed parses and yields a release'
        $api = Select-LatestFromApi -Json (Get-UpdateWebText -Uri "$script:UpdateApiBase/repos/$script:UpdateRepo/releases?per_page=30")
        Assert-That (($null -eq $api) -or ($api.Tag -eq $feed.Tag)) 'feed and API agree on the latest release'

        $work = Join-Path $tmp 'live'; $stage = Join-Path $work 'stage'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Save-UpdateFile -Uri "$script:UpdateWebBase/$script:UpdateRepo/archive/refs/tags/$($latest.Tag).zip" -OutFile (Join-Path $work 'r.zip')
        Expand-UpdateArchive -Zip (Join-Path $work 'r.zip') -StageDir $stage
        Assert-That ((Test-Path (Join-Path $stage 'ProtonPortSync.ps1'))) 'real archive extracts the main script'
        $problem = Test-StagedUpdate -StageDir $stage -ExpectedVersion $latest.Version
        Assert-That ($null -eq $problem) "real release passes validation ($problem)"
    }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
