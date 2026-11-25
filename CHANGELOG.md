# Changelog

## 1.2.1 - 2026-11-25

### Fixed
- Updater: the GitHub API fallback picked the wrong release on Windows PowerShell 5.1
  (a JSON list was read as a single item). The normal release-feed path was not affected.

## 1.2.0 - 2026-11-25

### Added
- **Automatic updates.** The background service checks the GitHub releases every 6 hours
  (`UpdateCheckHours`) and installs a newer `vX.Y.Z` release on its own, then restarts itself.
  Safeguards: pre-release and `macos-v...` tags are ignored; the download is validated
  (every script must parse, version must match the tag) before anything is replaced; a
  fixed list of file names only; the old files are backed up; a version that fails to start
  3 times is rolled back and skipped; a git checkout is never touched.
  Turn off with `"AutoUpdate": false` in `config.json`.
- **Setup asks whether to enable automatic updates** (`-AutoUpdate` / `-NoAutoUpdate` skip the question; re-running Setup keeps your earlier answer).
- `-CheckUpdate` (report only) and `-Update` (install now, restart the service).
- `-Status` shows the version and whether auto-update is on.
- `Test-Updater.ps1` (offline simulation of whole update cycles; `-Live` also checks the
  real GitHub feed) and CI steps that run it on Windows PowerShell 5.1.

### Note
- Upgrading from 1.1.x to 1.2.0 must be done by hand once (older versions have no updater).

## 1.1.1 - 2026-11-25

### Fixed
- TCP and UDP were swapped in the NAT-PMP check: RFC 6886 defines opcode 1 as UDP and
  opcode 2 as TCP. The sync itself was never affected (both must succeed), but the
  `TCP=`/`UDP=` values shown by `-Status` and in log warnings were reversed.

## macOS 0.1.0-beta.1 - 2026-11-25 (separate from the Windows version below)

First test build of the macOS version in [`macos/`](macos/README.md). Python 3 standard
library only. Finds the forwarded port over NAT-PMP, detects the VPN's `utunN` interface and
sets both in qBittorrent, stores the password in the Keychain and runs as a launchd agent.
Automated tests pass against mock servers; **not yet verified on a real Mac with ProtonVPN**.
The Windows scripts are unchanged by this release.

## 1.1.0 - 2026-11-21

### Fixed
- **Watchdog restart:** if the service was killed, the relaunched copy could fail with a
  fatal error because the global mutex was left abandoned. An abandoned mutex is now taken
  over, so the 10-minute watchdog reliably revives the service.
- **Self-inflicted qBittorrent ban:** after a rejected login (401) the service kept
  retrying every poll and could trip qBittorrent's 5-failure IP ban. It now logs the error
  once and stops retrying until `config.json` changes.
- Setup no longer assigns to PowerShell's reserved `$input` variable.

### Changed
- The service re-reads `config.json` every poll, so a new password or URL applies without
  restarting it.
- The slow recursive search for the ProtonVPN log folder runs at most every 5 minutes, and
  a folder that was found is remembered.
- The startup log line now includes the version.

### Security
- `Setup.ps1` reads the password from `$env:PROTONPORTSYNC_PASSWORD` when set, and warns
  that `-Password` on the command line can end up in shell history.
- Both Setup and the service warn when the WebUI URL is plain HTTP on a non-local address.

## 1.0.0

Initial release: keeps qBittorrent's listening port in sync with ProtonVPN's forwarded
port (log discovery, NAT-PMP confirmation, WebAPI update, logon task with watchdog).
