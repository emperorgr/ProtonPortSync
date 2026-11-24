# ProtonPortSync for macOS (beta)

Keeps **qBittorrent**'s listening port - and its **network interface** - in sync with
**ProtonVPN** port forwarding on a Mac, so you stay connectable without touching settings
by hand.

> **Beta.** This version has passed automated tests against a mock qBittorrent and a mock
> ProtonVPN gateway, but it has **not yet been run on a real Mac with real ProtonVPN**.
> See [Help wanted](#help-wanted--what-to-report) - your test report is the point of this
> release.

No dependencies: Python 3 standard library only.

## What it does on a Mac

ProtonVPN gives you one forwarded port per VPN session, and it changes on every reconnect.
On a Mac there is a second thing that changes: qBittorrent has no "ProtonVPN" entry in its
network interface list, only the tunnel's name (`utun4`, `utun5`, ...), and **the number can
be different each time you connect**. This tool handles both:

1. Asks the ProtonVPN gateway for the forwarded port (NAT-PMP - the same request Proton's
   own manual setup guide uses with `natpmpc`).
2. Works out which `utunN` interface carries the VPN traffic.
3. Sets qBittorrent's `listen_port` and network interface through its Web UI API, in a single
   request, and reads them back to check.

Safety rules:

* **It never unbinds.** If the VPN drops and no tunnel is found, qBittorrent stays bound to
  the old (now missing) interface, so torrents stop instead of leaking over your normal
  connection. It only ever switches to a *new* tunnel.
* A port is only applied when the gateway answers **and** returns the same port for UDP and
  TCP - so a disconnected VPN never pushes a stale port.
* Nothing is written when qBittorrent is already correct.
* A wrong Web UI password is tried **once**, then it stops until you run `setup` again, so
  qBittorrent cannot ban your IP.
* Your password is stored in the **macOS Keychain**, not in a file.

You can turn the interface handling off during setup (`--no-interface`) if you prefer to set
the interface yourself.

## Requirements

* macOS with **Python 3**. Check with `python3 --version` in Terminal. If it is missing,
  macOS offers to install Apple's command line tools; or run `xcode-select --install`.
* Proton VPN (paid plan) with **port forwarding turned on**, connected to a P2P server.
* qBittorrent → *Settings → Web UI*: **enabled**, with a username and password.
* qBittorrent → *Settings → Connection*: **Random port off**, and
  **"Use UPnP / NAT-PMP port forwarding from my router" off**.

## Install

1. Download the latest **macOS beta** zip from the
   [Releases](https://github.com/emperorgr/ProtonPortSync/releases) page and unzip it.
2. Open Terminal, go to the unzipped folder, and run setup:

   ```sh
   cd ~/Downloads/ProtonPortSync-macOS-*
   python3 protonportsync.py setup
   ```

   It asks for your Web UI address (default `http://127.0.0.1:8080`), username and password,
   tests the login, saves the settings, runs a first sync, and offers to **start automatically
   at login** (a launchd agent that also restarts itself if it ever stops).

The service runs from its own copy in `~/Library/Application Support/ProtonPortSync`, so you
can delete the download folder afterwards.

## Daily use

```sh
python3 protonportsync.py status     # VPN port, tunnel interface, qBittorrent state, IN SYNC?
python3 protonportsync.py once       # run one sync cycle now
tail -f ~/Library/Logs/ProtonPortSync/ProtonPortSync.log
```

Steady state is quiet on purpose: a line is written only when something changes, plus a
heartbeat every 30 minutes. If you installed it, run these from the installed copy:
`python3 ~/Library/Application\ Support/ProtonPortSync/protonportsync.py status`.

## Updating to a new build

Settings and your Keychain password are kept outside the download, so you do **not** run
`setup` again:

1. Download and unzip the new release.
2. In Terminal, from the new folder:

   ```sh
   python3 protonportsync.py install
   ```

   This stops the old service, replaces its copy with the new version and starts it again.
3. Check: `python3 protonportsync.py status`, and look for
   `ProtonPortSync <version> started` in the log.

## Uninstall

```sh
python3 protonportsync.py uninstall            # remove the background service, keep settings
python3 protonportsync.py uninstall --purge    # also delete settings, Keychain entry and logs
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No answer from the ProtonVPN gateway` | VPN not connected, not on a P2P server, or port forwarding is off in the Proton app. |
| `Could not find the VPN tunnel interface` | The tool could not match a `utunN` to the VPN. Port sync still works; see *What to report*. |
| `rejected the username/password` | Wrong Web UI credentials. Run `setup` again. |
| `banned this IP` | Too many failed logins. Restart qBittorrent (clears the ban); the tool waits 5 minutes. |
| Port keeps reverting | Turn off *Random port* in qBittorrent's connection settings. |
| Keychain asks for permission | Choose **Always Allow** once; please tell us (see below). |

## Help wanted - what to report

This beta is built from Proton's documentation and automated tests, so a few things need a real
Mac to confirm. Please report (redact your public/VPN IP addresses):

1. Did `setup` finish, and does `status` say **IN SYNC** while connected to Proton?
2. Is the port shown by `status` the **same port the Proton VPN app shows**?
3. Did qBittorrent accept the interface (*Settings → Connection → Network interface* shows
   `utunN`)? And after you **disconnect and reconnect**, did it follow to the new `utunN`?
4. Does it start at login and survive a reboot? Any **Keychain prompt** under launchd?
5. If something failed: the output of `python3 protonportsync.py status`, the last lines of
   `~/Library/Logs/ProtonPortSync/ProtonPortSync.log`, and the output of
   `route -n get 10.2.0.1` while connected.

Open an [issue](https://github.com/emperorgr/ProtonPortSync/issues) or reply on the Reddit
thread.

## Tests

```sh
cd macos
python3 -m unittest discover -s tests -v
```

Covers NAT-PMP packets, route/ifconfig parsing, and end-to-end runs against a mock
qBittorrent API and a mock gateway (port change, new tunnel after reconnect, VPN down,
mismatched ports, wrong password, qBittorrent not running).

## Differences from the Windows version

| | Windows | macOS (beta) |
|---|---|---|
| Language | PowerShell 5.1 | Python 3 |
| Finds the port from | ProtonVPN app log, confirmed by NAT-PMP | NAT-PMP only (no app log needed) |
| Network interface | Set once by hand ("ProtonVPN" adapter keeps its name) | Detected and set automatically |
| Password storage | Windows DPAPI | macOS Keychain |
| Background service | Scheduled task + 10-min watchdog | launchd agent (restarts itself) |

Independent, unofficial project; not affiliated with Proton AG or the qBittorrent project.
MIT licensed - see [LICENSE](../LICENSE).
