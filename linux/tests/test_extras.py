"""Tests for the 0.2 additions: status.json, on_port_change hook, port reachability check,
health checks, masking and the support bundle - plus how sync_cycle drives them, against the
mock qBittorrent and mock ProtonVPN gateway from test_protonportsync.

    python3 -m unittest discover -s tests -v
"""
import json
import logging
import os
import re
import stat
import sys
import tempfile
import time
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import protonportsync as pps  # noqa: E402
from test_protonportsync import MockGateway, MockQbt  # noqa: E402


class Capture(logging.Handler):
    def __init__(self):
        super().__init__()
        self.lines = []

    def emit(self, record):
        self.lines.append('%s %s' % (record.levelname, record.getMessage()))

    def has(self, pattern):
        return any(re.search(pattern, line) for line in self.lines)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self._env = {k: os.environ.get(k) for k in ('PROTONPORTSYNC_HOME', 'PROTONPORTSYNC_PASSWORD', 'HOME')}
        os.environ['PROTONPORTSYNC_HOME'] = self.dir
        self.capture = Capture()
        for handler in list(pps.log.handlers):
            pps.log.removeHandler(handler)
        pps.log.addHandler(self.capture)
        pps.log.setLevel(logging.DEBUG)
        pps.log.propagate = False
        self.cfg = dict(pps.DEFAULTS)

    def tearDown(self):
        pps.log.removeHandler(self.capture)
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def script(self, name, body, executable=True):
        path = os.path.join(self.dir, name)
        with open(path, 'w') as fh:
            fh.write(body)
        os.chmod(path, 0o755 if executable else 0o644)
        return path


class StatusFileTests(Base):
    def make_state(self, **cycle):
        state = pps.State()
        state.cycle = pps.new_cycle()
        state.cycle.update(state='in_sync', in_sync=True, vpn_connected=True,
                           forwarded_port=51820, qbittorrent_port=51820)
        state.cycle.update(cycle)
        state.last_port_change = '2026-01-01T00:00:00Z'
        return state

    def read(self, path):
        with open(path, encoding='utf-8') as fh:
            return json.load(fh)

    def test_contents(self):
        path = os.path.join(self.dir, 'status.json')
        pps.write_status(self.cfg, self.make_state(), path, now=1000)
        data = self.read(path)
        self.assertEqual((data['state'], data['inSync'], data['forwardedPort'], data['qbittorrentPort']),
                         ('in_sync', True, 51820, 51820))
        self.assertEqual(data['version'], pps.__version__)
        self.assertEqual(data['lastPortChangeUtc'], '2026-01-01T00:00:00Z')
        self.assertRegex(data['updatedUtc'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
        self.assertFalse(os.path.exists(path + '.tmp'))
        self.assertEqual(pps.status_path(os.path.join(self.dir, 'config.json')), path)

    def test_only_rewritten_on_change_or_after_five_minutes(self):
        path = os.path.join(self.dir, 'status.json')
        state = self.make_state()
        pps.write_status(self.cfg, state, path, now=1000)
        first = self.read(path)['updatedUtc']
        pps.write_status(self.cfg, state, path, now=1100)
        self.assertEqual(self.read(path)['updatedUtc'], first)            # unchanged, recent
        pps.write_status(self.cfg, state, path, now=1000 + pps.STATUS_WRITE_SECONDS + 1)
        self.assertNotEqual(self.read(path)['updatedUtc'], first)         # heartbeat rewrite
        state.cycle.update(state='qbt_unreachable', in_sync=False, error='refused')
        pps.write_status(self.cfg, state, path, now=1000 + pps.STATUS_WRITE_SECONDS + 2)
        data = self.read(path)
        self.assertEqual((data['state'], data['inSync'], data['lastError']), ('qbt_unreachable', False, 'refused'))

    def test_can_be_turned_off(self):
        path = os.path.join(self.dir, 'status.json')
        self.cfg['status_file'] = False
        pps.write_status(self.cfg, self.make_state(), path, now=1)
        self.assertFalse(os.path.exists(path))


class HookTests(Base):
    def test_nothing_configured(self):
        pps.run_hook(self.cfg, 1, 2)
        self.assertEqual(self.capture.lines, [])

    def test_refused_inputs(self):
        for value, pattern in (('relative.sh', 'file not found'),
                               (os.path.join(self.dir, 'missing.sh'), 'file not found'),
                               (self.script('plain.txt', 'x', executable=False), 'not executable')):
            self.capture.lines.clear()
            self.cfg['on_port_change'] = value
            pps.run_hook(self.cfg, 1, 2)
            self.assertTrue(self.capture.has(pattern), (value, self.capture.lines))

    def test_executable_script_gets_environment(self):
        out = os.path.join(self.dir, 'out.txt')
        self.cfg['on_port_change'] = self.script(
            'hook.sh', '#!/bin/sh\necho "$PPS_EVENT $PPS_OLD_PORT $PPS_NEW_PORT $PPS_VERSION" > "%s"\n' % out)
        pps.run_hook(self.cfg, 40000, 51820)
        with open(out) as fh:
            self.assertEqual(fh.read().strip(), 'port_changed 40000 51820 %s' % pps.__version__)
        self.assertTrue(self.capture.has('on_port_change: ran'))
        self.assertNotIn('PPS_NEW_PORT', os.environ)            # nothing leaks into this process

    def test_python_file_does_not_need_exec_bit(self):
        out = os.path.join(self.dir, 'py-out.txt')
        self.cfg['on_port_change'] = '"%s"' % self.script(
            'hook.py', 'import os\nopen(%r, "w").write(os.environ["PPS_NEW_PORT"])\n' % out, executable=False)
        pps.run_hook(self.cfg, 1, 777)
        with open(out) as fh:
            self.assertEqual(fh.read(), '777')

    def test_failure_and_timeout_are_reported(self):
        self.cfg['on_port_change'] = self.script('fail.sh', '#!/bin/sh\nexit 3\n')
        pps.run_hook(self.cfg, 1, 2)
        self.assertTrue(self.capture.has('exited with code 3'))
        self.capture.lines.clear()
        self.cfg['on_port_change'] = self.script('slow.sh', '#!/bin/sh\nexec sleep 10\n')
        saved, pps.HOOK_TIMEOUT = pps.HOOK_TIMEOUT, 1
        try:
            started = time.time()
            pps.run_hook(self.cfg, 1, 2)
            self.assertLess(time.time() - started, 6)
        finally:
            pps.HOOK_TIMEOUT = saved
        self.assertTrue(self.capture.has('did not finish within'))


class PortCheckTests(Base):
    def setUp(self):
        super().setUp()
        self.answer = '1'
        self.urls = []
        self._orig = pps.fetch_text
        pps.fetch_text = lambda url, timeout=10: (self.urls.append(url), self.answer)[1]
        self.cfg['port_check'] = True
        self.cfg['port_check_url'] = 'https://check.example/{port}'
        self.state = pps.State()
        self.state.cycle = pps.new_cycle()
        self.state.cycle.update(state='in_sync', in_sync=True, forwarded_port=51820, qbittorrent_port=51820)

    def tearDown(self):
        pps.fetch_text = self._orig
        super().tearDown()

    def test_answers(self):
        self.assertIs(pps.check_port_reachable(self.cfg, 51820), True)
        self.assertEqual(self.urls[0], 'https://check.example/51820')
        self.answer = ' 0\n'
        self.assertIs(pps.check_port_reachable(self.cfg, 1), False)
        self.answer = '<html>oops</html>'
        self.assertIsNone(pps.check_port_reachable(self.cfg, 1))
        self.answer = None
        self.assertIsNone(pps.check_port_reachable(self.cfg, 1))

    def test_schedule_and_closed_logic(self):
        t0 = 1_000_000
        self.cfg['port_check'] = False
        pps.port_check_if_due(self.cfg, self.state, t0)
        self.assertEqual(self.urls, [])                                   # off = never contacts the service
        self.cfg['port_check'] = True
        pps.port_check_if_due(self.cfg, self.state, t0)
        self.assertEqual(self.urls, [])                                   # new port: 2 minutes to settle
        pps.port_check_if_due(self.cfg, self.state, t0 + 130)
        self.assertEqual(len(self.urls), 1)
        self.assertIs(self.state.port_reachable, True)
        pps.port_check_if_due(self.cfg, self.state, t0 + 600)
        self.assertEqual(len(self.urls), 1)                               # not before port_check_minutes
        self.answer = '0'
        pps.port_check_if_due(self.cfg, self.state, t0 + 130 + 1900)
        self.assertIs(self.state.port_reachable, True)                    # one closed answer alone: no report
        self.assertFalse(self.capture.has('CLOSED'))
        pps.port_check_if_due(self.cfg, self.state, t0 + 130 + 1900 + 130)
        self.assertIs(self.state.port_reachable, False)
        self.assertTrue(self.capture.has('looks CLOSED'))
        self.answer = None
        before = self.state.port_reachable
        pps.port_check_if_due(self.cfg, self.state, t0 + 10_000)
        self.assertIs(self.state.port_reachable, before)                  # service down: result unchanged

    def test_new_port_resets_and_out_of_sync_is_skipped(self):
        t0 = 2_000_000
        pps.port_check_if_due(self.cfg, self.state, t0)
        pps.port_check_if_due(self.cfg, self.state, t0 + 130)
        self.assertIs(self.state.port_reachable, True)
        self.state.cycle.update(forwarded_port=40404, qbittorrent_port=40404)
        pps.port_check_if_due(self.cfg, self.state, t0 + 200)
        self.assertIsNone(self.state.port_reachable)
        count = len(self.urls)
        self.state.cycle.update(in_sync=False)
        pps.port_check_if_due(self.cfg, self.state, t0 + 99_999)
        self.assertEqual(len(self.urls), count)


def make_snap(**over):
    snap = {'version': pps.__version__, 'webui_url': 'http://127.0.0.1:8080', 'vpn_ip': '203.0.113.5',
            'udp': 51820, 'tcp': 51820, 'port': 51820, 'vpn_iface': 'tun9', 'manage_interface': True,
            'qbt_ok': True, 'qbt_error': '', 'qbt_error_kind': '', 'qbt_port': 51820, 'qbt_iface': 'tun9',
            'random_port': False, 'upnp': False, 'in_sync': True, 'port_reachable': None}
    snap.update(over)
    return snap


class HealthTests(unittest.TestCase):
    def check(self, level, pattern, hint_pattern=None, **over):
        items = pps.health_checks(make_snap(**over))
        hits = [i for i in items if i['level'] == level and re.search(pattern, i['message'])]
        self.assertTrue(hits, (level, pattern, items))
        if hint_pattern:
            self.assertTrue(re.search(hint_pattern, hits[0]['hint']), hits[0])

    def test_healthy(self):
        items = pps.health_checks(make_snap())
        self.assertFalse([i for i in items if i['level'] in ('WARN', 'ERROR')])
        self.assertTrue(any('Everything looks fine' in i['message'] for i in items))

    def test_vpn_problems(self):
        self.check('ERROR', 'does not appear to be connected', 'P2P', vpn_ip=None, udp=None, tcp=None, port=None, in_sync=False)
        self.check('WARN', 'gave no forwarded port', 'Port Forwarding', udp=None, tcp=None, port=None, in_sync=False)
        self.check('WARN', 'different or missing ports', 'Reconnect', tcp=51821, port=None, in_sync=False)

    def test_qbittorrent_problems(self):
        base = dict(qbt_ok=False, qbt_port=None, qbt_iface='', in_sync=False)
        self.check('ERROR', 'Cannot reach qBittorrent at http://127.0.0.1:8080', 'Web UI', qbt_error_kind='unreachable', **base)
        self.check('ERROR', 'rejected the username', 'setup', qbt_error_kind='auth', **base)
        self.check('ERROR', 'banned', 'Restart qBittorrent', qbt_error_kind='banned', **base)
        self.check('ERROR', 'weird failure', qbt_error_kind='other', qbt_error='weird failure', **base)

    def test_settings_warnings(self):
        self.check('WARN', 'random port', 'turn off', random_port=True)
        self.check('WARN', 'UPnP', upnp=True)
        self.check('WARN', 'listens on 40000 but the VPN forwards 51820', qbt_port=40000, in_sync=False)

    def test_interface_findings(self):
        self.check('WARN', 'Could not find the VPN tunnel interface', pps.IFACE_LOOKUP_CMD, vpn_iface=None, in_sync=False)
        self.check('WARN', 'not bound to a network interface yet', 'tun9', qbt_iface='', in_sync=False)
        self.check('WARN', 'bound to "eth0" but the VPN tunnel is "tun9"', qbt_iface='eth0', in_sync=False)
        self.check('WARN', 'not bound to a network interface\\.', 'Advanced', manage_interface=False, qbt_iface='')
        self.check('OK', 'bound to the VPN tunnel "tun9"')

    def test_reachability(self):
        self.check('WARN', 'looks closed', 'firewall', port_reachable=False)
        self.check('OK', 'reachable from the internet', port_reachable=True)


class MaskAndBundleTests(Base):
    def test_mask_text(self):
        home = os.path.join(self.dir, 'home', 'alex')
        os.environ['HOME'] = home
        masked = pps.mask_text('pub 185.107.44.9 gw 10.2.0.1 lan 192.168.1.20 lo 127.0.0.1 '
                               'b 172.20.1.1 c 172.32.0.1 path %s/hook.sh bad 999.1.1.1' % home)
        self.assertNotIn('185.107.44.9', masked)
        self.assertNotIn('172.32.0.1', masked)
        self.assertNotIn('999.1.1.1', masked)
        for kept in ('10.2.0.1', '192.168.1.20', '127.0.0.1', '172.20.1.1', '~/hook.sh'):
            self.assertIn(kept, masked)
        self.assertNotIn(home, masked)

    def test_masked_config(self):
        cfg = dict(self.cfg, username='alex', webui_url='http://nas.home.example:9090')
        text = pps.masked_config(cfg)
        self.assertNotIn('alex', text)
        self.assertNotIn('nas.home.example', text)
        self.assertIn('(remote-host):9090', text)
        self.assertIn('127.0.0.1:8080', pps.masked_config(dict(self.cfg, username='alex')))

    def test_bundle(self):
        cfg_path = os.path.join(self.dir, 'config.json')
        pps.save_config(cfg_path, dict(self.cfg, username='alex'))
        os.makedirs(pps.log_dir(), exist_ok=True)
        with open(os.path.join(pps.log_dir(), 'ProtonPortSync.log'), 'w') as fh:
            for n in range(1, 1501):
                fh.write('2026-06-01 12:00:00 [INFO] line %d VPN IP 185.107.44.9\n' % n)
        with open(pps.status_path(cfg_path), 'w') as fh:
            fh.write('{"state": "in_sync"}\n')
        out_dir = os.path.join(self.dir, 'out')
        os.makedirs(out_dir)
        path = pps.make_support_bundle(dict(self.cfg, username='alex'), make_snap(), cfg_path, out_dir)
        self.assertTrue(path.startswith(out_dir) and 'ProtonPortSync-support-' in path)
        with zipfile.ZipFile(path) as zf:
            names = set(zf.namelist())
            self.assertTrue({'report.txt', 'config.json', 'status.json', 'ProtonPortSync.log'} <= names, names)
            everything = '\n'.join(zf.read(n).decode('utf-8') for n in names)
            log_lines = zf.read('ProtonPortSync.log').decode().splitlines()
        self.assertNotIn('185.107.44.9', everything)
        self.assertNotIn('alex', everything)
        self.assertEqual(len(log_lines), 1000)
        self.assertIn('line 1500', log_lines[-1])
        self.assertIn('Everything looks fine', everything)
        fallback = pps.make_support_bundle(self.cfg, make_snap(), cfg_path, os.path.join(self.dir, 'nope'))
        self.assertEqual(os.path.dirname(fallback), self.dir)


class CycleIntegrationTests(Base):
    """sync_cycle against the mock gateway and mock qBittorrent."""

    def setUp(self):
        super().setUp()
        os.environ['PROTONPORTSYNC_PASSWORD'] = 'secret'
        pps.NATPMP_TIMEOUT = 0.3
        pps.NATPMP_TRIES = 1
        self.gw = MockGateway()
        self.gw.start()
        self.qbt = MockQbt()
        self.config_path = os.path.join(self.dir, 'config.json')
        self.hook_out = os.path.join(self.dir, 'hook-calls.txt')
        self.cfg.update(webui_url='http://127.0.0.1:%d' % self.qbt.port, nat_pmp_gateway='127.0.0.1',
                        nat_pmp_port=self.gw.port, manage_interface=False,
                        on_port_change=self.script('hook.sh', '#!/bin/sh\necho "$PPS_OLD_PORT->$PPS_NEW_PORT" >> "%s"\n' % self.hook_out))
        pps.save_config(self.config_path, self.cfg)
        self.state = pps.State()

    def tearDown(self):
        self.gw.close()
        self.qbt.close()
        super().tearDown()

    def cycle(self):
        return pps.sync_cycle(self.cfg, self.state, self.config_path)

    def hook_calls(self):
        if not os.path.exists(self.hook_out):
            return []
        with open(self.hook_out) as fh:
            return fh.read().split()

    def test_change_records_state_and_runs_hook_once(self):
        self.assertTrue(self.cycle())
        cyc = self.state.cycle
        self.assertEqual((cyc['state'], cyc['in_sync'], cyc['vpn_connected']), ('in_sync', True, True))
        self.assertEqual((cyc['forwarded_port'], cyc['qbittorrent_port']), (44139, 44139))
        self.assertEqual(self.hook_calls(), ['51274->44139'])
        self.assertRegex(self.state.last_port_change, r'^\d{4}-')
        self.assertTrue(self.cycle())
        self.assertEqual(self.hook_calls(), ['51274->44139'])            # nothing changed: hook not run again
        pps.write_status(self.cfg, self.state, pps.status_path(self.config_path), force=True)
        with open(pps.status_path(self.config_path)) as fh:
            data = json.load(fh)
        self.assertEqual((data['state'], data['forwardedPort']), ('in_sync', 44139))

    def test_failure_states(self):
        self.gw.close()
        self.assertFalse(self.cycle())
        self.assertEqual((self.state.cycle['state'], self.state.cycle['vpn_connected']), ('vpn_down', False))
        self.gw = MockGateway()
        self.gw.start()
        self.cfg['nat_pmp_port'] = self.gw.port
        os.environ['PROTONPORTSYNC_PASSWORD'] = 'wrong'
        self.assertFalse(self.cycle())
        self.assertEqual(self.state.cycle['state'], 'auth_failed')
        self.assertFalse(self.cycle())                                    # the "tried once" guard path
        self.assertEqual(self.state.cycle['state'], 'auth_failed')
        self.qbt.close()
        os.environ['PROTONPORTSYNC_PASSWORD'] = 'secret'
        self.state = pps.State()
        self.assertFalse(self.cycle())
        self.assertEqual(self.state.cycle['state'], 'qbt_unreachable')
        self.assertIn('unreachable', self.state.cycle['error'])
        self.qbt = MockQbt()                                              # tearDown closes this one

    def test_snapshot_and_interface_findings(self):
        self.cfg['manage_interface'] = True
        orig = pps.detect_vpn_interface
        pps.detect_vpn_interface = lambda gateway, *a, **k: 'tun9'
        try:
            self.assertTrue(self.cycle())
            snap = pps.gather_snapshot(self.cfg)
            self.assertTrue(snap['qbt_ok'] and snap['in_sync'])
            self.assertEqual((snap['port'], snap['qbt_iface'], snap['vpn_iface']), (44139, 'tun9', 'tun9'))
            self.assertFalse([i for i in pps.health_checks(snap) if i['level'] in ('WARN', 'ERROR')])
            self.qbt.prefs['current_network_interface'] = ''
            snap = pps.gather_snapshot(self.cfg)
            self.assertFalse(snap['in_sync'])
            self.assertTrue(any('not bound' in i['message'] for i in pps.health_checks(snap)))
        finally:
            pps.detect_vpn_interface = orig


if __name__ == '__main__':
    unittest.main()
