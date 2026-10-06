"""Isolated user directories and launchd doubles; never touch the real account or jobs."""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('installation', PROJECT / 'Scripts/installation.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class PowerLoss(BaseException):
    pass


def bundle(path, marker):
    (path / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (path / 'Contents/MacOS/CodexUsage').write_text(marker)
    (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': m.BUNDLE_ID}))


class FakeMac:
    def __init__(self):
        self.jobs = {}
        self.extra = []
        self.commands = []
        self.events = []
        self.fail_start = None
        self.fail_build = False
        self.fail_health = False
        self.after_stop = None
        self.health_hook = None

    def run(self, args, **kwargs):
        self.commands.append([str(x) for x in args])
        # Production execute() may run only the selected CLI's version command.
        assert args[-1] == '--version'
        return SimpleNamespace(returncode=0, stdout='synthetic CLI')

    def job(self, label):
        return self.jobs.get(label)

    def verify_job(self, label, path, arguments):
        job = self.jobs.get(label)
        if job is not None:
            if job['path'] != str(path) or job['definition']['ProgramArguments'] != arguments:
                raise m.InstallError('Unexpected loaded service identity')
            return True
        return False

    def processes(self):
        return [(100 + i, ' '.join(job['definition']['ProgramArguments']))
                for i, job in enumerate(self.jobs.values())] + list(self.extra)

    def stop(self, label):
        self.events.append(('stop', label))
        self.jobs.pop(label, None)
        if self.after_stop:
            hook = self.after_stop
            self.after_stop = None
            hook(label)

    def stop_apps(self, binary):
        self.extra = [(pid, args) for pid, args in self.extra if not args.startswith(str(binary))]

    def start(self, path):
        value = plistlib.loads(path.read_bytes())
        label = value['Label']
        self.events.append(('start', label))
        if label == self.fail_start:
            self.fail_start = None
            raise m.InstallError('Synthetic bootstrap failure')
        if label in self.jobs:
            raise m.InstallError('Duplicate service bootstrap')
        self.jobs[label] = {'path': str(path), 'definition': value}
        consumers = [job for job in self.jobs.values()
                     if '--reset-worker' in job['definition']['ProgramArguments']
                     or any('reset_credit_watcher.py' in a for a in job['definition']['ProgramArguments'])]
        assert len(consumers) <= 1, 'Two consumers overlapped'

    def verify_bundle(self, app):
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info['CFBundleIdentifier'] != m.BUNDLE_ID:
            raise m.InstallError('Wrong bundle')

    def prepare_build(self, project, output):
        if self.fail_build:
            raise m.InstallError('Synthetic failed build')
        bundle(output, 'new')

    def health(self, plan, reset, since):
        assert m.read(reset / 'ownership.json')['active'] is False, 'Health check enabled consumption'
        assert set(self.jobs) == {m.MENU, plan['workerLabel']}
        if self.health_hook:
            self.health_hook(reset)
        if self.fail_health:
            self.fail_health = False
            raise m.InstallError('Synthetic health failure')
        state = m.read(reset / 'state.json')
        state['workerSeenAt'] = since - m.REFERENCE
        m.put(reset / 'state.json', state)

    def open_app(self, app):
        self.extra.append((999, str(app / 'Contents/MacOS/CodexUsage')))


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='codex-install-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'Synthetic User'
        self.project = self.root / 'source'
        self.cli = self.root / 'mock-codex'
        self.cli.write_text('#!/bin/sh\nexit 0\n')
        self.cli.chmod(0o755)
        self.mac = FakeMac()
        self.i = m.Installer(self.home, self.project, self.mac, {'CODEX_PATH': str(self.cli)})
        self.app = self.home / 'Applications/CodexUsage.app'

    def state(self):
        return m.read(self.i.reset / 'state.json')

    def settings(self):
        return m.read(self.i.reset / 'settings.json')

    def install(self):
        return self.i.execute('install')

    def marker(self):
        return (self.app / 'Contents/MacOS/CodexUsage').read_text()

    def attempt(self, outcome='pending', key='synthetic-existing-key'):
        return dict(key=key, attemptedAt=915148700, expiresAt=915149900, outcome=outcome)

    def legacy(self, unresolved=False):
        folder = self.home / '.codex/automations/codex'
        folder.mkdir(parents=True)
        (folder / 'reset_credit_watcher.py').write_text('# synthetic; never executed')
        self.legacy_ledger = folder / 'reset_credit_watcher_state.json'
        record = {'consume': {}, 'alerts': {}}
        if unresolved:
            record['consume']['credit'] = dict(lastAttemptAt='2030-01-01T00:00:00+00:00',
                                               idempotencyKey='synthetic-legacy-key', outcome='unknown')
        m.put(self.legacy_ledger, record)
        path = self.i.agents / 'example.legacy.plist'
        self.i.agents.mkdir(parents=True)
        path.write_bytes(plistlib.dumps(dict(Label='example.legacy',
            ProgramArguments=['/example/Python', str(folder / 'reset_credit_watcher.py')], RunAtLoad=True)))
        self.mac.start(path)
        return path

    def make_prior_native(self, auto=False, reminders=True):
        self.install()
        (self.app / 'Contents/MacOS/CodexUsage').write_text('old')
        m.put(self.i.reset / 'settings.json', dict(autoUse=auto, reminders=reminders))
        state = self.state()
        state['attempts']['credit'] = self.attempt()
        state['reminders']['credit'] = [3600]
        m.put(self.i.reset / 'state.json', state)
        return copy.deepcopy(state)

    def test_fresh_install_registers_both_with_auto_off_and_alerts_on(self):
        self.install()
        self.assertEqual(set(self.mac.jobs), {m.MENU, m.WORKER})
        self.assertEqual(self.settings(), {'autoUse': False, 'reminders': True})
        self.assertTrue(m.read(self.i.reset / 'ownership.json')['active'])
        self.assertEqual(self.marker(), 'new')
        self.assertEqual((self.i.reset / 'state.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.mac.jobs[m.WORKER]['definition']['Umask'], 0o077)
        self.assertTrue(all(cmd[-1] == '--version' for cmd in self.mac.commands))

    def test_repeat_install_preserves_switches_pending_keys_and_reminders(self):
        prior = self.make_prior_native(auto=False, reminders=False)
        for _ in range(2):
            self.install()
            self.assertEqual(self.settings(), {'autoUse': False, 'reminders': False})
            self.assertEqual(self.state()['attempts'], prior['attempts'])
            self.assertEqual(self.state()['reminders'], prior['reminders'])
            self.assertEqual(len(self.mac.jobs), 2)

    def test_existing_enabled_choice_is_preserved_without_enabling_health_checks(self):
        self.make_prior_native(auto=True)
        self.install()
        self.assertTrue(self.settings()['autoUse'])
        self.assertEqual(self.state()['attempts']['credit']['key'], 'synthetic-existing-key')

    def test_usage_only_install_is_upgraded_in_place(self):
        bundle(self.app, 'usage-only')
        path = self.i.agents / (m.MENU + '.plist')
        path.parent.mkdir(parents=True)
        path.write_bytes(plistlib.dumps(dict(Label=m.MENU, ProgramArguments=[str(self.app / 'Contents/MacOS/CodexUsage')],
            EnvironmentVariables={'CODEX_USAGE_REFRESH_SECONDS': '120'})))
        self.mac.start(path)
        self.install()
        self.assertEqual(len(self.mac.jobs), 2)
        self.assertEqual(self.mac.jobs[m.MENU]['definition']['EnvironmentVariables']['CODEX_USAGE_REFRESH_SECONDS'], '120')

    def test_legacy_is_discovered_stopped_and_final_ledger_imported(self):
        path = self.legacy()
        def late_result(_):
            m.put(self.legacy_ledger, {'consume': {'late': dict(lastAttemptAt='2030-01-01T00:00:00+00:00',
                idempotencyKey='synthetic-late-key', outcome='reset')}, 'alerts': {'late:1': {'localAt': 'synthetic'}}})
        self.mac.after_stop = late_result
        self.install()
        self.assertEqual(set(self.mac.jobs), {m.MENU, 'example.legacy'})
        self.assertEqual(m.read(self.i.reset / 'worker.json')['launchAgent'], str(path))
        self.assertIn('--reset-worker', self.mac.jobs['example.legacy']['definition']['ProgramArguments'])
        self.assertEqual(self.state()['attempts']['late']['key'], 'synthetic-late-key')
        self.assertEqual(self.state()['reminders']['late'], [3600])
        self.assertFalse(self.settings()['autoUse'])
        self.assertTrue(self.legacy_ledger.exists())

    def test_unresolved_legacy_aborts_before_stopping_or_building(self):
        self.legacy(unresolved=True)
        events = list(self.mac.events)
        with self.assertRaisesRegex(m.InstallError, 'unresolved'):
            self.install()
        self.assertEqual(events, self.mac.events)
        self.assertEqual(set(self.mac.jobs), {'example.legacy'})
        self.assertFalse(self.app.exists())

    def test_late_legacy_unknown_restores_original_service_and_record(self):
        self.legacy()
        def late_unknown(_):
            m.put(self.legacy_ledger, {'consume': {'late': dict(lastAttemptAt='2030-01-01T00:00:00+00:00',
                idempotencyKey='synthetic-late-unknown')}, 'alerts': {}})
        self.mac.after_stop = late_unknown
        with self.assertRaisesRegex(m.InstallError, 'unresolved'):
            self.install()
        self.assertEqual(set(self.mac.jobs), {'example.legacy'})
        self.assertEqual(m.read(self.legacy_ledger)['consume']['late']['idempotencyKey'], 'synthetic-late-unknown')

    def test_legacy_bootstrap_failure_can_be_retried_without_losing_import(self):
        self.legacy()
        m.put(self.legacy_ledger, {'consume': {'credit': dict(lastAttemptAt='2030-01-01T00:00:00+00:00',
            idempotencyKey='synthetic-terminal', outcome='reset')}, 'alerts': {}})
        self.mac.fail_start = m.MENU
        with self.assertRaises(m.InstallError):
            self.install()
        self.assertEqual(set(self.mac.jobs), {'example.legacy'})
        self.install()
        self.assertEqual(self.state()['attempts']['credit']['key'], 'synthetic-terminal')

    def test_build_failure_leaves_live_installation_untouched(self):
        prior = self.make_prior_native()
        jobs = copy.deepcopy(self.mac.jobs)
        self.mac.fail_build = True
        with self.assertRaisesRegex(m.InstallError, 'build'):
            self.install()
        self.assertEqual(self.mac.jobs, jobs)
        self.assertEqual(self.marker(), 'old')
        self.assertEqual(self.state(), prior)

    def test_start_failure_restores_old_app_jobs_and_settings(self):
        prior = self.make_prior_native(reminders=False)
        old_jobs = copy.deepcopy(self.mac.jobs)
        self.mac.fail_start = m.MENU
        with self.assertRaises(m.InstallError):
            self.install()
        self.assertEqual(self.marker(), 'old')
        self.assertEqual(self.mac.jobs, old_jobs)
        self.assertEqual(self.settings(), {'autoUse': False, 'reminders': False})
        self.assertEqual(self.state()['attempts'], prior['attempts'])

    def test_health_failure_never_restores_an_older_ledger(self):
        self.make_prior_native()
        def last_record(reset):
            state = m.read(reset / 'state.json')
            state['attempts']['additional'] = self.attempt(key='synthetic-late-pending')
            m.put(reset / 'state.json', state)
        self.mac.health_hook = last_record
        self.mac.fail_health = True
        with self.assertRaises(m.InstallError):
            self.install()
        self.assertEqual(self.marker(), 'old')
        self.assertEqual(self.state()['attempts']['additional']['key'], 'synthetic-late-pending')

    def test_uninstall_stops_both_keeps_settings_and_pending_then_reinstall(self):
        prior = self.make_prior_native(auto=False, reminders=False)
        self.i.execute('uninstall')
        self.assertFalse(self.mac.jobs)
        self.assertFalse(self.app.exists())
        self.assertFalse(list(self.i.agents.glob('*.plist')))
        self.assertFalse(m.read(self.i.reset / 'ownership.json')['active'])
        self.assertEqual(self.state()['attempts'], prior['attempts'])
        self.assertEqual(self.settings(), {'autoUse': False, 'reminders': False})
        self.i.execute('uninstall')
        self.install()
        self.assertEqual(len(self.mac.jobs), 2)
        self.assertEqual(self.state()['attempts'], prior['attempts'])
        self.assertFalse(self.settings()['autoUse'])

    def test_uninstall_failure_restores_app_and_both_services(self):
        self.make_prior_native()
        original = m.put
        failed = False
        def failure(path, value):
            nonlocal failed
            if path == self.i.support / 'installation.json' and value.get('status') == 'uninstalled' and not failed:
                failed = True
                raise OSError('synthetic failure')
            return original(path, value)
        with patch.object(m, 'put', failure):
            with self.assertRaises(OSError):
                self.i.execute('uninstall')
        self.assertEqual(self.marker(), 'old')
        self.assertEqual(len(self.mac.jobs), 2)
        self.assertEqual(self.state()['attempts']['credit']['key'], 'synthetic-existing-key')

    def test_power_loss_after_app_removal_recovers_before_retry(self):
        self.make_prior_native()
        original = Path.rename
        def crash(path, target):
            if Path(target) == self.app:
                raise PowerLoss()
            return original(path, target)
        with patch.object(Path, 'rename', crash):
            with self.assertRaises(PowerLoss):
                self.install()
        self.assertFalse(self.app.exists())
        self.assertEqual(m.read(self.i.journal)['phase'], 'changing')
        self.i.recover()
        self.assertEqual(self.marker(), 'old')
        self.assertEqual(len(self.mac.jobs), 2)
        self.install()
        self.assertEqual(self.marker(), 'new')
        self.assertEqual(self.state()['attempts']['credit']['key'], 'synthetic-existing-key')

    def test_failed_activation_finishes_forward_without_ledger_rollback(self):
        self.make_prior_native()
        original = m.put
        failed = False
        def failure(path, value):
            nonlocal failed
            if path == self.i.reset / 'ownership.json' and value == {'active': True} and not failed:
                failed = True
                raise OSError('synthetic activation failure')
            return original(path, value)
        with patch.object(m, 'put', failure):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual(m.read(self.i.journal)['phase'], 'committed')
        self.assertFalse(m.read(self.i.reset / 'ownership.json')['active'])
        state = self.state()
        state['attempts']['extra'] = self.attempt(key='synthetic-preserved')
        m.put(self.i.reset / 'state.json', state)
        self.i.recover()
        self.assertTrue(m.read(self.i.reset / 'ownership.json')['active'])
        self.assertEqual(self.state()['attempts'], state['attempts'])

    def test_concurrent_installer_is_rejected(self):
        with m.lease(self.i.support / 'installation.lock'):
            with self.assertRaisesRegex(m.InstallError, 'Another installer'):
                self.install()
        self.assertFalse(self.mac.jobs)

    def test_standalone_menu_is_reopened_after_failed_install(self):
        bundle(self.app, 'old')
        binary = str(self.app / 'Contents/MacOS/CodexUsage')
        self.mac.extra = [(111, binary + ' --export-menu-state /example/observation.json')]
        self.mac.fail_health = True
        with self.assertRaises(m.InstallError):
            self.install()
        self.assertEqual(self.marker(), 'old')
        self.assertEqual([args for _, args in self.mac.extra], [binary])

    def test_unregistered_worker_is_not_silently_stopped(self):
        self.mac.extra = [(112, str(self.app / 'Contents/MacOS/CodexUsage') + ' --reset-worker')]
        with self.assertRaisesRegex(m.InstallError, 'unregistered'):
            self.install()
        self.assertEqual(len(self.mac.extra), 1)
        self.assertFalse(self.mac.events)

    def test_last_off_choice_and_late_pending_are_preserved_on_rollback(self):
        self.make_prior_native(auto=True)
        def final_state(_):
            m.put(self.i.reset / 'settings.json', {'autoUse': False, 'reminders': False})
            state = self.state()
            state['attempts']['last'] = self.attempt(key='synthetic-final-key')
            m.put(self.i.reset / 'state.json', state)
        self.mac.after_stop = final_state
        self.mac.fail_start = m.MENU
        with self.assertRaises(m.InstallError):
            self.install()
        self.assertFalse(self.settings()['autoUse'])
        self.assertFalse(self.settings()['reminders'])
        self.assertEqual(self.state()['attempts']['last']['key'], 'synthetic-final-key')

    def test_existing_custom_worker_identity_is_reused(self):
        self.make_prior_native()
        old = self.i.agents / (m.WORKER + '.plist')
        target = self.i.agents / 'example.existing.plist'
        definition = plistlib.loads(old.read_bytes())
        self.mac.stop(m.WORKER)
        definition['Label'] = 'example.existing'
        target.write_bytes(plistlib.dumps(definition))
        old.unlink()
        registration = m.read(self.i.reset / 'worker.json')
        registration.update(label='example.existing', launchAgent=str(target))
        m.put(self.i.reset / 'worker.json', registration)
        self.mac.start(target)
        self.install()
        self.assertEqual(set(self.mac.jobs), {m.MENU, 'example.existing'})
        self.assertFalse(old.exists())
        self.i.execute('uninstall')
        self.assertFalse(target.exists())

    def test_account_location_and_refresh_survive_removal_and_reinstall(self):
        custom = str(self.home / 'chosen-codex')
        self.i.env.update(CODEX_HOME=custom, CODEX_USAGE_REFRESH_SECONDS='120')
        self.install()
        self.i.execute('uninstall')
        self.i.env.pop('CODEX_HOME')
        self.i.env.pop('CODEX_USAGE_REFRESH_SECONDS')
        self.install()
        env = self.mac.jobs[m.WORKER]['definition']['EnvironmentVariables']
        self.assertEqual(env['CODEX_HOME'], custom)
        self.assertEqual(env['CODEX_USAGE_REFRESH_SECONDS'], '120')
        self.i.env['CODEX_HOME'] = str(self.home / 'different-codex')
        jobs = copy.deepcopy(self.mac.jobs)
        with self.assertRaisesRegex(m.InstallError, 'account location'):
            self.install()
        self.assertEqual(self.mac.jobs, jobs)

    def test_unknown_legacy_schema_is_preserved_before_changes(self):
        self.legacy()
        self.legacy_ledger.write_text('{"unknownFormat":true}')
        with self.assertRaisesRegex(m.InstallError, 'unreadable'):
            self.install()
        self.assertEqual(set(self.mac.jobs), {'example.legacy'})
        self.assertEqual(self.legacy_ledger.read_text(), '{"unknownFormat":true}')

    def test_sensitive_environment_is_not_copied_into_new_metadata(self):
        path = self.legacy()
        value = plistlib.loads(path.read_bytes())
        value['EnvironmentVariables'] = {'EXAMPLE_API_KEY': 'synthetic-placeholder'}
        path.write_bytes(plistlib.dumps(value))
        with self.assertRaisesRegex(m.InstallError, 'authentication settings'):
            self.install()
        self.assertFalse(self.i.journal.exists())
        self.assertFalse((self.i.support / 'install-backups').exists())

    def test_removing_paused_committed_install_never_activates_it(self):
        self.make_prior_native(auto=True)
        data = m.read(self.i.journal)
        data['activationPending'] = True
        m.put(self.i.journal, data)
        m.put(self.i.reset / 'ownership.json', {'active': False})
        events = len(self.mac.events)
        original = m.put
        def no_activation(path, value):
            if path == self.i.reset / 'ownership.json':
                self.assertFalse(value['active'])
            return original(path, value)
        with patch.object(m, 'put', no_activation):
            self.i.execute('uninstall')
        self.assertFalse(self.mac.jobs)
        self.assertTrue(all(event[0] != 'start' for event in self.mac.events[events:]))
        self.assertEqual(self.state()['attempts']['credit']['key'], 'synthetic-existing-key')

    def test_unrelated_agent_and_refresh_configuration_are_preserved(self):
        self.i.agents.mkdir(parents=True)
        target = self.root / 'unrelated.plist'
        target.write_bytes(plistlib.dumps({'Label': 'example.other', 'ProgramArguments': ['/example/unrelated']}))
        link = self.i.agents / 'example.other.plist'
        link.symlink_to(target)
        self.install()
        self.assertTrue(link.is_symlink())
        self.i.execute('uninstall')
        self.assertTrue(link.is_symlink())
        self.assertTrue(target.exists())

    def test_extra_legacy_service_and_orphan_process_are_rejected(self):
        path = self.legacy()
        duplicate = self.i.agents / 'example.other.plist'
        value = plistlib.loads(path.read_bytes())
        value['Label'] = 'example.other'
        duplicate.write_bytes(plistlib.dumps(value))
        with self.assertRaisesRegex(m.InstallError, 'Multiple'):
            self.install()
        duplicate.unlink()
        self.mac.extra = [(888, '/example/Python /other/reset_credit_watcher.py')]
        with self.assertRaisesRegex(m.InstallError, 'additional'):
            self.install()

    def test_corrupt_or_missing_native_state_never_resets_recovery(self):
        self.make_prior_native()
        state_path = self.i.reset / 'state.json'
        for content in ('broken json', '{"version":1}'):
            state_path.write_text(content)
            with self.assertRaises(m.InstallError):
                self.install()
            self.assertEqual(state_path.read_text(), content)
            self.assertEqual(self.marker(), 'old')
        state_path.unlink()
        with self.assertRaises(m.InstallError):
            self.install()
        self.assertFalse(state_path.exists())

    def test_metadata_symlink_and_wrong_loaded_identity_are_rejected(self):
        self.make_prior_native()
        path = self.i.reset / 'settings.json'
        saved = self.root / 'outside-settings.json'
        path.rename(saved)
        path.symlink_to(saved)
        with self.assertRaisesRegex(m.InstallError, 'symbolic'):
            self.install()
        path.unlink()
        saved.rename(path)
        self.mac.jobs[m.MENU]['definition']['ProgramArguments'] = ['/example/unrelated']
        with self.assertRaisesRegex(m.InstallError, 'identity'):
            self.install()
        self.assertEqual(self.mac.jobs[m.MENU]['definition']['ProgramArguments'], ['/example/unrelated'])

    def test_worker_lock_blocks_replacement_and_recovery_waits_for_release(self):
        self.make_prior_native()
        with m.lease(self.i.reset / 'worker.lock'):
            with self.assertRaisesRegex(m.InstallError, 'recovery is incomplete'):
                self.install()
            self.assertEqual(self.marker(), 'old')
            self.assertFalse(self.mac.jobs)
        self.i.recover()
        self.assertEqual(len(self.mac.jobs), 2)
        self.assertEqual(self.marker(), 'old')

    def test_file_write_failures_restore_previous_installation(self):
        targets = ['settings.json', 'worker.json', m.MENU + '.plist', m.WORKER + '.plist', 'codex-path', 'installation.json']
        original = m.atomic
        for target in targets:
            with self.subTest(target=target):
                # Fresh install exercises default settings too; no old app to lose.
                case = self.root / target
                mac = FakeMac()
                installer = m.Installer(case, self.project, mac, {'CODEX_PATH': str(self.cli)})
                hit = False
                def fail(path, data, mode=0o600):
                    nonlocal hit
                    if path.name == target and 'install-backups' not in path.parts and not hit:
                        hit = True
                        raise OSError('synthetic disk write failure')
                    return original(path, data, mode)
                with patch.object(m, 'atomic', fail):
                    with self.assertRaises(OSError):
                        installer.execute('install')
                self.assertTrue(hit)
                self.assertFalse(mac.jobs)
                self.assertFalse((case / 'Applications/CodexUsage.app').exists())
                installer.execute('install')
                self.assertEqual(len(mac.jobs), 2)
                self.assertFalse(m.read(installer.reset / 'settings.json')['autoUse'])


class MacAdapterTests(unittest.TestCase):
    def test_launchctl_identity_supports_spaces_and_rejects_other_programs(self):
        platform = m.Mac()
        text = 'service = {\n\tpath = /example/User Space/agent.plist\n\tprogram = /example/User Space/CodexUsage\n\tpid = 123\n}\n'
        with patch.object(platform, 'run', return_value=SimpleNamespace(returncode=0, stdout=text)):
            self.assertTrue(platform.verify_job('example.worker', Path('/example/User Space/agent.plist'), ['/example/User Space/CodexUsage']))
            with self.assertRaisesRegex(m.InstallError, 'identity'):
                platform.verify_job('example.worker', Path('/example/User Space/agent.plist'), ['/example/Other'])

    def test_only_absent_service_code_is_accepted_as_missing(self):
        platform = m.Mac()
        with patch.object(platform, 'run', return_value=SimpleNamespace(returncode=113, stdout='')):
            self.assertIsNone(platform.job('example.missing'))
        with patch.object(platform, 'run', return_value=SimpleNamespace(returncode=1, stdout='')):
            with self.assertRaisesRegex(m.InstallError, 'inspect'):
                platform.job('example.denied')


if __name__ == '__main__':
    unittest.main()
