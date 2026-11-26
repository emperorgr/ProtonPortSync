#!/usr/bin/env python3
"""ProtonPortSync for Linux (beta).

Keeps qBittorrent's listening port - and, optionally, its network interface -
in sync with ProtonVPN port forwarding.

Pure Python 3 standard library (3.8+), no third-party packages.

Usage:
    python3 protonportsync.py setup        one-time configuration (+ optional auto-start)
    python3 protonportsync.py status       show VPN port, interface and qBittorrent state
    python3 protonportsync.py once         run a single sync cycle
    python3 protonportsync.py run          run in the foreground (what systemd runs)
    python3 protonportsync.py install      (re)install the systemd user service - use this to update
    python3 protonportsync.py uninstall    remove the service  (--purge also removes data)
    python3 protonportsync.py version

How it works
    1. Ask the ProtonVPN gateway (NAT-PMP, 10.2.0.1:5351) for the forwarded port.
       This is the same request Proton documents for `natpmpc -a 1 0 udp 60 -g 10.2.0.1`.
       It also keeps the 60 s lease alive.
    2. Find the tunnel interface (proton0, wg0, tun0 ...) that carries the VPN traffic,
       so qBittorrent can be bound to it even when the name changes between setups.
    3. Push listen_port (and current_network_interface) to qBittorrent's Web UI API.
"""

import argparse
import getpass
import json
import logging
import logging.handlers
import os
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

try:
    import fcntl
except ImportError:  # pragma: no cover - not available on Windows
    fcntl = None

__version__ = '0.1.0-beta.1'
SYSFS_NET = '/sys/class/net'

APP_NAME = 'ProtonPortSync'
SERVICE_NAME = 'protonportsync.service'
KEYRING_SERVICE = 'ProtonPortSync'

DEFAULTS = {
    'webui_url': 'http://127.0.0.1:8080',
    'username': 'admin',
    'nat_pmp_gateway': '10.2.0.1',
    'nat_pmp_port': 5351,
    'interval_seconds': 20,
    'manage_interface': True,
    'last_applied_port': 0,
}

NATPMP_TIMEOUT = 2.0      # seconds per attempt (tests lower this)
NATPMP_TRIES = 2
NATPMP_LIFETIME = 60
HTTP_TIMEOUT = 8
BAN_BACKOFF_SECONDS = 300
HEARTBEAT_SECONDS = 30 * 60

OP_ADDRESS, OP_UDP, OP_TCP = 0, 1, 2   # RFC 6886

log = logging.getLogger('pps')
OK_LEVEL = 25
logging.addLevelName(OK_LEVEL, 'OK')
logging.addLevelName(logging.WARNING, 'WARN')


# --------------------------------------------------------------------------- paths

def _xdg(env, fallback):
    value = os.environ.get(env)
    return value if value and os.path.isabs(value) else os.path.expanduser(fallback)


def config_dir():
    """config.json (and the password file, if used) live here."""
    if os.environ.get('PROTONPORTSYNC_HOME'):
        return os.environ['PROTONPORTSYNC_HOME']
    return os.path.join(_xdg('XDG_CONFIG_HOME', '~/.config'), 'protonportsync')


def support_dir():
    """The private copy of the script and the single-instance lock."""
    if os.environ.get('PROTONPORTSYNC_HOME'):
        return os.environ['PROTONPORTSYNC_HOME']
    return os.path.join(_xdg('XDG_DATA_HOME', '~/.local/share'), 'protonportsync')


def log_dir():
    if os.environ.get('PROTONPORTSYNC_LOGDIR'):
        return os.environ['PROTONPORTSYNC_LOGDIR']
    if os.environ.get('PROTONPORTSYNC_HOME'):
        return os.path.join(os.environ['PROTONPORTSYNC_HOME'], 'logs')
    return os.path.join(_xdg('XDG_STATE_HOME', '~/.local/state'), 'protonportsync')


def default_config_path():
    return os.path.join(config_dir(), 'config.json')


def password_file():
    return os.path.join(config_dir(), 'password')


def unit_path():
    return os.path.join(_xdg('XDG_CONFIG_HOME', '~/.config'), 'systemd', 'user', SERVICE_NAME)


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

def run_command(args, timeout=10, input_text=None):
    """Run a command and return (returncode, stdout). Never raises."""
    try:
        proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              input=input_text, timeout=timeout, universal_newlines=True)
        return proc.returncode, proc.stdout
    except FileNotFoundError:
        return 127, ''
    except (subprocess.TimeoutExpired, OSError):
        return 1, ''


def is_linux():
    return sys.platform.startswith('linux')





# --------------------------------------------------------------------------- password

def _secret_tool(*args, **kw):
    return run_command(['secret-tool'] + list(args), **kw)


def get_password(cfg):
    """Order: environment variable, password file, desktop keyring (libsecret)."""
    env = os.environ.get('PROTONPORTSYNC_PASSWORD')
    if env:
        return env
    path = password_file()
    if os.path.exists(path):
        try:
            with open(path, 'r', encoding='utf-8') as fh:
                value = fh.read().rstrip('\r\n')
            if value:
                return value
        except OSError as exc:
            raise ConfigError('Cannot read %s: %s' % (path, exc))
    rc, out = _secret_tool('lookup', 'service', KEYRING_SERVICE, 'account', cfg['username'])
    if rc == 0 and out:
        return out.rstrip('\n')
    raise ConfigError('Password not found (no password file and nothing in the keyring). '
                      'Run "python3 protonportsync.py setup" again.')


def keyring_available():
    return shutil.which('secret-tool') is not None


def store_password_keyring(username, password):
    """Store in the desktop keyring. The password goes through stdin, never through argv."""
    rc, _ = _secret_tool('store', '--label=ProtonPortSync qBittorrent password',
                         'service', KEYRING_SERVICE, 'account', username, input_text=password)
    if rc != 0:
        return False
    rc, out = _secret_tool('lookup', 'service', KEYRING_SERVICE, 'account', username)
    return rc == 0 and out.rstrip('\n') == password


def store_password_file(password):
    """Plain file readable only by the current user (mode 600)."""
    path = password_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        fh.write(password + '\n')
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def delete_password(username):
    if keyring_available():
        _secret_tool('clear', 'service', KEYRING_SERVICE, 'account', username)
    try:
        os.remove(password_file())
    except OSError:
        pass


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

_ROUTE_DEV = re.compile(r'\bdev\s+(\S+)')
_ADDR_LINE = re.compile(r'^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)')


def parse_route_dev(text):
    """`ip -o route get 10.2.0.1` -> '10.2.0.1 dev proton0 src 10.2.0.2 uid 1000' -> 'proton0'."""
    match = _ROUTE_DEV.search(text or '')
    return match.group(1) if match else None


def parse_ip_addr_vpn(text, prefix, sysfs=None):
    """Fallback: first tunnel interface that has an IPv4 address starting with prefix."""
    for line in (text or '').splitlines():
        match = _ADDR_LINE.match(line)
        if match and match.group(2).startswith(prefix) and is_tunnel_interface(match.group(1), sysfs):
            return match.group(1)
    return None


def _read(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            return fh.read()
    except OSError:
        return ''


def is_tunnel_interface(name, sysfs=None):
    """True for tun/tap, WireGuard and other point-to-point tunnels; False for eth0, wlan0 ...
    This is what stops us from ever binding qBittorrent to the normal network card when the
    VPN is down (the route to the gateway then goes out through eth0)."""
    base = os.path.join(sysfs or SYSFS_NET, name)
    if not name or '/' in name or not os.path.isdir(base):
        return False
    if os.path.exists(os.path.join(base, 'tun_flags')):          # tun/tap (OpenVPN)
        return True
    if 'DEVTYPE=wireguard' in _read(os.path.join(base, 'uevent')):
        return True
    return _read(os.path.join(base, 'type')).strip() == '65534'  # ARPHRD_NONE: raw IP tunnels


def detect_vpn_interface(gateway, runner=None, sysfs=None):
    """Name of the tunnel interface that carries traffic to the VPN gateway, or None."""
    runner = runner or run_command
    rc, out = runner(['ip', '-o', 'route', 'get', gateway])
    if rc == 0:
        dev = parse_route_dev(out)
        return dev if dev and is_tunnel_interface(dev, sysfs) else None
    # `ip route get` failed: look for a tunnel holding a 10.2.x.x address
    rc, out = runner(['ip', '-o', '-4', 'addr', 'show'])
    if rc == 0:
        return parse_ip_addr_vpn(out, '.'.join(gateway.split('.')[:2]) + '.', sysfs)
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
    port = discover_port(cfg)
    if port is None:
        return False
    if state.last_port != port:
        state.last_port = port
        log.info('Detected ProtonVPN forwarded port %d (VPN IP %s)', port, get_public_ip(cfg) or 'unknown')

    iface = None
    if cfg['manage_interface']:
        iface = detect_vpn_interface(cfg['nat_pmp_gateway'])
        if iface is None and not state.iface_missing_logged:
            state.iface_missing_logged = True
            log.warning('Could not find the VPN tunnel interface (proton0, wg0, tun0 ...); leaving the qBittorrent '
                        'network interface setting unchanged.')
        elif iface is not None:
            state.iface_missing_logged = False

    # After a rejected password do NOT keep retrying: five bad logins get this IP banned.
    if state.auth_failed_stamp is not None:
        if _config_stamp(config_path) == state.auth_failed_stamp:
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

        if cfg.get('last_applied_port') != port:
            cfg['last_applied_port'] = port
            try:
                save_config(config_path, cfg)
            except OSError:
                pass
        return True

    except QbtBanned as exc:
        state.ban_until = time.time() + BAN_BACKOFF_SECONDS
        log.error('%s', exc)
    except QbtAuthError as exc:
        state.auth_failed_stamp = _config_stamp(config_path)
        state.qbt = None
        log.error('%s Not retrying until the configuration changes - run "setup" again.', exc)
    except QbtUnreachable as exc:
        state.qbt = None
        log.warning('%s', exc)
    except ConfigError as exc:
        log.error('%s', exc)
    except QbtError as exc:
        state.qbt = None
        log.error('qBittorrent sync failed: %s', exc)
    return False


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
    return 0 if sync_cycle(cfg, State(), args.config) else 1


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
        if time.time() - last_heartbeat >= HEARTBEAT_SECONDS:
            last_heartbeat = time.time()
            log.info('Heartbeat: service alive, %s (port %s)',
                     'in sync' if in_sync else 'NOT in sync', cfg.get('last_applied_port'),
                     extra={'force': True})
        wait = interval
        if state.ban_until > time.time():
            wait = max(30, int(state.ban_until - time.time()))
        time.sleep(wait)


def cmd_status(args):
    try:
        cfg = load_config(args.config)
    except ConfigError as exc:
        print(exc)
        return 1
    setup_logging(quiet=True)
    print()
    print('  ProtonVPN -> qBittorrent status (Linux %s)' % __version__)
    print('  ' + '-' * 40)
    ip = get_public_ip(cfg)
    print('  VPN reachable      : %s' % ('yes (%s)' % ip if ip else 'no'))
    port = None
    if ip:
        gw, gp = cfg['nat_pmp_gateway'], int(cfg['nat_pmp_port'])
        udp = natpmp_exchange(gw, gp, OP_UDP, 1, 0, NATPMP_LIFETIME)
        tcp = natpmp_exchange(gw, gp, OP_TCP, 1, 0, NATPMP_LIFETIME)
        print('  Forwarded port     : UDP=%s TCP=%s' % (udp[1] if udp else 'none', tcp[1] if tcp else 'none'))
        if udp and tcp and udp[1] == tcp[1]:
            port = udp[1]
    iface = detect_vpn_interface(cfg['nat_pmp_gateway'])
    print('  VPN interface      : %s' % (iface or 'not found'))
    try:
        client = Qbt(cfg['webui_url'], cfg['username'], get_password(cfg))
        client.login()
        prefs = client.preferences()
        q_port = int(prefs.get('listen_port', 0))
        q_iface = prefs.get('current_network_interface', '') or '(any)'
        print('  qBittorrent port   : %d' % q_port)
        print('  qBittorrent iface  : %s' % q_iface)
        port_ok = port is not None and q_port == port
        iface_ok = (not cfg['manage_interface']) or (iface is not None and prefs.get('current_network_interface') == iface)
        print('  Sync               : %s' % ('IN SYNC' if port_ok and iface_ok else 'OUT OF SYNC'))
    except (QbtError, ConfigError) as exc:
        print('  qBittorrent        : error - %s' % exc)
    if shutil.which('systemctl'):
        rc, out = run_command(['systemctl', '--user', 'is-active', SERVICE_NAME])
        text = out.strip()
        print('  Background service : %s' % (
            'running (systemd)' if text == 'active' else
            'installed but %s' % text if os.path.exists(unit_path()) else 'not installed'))
    print()
    return 0


def _quote_unit(value):
    return '"%s"' % value.replace('\\', '\\\\').replace('"', '\\"')


def build_unit(python, script, config=None):
    exec_line = '%s %s' % (_quote_unit(python), _quote_unit(script))
    if config:
        exec_line += ' --config %s' % _quote_unit(config)
    exec_line += ' run'
    return (
        '[Unit]\n'
        'Description=ProtonPortSync - keep qBittorrent in sync with ProtonVPN port forwarding\n'
        '\n'
        '[Service]\n'
        'Type=simple\n'
        'ExecStart=%s\n'
        'Environment=PYTHONUNBUFFERED=1\n'
        'Restart=always\n'
        'RestartSec=30\n'
        '\n'
        '[Install]\n'
        'WantedBy=default.target\n' % exec_line)


def _systemctl(*args):
    return run_command(['systemctl', '--user'] + list(args), timeout=30)


def cmd_install(args):
    if not is_linux():
        print('The systemd service can only be installed on Linux.')
        return 1
    if not shutil.which('systemctl'):
        print('systemctl was not found, so no service can be installed here.\n'
              'Start it yourself with: python3 protonportsync.py run')
        return 1
    try:
        load_config(args.config)
    except ConfigError as exc:
        print(exc)
        return 1
    os.makedirs(support_dir(), exist_ok=True)
    os.makedirs(log_dir(), exist_ok=True)
    # Run from a private copy so deleting/moving the download folder cannot break the service.
    dest = os.path.join(support_dir(), 'protonportsync.py')
    if os.path.abspath(__file__) != os.path.abspath(dest):
        shutil.copy2(os.path.abspath(__file__), dest)
    os.chmod(dest, 0o755)
    python = sys.executable or '/usr/bin/python3'
    path = unit_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(build_unit(python, dest, os.path.abspath(args.config)))
    _systemctl('daemon-reload')
    rc, _ = _systemctl('enable', '--now', SERVICE_NAME)
    if rc != 0:
        print('Could not start the service. Is a systemd user session running? Try:\n'
              '  systemctl --user enable --now %s' % SERVICE_NAME)
        return 1
    _systemctl('restart', SERVICE_NAME)          # pick up an updated copy of the script
    print('Installed. ProtonPortSync %s now starts at login and restarts itself if it stops.' % __version__)
    print('Log file: %s' % os.path.join(log_dir(), 'ProtonPortSync.log'))
    user = os.environ.get('USER') or getpass.getuser()
    rc, out = run_command(['loginctl', 'show-user', user, '--property=Linger'])
    if rc == 0 and 'Linger=no' in out:
        print('Tip: to also run without being logged in (headless box), run: loginctl enable-linger')
    return 0


def cmd_uninstall(args):
    if shutil.which('systemctl'):
        _systemctl('disable', '--now', SERVICE_NAME)
    if os.path.exists(unit_path()):
        os.remove(unit_path())
        if shutil.which('systemctl'):
            _systemctl('daemon-reload')
    installed = os.path.join(support_dir(), 'protonportsync.py')
    if os.path.exists(installed):
        os.remove(installed)
    if args.purge:
        username = DEFAULTS['username']
        try:
            username = load_config(args.config)['username']
        except ConfigError:
            pass
        delete_password(username)
        for folder in (support_dir(), config_dir(), log_dir()):
            shutil.rmtree(folder, ignore_errors=True)
        print('Removed the service, settings, saved password and logs.')
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
    stored = None
    if not args.password_file and keyring_available():
        if store_password_keyring(cfg['username'], password):
            stored = 'keyring'
            try:
                os.remove(password_file())      # an old file would take priority over the keyring
            except OSError:
                pass
            print('Password stored in the desktop keyring (libsecret).')
        else:
            print('The desktop keyring is not available (no unlocked keyring in this session).')
    elif not args.password_file:
        print('secret-tool (libsecret-tools) is not installed, so there is no keyring to use.')
    if stored is None:
        if args.password_file or not interactive or _yes(
                'Save the password in a file only you can read (%s, mode 600)?' % password_file(), True):
            store_password_file(password)
            stored = 'file'
            print('Password saved to %s (readable only by you).' % password_file())
        else:
            print('Aborted: no password was saved.')
            return 1
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
    print('ProtonPortSync for Linux %s' % __version__)
    return 0


def cmd_print_unit(args):
    sys.stdout.write(build_unit(sys.executable or '/usr/bin/python3',
                                os.path.join(support_dir(), 'protonportsync.py'),
                                os.path.abspath(args.config)))
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
    sub.add_parser('install', help='install/update the systemd user service').set_defaults(func=cmd_install)
    un = sub.add_parser('uninstall', help='remove the systemd user service')
    un.add_argument('--purge', action='store_true', help='also delete settings, saved password and logs')
    un.set_defaults(func=cmd_uninstall)
    st = sub.add_parser('setup', help='one-time configuration')
    st.add_argument('--url')
    st.add_argument('--username')
    st.add_argument('--password-stdin', action='store_true', help='read the password from stdin')
    st.add_argument('--no-interface', action='store_true', help='do not manage the qBittorrent network interface')
    st.add_argument('--skip-test', action='store_true')
    st.add_argument('--password-file', action='store_true', help='store the password in a mode-600 file instead of the keyring')
    st.add_argument('--install', action='store_true', help='install the systemd service without asking')
    st.add_argument('--no-install', action='store_true', help='do not ask about the service')
    st.set_defaults(func=cmd_setup)
    sub.add_parser('version', help='print the version').set_defaults(func=cmd_version)
    sub.add_parser('print-unit', help='print the systemd unit file (debug)').set_defaults(func=cmd_print_unit)
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
