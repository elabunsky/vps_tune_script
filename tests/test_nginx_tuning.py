"""Exercise the standalone script's embedded nginx transaction without root."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "tune.sh"
CODE = SOURCE.read_text().split("<<'NGINX_PY'\n", 1)[1].split("\nNGINX_PY", 1)[0]
spec = importlib.util.spec_from_loader("nginx_tuning", loader=None)
nginx = importlib.util.module_from_spec(spec)
exec(compile(CODE, str(SOURCE) + ":nginx", "exec"), nginx.__dict__)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.config = self.root / "nginx.conf"

    def plan(self, text):
        self.config.write_text(text)
        return nginx.plan_config(self.config, 262144, 32768)

    def test_standard_config_and_idempotence(self):
        changes, nofile, conns = self.plan(
            '# worker_rlimit_nofile 10;\nworker_processes auto;\nevents {\n'
            ' worker_connections 512; # keep comment\n}\nhttp { server { '
            'set $v "quoted { # ; }"; set $b pre${host}; } }\n')
        text = changes[self.config]
        self.assertIn("worker_rlimit_nofile 262144;", text)
        self.assertIn("worker_connections 32768; # keep comment", text)
        self.assertIn('set $v "quoted { # ; }";', text)
        self.config.write_text(text)
        self.assertEqual(nginx.plan_config(self.config, nofile, conns)[0], {})

    def test_preserves_higher_limits_with_headroom(self):
        changes, nofile, conns = self.plan(
            'worker_rlimit_nofile 524288; events { worker_connections 400000; }')
        self.assertEqual((nofile, conns), (524288, 400000))
        self.assertEqual(changes, {})
        changes, nofile, conns = self.plan('events { worker_connections 300000; }')
        self.assertEqual((nofile, conns), (301024, 300000))

    def test_includes_in_main_and_events_and_symlink(self):
        limits = self.root / "limits.conf"
        limits.write_text('worker_rlimit_nofile 65535;\n')
        events = self.root / "events.conf"
        events.write_text('worker_connections 1024; # included\n')
        linked = self.root / "linked.conf"
        linked.symlink_to(limits)
        changes, _, _ = self.plan('include linked.conf; events { include events.conf; }')
        self.assertEqual(set(changes), {limits, events})
        self.assertEqual(changes[limits], 'worker_rlimit_nofile 262144;\n')
        self.assertTrue(linked.is_symlink())

    def test_symlink_main_keeps_original_include_prefix(self):
        target = self.root / 'elsewhere' / 'real.conf'
        target.parent.mkdir()
        target.write_text('include limits.conf; events {}')
        self.config.symlink_to(target)
        limits = self.root / 'limits.conf'
        limits.write_text('worker_rlimit_nofile 65535;')
        changes, _, _ = nginx.plan_config(self.config, 262144, 32768)
        self.assertIn(target, changes)
        self.assertIn(limits, changes)
        self.assertTrue(self.config.is_symlink())

    def test_adds_missing_directives_in_correct_context(self):
        changes, _, _ = self.plan('events {} http { server { listen 8080; } }')
        self.assertTrue(changes[self.config].startswith('worker_rlimit_nofile 262144;'))
        self.assertIn('events {\n    worker_connections 32768;\n}', changes[self.config])

    def test_refuses_ambiguous_configs_without_writes(self):
        for text in ('events {} events {}', 'http {}',
                     'worker_rlimit_nofile 10; worker_rlimit_nofile 20; events {}',
                     'events { worker_connections auto; }',
                     'events { include missing.conf; }', 'events {',
                     'events {} include nginx.conf;'):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    self.plan(text)
                self.assertEqual(self.config.read_text(), text)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.config = self.root / "nginx.conf"
        self.config.write_bytes(b'# original\r\nevents { worker_connections 512; }\r\n')
        self.config.chmod(0o640)
        self.original = self.config.read_bytes()
        self.dropin = self.root / "nginx.service.d" / "zz-vps-tune-nofile.conf"
        self.backups = self.root / "backups"
        self.values = {"ActiveState": "active", "MainPID": "100", "LimitNOFILESoft": "524288",
                       "LimitNOFILE": "524288"}
        self.calls = []
        self.fail_command = None
        self.worker_failure = False
        self.patch("DROPIN", self.dropin)
        self.patch("BACKUPS", self.backups)
        self.patch("prop", lambda name: self.values[name])
        self.patch("process_limits", lambda pid: [1024, 524288] if str(pid) == "100" else [262144, 262144])
        self.patch("worker_pids", lambda pid: ["101"])
        self.patch("verify_workers", self.verify)
        self.patch("run", self.run_command)
        # chown is root-only on some platforms; no ownership changes in tests.
        chown = patch.object(nginx.os, "chown")
        chown.start()
        self.addCleanup(chown.stop)

    def patch(self, name, value):
        mock = patch.object(nginx, name, value)
        mock.start()
        self.addCleanup(mock.stop)

    def run_command(self, *args):
        self.calls.append(args)
        if args == self.fail_command:
            self.fail_command = None  # recovery commands can succeed
            if "restart" in args:
                self.values["ActiveState"] = "failed"
            raise subprocess.CalledProcessError(1, args, stderr="injected failure")
        if args[:2] == ("systemctl", "start"):
            self.values["ActiveState"] = "active"
        return ""

    def verify(self, nofile, previous=()):
        if self.worker_failure:
            raise RuntimeError("worker limit not applied")

    def apply(self, dry=False, restart=False, changes=None):
        if changes is None:
            changes = {self.config: 'worker_rlimit_nofile 262144; events { worker_connections 32768; }',
                       self.dropin: '[Service]\nLimitNOFILE=524288\n'}
        nginx.apply(changes, self.config, 262144, 524288, dry, restart)

    def assert_rolled_back(self):
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        self.assertFalse(self.dropin.exists())
        self.assertEqual(len(list(self.backups.glob('*/manifest.json'))), 1)

    def test_dry_run_writes_nothing(self):
        before = sorted(str(p) for p in self.root.rglob('*'))
        self.apply(dry=True)
        self.assertEqual(before, sorted(str(p) for p in self.root.rglob('*')))
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.calls, [])

    def test_success_then_noop(self):
        self.apply()
        self.assertIn(("systemctl", "reload", nginx.SERVICE), self.calls)
        self.assertNotIn(("systemctl", "restart", nginx.SERVICE), self.calls)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        self.calls.clear()
        self.apply(changes={})
        self.assertEqual(self.calls, [])
        self.assertEqual(len(list(self.backups.iterdir())), 1)

    def test_stale_worker_limits_trigger_reload_without_file_changes(self):
        self.patch("process_limits", lambda pid: [1024, 524288])
        self.apply(changes={})
        self.assertIn(("systemctl", "reload", nginx.SERVICE), self.calls)
        self.assertFalse(self.backups.exists())

    def test_invalid_candidate_restores_files_without_reload(self):
        self.fail_command = ("nginx", "-t", "-c", str(self.config))
        with self.assertRaises(subprocess.CalledProcessError):
            self.apply()
        self.assert_rolled_back()
        self.assertFalse(any("reload" in cmd or "restart" in cmd for cmd in self.calls))

    def test_failed_reload_and_worker_verification_restore_original(self):
        for worker_failure in (False, True):
            with self.subTest(worker_failure=worker_failure):
                # Separate backup per failed transaction.
                self.patch("BACKUPS", self.backups / str(worker_failure))
                self.worker_failure = worker_failure
                self.fail_command = None if worker_failure else ("systemctl", "reload", nginx.SERVICE)
                with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                    self.apply()
                self.assertEqual(self.config.read_bytes(), self.original)
                self.assertFalse(self.dropin.exists())
                self.assertEqual(self.calls[-1], ("systemctl", "reload", nginx.SERVICE))

    def test_restart_failure_starts_previous_config(self):
        self.fail_command = ("systemctl", "restart", nginx.SERVICE)
        with self.assertRaises(subprocess.CalledProcessError):
            self.apply(restart=True)
        self.assert_rolled_back()
        self.assertEqual(self.calls[-1], ("systemctl", "start", nginx.SERVICE))
        self.assertEqual(self.values["ActiveState"], "active")

    def test_existing_dropin_restored(self):
        self.dropin.parent.mkdir()
        self.dropin.write_text('[Service]\nLimitNOFILE=100000\n')
        self.fail_command = ("nginx", "-t", "-c", str(self.config))
        with self.assertRaises(subprocess.CalledProcessError):
            self.apply()
        self.assertEqual(self.dropin.read_text(), '[Service]\nLimitNOFILE=100000\n')

    def test_systemd_override_detected_before_reload(self):
        self.values['LimitNOFILESoft'] = '1024'
        with self.assertRaisesRegex(RuntimeError, "overrides"):
            self.apply()
        self.assert_rolled_back()
        self.assertFalse(any("reload" in cmd for cmd in self.calls))

    def test_stopped_service_left_stopped(self):
        self.values['ActiveState'] = 'inactive'
        self.apply(restart=True)
        self.assertFalse(any(cmd[1] in ('start', 'reload', 'restart') for cmd in self.calls))
        self.assertEqual(self.values['ActiveState'], 'inactive')


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.config = self.root / "nginx.conf"
        self.config.write_text('worker_rlimit_nofile 65535; events { worker_connections 32768; }')
        self.nr_open = self.root / 'nr_open'
        self.nr_open.write_text('1048576')
        self.props = {'ExecStart': '{ path=/usr/sbin/nginx ; argv[]=/usr/sbin/nginx -g daemon on; master_process on; ; }',
                      'FragmentPath': '/usr/lib/systemd/system/nginx.service', 'User': '',
                      'LimitNOFILESoft': '1024', 'LimitNOFILE': '524288'}
        for name, value in {'NR_OPEN': self.nr_open, 'DROPIN': self.root / 'dropin.conf',
                            'prop': lambda name: self.props[name], 'run': lambda *args: ''}.items():
            mock = patch.object(nginx, name, value)
            mock.start()
            self.addCleanup(mock.stop)
        for target, kwargs in ((nginx.shutil, {'which': lambda name: '/usr/sbin/nginx'}),):
            for name, value in kwargs.items():
                mock = patch.object(target, name, value)
                mock.start()
                self.addCleanup(mock.stop)
        mock = patch.object(nginx.subprocess, 'run', return_value=subprocess.CompletedProcess(
            [], 0, stdout='', stderr=f'configure arguments: --conf-path={self.config}'))
        mock.start()
        self.addCleanup(mock.stop)
        mock = patch.object(nginx.sys, 'argv', ['-', '1', '0', '262144', '32768'])
        mock.start()
        self.addCleanup(mock.stop)

    def test_preserves_larger_systemd_hard_limit(self):
        with patch.object(nginx, 'apply') as apply:
            nginx.main()
        self.assertEqual(apply.call_args.args[2:4], (262144, 524288))
        self.assertEqual(apply.call_args.args[0][nginx.DROPIN],
                         '# Managed by vps_tune_script/tune.sh\n[Service]\nLimitNOFILE=524288\n')
        self.assertEqual(set(self.root.iterdir()), {self.config, self.nr_open})

    def test_kernel_ceiling_fails_before_writes(self):
        self.nr_open.write_text('131072')
        with self.assertRaisesRegex(ValueError, 'exceeds fs.nr_open'):
            nginx.main()
        self.assertFalse(nginx.DROPIN.exists())

    def test_custom_service_and_infinite_limits_fail_before_writes(self):
        baseline = self.props.copy()
        for name, value in (('ExecStart', '{ path=/usr/sbin/nginx ; argv[]=/usr/sbin/nginx -c /custom.conf ; }'),
                            ('ExecStart', '{ path=/custom/nginx ; }'), ('User', 'www-data'),
                            ('LimitNOFILE', 'infinity')):
            with self.subTest(name=name, value=value):
                self.props = dict(baseline, **{name: value})
                with self.assertRaises(ValueError):
                    nginx.main()
                self.assertFalse(nginx.DROPIN.exists())


if __name__ == '__main__':
    unittest.main()
