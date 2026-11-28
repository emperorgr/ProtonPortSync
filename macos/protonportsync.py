#!/usr/bin/env python3
"""ProtonPortSync for macOS (beta).

Keeps qBittorrent's listening port - and, optionally, its network interface -
in sync with ProtonVPN port forwarding.

Pure Python 3 standard library (3.8+), no third-party packages.

Usage:
    python3 protonportsync.py setup        one-time configuration (+ optional auto-start)
    python3 protonportsync.py status       show VPN port, interface and qBittorrent state
    python3 protonportsync.py once         run a single sync cycle
    python3 protonportsync.py run          run in the foreground (what launchd runs)
    python3 protonportsync.py install      (re)install the LaunchAgent - use this to update
    python3 protonportsync.py uninstall    remove the LaunchAgent  (--purge also removes data)
    python3 protonportsync.py support-bundle   zip with checks, recent log and settings (secrets removed)
    python3 protonportsync.py version

How it works
    1. Ask the ProtonVPN gateway (NAT-PMP, 10.2.0.1:5351) for the forwarded port.
       This is the same request Proton documents for `natpmpc -a 1 0 udp 60 -g 10.2.0.1`.
       It also keeps the 60 s lease alive.
    2. Find the utunN interface that carries the VPN traffic (it changes between
       connections, which is why it cannot be chosen once in qBittorrent's options).
    3. Push listen_port (and current_network_interface) to qBittorrent's Web UI API.
"""

import argparse
import datetime
import getpass
import json
import logging
import logging.handlers
import os
import plistlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import http.cookiejar
import ipaddress
import platform
import zipfile

try:
    import fcntl
except ImportError:  # pragma: no cover - not available on Windows
    fcntl = None

__version__ = '0.2.0-beta.1'

APP_NAME = 'ProtonPortSync'
LABEL = 'com.github.emperorgr.protonportsync'
KEYCHAIN_SERVICE = 'ProtonPortSync'

DEFAULTS = {
    'webui_url': 'http://127.0.0.1:8080',
    'username': 'admin',
    'nat_pmp_gateway': '10.2.0.1',
    'nat_pmp_port': 5351,
    'interval_seconds': 20,
    'manage_interface': True,
    'last_applied_port': 0,
    'status_file': True,
    'on_port_change': '',
    'port_check': False,
    'port_check_url': 'https://portcheck.transmissionbt.com/{port}',
    'port_check_minutes': 30,
}

NATPMP_TIMEOUT = 2.0      # seconds per attempt (tests lower this)
NATPMP_TRIES = 2
NATPMP_LIFETIME = 60
HTTP_TIMEOUT = 8
BAN_BACKOFF_SECONDS = 300
HEARTBEAT_SECONDS = 30 * 60
STATUS_WRITE_SECONDS = 300
HOOK_TIMEOUT = 15

PLATFORM_LABEL = 'macOS'
QBT_OPTIONS = 'Settings'
TUNNEL_EXAMPLE = 'utunN'
IFACE_LOOKUP_CMD = 'route -n get 10.2.0.1'
EXTRA_LOG_NAMES = ('launchd.log',)

OP_ADDRESS, OP_UDP, OP_TCP = 0, 1, 2   # RFC 6886

log = logging.getLogger('pps')
OK_LEVEL = 25
logging.addLevelName(OK_LEVEL, 'OK')
logging.addLevelName(logging.WARNING, 'WARN')


# --------------------------------------------------------------------------- paths

def support_dir():
    return os.environ.get('PROTONPORTSYNC_HOME') or \
        os.path.expanduser('~/Library/Application Support/ProtonPortSync')


def log_dir():
    if os.environ.get('PROTONPORTSYNC_LOGDIR'):
        return os.environ['PROTONPORTSYNC_LOGDIR']
    if os.environ.get('PROTONPORTSYNC_HOME'):
        return os.path.join(os.environ['PROTONPORTSYNC_HOME'], 'logs')
    return os.path.expanduser('~/Library/Logs/ProtonPortSync')


def default_config_path():
    return os.path.join(support_dir(), 'config.json')


def plist_path():
    return os.path.expanduser('~/Library/LaunchAgents/%s.plist' % LABEL)


# --------------------------------------------------------------------------- config

class ConfigError(Exception):
    pass


def load_config(path):
    if not os.path.exists(path):
        raise ConfigError('Config not found: %s. Run "python3 protonportsync.py setup" first.' % path)
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as exc:
        raise ConfigError('Cannot read %s: %s' % (path, exc))
    cfg = dict(DEFAULTS)
    cfg.update(raw)
    return cfg


def save_config(path, cfg):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    tmp = path + '.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(cfg, fh, indent=2, sort_keys=True)
        fh.write('\n')
    os.replace(tmp, path)


# --------------------------------------------------------------------------- helpers

def run_command(args, timeout=10):
    """Run a command and return (returncode, stdout). Never raises."""
    try:
        proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout, universal_newlines=True)
        return proc.returncode, proc.stdout
    except FileNotFoundError:
        return 127, ''
    except (subprocess.TimeoutExpired, OSError):
        return 1, ''


def is_macos():
    return sys.platform == 'darwin'


# --------------------------------------------------------------------------- keychain

def get_password(cfg):
    env = os.environ.get('PROTONPORTSYNC_PASSWORD')
    if env:
        return env
    if not is_macos():
        raise ConfigError('No Keychain on this platform; set PROTONPORTSYNC_PASSWORD.')
    rc, out = run_command(['/usr/bin/security', 'find-generic-password',
                           '-a', cfg['username'], '-s', KEYCHAIN_SERVICE, '-w'])
    if rc != 0 or not out:
        raise ConfigError('Password not found in the macOS Keychain. Run "python3 protonportsync.py setup" again.')
    return out.rstrip('\n')


def store_password(username, password):
    """Store in the login Keychain. Note: `security` takes the password as an
    argument, so it is visible to other local users via `ps` for a few milliseconds."""
    rc, _ = run_command(['/usr/bin/security', 'add-generic-password', '-a', username,
                         '-s', KEYCHAIN_SERVICE, '-w', password, '-U'])
    return rc == 0


def delete_password(username):
    run_command(['/usr/bin/security', 'delete-generic-password', '-a', username, '-s', KEYCHAIN_SERVICE])


# --------------------------------------------------------------------------- NAT-PMP

class NatPmpError(Exception):
    pass


def build_request(opcode, internal_port=0, suggested_port=0, lifetime=0):
    if opcode == OP_ADDRESS:
        return struct.pack('!BB', 0, 0)
    return struct.pack('!BBHHHI', 0, opcode, 0, internal_port, suggested_port, lifetime)


def parse_response(data, opcode):
    """Return the external IP (opcode 0) or (internal, external, lifetime). None if malformed."""
    if len(data) < 8:
        return None
    _version, op, result = struct.unpack('!BBH', data[:4])
    if op != opcode + 128:
        return None
    if result != 0:
        raise NatPmpError('gateway returned result code %d' % result)
    if opcode == OP_ADDRESS:
        if len(data) < 12:
            return None
        return socket.inet_ntoa(data[8:12])
    if len(data) < 16:
        return None
    return struct.unpack('!HHI', data[8:16])


def natpmp_exchange(gateway, port, opcode, internal_port=0, suggested_port=0, lifetime=0):
    """Send one request, return the parsed response or None on timeout/unreachable."""
    packet = build_request(opcode, internal_port, suggested_port, lifetime)
    for _ in range(NATPMP_TRIES):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.settimeout(NATPMP_TIMEOUT)
            sock.connect((gateway, port))     # connect() makes the kernel drop other senders
            sock.send(packet)
            data = sock.recv(64)
        except socket.timeout:
            continue
        except OSError:
            return None                        # network unreachable / refused: VPN is down
        finally:
            sock.close()
        try:
            return parse_response(data, opcode)
        except NatPmpError as exc:
            log.warning('NAT-PMP: %s', exc)
            return None
    return None


def discover_port(cfg):
    """Ask the gateway for the forwarded port on UDP and TCP. Returns the port or None."""
    gw, gp = cfg['nat_pmp_gateway'], int(cfg['nat_pmp_port'])
    udp = natpmp_exchange(gw, gp, OP_UDP, internal_port=1, suggested_port=0, lifetime=NATPMP_LIFETIME)
    if udp is None:
        log.warning('No answer from the ProtonVPN gateway %s - is the VPN connected with port forwarding on?', gw)
        return None
    tcp = natpmp_exchange(gw, gp, OP_TCP, internal_port=1, suggested_port=0, lifetime=NATPMP_LIFETIME)
    if tcp is None:
        log.warning('Gateway answered for UDP (port %d) but not for TCP; not applying.', udp[1])
        return None
    if udp[1] != tcp[1]:
        log.warning('Gateway returned different ports for UDP (%d) and TCP (%d); not applying.', udp[1], tcp[1])
        return None
    port = udp[1]
    if not 1 <= port <= 65535:
        return None
    return port


def get_public_ip(cfg):
    ip = natpmp_exchange(cfg['nat_pmp_gateway'], int(cfg['nat_pmp_port']), OP_ADDRESS)
    return ip if isinstance(ip, str) else None


# --------------------------------------------------------------------------- VPN interface

_ROUTE_IFACE = re.compile(r'^\s*interface:\s*(\S+)\s*$', re.M)
_UTUN = re.compile(r'^utun\d+$')


def parse_route_interface(text):
    match = _ROUTE_IFACE.search(text or '')
    return match.group(1) if match else None


def parse_ifconfig_vpn(text, prefix):
    """Fallback: first utunN interface that has an inet address starting with prefix."""
    current = None
    for line in (text or '').splitlines():
        header = re.match(r'^(\S+?):\s+flags=', line)
        if header:
            current = header.group(1)
            continue
        if current and _UTUN.match(current) and re.match(r'^\s+inet\s+%s' % re.escape(prefix), line):
            return current
    return None


def detect_vpn_interface(gateway, runner=None):
    """Name of the utunN interface that carries traffic to the VPN gateway, or None."""
    runner = runner or run_command
    rc, out = runner(['/sbin/route', '-n', 'get', gateway])
    if rc == 0:
        iface = parse_route_interface(out)
        return iface if iface and _UTUN.match(iface) else None
    # `route` unavailable or failed: look for a tunnel holding a 10.2.x.x address
    rc, out = runner(['/sbin/ifconfig'])
    if rc == 0:
        return parse_ifconfig_vpn(out, '.'.join(gateway.split('.')[:2]) + '.')
    return None


# --------------------------------------------------------------------------- qBittorrent

class QbtError(Exception):
    pass


class QbtAuthError(QbtError):
    pass


class QbtBanned(QbtError):
    pass


class QbtUnreachable(QbtError):
    pass


class QbtSessionExpired(QbtError):
    pass


class Qbt:
    """Minimal qBittorrent WebAPI v2 client.

    No Origin/Referer header is sent: qBittorrent's CSRF check explicitly allows
    API clients that send neither.
    """

    def __init__(self, base_url, username, password):
        self.base = base_url.rstrip('/')
        self.username = username
        self.password = password
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def _call(self, path, data=None, login=False):
        body = None
        if data is not None:
            body = urllib.parse.urlencode(data).encode('utf-8')
        request = urllib.request.Request(self.base + path, data=body)
        try:
            with self.opener.open(request, timeout=HTTP_TIMEOUT) as resp:
                return resp.status, resp.read().decode('utf-8', 'replace')
        except urllib.error.HTTPError as exc:
            text = ''
            try:
                text = exc.read().decode('utf-8', 'replace')
            except Exception:
                pass
            if login:
                if exc.code == 401:
                    raise QbtAuthError('qBittorrent rejected the username/password (401 Unauthorized).')
                if exc.code == 403:
                    if 'banned' in text.lower():
                        raise QbtBanned('qBittorrent has banned this IP after repeated failed logins. '
                                        'Restart qBittorrent (clears the in-memory ban) or wait for it to expire.')
                    raise QbtError('qBittorrent refused the login (403). %s' % text.strip())
            if exc.code in (401, 403):
                raise QbtSessionExpired('session expired (HTTP %d)' % exc.code)
            raise QbtError('qBittorrent returned HTTP %d for %s' % (exc.code, path))
        except (urllib.error.URLError, socket.timeout, ConnectionError, OSError) as exc:
            reason = getattr(exc, 'reason', exc)
            raise QbtUnreachable('qBittorrent WebAPI unreachable: %s' % reason)

    def login(self):
        _status, text = self._call('/api/v2/auth/login',
                                   {'username': self.username, 'password': self.password}, login=True)
        text = text.strip()
        if text == 'Fails.':
            raise QbtAuthError('qBittorrent rejected the username/password.')
        if text and not text.startswith('Ok.'):
            raise QbtError("Unexpected login response from qBittorrent: '%s'" % text)
        # Definitive check: an authenticated endpoint must answer with this session.
        try:
            self._call('/api/v2/app/version')
        except QbtSessionExpired:
            raise QbtError('Login did not establish an authenticated session.')

    def preferences(self):
        _status, text = self._call('/api/v2/app/preferences')
        try:
            return json.loads(text)
        except ValueError:
            raise QbtError('qBittorrent returned unreadable preferences.')

    def set_preferences(self, changes):
        self._call('/api/v2/app/setPreferences', {'json': json.dumps(changes, separators=(',', ':'))})


# --------------------------------------------------------------------------- sync

class State:
    def __init__(self):
        self.qbt = None
        self.last_port = None
        self.auth_failed_stamp = None
        self.ban_until = 0.0
        self.http_warned = False
        self.iface_missing_logged = False
        self.warned = set()
        self.cycle = None
        self.last_port_change = None
        self.port_reachable = None
        self.port_checked_utc = None
        self.port_checked_port = None
        self.next_port_check = None
        self.port_closed_count = 0
        self.status_signature = None
        self.status_written_at = 0.0

    def warn_once(self, key, message):
        """Log a warning once per condition; re-arm it when the condition clears."""
        if key not in self.warned:
            self.warned.add(key)
            log.warning('%s', message)


def _config_stamp(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


def _connect(cfg, state, force=False):
    if force or state.qbt is None:
        client = Qbt(cfg['webui_url'], cfg['username'], get_password(cfg))
        client.login()
        state.qbt = client
    return state.qbt


def sync_cycle(cfg, state, config_path):
    """One detection + push cycle. Returns True when qBittorrent is in sync."""
    state.cycle = new_cycle()
    port = discover_port(cfg)
    if port is None:
        state.cycle['state'] = 'vpn_down'
        return False
    state.cycle['vpn_connected'] = True
    state.cycle['forwarded_port'] = port
    if state.last_port != port:
        state.last_port = port
        log.info('Detected ProtonVPN forwarded port %d (VPN IP %s)', port, get_public_ip(cfg) or 'unknown')

    iface = None
    if cfg['manage_interface']:
        iface = detect_vpn_interface(cfg['nat_pmp_gateway'])
        if iface is None and not state.iface_missing_logged:
            state.iface_missing_logged = True
            log.warning('Could not find the VPN tunnel interface (utunN); leaving the qBittorrent '
                        'network interface setting unchanged.')
        elif iface is not None:
            state.iface_missing_logged = False

    # After a rejected password do NOT keep retrying: five bad logins get this IP banned.
    if state.auth_failed_stamp is not None:
        if _config_stamp(config_path) == state.auth_failed_stamp:
            state.cycle.update(state='auth_failed', error='qBittorrent rejected the username or password.')
            return False
        state.auth_failed_stamp = None
        log.info('Configuration changed; retrying qBittorrent login.')

    parsed = urllib.parse.urlparse(cfg['webui_url'])
    if (not state.http_warned and parsed.scheme == 'http'
            and parsed.hostname not in ('127.0.0.1', 'localhost', '::1')):
        state.http_warned = True
        log.warning('WebUI URL is plain HTTP on a non-local address: the password is sent unencrypted.')

    try:
        client = _connect(cfg, state)
        try:
            prefs = client.preferences()
        except (QbtSessionExpired, QbtUnreachable):
            state.qbt = None                      # expired session or qBittorrent restarted
            client = _connect(cfg, state, force=True)
            prefs = client.preferences()

        state.cycle['qbittorrent_port'] = int(prefs.get('listen_port', 0))
        if prefs.get('random_port'):
            state.warn_once('random_port', 'qBittorrent has "random_port" enabled - it will override this sync. Disable it.')
        else:
            state.warned.discard('random_port')
        if prefs.get('upnp'):
            state.warn_once('upnp', 'qBittorrent has "Use UPnP / NAT-PMP port forwarding" enabled - '
                                    'Proton recommends disabling it.')
        else:
            state.warned.discard('upnp')

        changes = {}
        if int(prefs.get('listen_port', 0)) != port:
            changes['listen_port'] = port
        current_iface = prefs.get('current_network_interface', '')
        if iface and current_iface != iface:
            changes['current_network_interface'] = iface
            if prefs.get('current_interface_address'):
                changes['current_interface_address'] = ''     # a stale bound address would break the bind

        if not changes:
            where = ' via %s' % iface if iface else ''
            log.log(OK_LEVEL, 'qBittorrent already listens on %d%s; nothing to do.', port, where)
        else:
            client.set_preferences(changes)
            time.sleep(0.4)
            after = client.preferences()
            if 'listen_port' in changes:
                if int(after.get('listen_port', 0)) != port:
                    log.error('qBittorrent did not accept the new port (still %s).', after.get('listen_port'))
                    state.cycle.update(state='error', qbittorrent_port=int(after.get('listen_port', 0)),
                                       error='qBittorrent did not accept the new port.')
                    return False
            if 'current_network_interface' in changes and after.get('current_network_interface') != iface:
                log.warning('qBittorrent did not accept network interface "%s" (still "%s").',
                            iface, after.get('current_network_interface'))
            parts = []
            if 'listen_port' in changes:
                parts.append('listen_port %s -> %d' % (prefs.get('listen_port'), port))
            if 'current_network_interface' in changes:
                parts.append('network interface "%s" -> "%s"' % (current_iface, iface))
            log.log(OK_LEVEL, 'Updated qBittorrent: %s', ', '.join(parts))
            state.cycle['qbittorrent_port'] = int(after.get('listen_port', 0))
            if 'listen_port' in changes:
                state.last_port_change = _iso(time.time())
                run_hook(cfg, int(prefs.get('listen_port', 0)), port)

        state.cycle.update(state='in_sync', in_sync=True)
        if cfg.get('last_applied_port') != port:
            cfg['last_applied_port'] = port
            try:
                save_config(config_path, cfg)
            except OSError:
                pass
        return True

    except QbtBanned as exc:
        state.cycle.update(state='qbt_banned', error=str(exc))
        state.ban_until = time.time() + BAN_BACKOFF_SECONDS
        log.error('%s', exc)
    except QbtAuthError as exc:
        state.cycle.update(state='auth_failed', error=str(exc))
        state.auth_failed_stamp = _config_stamp(config_path)
        state.qbt = None
        log.error('%s Not retrying until the configuration changes - run "setup" again.', exc)
    except QbtUnreachable as exc:
        state.cycle.update(state='qbt_unreachable', error=str(exc))
        state.qbt = None
        log.warning('%s', exc)
    except ConfigError as exc:
        state.cycle.update(state='error', error=str(exc))
        log.error('%s', exc)
    except QbtError as exc:
        state.cycle.update(state='error', error=str(exc))
        state.qbt = None
        log.error('qBittorrent sync failed: %s', exc)
    return False


# --------------------------------------------------------------------------- status file, hook, checks, bundle

def status_path(config_path):
    return os.path.join(os.path.dirname(os.path.abspath(config_path)), 'status.json')


def _iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def new_cycle():
    return {'state': 'starting', 'in_sync': False, 'vpn_connected': False,
            'forwarded_port': None, 'qbittorrent_port': None, 'error': None}


def write_status(cfg, state, path, force=False, now=None):
    """Write status.json. Only rewritten when something besides the timestamp changed,
    or every STATUS_WRITE_SECONDS, to avoid needless disk writes."""
    if not cfg.get('status_file', True) or not state.cycle:
        return
    cyc = state.cycle
    data = {
        'version': __version__,
        'state': cyc['state'],
        'inSync': bool(cyc['in_sync']),
        'vpnConnected': bool(cyc['vpn_connected']),
        'forwardedPort': cyc['forwarded_port'],
        'qbittorrentPort': cyc['qbittorrent_port'],
        'lastPortChangeUtc': state.last_port_change,
        'lastError': cyc['error'],
        'portReachable': state.port_reachable,
        'portCheckedUtc': state.port_checked_utc,
    }
    signature = json.dumps(data, sort_keys=True)
    now = time.time() if now is None else now
    if (not force and signature == state.status_signature
            and now - state.status_written_at < STATUS_WRITE_SECONDS):
        return
    data['updatedUtc'] = _iso(now)
    try:
        tmp = path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as fh:
            json.dump(data, fh, indent=2)
            fh.write('\n')
        os.replace(tmp, path)
        state.status_signature = signature
        state.status_written_at = now
    except OSError:
        pass


def run_hook(cfg, old_port, new_port):
    """Run the program named in on_port_change after qBittorrent accepted a new port.
    The details arrive in environment variables: PPS_EVENT, PPS_NEW_PORT, PPS_OLD_PORT, PPS_VERSION."""
    raw = str(cfg.get('on_port_change') or '').strip().strip('"')
    if not raw:
        return
    if not os.path.isabs(raw) or not os.path.isfile(raw):
        log.warning('on_port_change: file not found: %s (give the full path to a script or program).', raw)
        return
    if raw.endswith('.py'):
        argv = [sys.executable or 'python3', raw]
    elif os.access(raw, os.X_OK):
        argv = [raw]
    else:
        log.warning('on_port_change: %s is not executable (run chmod +x on it, or use a .py file).', raw)
        return
    env = dict(os.environ, PPS_EVENT='port_changed', PPS_NEW_PORT=str(new_port),
               PPS_OLD_PORT=str(old_port), PPS_VERSION=__version__)
    try:
        proc = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=HOOK_TIMEOUT)
        if proc.returncode != 0:
            log.warning('on_port_change: %s exited with code %d.', raw, proc.returncode)
        else:
            log.info('on_port_change: ran %s.', raw)
    except subprocess.TimeoutExpired:
        log.warning('on_port_change: %s did not finish within %d seconds and was stopped.', raw, HOOK_TIMEOUT)
    except OSError as exc:
        log.warning('on_port_change: could not run %s - %s', raw, exc)


def fetch_text(url, timeout=10):
    """Small GET returning text, or None on any failure (tests replace this)."""
    try:
        request = urllib.request.Request(url, headers={'User-Agent': 'ProtonPortSync/%s' % __version__})
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            return resp.read(200).decode('ascii', 'replace')
    except Exception:
        return None


def check_port_reachable(cfg, port):
    """True = open, False = closed, None = unknown (service unavailable or odd answer)."""
    template = str(cfg.get('port_check_url') or DEFAULTS['port_check_url'])
    text = fetch_text(template.replace('{port}', str(int(port))))
    if text is None:
        return None
    text = text.strip()
    return True if text == '1' else False if text == '0' else None


def port_check_if_due(cfg, state, now=None):
    """Optional internet check of the forwarded port. Warns only, never changes anything.
    Starts 2 minutes after a new port; "closed" is reported after two closed answers in a row;
    an unreachable check service is never reported as closed."""
    if not cfg.get('port_check'):
        return
    cyc = state.cycle
    if not cyc or not cyc['in_sync'] or not cyc['forwarded_port']:
        state.port_closed_count = 0
        return
    now = time.time() if now is None else now
    port = int(cyc['forwarded_port'])
    if state.port_checked_port != port:
        state.port_checked_port = port
        state.port_reachable = None
        state.port_closed_count = 0
        state.next_port_check = now + 120
    if state.next_port_check is None:
        state.next_port_check = now + 120
    if now < state.next_port_check:
        return
    try:
        minutes = max(5, int(cfg.get('port_check_minutes') or 30))
    except (TypeError, ValueError):
        minutes = 30
    state.next_port_check = now + minutes * 60
    result = check_port_reachable(cfg, port)
    state.port_checked_utc = _iso(now)
    if result is True:
        state.port_closed_count = 0
        state.port_reachable = True
        log.log(OK_LEVEL, 'Port %d is reachable from the internet.', port)
    elif result is False:
        state.port_closed_count += 1
        if state.port_closed_count >= 2:
            state.port_reachable = False
            log.warning('Port %d looks CLOSED from the internet. Check that qBittorrent is running and not '
                        'blocked by a firewall, and that you are on a P2P server with port forwarding on.', port)
            state.next_port_check = now + 300       # look again soon so the status recovers quickly
        else:
            state.next_port_check = now + 120
    else:
        log.info('Port check service gave no usable answer; will try again later.')


def gather_snapshot(cfg):
    """Everything `status` and `support-bundle` report on (talks to the VPN gateway and qBittorrent)."""
    gw, gp = cfg['nat_pmp_gateway'], int(cfg['nat_pmp_port'])
    snap = {'version': __version__, 'webui_url': cfg['webui_url'], 'vpn_ip': get_public_ip(cfg),
            'udp': None, 'tcp': None, 'port': None, 'vpn_iface': None,
            'manage_interface': bool(cfg.get('manage_interface')),
            'qbt_ok': False, 'qbt_error': '', 'qbt_error_kind': '', 'qbt_port': None, 'qbt_iface': '',
            'random_port': False, 'upnp': False, 'in_sync': False, 'port_reachable': None}
    if snap['vpn_ip']:
        udp = natpmp_exchange(gw, gp, OP_UDP, 1, 0, NATPMP_LIFETIME)
        tcp = natpmp_exchange(gw, gp, OP_TCP, 1, 0, NATPMP_LIFETIME)
        snap['udp'] = udp[1] if udp else None
        snap['tcp'] = tcp[1] if tcp else None
        if udp and tcp and udp[1] == tcp[1]:
            snap['port'] = udp[1]
    snap['vpn_iface'] = detect_vpn_interface(gw)
    try:
        client = Qbt(cfg['webui_url'], cfg['username'], get_password(cfg))
        client.login()
        prefs = client.preferences()
        snap['qbt_ok'] = True
        snap['qbt_port'] = int(prefs.get('listen_port', 0))
        snap['qbt_iface'] = prefs.get('current_network_interface', '') or ''
        snap['random_port'] = bool(prefs.get('random_port'))
        snap['upnp'] = bool(prefs.get('upnp'))
        port_ok = snap['port'] is not None and snap['qbt_port'] == snap['port']
        iface_ok = (not snap['manage_interface']) or (snap['vpn_iface'] is not None
                                                       and snap['qbt_iface'] == snap['vpn_iface'])
        snap['in_sync'] = bool(port_ok and iface_ok)
    except QbtAuthError as exc:
        snap['qbt_error'], snap['qbt_error_kind'] = str(exc), 'auth'
    except QbtBanned as exc:
        snap['qbt_error'], snap['qbt_error_kind'] = str(exc), 'banned'
    except QbtUnreachable as exc:
        snap['qbt_error'], snap['qbt_error_kind'] = str(exc), 'unreachable'
    except (QbtError, ConfigError) as exc:
        snap['qbt_error'], snap['qbt_error_kind'] = str(exc), 'other'
    if cfg.get('port_check') and snap['port'] and snap['in_sync']:
        snap['port_reachable'] = check_port_reachable(cfg, snap['port'])
    return snap


def _item(level, message, hint=''):
    return {'level': level, 'message': message, 'hint': hint}


def health_checks(snap):
    """Plain-language findings with a fix hint each. Pure: reads the snapshot only."""
    items = []
    if not snap['vpn_ip']:
        items.append(_item('ERROR', 'ProtonVPN does not appear to be connected.',
                           'Connect Proton VPN to a P2P server.'))
    elif snap['udp'] is None and snap['tcp'] is None:
        items.append(_item('WARN', 'The VPN gateway answers, but gave no forwarded port.',
                           'Turn on Port Forwarding in the Proton VPN app (or use a config with NAT-PMP enabled) '
                           'and reconnect to a P2P-capable server.'))
    elif snap['port'] is None:
        items.append(_item('WARN', 'The gateway returned different or missing ports (UDP=%s, TCP=%s).'
                           % (snap['udp'], snap['tcp']), 'Reconnect the VPN to get a fresh port.'))

    if not snap['qbt_ok']:
        kind, msg = snap['qbt_error_kind'], snap['qbt_error']
        if kind == 'auth':
            items.append(_item('ERROR', 'qBittorrent rejected the username or password.',
                               'Run "python3 protonportsync.py setup" again and enter the Web UI password.'))
        elif kind == 'banned':
            items.append(_item('ERROR', 'qBittorrent has banned this computer after too many failed logins.',
                               'Restart qBittorrent (this clears the ban), then check the password with setup.'))
        elif kind == 'unreachable':
            items.append(_item('ERROR', 'Cannot reach qBittorrent at %s.' % snap['webui_url'],
                               'Start qBittorrent and turn on the Web UI (%s > Web UI).' % QBT_OPTIONS))
        else:
            items.append(_item('ERROR', 'qBittorrent check failed: %s' % msg,
                               'Run "python3 protonportsync.py once" and read the log.'))
    else:
        if snap['port'] is not None and snap['qbt_port'] == snap['port']:
            items.append(_item('OK', 'qBittorrent listens on the forwarded port (%d).' % snap['port']))
        elif snap['port'] is not None:
            items.append(_item('WARN', 'qBittorrent listens on %s but the VPN forwards %d.' % (snap['qbt_port'], snap['port']),
                               'The background service corrects this within a cycle. If it does not, check that '
                               'the service is running and read the log.'))
        if snap['random_port']:
            items.append(_item('WARN', 'qBittorrent has "random port" turned on, which overrides the synced port.',
                               '%s > Connection: turn off "Use random port on each start".' % QBT_OPTIONS))
        if snap['upnp']:
            items.append(_item('WARN', 'qBittorrent has UPnP / NAT-PMP port forwarding turned on.',
                               '%s > Connection: turn off "Use UPnP / NAT-PMP port forwarding from my router" '
                               '(Proton advises against it).' % QBT_OPTIONS))
        if snap['manage_interface']:
            if snap['vpn_iface'] is None:
                items.append(_item('WARN', 'Could not find the VPN tunnel interface (%s).' % TUNNEL_EXAMPLE,
                                   'Port sync still works. While connected, run "%s" and report the output.'
                                   % IFACE_LOOKUP_CMD))
            elif not snap['qbt_iface']:
                items.append(_item('WARN', 'qBittorrent is not bound to a network interface yet.',
                                   'The service sets it to "%s" on its next cycle.' % snap['vpn_iface']))
            elif snap['qbt_iface'] != snap['vpn_iface']:
                items.append(_item('WARN', 'qBittorrent is bound to "%s" but the VPN tunnel is "%s".'
                                   % (snap['qbt_iface'], snap['vpn_iface']),
                                   'The service switches it on its next cycle.'))
            else:
                items.append(_item('OK', 'qBittorrent is bound to the VPN tunnel "%s".' % snap['qbt_iface']))
        elif not snap['qbt_iface']:
            items.append(_item('WARN', 'qBittorrent is not bound to a network interface.',
                               '%s > Advanced > Network interface: pick the VPN tunnel. Otherwise, if the VPN drops, '
                               'torrents continue over your normal connection.' % QBT_OPTIONS))

    if snap['port_reachable'] is True:
        items.append(_item('OK', 'The port is reachable from the internet.'))
    elif snap['port_reachable'] is False:
        items.append(_item('WARN', 'The port looks closed from the internet.',
                           'Make sure qBittorrent is running and not blocked by a firewall, and that you are on a '
                           'P2P server with port forwarding on.'))

    if not [i for i in items if i['level'] in ('WARN', 'ERROR')]:
        items.append(_item('OK', 'Everything looks fine.'))
    return items


_IPV4 = re.compile(r'\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b')


def _mask_ip(match):
    try:
        ip = ipaddress.ip_address(match.group(0))
    except ValueError:
        return 'x.x.x.x'
    return match.group(0) if (ip.is_private or ip.is_loopback or ip.is_link_local) else 'x.x.x.x'


def mask_text(text):
    """Remove public IPv4 addresses and the home folder path from text that may be shared."""
    text = _IPV4.sub(_mask_ip, text or '')
    home = os.path.expanduser('~')
    if home and len(home) > 1:
        text = text.replace(home, '~')
    return text


def masked_config(cfg):
    copy = dict(cfg)
    copy['username'] = '(set)' if copy.get('username') else ''
    try:
        parsed = urllib.parse.urlparse(str(copy.get('webui_url', '')))
        if parsed.hostname and parsed.hostname not in ('127.0.0.1', 'localhost', '::1'):
            copy['webui_url'] = '%s://(remote-host):%s' % (parsed.scheme, parsed.port or '')
    except ValueError:
        pass
    return mask_text(json.dumps(copy, indent=2, sort_keys=True))


def health_report(snap, items):
    lines = ['ProtonPortSync support report - %s UTC' % _iso(time.time()),
             'Version        : %s (%s)' % (snap['version'], PLATFORM_LABEL),
             'Python         : %s' % platform.python_version(),
             'System         : %s' % platform.platform(),
             'VPN reachable  : %s' % ('yes' if snap['vpn_ip'] else 'no'),
             'Forwarded port : %s' % (snap['port'] if snap['port'] else 'none'),
             'VPN interface  : %s' % (snap['vpn_iface'] or 'not found'),
             'qBittorrent    : %s' % ('port %s' % snap['qbt_port'] if snap['qbt_ok'] else 'error - %s' % snap['qbt_error']),
             'In sync        : %s' % snap['in_sync'], '', 'Checks']
    for item in items:
        lines.append('  [%s] %s' % (item['level'], item['message']))
        if item['hint']:
            lines.append('         -> %s' % item['hint'])
    return mask_text('\n'.join(lines) + '\n')


def _tail(path, count=1000):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            return ''.join(fh.readlines()[-count:])
    except OSError:
        return None


def make_support_bundle(cfg, snap, config_path, out_dir):
    """Zip with report, masked settings, status.json and the recent log. Returns the zip path."""
    if not out_dir or not os.path.isdir(out_dir):
        out_dir = os.path.dirname(os.path.abspath(config_path))
    zip_path = os.path.join(out_dir, 'ProtonPortSync-support-%s.zip' % time.strftime('%Y%m%d-%H%M%S'))
    entries = [('report.txt', health_report(snap, health_checks(snap))),
               ('config.json', masked_config(cfg))]
    status = _tail(status_path(config_path))
    if status is not None:
        entries.append(('status.json', mask_text(status)))
    names = ['ProtonPortSync.log', 'ProtonPortSync.log.1'] + list(EXTRA_LOG_NAMES)
    for name in names:
        text = _tail(os.path.join(log_dir(), name))
        if text is not None:
            entries.append((name, mask_text(text)))
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
        for name, text in entries:
            zf.writestr(name, text)
    return zip_path


def cmd_support_bundle(args):
    setup_logging(quiet=True)
    try:
        cfg = load_config(args.config)
    except ConfigError as exc:
        print(exc)
        return 1
    snap = gather_snapshot(cfg)
    desktop = os.path.expanduser('~/Desktop')
    path = make_support_bundle(cfg, snap, args.config, desktop if os.path.isdir(desktop) else os.path.expanduser('~'))
    print('\nSupport bundle created: %s' % path)
    print('It contains the checks, your recent log and your settings without the user name.')
    print('Public IP addresses and your home folder path are removed. Look inside before sharing,')
    print('then attach it to a GitHub issue: https://github.com/emperorgr/ProtonPortSync/issues')
    return 0


# --------------------------------------------------------------------------- logging & lock

class DedupFilter(logging.Filter):
    """Drop a record identical to the previous one, so a steady state stays quiet."""

    def __init__(self):
        super().__init__()
        self.last = None

    def filter(self, record):
        if getattr(record, 'force', False):
            self.last = None
            return True
        key = (record.levelno, record.getMessage())
        if key == self.last:
            return False
        self.last = key
        return True


def setup_logging(quiet):
    for handler in list(log.handlers):
        handler.close()
        log.removeHandler(handler)
    log.setLevel(logging.INFO)
    log.propagate = False
    fmt = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s', '%Y-%m-%d %H:%M:%S')
    dedupe = DedupFilter()
    try:
        os.makedirs(log_dir(), exist_ok=True)
        fh = logging.handlers.RotatingFileHandler(os.path.join(log_dir(), 'ProtonPortSync.log'),
                                                  maxBytes=1024 * 1024, backupCount=1, encoding='utf-8')
        fh.setFormatter(fmt)
        fh.addFilter(dedupe)
        log.addHandler(fh)
    except OSError:
        pass
    if not quiet:
        sh = logging.StreamHandler(sys.stdout)
        sh.setFormatter(fmt)
        sh.addFilter(DedupFilter())
        log.addHandler(sh)


_lock_handle = None


def acquire_lock():
    """Single-instance lock. Released automatically when the process dies."""
    global _lock_handle
    if fcntl is None:
        return True
    os.makedirs(support_dir(), exist_ok=True)
    _lock_handle = open(os.path.join(support_dir(), 'ProtonPortSync.lock'), 'w')
    try:
        fcntl.flock(_lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    return True


# --------------------------------------------------------------------------- commands

def cmd_once(args):
    setup_logging(quiet=False)
    try:
        cfg = load_config(args.config)
    except ConfigError as exc:
        print(exc)
        return 1
    log.info('Running single sync cycle (version %s).', __version__)
    state = State()
    ok = sync_cycle(cfg, state, args.config)
    write_status(cfg, state, status_path(args.config), force=True)
    return 0 if ok else 1


def cmd_run(args):
    setup_logging(quiet=not sys.stdout.isatty())
    if not acquire_lock():
        log.warning('Another instance is already running. Exiting.')
        return 0
    try:
        cfg = load_config(args.config)
    except ConfigError as exc:
        log.error('%s', exc)
        print(exc)
        return 1
    interval = max(5, args.interval or int(cfg['interval_seconds']))
    log.info('ProtonPortSync %s started (interval %ds, WebUI %s).', __version__, interval, cfg['webui_url'])
    state = State()
    last_heartbeat = time.time()
    while True:
        try:
            cfg = load_config(args.config)    # pick up edits; keep the last good config otherwise
        except ConfigError:
            pass
        try:
            in_sync = sync_cycle(cfg, state, args.config)
        except Exception as exc:               # never let one bad cycle kill the service
            log.error('Unexpected error: %s', exc)
            in_sync = False
            if state.cycle is not None:
                state.cycle.update(state='error', error=str(exc))
        try:
            port_check_if_due(cfg, state)
            write_status(cfg, state, status_path(args.config))
        except Exception as exc:
            log.warning('Status/port-check step failed: %s', exc)
        if time.time() - last_heartbeat >= HEARTBEAT_SECONDS:
            last_heartbeat = time.time()
            log.info('Heartbeat: service alive, %s (port %s)',
                     'in sync' if in_sync else 'NOT in sync', cfg.get('last_applied_port'),
                     extra={'force': True})
        wait = interval
        if state.ban_until > time.time():
            wait = max(30, int(state.ban_until - time.time()))
        time.sleep(wait)


def service_status_line():
    if not is_macos():
        return None
    rc, _ = run_command(['/bin/launchctl', 'print', 'gui/%d/%s' % (os.getuid(), LABEL)])
    return 'installed (launchd)' if rc == 0 else 'not installed'


def cmd_status(args):
    try:
        cfg = load_config(args.config)
    except ConfigError as exc:
        print(exc)
        return 1
    setup_logging(quiet=True)
    snap = gather_snapshot(cfg)
    print()
    print('  ProtonVPN -> qBittorrent status (%s %s)' % (PLATFORM_LABEL, __version__))
    print('  ' + '-' * 40)
    print('  VPN reachable      : %s' % ('yes (%s)' % snap['vpn_ip'] if snap['vpn_ip'] else 'no'))
    if snap['vpn_ip']:
        print('  Forwarded port     : UDP=%s TCP=%s' % (snap['udp'] if snap['udp'] else 'none',
                                                      snap['tcp'] if snap['tcp'] else 'none'))
    print('  VPN interface      : %s' % (snap['vpn_iface'] or 'not found'))
    if snap['qbt_ok']:
        print('  qBittorrent port   : %d' % snap['qbt_port'])
        print('  qBittorrent iface  : %s' % (snap['qbt_iface'] or '(any)'))
        print('  Sync               : %s' % ('IN SYNC' if snap['in_sync'] else 'OUT OF SYNC'))
    else:
        print('  qBittorrent        : error - %s' % snap['qbt_error'])
    service = service_status_line()
    if service:
        print('  Background service : %s' % service)
    print()
    print('  Checks')
    for item in health_checks(snap):
        print('  [%-5s] %s' % (item['level'], item['message']))
        if item['hint']:
            print('          -> %s' % item['hint'])
    print()
    return 0


def build_plist(python, script):
    out = os.path.join(log_dir(), 'launchd.log')
    return {
        'Label': LABEL,
        'ProgramArguments': [python, script, 'run'],
        'RunAtLoad': True,
        'KeepAlive': True,
        'ThrottleInterval': 30,
        'ProcessType': 'Background',
        'StandardOutPath': out,
        'StandardErrorPath': out,
    }


def _domain():
    return 'gui/%d' % os.getuid()


def cmd_install(args):
    if not is_macos():
        print('The LaunchAgent can only be installed on macOS.')
        return 1
    try:
        load_config(args.config)
    except ConfigError as exc:
        print(exc)
        return 1
    os.makedirs(support_dir(), exist_ok=True)
    os.makedirs(log_dir(), exist_ok=True)
    # Run from a private copy so deleting/moving the download folder cannot break the service
    # (and macOS privacy rules for Downloads/Desktop do not apply to it).
    dest = os.path.join(support_dir(), 'protonportsync.py')
    if os.path.abspath(__file__) != os.path.abspath(dest):
        shutil.copy2(os.path.abspath(__file__), dest)
    os.chmod(dest, 0o755)
    python = sys.executable or '/usr/bin/python3'
    path = plist_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as fh:
        plistlib.dump(build_plist(python, dest), fh)
    run_command(['/bin/launchctl', 'bootout', '%s/%s' % (_domain(), LABEL)])   # stop an old copy, ignore errors
    rc, _ = run_command(['/bin/launchctl', 'bootstrap', _domain(), path])
    if rc != 0:
        rc, _ = run_command(['/bin/launchctl', 'load', '-w', path])
    if rc != 0:
        print('Could not start the service with launchctl. Try: launchctl bootstrap %s "%s"' % (_domain(), path))
        return 1
    run_command(['/bin/launchctl', 'kickstart', '-k', '%s/%s' % (_domain(), LABEL)])
    print('Installed. ProtonPortSync %s now starts at login and restarts itself if it stops.' % __version__)
    print('Log file: %s' % os.path.join(log_dir(), 'ProtonPortSync.log'))
    return 0


def cmd_uninstall(args):
    if is_macos():
        run_command(['/bin/launchctl', 'bootout', '%s/%s' % (_domain(), LABEL)])
        if os.path.exists(plist_path()):
            os.remove(plist_path())
    installed = os.path.join(support_dir(), 'protonportsync.py')
    if os.path.exists(installed):
        os.remove(installed)
    if args.purge:
        username = DEFAULTS['username']
        try:
            username = load_config(args.config)['username']
        except ConfigError:
            pass
        if is_macos():
            delete_password(username)
        shutil.rmtree(support_dir(), ignore_errors=True)
        shutil.rmtree(log_dir(), ignore_errors=True)
        print('Removed the service, settings, Keychain entry and logs.')
    else:
        print('Removed the service. Settings and logs were kept (use --purge to delete them too).')
    return 0


def _ask(prompt, default=''):
    answer = input('%s%s: ' % (prompt, ' [%s]' % default if default else '')).strip()
    return answer or default


def _yes(prompt, default=True):
    answer = input('%s [%s]: ' % (prompt, 'Y/n' if default else 'y/N')).strip().lower()
    if not answer:
        return default
    return answer in ('y', 'yes')


def cmd_setup(args):
    setup_logging(quiet=True)
    interactive = sys.stdin.isatty()
    cfg = dict(DEFAULTS)
    try:
        cfg.update(load_config(args.config))
    except ConfigError:
        pass

    print('\n== qBittorrent WebUI')
    cfg['webui_url'] = (args.url or (_ask('WebUI URL', cfg['webui_url']) if interactive else cfg['webui_url'])).rstrip('/')
    cfg['username'] = args.username or (_ask('Username', cfg['username']) if interactive else cfg['username'])

    password = os.environ.get('PROTONPORTSYNC_PASSWORD')
    if args.password_stdin:
        password = sys.stdin.readline().rstrip('\n')
    if not password:
        password = getpass.getpass('Password: ')

    if args.no_interface:
        cfg['manage_interface'] = False
    elif interactive and not args.url:
        cfg['manage_interface'] = _yes('Bind qBittorrent to the VPN network interface automatically (recommended)?',
                                       cfg['manage_interface'])

    if args.no_port_check:
        cfg['port_check'] = False
    elif args.port_check:
        cfg['port_check'] = True
    elif interactive and not args.url:
        print('\n== Port check (optional)')
        print('Every 30 minutes ProtonPortSync can ask a public web service (portcheck.transmissionbt.com)')
        print('whether your forwarded port is really open, and warn you in the log if not. That service')
        print('sees your VPN IP address and port number. It stays off unless you say yes.')
        cfg['port_check'] = _yes('Enable the internet port check?', bool(cfg.get('port_check')))

    if not args.skip_test:
        print('\n== Testing connection')
        try:
            client = Qbt(cfg['webui_url'], cfg['username'], password)
            client.login()
            prefs = client.preferences()
            print('Login OK. qBittorrent listen_port is %s, network interface is "%s".' %
                  (prefs.get('listen_port'), prefs.get('current_network_interface') or 'any'))
        except QbtError as exc:
            print('Connection test FAILED: %s' % exc)
            if not interactive or not _yes('Save the configuration anyway?', False):
                print('Aborted.')
                return 1

    print('\n== Saving configuration')
    if is_macos():
        if store_password(cfg['username'], password):
            print('Password stored in the macOS Keychain.')
        else:
            print('Could not write to the Keychain. Aborting so no password is left unprotected.')
            return 1
    else:
        print('Not macOS: set PROTONPORTSYNC_PASSWORD in the environment of the service.')
    save_config(args.config, cfg)
    print('Saved to %s' % args.config)

    print('\n== First sync')
    previous = os.environ.get('PROTONPORTSYNC_PASSWORD')
    os.environ['PROTONPORTSYNC_PASSWORD'] = password
    try:
        cmd_once(args)
    finally:
        if previous is None:
            os.environ.pop('PROTONPORTSYNC_PASSWORD', None)
        else:
            os.environ['PROTONPORTSYNC_PASSWORD'] = previous

    want_install = args.install or (interactive and not args.no_install and
                                    _yes('\nStart automatically at login?', True))
    if want_install:
        return cmd_install(args)
    print('\nDone. Run "python3 protonportsync.py status" to check, or "install" to start at login.')
    return 0


def cmd_version(_args):
    print('ProtonPortSync for macOS %s' % __version__)
    return 0


def cmd_print_plist(_args):
    sys.stdout.write(plistlib.dumps(build_plist(sys.executable or '/usr/bin/python3',
                                                os.path.join(support_dir(), 'protonportsync.py'))).decode('utf-8'))
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog='protonportsync.py',
                                     description='Keep qBittorrent in sync with ProtonVPN port forwarding.')
    parser.add_argument('--config', default=default_config_path(), help='path to config.json')
    sub = parser.add_subparsers(dest='command')

    sub.add_parser('status', help='show current state').set_defaults(func=cmd_status)
    sub.add_parser('once', help='run one sync cycle').set_defaults(func=cmd_once)
    run = sub.add_parser('run', help='run in the foreground')
    run.add_argument('--interval', type=int, default=0, help='poll interval in seconds (default 20)')
    run.set_defaults(func=cmd_run)
    sub.add_parser('install', help='install/update the LaunchAgent').set_defaults(func=cmd_install)
    un = sub.add_parser('uninstall', help='remove the LaunchAgent')
    un.add_argument('--purge', action='store_true', help='also delete settings, Keychain entry and logs')
    un.set_defaults(func=cmd_uninstall)
    st = sub.add_parser('setup', help='one-time configuration')
    st.add_argument('--url')
    st.add_argument('--username')
    st.add_argument('--password-stdin', action='store_true', help='read the password from stdin')
    st.add_argument('--no-interface', action='store_true', help='do not manage the qBittorrent network interface')
    st.add_argument('--skip-test', action='store_true')
    st.add_argument('--port-check', action='store_true', help='turn the internet port check on without asking')
    st.add_argument('--no-port-check', action='store_true', help='turn the internet port check off without asking')
    st.add_argument('--install', action='store_true', help='install the LaunchAgent without asking')
    st.add_argument('--no-install', action='store_true', help='do not ask about the LaunchAgent')
    st.set_defaults(func=cmd_setup)
    sub.add_parser('support-bundle', help='zip with checks, log and settings to attach to a bug report').set_defaults(func=cmd_support_bundle)
    sub.add_parser('version', help='print the version').set_defaults(func=cmd_version)
    sub.add_parser('print-plist', help='print the LaunchAgent plist (debug)').set_defaults(func=cmd_print_plist)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, 'func', None):
        parser.print_help()
        return 0
    try:
        return args.func(args) or 0
    except KeyboardInterrupt:
        return 130


if __name__ == '__main__':
    sys.exit(main())
