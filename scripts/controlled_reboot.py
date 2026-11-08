#!/usr/bin/env python3
"""Controlled Mjolnir host maintenance. Plan is read-only; mutations need --execute."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import secrets
import shlex
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from maintenance_host import Refused, atomic_json, config_defaults, digest

TARGET = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_.@:-]*$')


def event(message):
    print(message, flush=True)


class SSHRemote:
    def __init__(self, target, config, runner=subprocess.run):
        if not TARGET.fullmatch(target) or target in ('localhost', '127.0.0.1', '::1'):
            raise Refused('Use a remote SSH alias or user@host, never options or localhost')
        self.target, self.config, self.runner = target, config, runner
        self.source = Path(__file__).with_name('maintenance_host.py').read_text()

    def argv(self):
        return ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
                self.target, shlex.join(['python3', '-c', self.source])]

    def request(self, action, _timeout=None, **values):
        payload = {'action': action, 'config': self.config, **values}
        timeout = 2400 if action == 'prepare' else (600 if action == 'plan' else max(60, self.config['command_timeout'] + 30))
        if _timeout is not None:
            timeout = min(timeout, max(0.1, _timeout))
        stop_watch = threading.Event()
        watcher = None
        if action == 'prepare' and self.runner is subprocess.run:
            def watch():
                while not stop_watch.wait(15):
                    try:
                        status = self.request('status', run_id=values['run_id'], _timeout=10)
                        event('Remote ' + status['phase'] + ': ' + str(status['stopped_units']) +
                              ' units stopped, ' + str(status['uncertain_stops']) +
                              ' stops pending/uncertain, ' + str(status['snapshots']) + ' snapshots.')
                    except Refused:
                        event('Remote preparation status unavailable (unknown); journal retained.')
            watcher = threading.Thread(target=watch, daemon=True)
            watcher.start()
        try:
            p = self.runner(self.argv(), input=json.dumps(payload).encode(),
                            capture_output=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired):
            if action == 'plan':
                raise Refused('Read-only planning failed/timed out; no maintenance journal or stop phase was created') from None
            raise Refused('SSH operation failed/timed out; inspect the run journal before continuing') from None
        finally:
            stop_watch.set()
            if watcher:
                watcher.join(timeout=11)
        try:
            reply = json.loads(p.stdout)
        except (ValueError, TypeError):
            raise Refused('SSH acknowledgement is unavailable; no automatic power retry is allowed') from None
        if p.returncode or 'error' in reply:
            raise Refused(reply.get('error', 'Remote operation failed'))
        if 'result' not in reply:
            raise Refused('Incomplete remote acknowledgement')
        return reply['result']

    def download(self, destination, receipt, **values):
        # No shell filename interpolation or scp expansion. Remote stream checks
        # ownership and exports only this run's fixed archive under its lock.
        payload = {'action': 'stream', 'config': self.config, 'execute': True, **values}
        path = Path(destination)
        if path.exists() or path.is_symlink():
            raise Refused('Refusing to overwrite a partial/unrelated backup artifact')
        with path.open('xb') as output:
            os.chmod(path, 0o600)
            try:
                def bound_copy():
                    resource.setrlimit(resource.RLIMIT_FSIZE, (receipt['bytes'], receipt['bytes']))
                p = self.runner(self.argv(), input=json.dumps(payload).encode(), stdout=output,
                                stderr=subprocess.DEVNULL, timeout=1800, preexec_fn=bound_copy)
            except (OSError, subprocess.TimeoutExpired):
                raise Refused('Backup copy interrupted; retain the private partial artifact') from None
        if p.returncode or path.stat().st_size != receipt['bytes']:
            raise Refused('Backup copy failed or has the wrong size')


def http_status(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password:
        raise Refused('HTTP probes require an HTTP(S) URL without embedded credentials')
    request = urllib.request.Request(url, method='GET')
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except (OSError, urllib.error.URLError, TimeoutError):
        return None


def check_recovery(before, current, guests, expected_kernel, http, baseline_http):
    errors = []
    if current['machine_id'] != before['machine_id']:
        errors.append('wrong machine')
    if current['boot_id'] == before['boot_id']:
        errors.append('host has not rebooted')
    if current['kernel'] != expected_kernel:
        errors.append('unexpected kernel')
    if set(current['vms']) != set(before['vms']):
        errors.append('VM membership differs')
    for vm, old in before['vms'].items():
        new = current['vms'].get(vm)
        g = guests.get(vm)
        if not new or new['state'] != 'running' or not g:
            errors.append('guest not ready: ' + vm)
            continue
        if old['iroh'] and old['iroh'] != new['iroh']:
            errors.append('guest identity changed: ' + vm)
        original_record = before['records'][vm]
        record = current['records'].get(vm, {})
        if any(record.get(k) != original_record.get(k) for k in ('root_uuid', 'intent', 'restart', 'managed')):
            errors.append('guest root/policy changed: ' + vm)
        previous = before['guests'][vm]
        if previous['boot_id'] == g['boot_id']:
            errors.append('guest did not cold boot: ' + vm)
        if set(previous['running']) - set(g['running']):
            errors.append('guest services missing: ' + vm)
        if set(g['failed']) - set(previous['failed']):
            errors.append('new failed guest services: ' + vm)
        if before['records'][vm]['managed'] and not g['secrets_mounted']:
            errors.append('managed secrets not mounted: ' + vm)
    for unit, previous in before['host_units'].items():
        if previous.get('ActiveState') == 'active' and current['host_units'].get(unit, {}).get('ActiveState') != 'active':
            errors.append('host service not active: ' + unit)
    for url, previous in baseline_http.items():
        status = http.get(url)
        if status is None or previous is None:
            errors.append('HTTP result unknown: ' + urllib.parse.urlsplit(url).hostname)
        elif 200 <= previous < 400 and not 200 <= status < 400:
            errors.append('HTTP baseline regressed: ' + urllib.parse.urlsplit(url).hostname)
        elif previous >= 400 and status >= 400 and previous != status:
            errors.append('Pre-existing HTTP failure changed: ' + urllib.parse.urlsplit(url).hostname)
    return errors


class Maintenance:
    def __init__(self, target, directory, remote=None, clock=time.monotonic, sleeper=time.sleep,
                 http=http_status):
        self.target, self.directory = target, Path(directory)
        self.remote = remote
        self.clock, self.sleep, self.http = clock, sleeper, http
        self.j = None

    def save(self):
        atomic_json(self.directory/'run.json', self.j)

    def load(self):
        p = self.directory/'run.json'
        if p.is_symlink() or self.directory.is_symlink():
            raise Refused('Run artifacts must not be symlinks')
        self.j = json.loads(p.read_text())
        if self.j['target'] != self.target:
            raise Refused('This run belongs to another SSH target')
        if digest(self.j['config']) != self.j['config_hash']:
            raise Refused('Frozen configuration was modified; create a new plan')
        if self.j.get('plan_hash') != self.plan_hash(self.j):
            raise Refused('The frozen baseline was modified; create a new plan')
        if not self.remote:
            self.remote = SSHRemote(self.target, self.j['config'])

    def values(self):
        return {'run_id': self.j['run_id'], 'token': self.j['token']}

    @staticmethod
    def plan_hash(journal):
        return digest({k: journal[k] for k in ('target', 'config_hash', 'baseline', 'http_before')})

    def mutation(self, action, **values):
        return self.remote.request(action, execute=True, **self.values(), **values)

    def local_backup_valid(self, receipt):
        archive = self.directory/'backup.tar.gz'
        if archive.is_symlink() or not archive.is_file() or archive.stat().st_size != receipt['bytes']:
            raise Refused('The off-host backup is missing or changed')
        with archive.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != receipt['sha256']:
                raise Refused('The off-host backup checksum changed')

    def plan(self, config):
        c = config_defaults(config)
        if self.directory.exists() or self.directory.is_symlink():
            raise Refused('Choose a new, private run directory; existing runs are never overwritten')
        self.directory.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if shutil.disk_usage(self.directory.parent).free < c['max_backup_bytes'] + c['reserve_bytes']:
            raise Refused('Insufficient off-host backup space for the configured budget')
        remote = self.remote or SSHRemote(self.target, c)
        baseline = remote.request('plan')
        local_id = Path('/etc/machine-id')
        if local_id.is_file() and hashlib.sha256(local_id.read_bytes()).hexdigest() == baseline['machine_id']:
            raise Refused('The backup client must run outside the target host')
        self.remote = remote
        statuses = {url: self.http(url) for url in c['http_urls']}
        if any(value is None for value in statuses.values()):
            raise Refused('A configured HTTP baseline is unreachable/unknown; review its coverage before maintenance')
        self.directory.mkdir(mode=0o700)
        self.j = {'schema': 1, 'target': self.target, 'run_id': str(uuid.uuid4()),
                  'token': secrets.token_hex(32), 'config': c, 'config_hash': digest(c),
                  'phase': 'planned', 'baseline': baseline,
                  'http_before': statuses}
        self.j['plan_hash'] = self.plan_hash(self.j)
        self.save()
        applications = sum(len(g['applications']) for g in baseline['guests'].values())
        event('Read-only plan saved: ' + str(len(baseline['vms'])) + ' VMs, ' +
              str(applications) + ' application units; inspect the private run.json before execution.')
        event('Configured coverage: ' + str(len(c['backup_hooks'])) + ' backup hooks, ' +
              str(len(c['readiness_probes'])) + ' readiness probes, ' + str(len(c['http_urls'])) + ' HTTP URLs.')

    def prepare(self):
        if self.j['phase'] in ('action_requested', 'complete', 'resumed'):
            raise Refused('This run cannot be prepared again')
        self.j['phase'] = 'preparing'
        self.save()
        event('Preparing remote host; production downtime starts when admission/writer units stop.')
        try:
            receipt = self.mutation('prepare', baseline=self.j['baseline'])
            if not isinstance(receipt.get('bytes'), int) or not 0 < receipt['bytes'] <= self.j['config']['max_backup_bytes']:
                raise Refused('Invalid backup size receipt')
            if not re.fullmatch('[0-9a-f]{64}', receipt.get('sha256', '')):
                raise Refused('Invalid backup checksum receipt')
            if shutil.disk_usage(self.directory).free < receipt['bytes'] + self.j['config']['reserve_bytes']:
                raise Refused('Not enough free space for the off-host copy')
            archive = self.directory/'backup.tar.gz'
            if not archive.exists():
                self.remote.download(archive, receipt, **self.values())
            if archive.is_symlink() or archive.stat().st_size != receipt['bytes']:
                raise Refused('Wrong backup file size/type')
            with archive.open('rb') as stream:
                sha = hashlib.file_digest(stream, 'sha256').hexdigest()
            if sha != receipt['sha256']:
                raise Refused('Off-host backup checksum mismatch')
            logical = 0
            with tarfile.open(archive, mode='r|gz') as stream:
                for member in stream:
                    logical += member.size
                    if logical > self.j['config']['max_logical_bytes']:
                        raise Refused('Off-host archive exceeds its logical-size budget')
            self.mutation('confirm', receipt=receipt)
            self.j.update(phase='prepared', receipt=receipt)
            self.save()
            event('Prepared: services quiesced; read-only snapshots and off-host backup verified.')
        except BaseException:
            try:
                self.mutation('resume')
                self.j['phase'] = 'resumed'
            except BaseException:
                self.j['phase'] = 'resume_incomplete'
            self.save()
            raise

    def resume(self):
        if self.j['phase'] in ('action_requested', 'complete', 'resumed'):
            raise Refused('Use verify after a power request; completed/resumed runs are terminal')
        # The remote operation invalidates preparation before any start.
        self.j['phase'] = 'resuming'
        self.save()
        try:
            self.mutation('resume')
        except BaseException:
            self.j['phase'] = 'resume_incomplete'
            self.save()
            raise
        self.j['phase'] = 'resumed'
        self.save()
        event('Original services restored. Use a new plan for further maintenance.')

    def power(self, action, timeout):
        if self.j['phase'] == 'action_requested':
            if action == 'reboot':
                return self.verify(timeout)
            raise Refused('Shutdown already requested; it will not be issued again')
        if self.j['phase'] != 'prepared':
            self.prepare()
        status = self.remote.request('status', run_id=self.j['run_id'])
        if status.get('config_hash') != self.j['config_hash']:
            raise Refused('Remote preparation belongs to another configuration')
        if status.get('phase') in ('action_requested', 'complete'):
            self.j.update(phase='action_requested', action=status.get('action'))
            self.save()
            if action == 'reboot' and status.get('action') == 'reboot':
                return self.verify(timeout)
            raise Refused('A host action is already recorded; use verify, never redispatch it')
        if status.get('phase') == 'resumed':
            self.j['phase'] = 'resumed'
            self.save()
            raise Refused('This preparation was resumed by another client; create a new plan')
        if status.get('phase') != 'prepared':
            raise Refused('Remote preparation state changed; inspect status before proceeding')
        try:
            if status.get('archive') != self.j.get('receipt'):
                raise Refused('Local and remote backup receipts differ')
            self.local_backup_valid(self.j['receipt'])
        except BaseException:
            try:
                self.resume()
            except BaseException:
                self.j['phase'] = 'resume_incomplete'
                self.save()
            raise
        self.j.update(phase='action_requested', action=action)
        self.save()
        acknowledged = False
        try:
            self.mutation('power', power_action=action)
            acknowledged = True
        except Refused:
            try:
                status = self.remote.request('status', run_id=self.j['run_id'])
                if status.get('phase') == 'prepared':
                    self.mutation('resume')
                    self.j['phase'] = 'resumed'
                    self.save()
                    raise Refused('Power was refused; original services restored. Create a fresh plan.')
            except Refused as exc:
                if self.j['phase'] == 'resumed':
                    raise exc
            # Unknown acknowledgement is not authority to dispatch twice.
            event('Power acknowledgement unavailable. Preserving action-requested; never retrying automatically.')
        if action == 'reboot':
            return self.verify(timeout)
        if not acknowledged:
            raise Refused('Poweroff acknowledgement is unknown; inspect status and verify after provider power-on')
        event('Poweroff requested; provider power-on is external. Run verify after the host is powered on.')

    def verify(self, timeout):
        if self.j['phase'] not in ('action_requested', 'complete'):
            raise Refused('Verification requires a recorded host power request')
        deadline = self.clock() + timeout
        last = ['host has not returned']
        while self.clock() < deadline:
            try:
                current = self.remote.request('inspect', _timeout=deadline-self.clock())
                if current['machine_id'] != self.j['baseline']['machine_id']:
                    raise Refused('Different machine returned; refusing recovery completion')
                if self.j['phase'] == 'complete' and current['boot_id'] != self.j.get('verified_boot_id'):
                    raise Refused('Different boot returned after this run completed')
                guests = {}
                if current['boot_id'] != self.j['baseline']['boot_id']:
                    for vm in self.j['baseline']['vms']:
                        if self.clock() >= deadline:
                            break
                        if current['vms'].get(vm, {}).get('state') == 'running':
                            try:
                                guests[vm] = self.remote.request('guest_read', vm=vm, _timeout=deadline-self.clock())
                            except Refused:
                                pass
                statuses = {url: self.http(url) for url in self.j['http_before']} if len(guests) == len(self.j['baseline']['vms']) else {}
                last = check_recovery(self.j['baseline'], current, guests,
                                      self.j['config']['expected_kernel'], statuses, self.j['http_before'])
                if not last:
                    self.remote.request('probes', baseline=self.j['baseline'], _timeout=deadline-self.clock())
                    if self.clock() >= deadline:
                        last = ['Recovery deadline exhausted']
                        break
                    existing = {url: status for url, status in statuses.items()
                                if status is not None and status >= 400 and self.j['http_before'][url] >= 400}
                    evidence = {'current': current, 'guests': guests, 'http': statuses, 'errors': [],
                                'preexisting_http_non_success': existing}
                    atomic_json(self.directory/'verification.json', evidence)
                    if self.j['phase'] != 'complete':
                        try:
                            self.mutation('complete', verification_ok=True, _timeout=deadline-self.clock())
                        except Refused:
                            # A lost final acknowledgement must not make a fully
                            # committed receipt impossible to recover, nor steal
                            # another run's lease.
                            status = self.remote.request('status', run_id=self.j['run_id'], _timeout=deadline-self.clock())
                            if not (status.get('phase') == 'complete' and not status.get('lease_owned')
                                    and status.get('config_hash') == self.j['config_hash']
                                    and status.get('verified_boot_id') == current['boot_id']):
                                raise
                    self.j['phase'] = 'complete'
                    self.j['verified_boot_id'] = current['boot_id']
                    self.save()
                    event('Recovery verified: kernel, original VM IDs, guest boots, identities, services, secrets and configured probes.')
                    if existing:
                        event(str(len(existing)) + ' pre-existing non-success HTTP responses remain explicit in verification.json.')
                    return
            except Refused as exc:
                last = [str(exc)]
                if 'Different machine' in str(exc) or 'Different boot' in str(exc):
                    break
            atomic_json(self.directory/'verification.json', {'errors': last})
            event('Waiting for recovery: ' + str(len(last)) + ' checks incomplete; details in verification.json.')
            self.sleep(min(10, max(0, deadline-self.clock())))
        raise Refused('Recovery incomplete; journal retained. Do not issue another automatic reboot.')


@contextlib.contextmanager
def local_lock(directory):
    path = Path(directory)/'client.lock'
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused('This run is already executing in another client') from None
        yield
    finally:
        os.close(fd)


def main(argv=None, remote_factory=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['plan', 'prepare', 'reboot', 'shutdown', 'verify', 'resume', 'status'])
    parser.add_argument('host')
    parser.add_argument('--run-dir', required=True)
    parser.add_argument('--config', help='Trusted operator JSON; required for plan')
    parser.add_argument('--execute', action='store_true', help='Authorize disruptive operations for this run')
    parser.add_argument('--timeout', type=int, default=900, help='Recovery deadline in seconds')
    args = parser.parse_args(argv)
    if not TARGET.fullmatch(args.host) or args.timeout < 1:
        raise Refused('Invalid SSH target or recovery deadline')
    if args.config and args.command != 'plan':
        raise Refused('--config is only accepted for a new plan; existing runs use their frozen configuration')
    if args.command in ('prepare', 'reboot', 'shutdown', 'resume') and not args.execute:
        raise Refused('No changes made. Add --execute only after reviewing the saved plan.')
    m = Maintenance(args.host, args.run_dir)
    if args.command == 'plan':
        if not args.config:
            raise Refused('plan requires --config')
        config = config_defaults(json.loads(Path(args.config).read_text()))
        if remote_factory:
            m.remote = remote_factory(args.host, config)
        m.plan(config)
        return 0
    m.load()
    mode = m.directory.stat()
    if mode.st_uid != os.geteuid() or mode.st_mode & 0o077:
        raise Refused('The saved run directory must be private and owned by this user')
    if remote_factory:
        m.remote = remote_factory(args.host, m.j['config'])
    if args.command == 'status':
        event('Local phase: ' + m.j['phase'])
        try:
            status = m.remote.request('status', run_id=m.j['run_id'])
            event('Remote phase: ' + status['phase'])
            event(str(status['stopped_units']) + ' units stopped; ' + str(status['uncertain_stops']) +
                  ' pending/uncertain stops; ' + str(status['snapshots']) + ' snapshots.')
        except Refused:
            event('Remote status unavailable (unknown).')
            return 1
        return 0
    with local_lock(m.directory):
        if args.command == 'prepare':
            m.prepare()
        elif args.command == 'resume':
            m.resume()
        elif args.command == 'verify':
            m.verify(args.timeout)
        else:
            m.power('poweroff' if args.command == 'shutdown' else 'reboot', args.timeout)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (Refused, OSError, ValueError, KeyError, tarfile.TarError) as exc:
        # No subprocess argv/output, hook contents, database rows or credentials.
        print(str(exc) if isinstance(exc, Refused) else type(exc).__name__, file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print('Interrupted. Inspect status; use resume before power or verify after a power request.', file=sys.stderr)
        raise SystemExit(130)
