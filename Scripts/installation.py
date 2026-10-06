#!/usr/bin/env python3
"""One local lifecycle for the menu and its worker. No credential or consume calls.

Tests inject paths and an OS adapter; the CLI always uses the actual user home.
The recovery ledger is never restored from an older backup, including rollback.
"""
import argparse
from contextlib import contextmanager
import datetime as dt
import fcntl
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

MENU = 'io.github.yulepapa.codex-usage-menubar'
WORKER = MENU + '.reset-worker'
BUNDLE_ID = 'io.github.yulepapa.CodexUsage'
REFERENCE = 978307200
ROOT = Path(__file__).resolve().parent.parent


class InstallError(RuntimeError):
    pass


def safe(path):
    """Refuse links rather than following them while replacing user resources."""
    path = Path(path)
    for part in (path, *path.parents):
        if part.is_symlink():
            raise InstallError('A managed path is a symbolic link; nothing was replaced')
    return path


def read(path, fallback=None, limit=4_194_304):
    safe(path)
    if not path.exists():
        return fallback
    if not path.is_file() or path.stat().st_size > limit:
        raise InstallError('Invalid managed file')
    try:
        return json.loads(path.read_text())
    except (ValueError, UnicodeError):
        raise InstallError('Unreadable settings or recovery record; preserve it for inspection')


def atomic(path, data, mode=0o600):
    safe(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name('.stage-' + uuid.uuid4().hex)
    try:
        with open(temp, 'xb') as stream:
            os.chmod(temp, mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if temp.exists():
            temp.unlink()


def put(path, value):
    atomic(path, (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode())


@contextmanager
def lease(path):
    safe(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise InstallError('Another installer or worker is still running; no files were replaced')
        yield
    finally:
        os.close(fd)


def validate_settings(value):
    if not isinstance(value, dict) or any(type(value.get(k)) is not bool for k in ('autoUse', 'reminders')):
        raise InstallError('Invalid settings; existing choices were preserved')


def number(value):
    return type(value) in (float, int) and math.isfinite(value)


def empty_state():
    return dict(version=1, phase='standby', inventory=[], attempts={}, reminders={}, notificationStatus='unknown')


def validate_state(value):
    if (not isinstance(value, dict) or value.get('version') != 1
            or not isinstance(value.get('phase'), str)
            or not isinstance(value.get('notificationStatus'), str)
            or not isinstance(value.get('attempts'), dict)
            or not isinstance(value.get('reminders'), dict)
            or not isinstance(value.get('inventory'), list)):
        raise InstallError('Invalid recovery record; it must not be reset by installation')
    for key, record in value['attempts'].items():
        if (not isinstance(key, str) or not isinstance(record, dict)
                or not isinstance(record.get('key'), str) or not record['key']
                or not number(record.get('expiresAt')) or not number(record.get('attemptedAt'))
                or record.get('outcome') not in ('pending', 'reset', 'alreadyRedeemed', 'noCredit', 'nothingToReset')):
            raise InstallError('Unrecognized saved consumption; preserve the recovery record')
    for record in value['inventory']:
        if not isinstance(record, dict) or not isinstance(record.get('id'), str) or not number(record.get('expiresAt')):
            raise InstallError('Invalid saved inventory')
    for key, milestones in value['reminders'].items():
        if not isinstance(key, str) or not isinstance(milestones, list) or any(type(x) is not int for x in milestones):
            raise InstallError('Invalid saved reminder record')
    for key in ('checkedAt', 'workerSeenAt', 'nextCheckAt'):
        if key in value and value[key] is not None and not number(value[key]):
            raise InstallError('Invalid saved worker timestamp')
    if value.get('availableCount') is not None and (type(value['availableCount']) is not int or value['availableCount'] < 0):
        raise InstallError('Invalid saved available count')
    if value.get('lastError') is not None and not isinstance(value['lastError'], str):
        raise InstallError('Invalid saved result status')


def legacy_state(path):
    old = read(path)
    if not isinstance(old, dict) or not isinstance(old.get('consume'), dict) or not isinstance(old.get('alerts'), dict):
        raise InstallError('Legacy recovery record is missing or unreadable')
    state = empty_state()
    for cid, record in old.get('consume', {}).items():
        if not isinstance(record, dict):
            raise InstallError('Unrecognized legacy consumption record')
        if not record.get('lastAttemptAt') and not record.get('idempotencyKey'):
            continue
        if record.get('outcome') not in ('reset', 'alreadyRedeemed', 'noCredit', 'nothingToReset'):
            raise InstallError('A legacy consumption result is unresolved; its watcher and key are preserved')
        try:
            date = dt.datetime.fromisoformat(record['lastAttemptAt'])
            if date.tzinfo is None:
                raise ValueError()
            stamp = date.timestamp() - REFERENCE
        except (ValueError, KeyError, TypeError):
            raise InstallError('Unrecognized legacy attempt time')
        state['attempts'][cid] = dict(key=record.get('idempotencyKey') or 'legacy-completed',
                                     attemptedAt=stamp, expiresAt=stamp, outcome=record['outcome'])
    for key, alert in old.get('alerts', {}).items():
        if key.endswith(':1') and isinstance(alert, dict) and alert.get('localAt'):
            state['reminders'][key[:-2]] = [3600]
    validate_state(state)
    return state


class Mac:
    def __init__(self):
        self.domain = 'gui/' + str(os.getuid())

    def run(self, args, check=True, timeout=60):
        p = subprocess.run([str(x) for x in args], capture_output=True, text=True,
                           encoding='utf-8', errors='replace', timeout=timeout)
        if check and p.returncode:
            raise InstallError(f'{Path(args[0]).name} failed (exit {p.returncode}); subprocess output was withheld')
        return p

    def job(self, label):
        p = self.run(['/bin/launchctl', 'print', self.domain + '/' + label], check=False)
        if p.returncode == 113:
            return None
        if p.returncode:
            raise InstallError('Could not inspect the selected login service')
        return p.stdout

    def verify_job(self, label, path, arguments):
        text = self.job(label)
        if text is None:
            return False
        fields = dict(re.findall(r'^\s*(path|program) = (.+)$', text, re.M))
        if fields.get('path') != str(path) or fields.get('program') != arguments[0]:
            raise InstallError('An existing service has an unexpected identity; it was left running')
        return True

    def stop(self, label):
        if self.job(label) is not None:
            self.run(['/bin/launchctl', 'bootout', self.domain + '/' + label])
            if self.job(label) is not None:
                raise InstallError('The selected service did not stop')

    def start(self, path):
        self.run(['/bin/launchctl', 'bootstrap', self.domain, path])

    def processes(self):
        # Only selected app/watcher matches leave this method; never print ps output.
        text = self.run(['/bin/ps', '-axo', 'pid=,args=']).stdout
        result = []
        for line in text.splitlines():
            row = line.strip().split(None, 1)
            if len(row) == 2 and ('CodexUsage.app/Contents/MacOS/CodexUsage' in row[1]
                                  or 'reset_credit_watcher.py' in row[1]):
                result.append((int(row[0]), row[1]))
        return result

    def stop_apps(self, binary):
        def matches():
            return [pid for pid, args in self.processes() if args == str(binary) or args.startswith(str(binary) + ' ')]
        for pid in matches():
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        end = time.monotonic() + 8
        while matches() and time.monotonic() < end:
            time.sleep(.1)
        if matches():
            raise InstallError('The installed app did not exit; no forced kill was used')

    def verify_bundle(self, app):
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != BUNDLE_ID:
            raise InstallError('The selected bundle is not the production Codex Usage app')
        self.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])

    def prepare_build(self, project, output):
        self.run([project / 'Scripts/build.sh', output], timeout=300)
        self.verify_bundle(output)

    def health(self, plan, reset, since):
        end = time.monotonic() + 35
        while time.monotonic() < end:
            state = read(reset / 'state.json', {})
            worker = self.job(plan['workerLabel'])
            menu = self.job(MENU)
            if (worker and menu and re.search(r'\bpid = \d+', worker) and re.search(r'\bpid = \d+', menu)
                    and state.get('workerSeenAt', 0) >= since - REFERENCE):
                return
            time.sleep(.25)
        raise InstallError('The menu or background worker did not start; restoring the previous installation')

    def open_app(self, app):
        self.run(['/usr/bin/open', '-g', app])


class Installer:
    def __init__(self, home, project, platform, environment=None):
        self.home = Path(home).resolve()
        self.project = Path(project).resolve()
        self.os = platform
        self.env = dict(os.environ if environment is None else environment)
        self.support = self.home / 'Library/Application Support/CodexUsage'
        self.reset = self.support / 'reset'
        self.agents = self.home / 'Library/LaunchAgents'
        self.journal = self.support / 'install-transaction.json'
        self.built = self.project / '.build/CodexUsage.app'

    def app_path(self, value):
        app = safe(Path(value))
        allowed = (self.home / 'Applications', Path('/Applications'))
        if app.name != 'CodexUsage.app' or app.parent not in allowed:
            raise InstallError('Unexpected installed app location; automatic replacement stopped')
        return app

    def agent(self, path):
        safe(path)
        if path.parent != self.agents or path.suffix != '.plist' or path.stat().st_size > 65_536:
            raise InstallError('Unexpected LaunchAgent location or size')
        try:
            value = plistlib.loads(path.read_bytes())
        except (ValueError, plistlib.InvalidFileException):
            raise InstallError('Unreadable selected LaunchAgent')
        args = value.get('ProgramArguments')
        label = value.get('Label')
        if (not isinstance(label, str) or not re.fullmatch(r'[A-Za-z0-9_.-]+', label)
                or not isinstance(args, list) or not args or not all(isinstance(a, str) for a in args)):
            raise InstallError('Invalid selected LaunchAgent')
        return value

    def plan(self, removing=False):
        worker = read(self.reset / 'worker.json')
        manifest = read(self.support / 'installation.json', {})
        menu_path = self.agents / (MENU + '.plist')
        menu = self.agent(menu_path) if menu_path.exists() else None
        if menu and (menu['Label'] != MENU or len(menu['ProgramArguments']) != 1):
            raise InstallError('Unexpected menu login service; preserving it')
        app = self.app_path(self.home / 'Applications/CodexUsage.app')
        if menu:
            app = self.app_path(Path(menu['ProgramArguments'][0]).parent.parent.parent)
        native_agents, legacy_agents = [], []
        for path in self.agents.glob('*.plist'):
            # Unrelated plists are neither changed nor logged.
            try:
                if path.stat().st_size > 65_536:
                    continue
                raw = plistlib.loads(path.read_bytes())
            except (ValueError, OSError, plistlib.InvalidFileException):
                continue  # Unrelated malformed files cannot be loaded by launchd.
            if not isinstance(raw, dict):
                continue
            args = raw.get('ProgramArguments', [])
            if not isinstance(args, list):
                continue
            if '--reset-worker' in args and any('CodexUsage.app/Contents/MacOS/CodexUsage' in str(a) for a in args):
                native_agents.append(path)
            if any(Path(str(a)).name == 'reset_credit_watcher.py' for a in args):
                legacy_agents.append(path)
        if len(native_agents) > 1 or len(legacy_agents) > 1 or (native_agents and legacy_agents):
            raise InstallError('Multiple reset services found; no service was replaced')
        legacy = None
        label, worker_path = WORKER, self.agents / (WORKER + '.plist')
        worker_agent = None
        if worker is not None:
            if not isinstance(worker, dict) or not all(isinstance(worker.get(k), str) for k in ('label', 'executable', 'launchAgent')):
                raise InstallError('Invalid worker registration')
            app = self.app_path(Path(worker['executable']).parent.parent.parent)
            if worker['executable'] != str(app / 'Contents/MacOS/CodexUsage'):
                raise InstallError('Worker executable does not match the installed app')
            label, worker_path = worker['label'], Path(worker['launchAgent'])
            if worker_path.parent != self.agents or not re.fullmatch(r'[A-Za-z0-9_.-]+', label) or label == MENU:
                raise InstallError('Worker service identity is invalid')
            if legacy_agents or any(p != worker_path for p in native_agents):
                raise InstallError('A second reset service is configured')
            if worker_path.exists():
                worker_agent = self.agent(worker_path)
                if worker_agent['Label'] != label or worker_agent['ProgramArguments'] != [worker['executable'], '--reset-worker']:
                    raise InstallError('Worker registration and service disagree')
                ownership = read(self.reset / 'ownership.json', {})
                if (not isinstance(ownership, dict) or any(type(v) is not bool for v in ownership.values())
                        or (ownership.get('active') is not True and not removing)):
                    raise InstallError('Worker ownership is paused; inspect that state before updating')
            elif manifest.get('status') != 'uninstalled':
                raise InstallError('Worker service is missing; preserve its recovery records')
            validate_settings(read(self.reset / 'settings.json'))
            validate_state(read(self.reset / 'state.json'))
        elif native_agents:
            raise InstallError('An unrecognized native worker already exists')
        elif legacy_agents:
            worker_path = legacy_agents[0]
            worker_agent = self.agent(worker_path)
            label = worker_agent['Label']
            args = worker_agent['ProgramArguments']
            scripts = [Path(a) for a in args if Path(a).name == 'reset_credit_watcher.py']
            if (len(scripts) != 1 or not re.fullmatch(r'python(?:[0-9.]+)?', Path(args[0]).name.lower())
                    or args[1:args.index(str(scripts[0]))] not in ([], ['-u'], ['-B'])):
                raise InstallError('Unsupported legacy watcher; no implicit execution was attempted')
            legacy = safe(scripts[0].parent / 'reset_credit_watcher_state.json')
            imported = legacy_state(legacy)
            native_attempts = read(self.reset / 'state.json', {}).get('attempts', {})
            if any(imported['attempts'].get(k) != v for k, v in native_attempts.items()):
                raise InstallError('Different legacy and native recovery histories exist; preserve both for review')
        else:
            base = Path(self.env.get('CODEX_HOME', str(self.home / '.codex'))) / 'automations/codex'
            if (base / 'reset_credit_watcher.py').exists() or (base / 'reset_credit_watcher_state.json').exists():
                raise InstallError('Legacy watcher files have no matching login service; inspect them before installing')
        if label == MENU or (worker_path.exists() and worker_agent is None):
            raise InstallError('The target background service belongs to another configuration')
        safe(worker_path)
        binary = app / 'Contents/MacOS/CodexUsage'
        if menu and menu['ProgramArguments'] != [str(binary)]:
            raise InstallError('Menu and worker point to different installed apps')
        processes = self.os.processes()
        for _, args in processes:
            if 'reset_credit_watcher.py' in args and (not legacy or str(legacy.parent / 'reset_credit_watcher.py') not in args):
                raise InstallError('An additional legacy watcher is running')
            if 'CodexUsage.app/Contents/MacOS/CodexUsage' in args and not (args == str(binary) or args.startswith(str(binary) + ' ')):
                raise InstallError('Another Codex Usage app is running; preserve it before installing')
            if '--reset-worker' in args and worker_agent is None:
                raise InstallError('An unregistered background worker is running; preserve it before installing')
        old = []
        for path, definition in ((menu_path, menu), (worker_path, worker_agent)):
            if definition:
                loaded = self.os.verify_job(definition['Label'], path, definition['ProgramArguments'])
                old.append(dict(path=str(path), label=definition['Label'], loaded=loaded))
        if worker_agent is None and self.os.job(label) is not None:
            raise InstallError('An unrecognized background service is loaded')
        if menu is None and self.os.job(MENU) is not None:
            raise InstallError('An unrecognized menu service is loaded')
        if legacy and not any(x['label'] == label and x['loaded'] for x in old):
            raise InstallError('The selected legacy watcher is not registered as running')
        state = read(self.reset / 'state.json')
        if state is not None:
            validate_state(state)
        settings = read(self.reset / 'settings.json')
        if settings is not None:
            validate_settings(settings)
        previous = dict(manifest.get('environment', {}))
        previous.update((menu or {}).get('EnvironmentVariables', {}))
        worker_env = (worker_agent or {}).get('EnvironmentVariables', {})
        if previous.get('CODEX_HOME') and worker_env.get('CODEX_HOME') and previous['CODEX_HOME'] != worker_env['CODEX_HOME']:
            raise InstallError('Menu and worker use different Codex account locations')
        previous.update(worker_env)
        if any(re.search(r'token|secret|password|credential|api.?key', key, re.I) for key in previous):
            raise InstallError('Service environment contains authentication settings; no credentials were copied')
        previous = {k: v for k, v in previous.items() if k in
                    ('CODEX_PATH', 'CODEX_HOME', 'CODEX_USAGE_REFRESH_SECONDS', 'PATH', 'LANG', 'LC_ALL', 'LC_CTYPE')}
        return dict(app=str(app), binary=str(binary), menuPath=str(menu_path), workerPath=str(worker_path),
                    workerLabel=label, legacy=str(legacy) if legacy else None, oldJobs=old,
                    native=worker is not None,
                    standaloneMenu=not menu and any((a == str(binary) or a.startswith(str(binary) + ' '))
                                                   and '--reset-worker' not in a for _, a in processes),
                    previousEnvironment=previous)

    def environment(self, plan):
        previous = plan['previousEnvironment']
        if not isinstance(previous, dict):
            raise InstallError('Invalid previous service environment')
        # Carry only path/configuration variables, never credentials.
        env = {k: v for k, v in previous.items() if k in ('CODEX_PATH', 'CODEX_HOME', 'CODEX_USAGE_REFRESH_SECONDS', 'PATH', 'LANG', 'LC_ALL', 'LC_CTYPE')}
        expected_account_home = previous.get('CODEX_HOME', str(self.home / '.codex'))
        if plan['native'] and self.env.get('CODEX_HOME', expected_account_home) != expected_account_home:
            raise InstallError('CODEX_HOME differs from the registered account location; existing services were preserved')
        for key in ('CODEX_PATH', 'CODEX_HOME', 'CODEX_USAGE_REFRESH_SECONDS'):
            if key in self.env:
                env[key] = self.env[key]
        if any(not isinstance(v, str) for v in env.values()):
            raise InstallError('Invalid service environment value')
        if 'CODEX_HOME' in env and not Path(env['CODEX_HOME']).is_absolute():
            raise InstallError('CODEX_HOME must be an absolute path')
        candidates = [env.get('CODEX_PATH'), read(self.support / 'installation.json', {}).get('codexPath')]
        configured = self.support / 'codex-path'
        if configured.exists():
            safe(configured)
            candidates.append(configured.read_text().strip())
        candidates.extend([shutil.which('codex'), *[str(self.home / x) for x in
            ('.local/bin/codex', '.volta/bin/codex', '.bun/bin/codex', '.asdf/shims/codex', '.local/share/mise/shims/codex')],
            '/opt/homebrew/bin/codex', '/usr/local/bin/codex'])
        if env.get('CODEX_PATH') and not os.access(env['CODEX_PATH'], os.X_OK):
            raise InstallError('The configured Codex CLI is not executable')
        cli = next((x for x in candidates if x and Path(x).is_absolute() and Path(x).is_file() and os.access(x, os.X_OK)), None)
        if not cli:
            raise InstallError('Install and sign in to Codex CLI, or set CODEX_PATH to its executable')
        env['CODEX_PATH'] = cli
        self.os.run([cli, '--version'])
        if 'CODEX_USAGE_REFRESH_SECONDS' in env:
            if not re.fullmatch(r'\d+', str(env['CODEX_USAGE_REFRESH_SECONDS'])) or int(env['CODEX_USAGE_REFRESH_SECONDS']) < 60:
                raise InstallError('Refresh interval must be an integer of at least 60 seconds')
        return env

    def snapshot(self, plan, action):
        backup = self.support / 'install-backups' / uuid.uuid4().hex
        backup.mkdir(parents=True, mode=0o700)
        app = Path(plan['app'])
        if app.exists():
            self.os.verify_bundle(app)
            shutil.copytree(app, backup / 'previous.app', symlinks=True)
        files = [Path(plan['menuPath']), Path(plan['workerPath']), self.support / 'codex-path',
                 self.support / 'installation.json', *[self.reset / name for name in
                 ('worker.json', 'ownership.json', 'settings.json')]]
        records = []
        for i, path in enumerate(files):
            safe(path)
            exists = path.exists()
            if exists:
                atomic(backup / str(i), path.read_bytes())
            records.append(dict(path=str(path), saved=str(i), existed=exists,
                                mode=(path.stat().st_mode & 0o777) if exists else 0o600))
        data = dict(version=1, phase='prepared', action=action, plan=plan, backup=str(backup),
                    appExisted=app.exists(), files=records)
        put(self.journal, data)
        return data

    def quiesce(self, plan):
        for label in (plan['workerLabel'], MENU):
            self.os.stop(label)
        self.os.stop_apps(Path(plan['binary']))
        if any('reset_credit_watcher.py' in args for _, args in self.os.processes()):
            raise InstallError('A legacy watcher is still running; no replacement worker was activated')

    def restore(self, data, restart=True):
        plan, backup = data['plan'], Path(data['backup'])
        self.quiesce(plan)
        with lease(self.reset / 'worker.lock'), lease(self.reset / 'settings.lock'):
            put(self.reset / 'ownership.json', {'active': False})
            app = safe(Path(plan['app']))
            if data['phase'] != 'prepared':
                if app.exists():
                    shutil.rmtree(app)
                if data['appExisted']:
                    shutil.copytree(backup / 'previous.app', app, symlinks=True)
                for record in data['files']:
                    path = safe(Path(record['path']))
                    # Settings may have changed just before shutdown; existing
                    # settings are never overwritten by an install or rollback.
                    if path == self.reset / 'settings.json' and record['existed']:
                        continue
                    if record['existed']:
                        atomic(path, (backup / record['saved']).read_bytes(), record['mode'])
                    elif path.exists():
                        path.unlink()
            else:
                owner = next(x for x in data['files'] if x['path'] == str(self.reset / 'ownership.json'))
                if owner['existed']:
                    atomic(self.reset / 'ownership.json', (backup / owner['saved']).read_bytes())
                else:
                    (self.reset / 'ownership.json').unlink()
            # state.json is deliberately not restored: keep even late pending keys.
        for old in plan['oldJobs']:
            if old['loaded'] and restart:
                self.os.start(Path(old['path']))
        if restart and plan['standaloneMenu'] and data['appExisted']:
            self.os.open_app(Path(plan['app']))
        data['phase'] = 'rolledBack'
        put(self.journal, data)
        put(backup / 'result.json', {'status': 'rolledBack', 'recoveryLedgerPreserved': True})

    def recover(self, action='install'):
        data = read(self.journal)
        if data and data.get('phase') == 'committed' and data.get('activationPending'):
            self.validate_journal(data)
            plan = data['plan']
            if action == 'uninstall':
                # Removing an interrupted installation must not briefly enable
                # an auto-use choice before stopping the service again.
                data['activationPending'] = False
                put(self.journal, data)
                return
            self.os.verify_bundle(Path(plan['app']))
            validate_settings(read(self.reset / 'settings.json'))
            validate_state(read(self.reset / 'state.json'))
            for key, label, arguments in (('workerPath', plan['workerLabel'], [plan['binary'], '--reset-worker']),
                                          ('menuPath', MENU, [plan['binary']])):
                path = Path(plan[key])
                definition = self.agent(path)
                if definition['Label'] != label or definition['ProgramArguments'] != arguments:
                    raise InstallError('Committed installation identity changed; activation was left paused')
                if not self.os.verify_job(label, path, arguments):
                    self.os.start(path)
            # This transaction is already committed: never roll back a worker
            # that might have consumed after activation. Forward completion only.
            put(self.reset / 'ownership.json', {'active': True})
            data['activationPending'] = False
            put(self.journal, data)
        if data and data.get('phase') not in ('committed', 'rolledBack'):
            self.validate_journal(data)
            try:
                self.restore(data, restart=action != 'uninstall')
            except Exception:
                raise InstallError('Interrupted installation could not be restored; preserve its backup and rerun after inspection')

    def validate_journal(self, data):
        # Recovery instructions are local metadata, not arbitrary filesystem authority.
        if data.get('version') != 1 or data.get('phase') not in ('prepared', 'changing', 'starting', 'committed'):
            raise InstallError('Unrecognized installation journal')
        plan = data['plan']
        self.app_path(plan['app'])
        backup = safe(Path(data['backup']))
        if backup.parent != self.support / 'install-backups' or not re.fullmatch('[0-9a-f]{32}', backup.name):
            raise InstallError('Unexpected installation backup')
        allowed = {self.support / 'codex-path', self.support / 'installation.json',
                   *[self.reset / name for name in ('worker.json', 'ownership.json', 'settings.json')]}
        for key in ('menuPath', 'workerPath'):
            path = safe(Path(plan[key]))
            if path.parent != self.agents or path.suffix != '.plist':
                raise InstallError('Unexpected recovery service path')
            allowed.add(path)
        if plan['menuPath'] != str(self.agents / (MENU + '.plist')) or not re.fullmatch(r'[A-Za-z0-9_.-]+', plan['workerLabel']):
            raise InstallError('Unexpected recovery service identity')
        for record in data['files']:
            if Path(record['path']) not in allowed or not str(record['saved']).isdigit():
                raise InstallError('Unexpected recovery file')
        for job in plan['oldJobs']:
            expected = plan['menuPath'] if job['label'] == MENU else plan['workerPath']
            if job['label'] not in (MENU, plan['workerLabel']) or job['path'] != expected or type(job['loaded']) is not bool:
                raise InstallError('Unexpected recovery service')
        if plan['binary'] != str(Path(plan['app']) / 'Contents/MacOS/CodexUsage'):
            raise InstallError('Unexpected recovery executable')

    def execute(self, action):
        safe(self.support)
        self.support.mkdir(parents=True, exist_ok=True, mode=0o700)
        with lease(self.support / 'installation.lock'):
            self.recover(action)
            plan = self.plan(removing=action == 'uninstall')
            if action == 'uninstall' and plan['legacy']:
                raise InstallError('This is an independent legacy watcher; integrate it before removing the combined app')
            env = None
            stage = None
            if action == 'install':
                env = self.environment(plan)
                self.os.prepare_build(self.project, self.built)
                app = Path(plan['app'])
                app.parent.mkdir(parents=True, exist_ok=True)
                stage = app.parent / ('.CodexUsage-stage-' + uuid.uuid4().hex + '.app')
                try:
                    shutil.copytree(self.built, stage, symlinks=True)
                    self.os.verify_bundle(stage)
                except Exception:
                    if stage.exists():
                        shutil.rmtree(stage)
                    raise
            data = None
            try:
                data = self.snapshot(plan, action)
                self.quiesce(plan)
                with lease(self.reset / 'worker.lock'), lease(self.reset / 'settings.lock'):
                    # Read the final settings/ledger after all previous writers exit.
                    state = read(self.reset / 'state.json')
                    if state is not None or plan['native']:
                        validate_state(state)
                    settings = read(self.reset / 'settings.json')
                    if settings is not None or plan['native']:
                        validate_settings(settings)
                    if plan['legacy']:
                        state = legacy_state(Path(plan['legacy']))
                        atomic(Path(data['backup']) / 'legacy-state-after-stop.json', Path(plan['legacy']).read_bytes())
                    data['phase'] = 'changing'
                    put(self.journal, data)
                    put(self.reset / 'ownership.json', {'active': False})
                    app = safe(Path(plan['app']))
                    if app.exists():
                        shutil.rmtree(app)
                    if action == 'install':
                        stage.rename(app)
                        self.os.verify_bundle(app)
                        if settings is None:
                            put(self.reset / 'settings.json', {'autoUse': False, 'reminders': True})
                        if plan['legacy'] or state is None:
                            put(self.reset / 'state.json', state or empty_state())
                        put(self.reset / 'worker.json', {'label': plan['workerLabel'], 'executable': plan['binary'], 'launchAgent': plan['workerPath']})
                        for label, path, args in ((MENU, plan['menuPath'], [plan['binary']]),
                                                 (plan['workerLabel'], plan['workerPath'], [plan['binary'], '--reset-worker'])):
                            agent = dict(Label=label, ProgramArguments=args, EnvironmentVariables=env, Umask=0o077,
                                         RunAtLoad=True, LimitLoadToSessionType='Aqua', ThrottleInterval=10,
                                         ProcessType='Interactive' if label == MENU else 'Background')
                            if label != MENU:
                                agent.update(KeepAlive=True, StandardOutPath=str(self.reset / 'worker.stdout.log'),
                                             StandardErrorPath=str(self.reset / 'worker.stderr.log'))
                            atomic(Path(path), plistlib.dumps(agent), 0o644)
                        atomic(self.support / 'codex-path', (env['CODEX_PATH'] + '\n').encode())
                    else:
                        for key in ('menuPath', 'workerPath'):
                            path = safe(Path(plan[key]))
                            if path.exists():
                                path.unlink()
                    put(self.support / 'installation.json', {'version': 1, 'status': 'installed' if action == 'install' else 'uninstalled',
                                                           'app': plan['app'], 'backup': data['backup'],
                                                           'environment': env if action == 'install' else plan['previousEnvironment']})
                if action == 'install':
                    data['phase'] = 'starting'
                    put(self.journal, data)
                    started_at = time.time()
                    self.os.start(Path(plan['workerPath']))
                    self.os.start(Path(plan['menuPath']))
                    # Ownership is still false: verification cannot consume or notify.
                    self.os.health(plan, self.reset, started_at)
                data['phase'] = 'committed'
                data['activationPending'] = action == 'install'
                put(self.journal, data)
                if action == 'install':
                    put(self.reset / 'ownership.json', {'active': True})
                    data['activationPending'] = False
                    put(self.journal, data)
                put(Path(data['backup']) / 'result.json', {'status': action + 'ed', 'recoveryLedgerPreserved': True})
                return {'status': action + 'ed', 'app': plan['app'], 'backup': data['backup'], 'recoveryLedgerPreserved': True}
            except Exception as error:
                if data is not None and data['phase'] != 'committed':
                    try:
                        self.restore(data)
                    except Exception:
                        raise InstallError('Installation failed and recovery is incomplete; keep the backup and journal for the next run') from error
                raise
            finally:
                if stage is not None and stage.exists():
                    shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description='Install, update or remove the menu and its bundled reset worker together')
    parser.add_argument('action', choices=('install', 'uninstall'))
    args = parser.parse_args()
    try:
        if sys.version_info < (3, 9):
            raise InstallError('Python 3.9 or later is required for the installation tools')
        value = Installer(Path.home(), ROOT, Mac()).execute(args.action)
        print(json.dumps(value, ensure_ascii=False))
        if args.action == 'install':
            print('Menu and background monitoring are ready. Change automatic use and notifications in the menu.')
        else:
            print('Both login services were removed. Settings, recovery records and backups were kept.')
        return 0
    except (Exception, KeyboardInterrupt) as error:
        # Only our own fixed messages are printable; OS exceptions can contain paths/output.
        message = str(error) if isinstance(error, InstallError) else 'Operation interrupted or failed; preserve the installation journal and rerun the same command'
        print(message, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
