"""Synthetic handoff/rollback tests: no launchd, CLI, notifications or real account."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest


class MigrationTests(unittest.TestCase):
    def setUp(self):
        project = Path(__file__).resolve().parent.parent
        folder = project / '.build/test/migration'
        folder.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='case-', dir=folder))
        spec = importlib.util.spec_from_file_location('migration', project / 'Scripts/reset-worker.py')
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        m = self.m
        m.APP = self.root / 'Installed.app'
        m.BUILT = self.root / 'Built.app'
        m.BASE = self.root / 'legacy'
        m.SUPPORT = self.root / 'support/reset'
        m.BACKUP_ROOT = self.root / 'support/backups'
        m.PLIST = self.root / 'example.worker.plist'
        m.LABEL = 'example.worker'
        m.BIN = m.APP / 'Contents/MacOS/CodexUsage'
        for bundle, content in ((m.APP, 'old'), (m.BUILT, 'new')):
            (bundle / 'Contents/MacOS').mkdir(parents=True)
            (bundle / 'Contents/MacOS/CodexUsage').write_text(content)
        m.BASE.mkdir()
        (m.BASE / 'reset_credit_watcher.py').write_text('# synthetic watcher')
        self.ledger = m.BASE / 'reset_credit_watcher_state.json'
        self.ledger.write_text('{"consume":{},"alerts":{}}')
        self.original = {'Label': m.LABEL,
                         'ProgramArguments': ['/example/Python', str(m.BASE / 'reset_credit_watcher.py')]}
        m.PLIST.write_bytes(plistlib.dumps(self.original))
        self.legacy = True
        self.native = False
        self.change_on_stop = None
        self.commands = []
        m.stop_ui = lambda: None
        m.legacy_running = lambda: self.legacy
        m.native_pid = lambda: 123 if self.native else None
        m.run = self.fake_run

    def apply(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.m.apply()

    def record(self, outcome='reset', key='synthetic-staging-key'):
        return {'idempotencyKey': key, 'lastAttemptAt': '2030-01-01T00:00:00+00:00',
                'outcome': outcome}

    def fake_run(self, args, check=True, timeout=45):
        args = [str(x) for x in args]
        self.commands.append(args)
        if args[:2] == ['/bin/launchctl', 'bootout']:
            self.legacy = self.native = False
            if self.change_on_stop is not None:
                self.ledger.write_text(json.dumps(self.change_on_stop))
                self.change_on_stop = None
        elif args[:2] == ['/bin/launchctl', 'bootstrap']:
            agent = plistlib.loads(self.m.PLIST.read_bytes())
            self.native = '--reset-worker' in agent['ProgramArguments']
            self.legacy = not self.native
            if self.native:
                state = json.loads((self.m.SUPPORT / 'state.json').read_text())
                state.update(checkedAt=1, phase='monitoring')
                self.m.put(self.m.SUPPORT / 'state.json', state)
        elif args[0] == '/usr/bin/open' and '--export-menu-state' in args:
            Path(args[-1]).write_text('{"version":"synthetic"}')
        return SimpleNamespace(returncode=0, stdout='')

    def test_framework_python_identity_is_exact(self):
        script = '/example/reset_credit_watcher.py'
        self.assertTrue(self.m.matches_legacy_process('/framework/Python ' + script, script))
        self.assertTrue(self.m.matches_legacy_process('/framework/python3.13 ' + script, script))
        self.assertFalse(self.m.matches_legacy_process('/framework/Python ' + script + '.other', script))
        self.assertFalse(self.m.matches_legacy_process('/bin/echo ' + script, script))
        self.assertFalse(self.m.matches_legacy_process('', script))

    def test_unresolved_legacy_request_blocks_before_changes(self):
        value = self.record(outcome='unconfirmed')
        self.ledger.write_text(json.dumps({'consume': {'sample-credit': value}}))
        with self.assertRaisesRegex(RuntimeError, 'unresolved'):
            self.apply()
        self.assertTrue(self.legacy)
        self.assertFalse(self.m.BACKUP_ROOT.exists())
        self.assertEqual(self.m.BIN.read_text(), 'old')

    def test_final_ledger_is_captured_after_stopping_old_consumer(self):
        self.change_on_stop = {'consume': {'sample-credit': self.record()}}
        self.apply()
        state = json.loads((self.m.SUPPORT / 'state.json').read_text())
        self.assertEqual(state['attempts']['sample-credit']['key'], 'synthetic-staging-key')
        self.assertTrue(self.native)
        self.assertFalse(self.legacy)
        self.assertEqual(plistlib.loads(self.m.PLIST.read_bytes())['Label'], 'example.worker')
        settings = json.loads((self.m.SUPPORT / 'settings.json').read_text())
        self.assertFalse(settings['autoUse'])
        self.assertTrue(settings['reminders'])
        self.assertEqual((self.m.SUPPORT / 'state.json').stat().st_mode & 0o777, 0o600)

    def test_late_unconfirmed_key_survives_automatic_rollback(self):
        self.change_on_stop = {'consume': {'sample-credit': self.record(outcome='unconfirmed')}}
        with self.assertRaisesRegex(RuntimeError, 'unresolved'):
            self.apply()
        self.assertTrue(self.legacy)
        self.assertFalse(self.native)
        self.assertEqual(self.m.BIN.read_text(), 'old')
        self.assertEqual(json.loads(self.ledger.read_text())['consume']['sample-credit']['idempotencyKey'],
                         'synthetic-staging-key')

    def test_rollback_preserves_native_pending_key(self):
        self.apply()
        backup = next(self.m.BACKUP_ROOT.iterdir())
        state = json.loads((self.m.SUPPORT / 'state.json').read_text())
        state['attempts']['sample-credit'] = {'key':'synthetic-recovery-key', 'expiresAt':1,
                                             'attemptedAt':1, 'outcome':'pending'}
        self.m.put(self.m.SUPPORT / 'state.json', state)
        self.m.rollback(backup)
        self.assertEqual(json.loads(self.ledger.read_text())['consume']['sample-credit']['idempotencyKey'],
                         'synthetic-recovery-key')
        self.assertTrue(self.legacy)
        self.assertFalse(self.native)
        self.assertEqual(self.m.BIN.read_text(), 'old')
        self.assertEqual(plistlib.loads(self.m.PLIST.read_bytes()), self.original)


if __name__ == '__main__':
    unittest.main()
