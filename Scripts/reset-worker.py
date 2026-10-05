#!/usr/bin/env python3
"""Explicit legacy LaunchAgent handoff; only the registered worker can redeem credits."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
USER = Path.home()
APP = USER / 'Applications/CodexUsage.app'
BUILT = ROOT / '.build/CodexUsage.app'
PLIST = None
BASE = Path(os.environ.get('CODEX_HOME', str(USER / '.codex'))) / 'automations/codex'
SUPPORT = USER / 'Library/Application Support/CodexUsage/reset'
BACKUP_ROOT = SUPPORT.parent / 'backups'
DOMAIN = f'gui/{os.getuid()}'
LABEL = None
BIN = APP / 'Contents/MacOS/CodexUsage'
REFERENCE = 978307200
AUTO_USE = False


def run(args, check=True, timeout=45):
    # Process arguments may contain non-UTF-8 bytes. Decode defensively without
    # printing the process list, so an unrelated process cannot break preflight.
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True,
                       encoding='utf-8', errors='replace', timeout=timeout)
    if check and p.returncode:
        # Do not echo stderr from Codex or arbitrary subprocesses.
        raise RuntimeError(f'{Path(args[0]).name} failed (exit {p.returncode})')
    return p

def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name('.' + path.name + '.stage')
    with open(tmp, 'wb') as f:
        os.chmod(tmp, 0o600); f.write(data); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)

def put(path, value): atomic(path, json.dumps(value, ensure_ascii=False, indent=2).encode())

def exact_app_pids():
    p = run(['/bin/ps', '-axo', 'pid=,args='])
    answer = []
    for line in p.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and (parts[1] == str(BIN) or parts[1].startswith(str(BIN) + ' ')):
            answer.append(int(parts[0]))
    return answer

def stop_ui():
    for pid in exact_app_pids():
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    end = time.monotonic() + 6
    while exact_app_pids() and time.monotonic() < end: time.sleep(.2)
    if exact_app_pids(): raise RuntimeError('Installed app did not exit; no forced kill performed')

def matches_legacy_process(command, script):
    args = command.strip().split()
    # Framework Python on macOS is displayed as Python by ps. Require the
    # exact script argument as well as a recognized interpreter name.
    return (len(args) >= 2 and script in args[1:]
            and Path(args[0]).name.casefold() in ('python', 'python3', 'python3.13'))

def legacy_running():
    p = run(['/bin/ps', '-axo', 'args='])
    path = str(BASE / 'reset_credit_watcher.py')
    return any(matches_legacy_process(s, path) for s in p.stdout.splitlines())

def native_pid():
    p = run(['/bin/launchctl', 'print', DOMAIN + '/' + LABEL], check=False)
    if p.returncode or str(BIN) not in p.stdout or '--reset-worker' not in p.stdout: return None
    for line in p.stdout.splitlines():
        if line.strip().startswith('pid = '): return int(line.split('=')[1])
    return None

def timestamp(value):
    return dt.datetime.fromisoformat(value).timestamp() - REFERENCE

def initial_state(legacy):
    state = dict(version=1, phase='standby', inventory=[], attempts={}, reminders={}, notificationStatus='unknown')
    for cid, record in legacy.get('consume', {}).items():
        if not isinstance(record, dict) or not record.get('lastAttemptAt'): continue
        outcome = record.get('outcome')
        if outcome not in ('reset', 'alreadyRedeemed', 'noCredit', 'nothingToReset'):
            # Uncertain legacy work must not be silently discarded.
            if record.get('idempotencyKey'): raise RuntimeError('Legacy unresolved redemption needs review before migration')
            continue
        state['attempts'][cid] = dict(key=record.get('idempotencyKey', 'legacy-completed'),
                                    expiresAt=timestamp(record['lastAttemptAt']),
                                    attemptedAt=timestamp(record['lastAttemptAt']), outcome=outcome)
    for key, value in legacy.get('alerts', {}).items():
        if key.endswith(':1') and isinstance(value, dict) and value.get('localAt'):
            state['reminders'][key[:-2]] = [3600]
    return state

def merge_for_rollback():
    path = SUPPORT / 'state.json'
    if not path.exists(): return
    native = json.loads(path.read_text())
    target = BASE / 'reset_credit_watcher_state.json'
    legacy = json.loads(target.read_text())
    for cid, record in native.get('attempts', {}).items():
        value = legacy.setdefault('consume', {}).setdefault(cid, {})
        value['idempotencyKey'] = record['key']
        value['lastAttemptAt'] = dt.datetime.fromtimestamp(record['attemptedAt'] + REFERENCE, dt.timezone.utc).isoformat()
        outcome = record['outcome']
        if outcome in ('reset','alreadyRedeemed','noCredit'): value['outcome'] = outcome
        else:
            value.pop('outcome', None)
            if outcome == 'pending': value['lastError'] = 'Native attempt result unconfirmed; retry same idempotency key'
            else: value['lastOutcome'] = outcome
    atomic(target, (json.dumps(legacy, ensure_ascii=False, indent=2)+'\n').encode())

def rollback(backup, merge_native=True):
    run(['/bin/launchctl', 'bootout', DOMAIN + '/' + LABEL], check=False)
    stop_ui()
    if merge_native:
        merge_for_rollback()
    put(SUPPORT / 'ownership.json', {'active': False})
    if (backup / 'CodexUsage.app').exists():
        if APP.exists():
            failed = backup / 'native-app-after-rollback.app'
            if failed.exists(): raise RuntimeError('Rollback destination already exists')
            APP.rename(failed)
        shutil.copytree(backup / 'CodexUsage.app', APP, symlinks=True)
    atomic(PLIST, (backup / 'watcher.plist').read_bytes())
    os.chmod(PLIST, 0o644)
    run(['/bin/launchctl', 'bootstrap', DOMAIN, PLIST])
    run(['/usr/bin/open', '-g', APP])
    put(backup / 'result.json', {'status': 'rolledBack', 'legacyRunning': legacy_running()})

def apply():
    if not APP.is_dir() or not PLIST.is_file(): raise RuntimeError('Expected original app or LaunchAgent missing')
    original = plistlib.loads(PLIST.read_bytes())
    if original.get('Label') != LABEL or str(BASE/'reset_credit_watcher.py') not in original.get('ProgramArguments', []):
        raise RuntimeError('LaunchAgent is not the verified legacy watcher; refusing overwrite')
    if not legacy_running(): raise RuntimeError('Legacy watcher is not running; inspect before handoff')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', BUILT])
    # First gate is read-only. A failure here leaves app, scheduler and state untouched.
    run([BUILT/'Contents/MacOS/CodexUsage', '--check-reset-worker'])
    legacy = json.loads((BASE/'reset_credit_watcher_state.json').read_text())
    state = initial_state(legacy)
    backup = BACKUP_ROOT / dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    BACKUP_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup.mkdir(mode=0o700)
    shutil.copytree(APP, backup/'CodexUsage.app', symlinks=True)
    shutil.copy2(PLIST, backup/'watcher.plist')
    shutil.copy2(BASE/'reset_credit_watcher_state.json', backup/'legacy-state.json')
    if SUPPORT.exists(): shutil.copytree(SUPPORT, backup/'prior-native-state', symlinks=True)
    put(backup/'migration.json', {'app':str(APP), 'launchAgent':str(PLIST), 'legacyDirectory':str(BASE), 'supportDirectory':str(SUPPORT)})
    put(backup/'result.json', {'status':'prepared'})
    stopped = False
    replaced = False
    state_prepared = False
    try:
        stage = APP.parent / '.CodexUsage-integrated-stage.app'
        if stage.exists(): raise RuntimeError('Unexpected install stage exists; refusing overwrite')
        shutil.copytree(BUILT, stage, symlinks=True)
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', stage])
        SUPPORT.mkdir(parents=True, exist_ok=True, mode=0o700)
        put(SUPPORT/'settings.json', {'autoUse':AUTO_USE, 'reminders':True})
        put(SUPPORT/'worker.json', {'label':LABEL,'executable':str(BIN),'launchAgent':str(PLIST)})
        # Only launchd's existing service label can start the worker. The UI
        # never launches it. Preparing ownership cannot create another consumer.
        put(SUPPORT/'ownership.json', {'active':True})
        stop_ui()
        APP.rename(backup/'previous-app-moving.app')
        stage.rename(APP); replaced = True
        run(['/bin/launchctl', 'bootout', DOMAIN + '/' + LABEL]); stopped = True
        if legacy_running(): raise RuntimeError('Another legacy watcher is still running')
        # Capture the final ledger after the old consumer stops. A redemption
        # during staging must not be lost or retried with a different key.
        legacy = json.loads((BASE/'reset_credit_watcher_state.json').read_text())
        state = initial_state(legacy)
        shutil.copy2(BASE/'reset_credit_watcher_state.json', backup/'legacy-state-after-stop.json')
        put(SUPPORT/'state.json', state)
        state_prepared = True
        # Reuse the existing label/path: after reboot there is exactly one service.
        agent = dict(original)
        agent['ProgramArguments'] = [str(BIN),'--reset-worker']
        agent['WorkingDirectory'] = str(SUPPORT)
        agent['EnvironmentVariables'] = dict(original.get('EnvironmentVariables',{}))
        if os.environ.get('CODEX_PATH'):
            agent['EnvironmentVariables']['CODEX_PATH'] = os.environ['CODEX_PATH']
        agent['StandardOutPath'] = str(SUPPORT/'worker.stdout.log')
        agent['StandardErrorPath'] = str(SUPPORT/'worker.stderr.log')
        atomic(PLIST, plistlib.dumps(agent)); os.chmod(PLIST, 0o644)
        run(['/bin/launchctl', 'bootstrap', DOMAIN, PLIST])
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            current = json.loads((SUPPORT/'state.json').read_text())
            if native_pid() and current.get('checkedAt') and current.get('phase') != 'standby': break
            time.sleep(.5)
        else: raise RuntimeError('Native worker did not complete its first read; rolling back')
        if legacy_running(): raise RuntimeError('Legacy process detected after handoff')
        observation = SUPPORT.parent/'diagnostics/menu.json'
        observation.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if observation.exists(): observation.rename(backup/'previous-ui-observation.json')
        run(['/usr/bin/open','-n',APP,'--args','--export-menu-state',observation])
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if observation.exists(): break
            time.sleep(.3)
        else: raise RuntimeError('Installed UI did not finish launching; rolling back')
        result = dict(status='installed', nativeWorkerPID=native_pid(), legacyRunning=False,
                      backup=str(backup), settings={'autoUse':AUTO_USE,'reminders':True},
                      syntheticRedemptionPerformed=False)
        put(backup/'result.json',result)
        print(json.dumps(result,ensure_ascii=False))
    except Exception:
        if stopped: rollback(backup, merge_native=state_prepared)
        elif replaced:
            stop_ui(); APP.rename(backup/'native-app-not-activated.app')
            shutil.copytree(backup/'CodexUsage.app',APP,symlinks=True)
            put(SUPPORT/'ownership.json',{'active':False})
            run(['/usr/bin/open','-g',APP],check=False)
        raise

def configure(args):
    global APP, BUILT, PLIST, BASE, SUPPORT, BACKUP_ROOT, LABEL, BIN, AUTO_USE
    if args.rollback:
        backup = args.rollback.expanduser().resolve()
        definition = json.loads((backup / 'migration.json').read_text())
        APP = Path(definition['app'])
        PLIST = Path(definition['launchAgent'])
        BASE = Path(definition['legacyDirectory'])
        SUPPORT = Path(definition['supportDirectory'])
    else:
        if not args.legacy_plist:
            raise RuntimeError('--legacy-plist is required; no watcher is selected implicitly')
        APP = args.app.expanduser().resolve()
        BUILT = args.built_app.expanduser().resolve()
        PLIST = args.legacy_plist.expanduser().resolve()
        BASE = args.legacy_dir.expanduser().resolve()
    if APP.suffix != '.app' or PLIST.suffix != '.plist':
        raise RuntimeError('Expected an app bundle and LaunchAgent plist')
    definition = plistlib.loads((backup / 'watcher.plist').read_bytes() if args.rollback else PLIST.read_bytes())
    LABEL = definition.get('Label')
    if not isinstance(LABEL, str) or not LABEL or '/' in LABEL:
        raise RuntimeError('Invalid LaunchAgent label')
    if str(BASE / 'reset_credit_watcher.py') not in definition.get('ProgramArguments', []):
        raise RuntimeError('Selected LaunchAgent is not the expected legacy watcher')
    BIN = APP / 'Contents/MacOS/CodexUsage'
    BACKUP_ROOT = SUPPORT.parent / 'backups'
    AUTO_USE = args.enable_auto_use
    if args.codex_path:
        path = args.codex_path.expanduser().resolve()
        if not path.is_file() or not os.access(path, os.X_OK):
            raise RuntimeError('Selected Codex CLI is not executable')
        os.environ['CODEX_PATH'] = str(path)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Reviewed legacy watcher handoff with private backups. No credentials are copied.')
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--plan', action='store_true', help='Read selected metadata and validate legacy outcomes without changing anything')
    action.add_argument('--apply', action='store_true', help='Back up, install and repoint the selected single LaunchAgent')
    action.add_argument('--rollback', type=Path, help='Restore a backup produced by this script')
    parser.add_argument('--legacy-plist', type=Path)
    parser.add_argument('--legacy-dir', type=Path, default=BASE)
    parser.add_argument('--app', type=Path, default=APP)
    parser.add_argument('--built-app', type=Path, default=BUILT)
    parser.add_argument('--codex-path', type=Path)
    parser.add_argument('--enable-auto-use', action='store_true', help='Explicitly enable normal conditional redemption after the handoff')
    args = parser.parse_args()
    try:
        configure(args)
        if args.plan:
            state = json.loads((BASE / 'reset_credit_watcher_state.json').read_text())
            initial_state(state)  # Reject unresolved legacy redemption before any changes.
            print(json.dumps({'mode':'readOnlyPlan', 'app':str(APP), 'label':LABEL,
                              'launchAgent':str(PLIST), 'backupDirectory':str(BACKUP_ROOT),
                              'autoUseAfterApply':AUTO_USE, 'remindersAfterApply':True,
                              'credentialsCopied':False}, ensure_ascii=False))
        elif args.rollback: rollback(args.rollback.expanduser().resolve())
        else: apply()
    except Exception as e:
        print(json.dumps({'status':'blocked','reason':str(e)}, ensure_ascii=False))
        raise SystemExit(1)
