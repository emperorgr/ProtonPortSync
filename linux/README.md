# ProtonPortSync for Linux (beta)

Keeps **qBittorrent**'s listening port - and its **network interface** - in sync with
**ProtonVPN** port forwarding on Linux, so you stay connectable without touching settings
by hand.

> **Beta.** This version has passed automated tests against a mock qBittorrent and a mock
> ProtonVPN gateway, but it has **not yet been run on a real Linux machine with real
> ProtonVPN**. See [Help wanted](#help-wanted--what-to-report) - your test report is the point
> of this release.

No dependencies: Python 3 standard library only (3.8+). Optional: `secret-tool` for the
desktop keyring.

## What it does

ProtonVPN gives you one forwarded port per VPN session, and it changes on every reconnect.
This tool:

1. Asks the ProtonVPN gateway for the forwarded port (NAT-PMP - the same request Proton's
   own manual setup guide uses with `natpmpc`). This works with the **Proton VPN app, plain
   WireGuard or OpenVPN** - it does not depend on any app's log.
2. Works out which tunnel interface (`proton0`, `wg0`, `tun0` ...) carries the VPN traffic.
3. Sets qBittorrent's `listen_port` and network interface through its Web UI API, in a single
   request, and reads them back to check.

Safety rules:

* **It never unbinds.** If the VPN drops, qBittorrent stays bound to the old (now missing)
  interface, so torrents stop instead of leaking over your normal connection. It never binds
  to `eth0`/`wlan0`: only tunnel devices (tun, tap, WireGuard) are accepted.
* A port is only applied when the gateway answers **and** returns the same port for UDP and
  TCP - so a disconnected VPN never pushes a stale port.
* Nothing is written when qBittorrent is already correct.
* A wrong Web UI password is tried **once**, then it stops until you run `setup` again, so
  qBittorrent cannot ban your IP.
* Your password goes into the **desktop keyring** (libsecret) when available, otherwise into
  a file that only your user can read (mode 600). It is never put in the config file or on a
  command line.

You can turn the interface handling off during setup (`--no-interface`).

## Requirements

* Linux with **Python 3.8+** (`python3 --version`) and the `ip` command (package `iproute2`,
  present on practically every distribution).
* A running **systemd user session** for auto-start (any current desktop distribution).
  Without systemd you can still run `python3 protonportsync.py run` from your own autostart.
* Proton VPN (paid plan) with **port forwarding on**, connected to a P2P server.
* qBittorrent → *Tools → Options → Web UI*: **enabled**, with a username and password.
* qBittorrent → *Tools → Options → Connection*: **Random port off**, and
  **"Use UPnP / NAT-PMP port forwarding from my router" off**.
* Optional, for keyring storage: `secret-tool` (Debian/Ubuntu: `libsecret-tools`,
  Fedora: `libsecret`, Arch: `libsecret`).

## Install

1. Download the latest **Linux beta** zip from the
   [Releases](https://github.com/emperorgr/ProtonPortSync/releases) page and unzip it.
2. Open a terminal in the unzipped folder and run setup:

   ```sh
   cd ~/Downloads/ProtonPortSync-Linux-*
   python3 protonportsync.py setup
   ```

   It asks for your Web UI address (default `http://127.0.0.1:8080`), username and password,
   tests the login, saves the settings, runs a first sync, and offers to **start
   automatically at login** (a systemd user service that also restarts itself).

   No keyring? It offers to keep the password in `~/.config/protonportsync/password`
   (mode 600) instead. On a server or script use `--password-file` and `--password-stdin`.

Where things live (XDG standard): settings in `~/.config/protonportsync`, the service's own copy
of the script in `~/.local/share/protonportsync`, logs in `~/.local/state/protonportsync`.
You can delete the download folder afterwards.

**Headless machine?** A user service normally stops when you log out. Run
`loginctl enable-linger` once and it keeps running.

**qBittorrent in Docker?** Use the container's published Web UI address in setup. Note that the
tunnel interface name is only meaningful when qBittorrent runs on the same host network as
the VPN; otherwise run setup with `--no-interface`.

## Daily use

```sh
python3 ~/.local/share/protonportsync/protonportsync.py status   # port, interface, IN SYNC?
python3 ~/.local/share/protonportsync/protonportsync.py once     # one sync cycle now
tail -f ~/.local/state/protonportsync/ProtonPortSync.log
systemctl --user status protonportsync
```

Steady state is quiet on purpose: a line is written only when something changes, plus a
heartbeat every 30 minutes.

## Updating to a new build

Settings and your password are kept outside the download, so you do **not** run `setup` again:

1. Download and unzip the new release.
2. From the new folder: `python3 protonportsync.py install`
   (replaces the service's copy and restarts it).
3. Check: `python3 protonportsync.py status`.

## Uninstall

```sh
python3 protonportsync.py uninstall            # remove the service, keep settings
python3 protonportsync.py uninstall --purge    # also delete settings, saved password and logs
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No answer from the ProtonVPN gateway` | VPN not connected, not a P2P server, or port forwarding is off in the Proton app / config. |
| `Could not find the VPN tunnel interface` | Port sync still works. Run `ip -o route get 10.2.0.1` while connected and report the output. |
| `Password not found` | The service could not read the keyring (locked, or no session bus). Run `setup --password-file`. |
| `rejected the username/password` | Wrong Web UI credentials. Run `setup` again. |
| `banned this IP` | Too many failed logins. Restart qBittorrent (clears the ban); the tool waits 5 minutes. |
| Port keeps reverting | Turn off *Random port* in qBittorrent's connection settings. |
| Service not running after reboot | Make sure `systemctl --user is-enabled protonportsync` says enabled; headless boxes need `loginctl enable-linger`. |

## Help wanted - what to report

Built from Proton's documentation and automated tests, so a few things need a real machine to
confirm. Please report (redact your public/VPN IP addresses):

1. Which setup: Proton VPN app, WireGuard config, or OpenVPN? Which distribution?
2. Did `setup` finish, and does `status` say **IN SYNC** while connected?
3. Is the port shown by `status` the **same port the Proton VPN app/website shows**?
4. Did qBittorrent accept the interface (*Options → Advanced → Network interface*)? After you
   **disconnect and reconnect**, did it follow?
5. Does it start at login and survive a reboot? Did the keyring work under systemd?
6. If something failed: the output of `status`, the last lines of
   `~/.local/state/protonportsync/ProtonPortSync.log`, and `ip -o route get 10.2.0.1`.

Open an [issue](https://github.com/emperorgr/ProtonPortSync/issues) or reply on the Reddit
thread.

## Tests

```sh
cd linux
python3 -m unittest discover -s tests -v
```

Covers NAT-PMP packets, tunnel detection (against a fake `/sys/class/net`), the systemd unit,
XDG paths, the private password file, and end-to-end runs against a mock qBittorrent API and a
mock gateway (port change, new tunnel after reconnect, VPN down, mismatched ports, wrong
password, qBittorrent not running).

## Differences from the other versions

| | Windows | macOS (beta) | Linux (beta) |
|---|---|---|---|
| Language | PowerShell 5.1 | Python 3 | Python 3 |
| Finds the port from | Proton app log + NAT-PMP | NAT-PMP only | NAT-PMP only |
| Network interface | Set once by hand | Detected (`utunN`) | Detected (`proton0`, `wg0`, `tun0` ...) |
| Password storage | Windows DPAPI | macOS Keychain | Keyring (libsecret) or mode-600 file |
| Background service | Scheduled task | launchd agent | systemd user service |
| Auto-update | Yes (1.2.0+) | No | No |

Independent, unofficial project; not affiliated with Proton AG or the qBittorrent project.
MIT licensed - see [LICENSE](../LICENSE).
