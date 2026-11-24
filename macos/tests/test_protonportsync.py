"""Tests for the macOS ProtonPortSync: unit tests plus an end-to-end run against a
mock qBittorrent WebAPI and a mock ProtonVPN NAT-PMP gateway, all on localhost.

    python3 -m unittest discover -s tests -v        (from the macos/ folder)
"""
import http.server
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import protonportsync as pps  # noqa: E402

ROUTE_UTUN4 = """   route to: 10.2.0.1
destination: 10.2.0.1
    gateway: 10.2.0.1
  interface: utun4
      flags: <UP,HOST,DONE,LLINFO,WASCLONED,IFSCOPE,IFREF>
"""
ROUTE_EN0 = """   route to: 10.2.0.1
destination: default
    gateway: 192.168.1.1
  interface: en0
"""
IFCONFIG = """lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
\tinet6 fe80::1%utun3 prefixlen 64 scopeid 0x10
utun6: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420
\tinet 10.2.0.2 --> 10.2.0.2 netmask 0xffffffff
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
"""


class MockGateway(threading.Thread):
    """Answers NAT-PMP: opcode 0 (address) and 1/2 (map UDP/TCP)."""

    def __init__(self, port_udp=44139, port_tcp=None):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(('127.0.0.1', 0))
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.port_udp = port_udp
        self.port_tcp = port_tcp if port_tcp is not None else port_udp
        self.requests = []
        self.stop = False

    def run(self):
        while not self.stop:
            try:
                data, addr = self.sock.recvfrom(64)
            except socket.timeout:
                continue
            except OSError:
                return
            opcode = data[1]
            self.requests.append(data)
            if opcode == 0:
                reply = struct.pack('!BBHI', 0, 128, 0, 1000) + socket.inet_aton('203.0.113.47')
            else:
                _v, _o, _r, internal, _sug, _life = struct.unpack('!BBHHHI', data[:12])
                ext = self.port_udp if opcode == 1 else self.port_tcp
                reply = struct.pack('!BBHIHHI', 0, 128 + opcode, 0, 1000, internal, ext, 60)
            self.sock.sendto(reply, addr)

    def close(self):
        self.stop = True
        self.sock.close()


class MockQbt:
    """qBittorrent WebAPI v2 mock: empty-body login (5.x), cookie auth, preferences."""

    def __init__(self):
        self.prefs = {'listen_port': 51274, 'random_port': False, 'upnp': False,
                      'current_network_interface': '', 'current_interface_address': ''}
        self.logins = 0
        self.failed_logins = 0
        self.set_calls = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, status, body='', headers=None):
                data = body.encode()
                self.send_response(status)
                self.send_header('Content-Length', str(len(data)))
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(data)

            def _authed(self):
                return 'SID=abc123' in (self.headers.get('Cookie') or '')

            def _form(self):
                n = int(self.headers.get('Content-Length') or 0)
                return dict(urllib.parse.parse_qsl(self.rfile.read(n).decode()))

            def do_GET(self):
                if self.path.startswith('/api/v2/app/version'):
                    return self._send(200, 'v5.2.3') if self._authed() else self._send(403, 'Forbidden')
                if self.path.startswith('/api/v2/app/preferences'):
                    if not self._authed():
                        return self._send(403, 'Forbidden')
                    return self._send(200, json.dumps(outer.prefs), {'Content-Type': 'application/json'})
                self._send(404)

            def do_POST(self):
                form = self._form()
                if self.path.startswith('/api/v2/auth/login'):
                    if form.get('username') == 'admin' and form.get('password') == 'secret':
                        outer.logins += 1
                        return self._send(200, '', {'Set-Cookie': 'SID=abc123; path=/'})
                    outer.failed_logins += 1
                    return self._send(401, 'Fails.')
                if self.path.startswith('/api/v2/app/setPreferences'):
                    if not self._authed():
                        return self._send(403, 'Forbidden')
                    changes = json.loads(form['json'])
                    outer.set_calls.append(changes)
                    outer.prefs.update(changes)
                    return self._send(200)
                self._send(404)

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class ParsingTests(unittest.TestCase):
    def test_request_packets(self):
        self.assertEqual(pps.build_request(pps.OP_ADDRESS), b'\x00\x00')
        pkt = pps.build_request(pps.OP_UDP, 1, 0, 60)
        self.assertEqual(len(pkt), 12)
        self.assertEqual(struct.unpack('!BBHHHI', pkt), (0, 1, 0, 1, 0, 60))

    def test_response_parsing(self):
        reply = struct.pack('!BBHIHHI', 0, 129, 0, 5, 1, 53186, 60)
        self.assertEqual(pps.parse_response(reply, pps.OP_UDP), (1, 53186, 60))
        addr = struct.pack('!BBHI', 0, 128, 0, 5) + socket.inet_aton('1.2.3.4')
        self.assertEqual(pps.parse_response(addr, pps.OP_ADDRESS), '1.2.3.4')
        self.assertIsNone(pps.parse_response(b'\x00\x81', pps.OP_UDP))
        self.assertIsNone(pps.parse_response(reply, pps.OP_TCP))      # wrong opcode
        with self.assertRaises(pps.NatPmpError):
            pps.parse_response(struct.pack('!BBHI', 0, 129, 2, 5) + b'\x00' * 8, pps.OP_UDP)

    def test_route_interface(self):
        self.assertEqual(pps.parse_route_interface(ROUTE_UTUN4), 'utun4')
        self.assertEqual(pps.parse_route_interface(ROUTE_EN0), 'en0')
        self.assertIsNone(pps.parse_route_interface('route: writing to routing socket: not in table'))

    def test_detect_interface(self):
        self.assertEqual(pps.detect_vpn_interface('10.2.0.1', lambda a: (0, ROUTE_UTUN4)), 'utun4')
        # VPN down: traffic to the gateway goes over the normal interface -> never bind to that
        self.assertIsNone(pps.detect_vpn_interface('10.2.0.1', lambda a: (0, ROUTE_EN0)))

    def test_detect_interface_ifconfig_fallback(self):
        def runner(args):
            return (1, '') if 'route' in args[0] else (0, IFCONFIG)
        self.assertEqual(pps.detect_vpn_interface('10.2.0.1', runner), 'utun6')
        self.assertIsNone(pps.parse_ifconfig_vpn(IFCONFIG, '172.16.'))

    def test_plist(self):
        data = pps.build_plist('/usr/bin/python3', '/x/protonportsync.py')
        self.assertEqual(data['ProgramArguments'], ['/usr/bin/python3', '/x/protonportsync.py', 'run'])
        self.assertTrue(data['RunAtLoad'] and data['KeepAlive'])


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ['PROTONPORTSYNC_HOME'] = self.tmp.name
        os.environ['PROTONPORTSYNC_PASSWORD'] = 'secret'
        pps.NATPMP_TIMEOUT = 0.3
        pps.NATPMP_TRIES = 1
        self.gw = MockGateway()
        self.gw.start()
        self.qbt = MockQbt()
        self.config_path = os.path.join(self.tmp.name, 'config.json')
        self.cfg = dict(pps.DEFAULTS, webui_url='http://127.0.0.1:%d' % self.qbt.port,
                        nat_pmp_gateway='127.0.0.1', nat_pmp_port=self.gw.port)
        pps.save_config(self.config_path, self.cfg)
        self.route = ROUTE_UTUN4
        self._orig = pps.run_command
        pps.run_command = lambda args, timeout=10: (0, self.route)
        pps.setup_logging(quiet=True)
        self.state = pps.State()

    def tearDown(self):
        pps.run_command = self._orig
        self.gw.close()
        self.qbt.close()
        os.environ.pop('PROTONPORTSYNC_PASSWORD', None)
        os.environ.pop('PROTONPORTSYNC_HOME', None)
        self.tmp.cleanup()

    def cycle(self):
        return pps.sync_cycle(self.cfg, self.state, self.config_path)

    def test_first_sync_sets_port_and_interface_in_one_call(self):
        self.assertTrue(self.cycle())
        self.assertEqual(self.qbt.prefs['listen_port'], 44139)
        self.assertEqual(self.qbt.prefs['current_network_interface'], 'utun4')
        self.assertEqual(len(self.qbt.set_calls), 1)
        self.assertEqual(self.gw.requests[0][1], 1)       # first map request is UDP (opcode 1)
        self.assertEqual(struct.unpack('!HH', self.gw.requests[0][4:8]), (1, 0))   # internal 1, suggest 0
        self.assertEqual(pps.load_config(self.config_path)['last_applied_port'], 44139)

    def test_idempotent(self):
        self.cycle()
        self.assertTrue(self.cycle())
        self.assertEqual(len(self.qbt.set_calls), 1)
        self.assertEqual(self.qbt.logins, 1)              # session is reused

    def test_new_port_and_new_utun_after_reconnect(self):
        self.cycle()
        self.gw.port_udp = self.gw.port_tcp = 51820
        self.route = ROUTE_UTUN4.replace('utun4', 'utun5')
        self.qbt.prefs['current_interface_address'] = '10.2.0.2'
        self.assertTrue(self.cycle())
        self.assertEqual(self.qbt.prefs['listen_port'], 51820)
        self.assertEqual(self.qbt.prefs['current_network_interface'], 'utun5')
        self.assertEqual(self.qbt.prefs['current_interface_address'], '')   # stale bound address cleared

    def test_vpn_down_changes_nothing_and_never_unbinds(self):
        self.cycle()
        self.gw.close()                                   # gateway stops answering
        self.route = ROUTE_EN0
        self.assertFalse(self.cycle())
        self.assertEqual(self.qbt.prefs['listen_port'], 44139)
        self.assertEqual(self.qbt.prefs['current_network_interface'], 'utun4')

    def test_tunnel_not_found_keeps_interface_but_syncs_port(self):
        self.route = ROUTE_EN0
        self.assertTrue(self.cycle())
        self.assertEqual(self.qbt.prefs['listen_port'], 44139)
        self.assertEqual(self.qbt.prefs['current_network_interface'], '')

    def test_mismatched_tcp_udp_ports_are_rejected(self):
        self.gw.port_tcp = 44140
        self.assertFalse(self.cycle())
        self.assertEqual(self.qbt.set_calls, [])

    def test_manage_interface_off(self):
        self.cfg['manage_interface'] = False
        self.assertTrue(self.cycle())
        self.assertEqual(self.qbt.prefs['current_network_interface'], '')

    def test_wrong_password_is_tried_once_until_config_changes(self):
        os.environ['PROTONPORTSYNC_PASSWORD'] = 'wrong'
        self.assertFalse(self.cycle())
        self.assertFalse(self.cycle())
        self.assertFalse(self.cycle())
        self.assertEqual(self.qbt.failed_logins, 1)       # no retry storm -> no IP ban
        os.environ['PROTONPORTSYNC_PASSWORD'] = 'secret'
        time.sleep(0.05)
        os.utime(self.config_path, (time.time() + 5, time.time() + 5))   # config "edited"
        self.assertTrue(self.cycle())

    def test_qbittorrent_not_running(self):
        self.qbt.close()
        self.assertFalse(self.cycle())
        self.qbt = MockQbt()                              # tearDown closes this one


if __name__ == '__main__':
    unittest.main()
