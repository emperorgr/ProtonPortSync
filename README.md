# ProtonPortSync

Keeps **qBittorrent**'s listening port automatically in sync with **ProtonVPN**'s
port-forwarding port, so you stay connectable without ever touching the port by hand.

No dependencies: pure Windows PowerShell 5.1 (already on every Windows 10/11 machine).

> **On a Mac?** There is a **beta macOS version** (Python 3, also dependency-free) in
> [`macos/`](macos/README.md). Besides the port it also follows ProtonVPN's changing `utunN`
> network interface. It needs testers - see its README.

---

## Why a companion service instead of a qBittorrent patch?

ProtonVPN reserves **exactly one** externally reachable port per VPN session. That port:

* changes on every reconnect,
* **cannot be chosen** — NAT-PMP only honors a mapping for the already-reserved port,
* is announced by the ProtonVPN client in its log as `Port pair <port>-><port>`.

Because the port lives outside qBittorrent, the only reliable integration point is
qBittorrent's official WebAPI (`/api/v2/app/setPreferences` → `listen_port`).
Patching the C++ source would still have to shell out to the ProtonVPN log, so it
adds a fragile rebuild for no functional gain.

> Verified against ProtonVPN's NAT-PMP gateway: asking for the reserved port returns
> the **same** port on TCP **and** UDP. Asking for any other port returns a *different*
> external port that ProtonVPN does not actually forward. Discovery, not invention.

## How it works

```
ProtonVPN client log  ──►  port discovery   (client-logs*.txt, newest "Port pair X->X")
                     ──►  NAT-PMP confirm   (10.2.0.1:5351, refreshes TCP+UDP lease)
                     ──►  change detection  (only acts when the port differs)
                     ──►  qBittorrent WebAPI(setPreferences {"listen_port":X})
                     ──►  read-back verify  (confirms qBittorrent accepted it)
```

Safety rails:

* The port is only applied if NAT-PMP confirms it **or** the log entry is fresh
  (<5 min), so a disconnected VPN never pushes a stale port.
* If qBittorrent already listens on the correct port, nothing is written (idempotent).
* `random_port` in qBittorrent is reported as a warning, because it would fight the sync.
* Repeated identical errors are not spammed into the log.

### qBittorrent API quirks handled

Both were verified against the qBittorrent 5.2.3 source, not guessed:

* **Login returns HTTP 200 with an empty body** on success (`AuthController::loginAction`
  calls `setStatus(Ok)` without a result). Older builds returned the literal `Ok.`.
  The tool accepts both and then *proves* the session by calling an authenticated endpoint.
* **No `Origin`/`Referer` headers are sent.** `WebApplication::isCrossOriginRequest()`
  explicitly returns `false` when both are absent ("lets be permissive here" — the
  supported path for Web API clients). Supplying them can trigger an origin mismatch.

## Setup (one time)

```powershell
cd ProtonPortSync
powershell -ExecutionPolicy Bypass -File .\ProtonPortSync.Setup.ps1 -RegisterStartup
```

You will be asked for:

| Prompt        | Default                     |
|---------------|-----------------------------|
| WebUI URL     | `http://127.0.0.1:8080`     |
| Username      | `admin`                     |
| Password      | *(hidden input)*            |

The password is encrypted with **Windows DPAPI (CurrentUser)** — it is readable only
by your Windows account on this machine, never stored in plaintext.

`-RegisterStartup` installs a hidden logon task (`ProtonPortSync`) that starts the
service in the background. Omit it to run manually.

Non-interactive alternative (the password is read from an environment variable so it
does not end up in your shell history):

```powershell
$env:PROTONPORTSYNC_PASSWORD = 'yourpass'
.\ProtonPortSync.Setup.ps1 -WebUiUrl http://127.0.0.1:8080 -Username admin -RegisterStartup
```

`-Password 'yourpass'` still works, but Setup warns that it can be recorded in history.

## Updating

### Automatic updates (version 1.2.0 and newer)

The background service checks this project's GitHub releases every 6 hours and installs a
newer version **by itself, with no prompt and no action from you**. It then restarts itself
on the new version within seconds. Your settings, encrypted password and logs are never
touched, and nothing needs to be set up again.

How it stays safe:

* Only plain `vX.Y.Z` releases count. Pre-releases (`v1.3.0-beta.1`) and the macOS test
  builds (`macos-v...`) are ignored.
* Before anything is replaced, every downloaded script must parse and the version inside
  must match the release. A bad download changes nothing.
* The current files are backed up first (`%LOCALAPPDATA%\ProtonPortSync\backup\<version>`).
  If the new version fails to start 3 times in a row it is **rolled back automatically** and
  that version is skipped from then on.
* Only a fixed list of file names in the project folder is replaced - never anything else.
* A folder that is a **git checkout** is never auto-updated (use `git pull`).
* The log says what happened: `Updated ProtonPortSync 1.2.0 -> 1.2.1. Restarting.`

Please note this means the service runs code downloaded from this repository's releases
(over HTTPS, with your user rights). If you do not want that, turn it off:

```json
"AutoUpdate": false
```

in `%LOCALAPPDATA%\ProtonPortSync\config.json` (`"UpdateCheckHours": 6` sets the interval).
Commands for doing it by hand:

```powershell
.\ProtonPortSync.ps1 -CheckUpdate   # is a newer version out? (installs nothing)
.\ProtonPortSync.ps1 -Update        # install it now and restart the background service
```

> **Upgrading from 1.1.x to 1.2.0 is manual, once:** older versions do not contain the
> updater. Use the manual steps below. From 1.2.0 on, updates install themselves.

### Manual update (any version)

Your settings (`config.json`, the encrypted password) and the log live in
`%LOCALAPPDATA%\ProtonPortSync`, outside the project folder, so an update never touches them
and you do **not** need to run Setup again.

1. **Get the new files.** Either `git pull` in the project folder, or download the
   *Source code (zip)* of the latest [release](https://github.com/emperorgr/ProtonPortSync/releases/latest) and extract it over
   the old folder (same location, overwrite when asked).
2. **Stop the running service.** The old version keeps running from memory until you stop it.
   It is a hidden `powershell.exe`; this command stops only that one:

   ```powershell
   Get-CimInstance Win32_Process |
       Where-Object { $_.CommandLine -match 'ProtonPortSync\.ps1' -and $_.ProcessId -ne $PID } |
       ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
   ```
3. **Start the new one.** Either wait up to 10 minutes for the watchdog, or start it right away:

   ```powershell
   Start-ScheduledTask -TaskName ProtonPortSync
   ```
4. **Check it.** Run `.\ProtonPortSync.ps1 -Status` (it should say `IN SYNC`), and look for
   `ProtonPortSync <version> started` in `%LOCALAPPDATA%\ProtonPortSync\ProtonPortSync.log`.

If you **moved the project folder**, run `ProtonPortSync.Setup.ps1 -RegisterStartup` once from
the new location so the logon task points at it. If you run the service manually instead of
through the task, just stop it (step 2) and start it again the way you normally do.

See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

## Daily use

```powershell
# live status: VPN IP, forwarded port, NAT-PMP confirmation, qBittorrent port
.\ProtonPortSync.ps1 -Status

# run one sync cycle (useful for testing)
.\ProtonPortSync.ps1 -Once

# run in the foreground
.\ProtonPortSync.ps1

# custom poll interval (seconds, default 20)
.\ProtonPortSync.ps1 -IntervalSeconds 30
```

Log file: `%LOCALAPPDATA%\ProtonPortSync\ProtonPortSync.log` (auto-rotates at 1 MB).
Config:   `%LOCALAPPDATA%\ProtonPortSync\config.json`.

Steady state is silent on purpose (no repeated lines). A heartbeat is written every
30 minutes so "no output" never looks like a dead service.

## Behaviour in each situation

| Situation | What happens |
|---|---|
| VPN reconnects with a new port | Detected from the log (≤20 s), confirmed via NAT-PMP, pushed to qBittorrent |
| VPN disconnects | Nothing is applied; the stale-port guard stops writes once the log entry is >5 min old; resumes automatically on reconnect |
| qBittorrent is closed | The service keeps running and retrying; it syncs on the first poll after qBittorrent starts |
| qBittorrent starts with an outdated port | It loads the old port from its own config, then the service corrects it within ~20 s |
| Windows reboot / logoff | The logon task restarts the service, which syncs within ~20 s |
| Service process killed | A 10-minute watchdog trigger relaunches it; a global mutex makes duplicates exit instantly (a mutex left behind by the killed process is taken over cleanly) |
| Wrong qBittorrent password (401) | Logged once, then login attempts stop so the IP cannot be banned; resumes automatically when `config.json` changes (re-run Setup) |
| You edit `config.json` | Picked up on the next poll, no restart needed |
| A new GitHub release appears | Installed automatically within about 6 hours, service restarts itself (see *Updating*); rolled back if it cannot start |

The only hard requirement is that the service is running. It starts at logon and is
supervised by the watchdog, so in normal use nothing else is needed.

## Requirements / prerequisites

* ProtonVPN connected with **Port forwarding enabled** (Plus plan feature).
* qBittorrent → *Options → Connection*: **Network Interface = ProtonVPN**, and **Random port = off**.
* qBittorrent → *Options → Web UI*: **enabled**, with a username/password.

## Tests

```powershell
.\Test-Detection.ps1   # log parsing, NAT-PMP confirm, bogus-port rejection, status
.\Test-E2E-Mock.ps1    # full push against a mock qBittorrent WebAPI + idempotency
.\Test-RealClient.ps1  # sets listen_port=40000 on the real client, then restores it
```

Sample passing output:

```
PASS: port=43692 internal=43692 age=1s file=client-logs.txt
TCP=True UDP=True OK=True
PASS: 203.0.113.47
PASS: correctly rejected
...
PASS: qBittorrent port synced to 43692
PASS: second run was a no-op (idempotent)
```

## Uninstall

```powershell
.\Uninstall-ProtonPortSync.ps1
```

Removes the logon task, the hidden launcher and any running instance. The config
folder is left in place; delete `%LOCALAPPDATA%\ProtonPortSync` to remove it too.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ProtonVPN log directory not found` | Re-run Setup and pass the Logs folder, or set `LogDirectory` in config.json. |
| `No ProtonVPN port announcement found` | VPN not connected, or port forwarding disabled in the ProtonVPN app. |
| `NAT-PMP did not confirm` | VPN is reconnecting, or you are on a plan without port forwarding. |
| `401/403` from qBittorrent | Wrong WebUI password (401; the service stops retrying until you re-run Setup), or the IP is banned (403). |
| Port keeps reverting | Disable **Random port** in qBittorrent's connection settings. |

### If you ever get banned

qBittorrent bans the client IP after 5 failed logins (`WebUI\MaxAuthenticationFailCount`)
for `WebUI\BanDuration` seconds (default 3600). The ban list is **in memory only**, so
restarting qBittorrent clears it immediately. The service detects a ban and backs off for
5 minutes instead of retrying.

## Notes

* ProtonVPN's log rotates; the tool reads `client-logs*.txt` and always takes the
  newest `Port pair` line, so rotation is handled transparently.
* A warning is logged if the WebUI URL is plain `http://` on a non-local address, because the
  password would be sent unencrypted.
* Only `listen_port` is modified. No other qBittorrent setting is touched.
* Tested against qBittorrent 5.2.3 / WebAPI v2 and ProtonVPN 3.x logs.

## Disclaimer

This is an independent, unofficial project. It is not affiliated with, endorsed by or
supported by Proton AG or the qBittorrent project. "ProtonVPN" and "qBittorrent" are
trademarks of their respective owners and are used here only to describe compatibility.

Port forwarding is a paid ProtonVPN feature. Use this tool only with an account you are
entitled to use.

## Credits

Prior art: [Quantum](https://github.com/UHAXM1/Quantum) demonstrated that the ProtonVPN
client log is a workable source for the forwarded port. This project was written
independently, adds direct NAT-PMP verification, and runs on stock Windows PowerShell
without the .NET runtime.

## License

MIT — see [LICENSE](LICENSE).
