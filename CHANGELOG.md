# Changelog

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
