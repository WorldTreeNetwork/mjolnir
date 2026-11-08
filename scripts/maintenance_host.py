#!/usr/bin/env python3
"""Private SSH-side implementation of controlled_reboot.py. Standard library only."""
import contextlib
import concurrent.futures
import fcntl
import fnmatch
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import re
import resource
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid

OPS = Path('/var/lib/mjolnir/ops/maintenance')
UNIT = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_@.:-]*\.service$')
ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$')
KEEP = ['mjolnir-agent.service', 'systemd-*.service', 'getty@*.service',
        'serial-getty@*.service', 'dbus.service', 'cron.service', 'ssh.service',
        'sshd.service', 'unattended-upgrades.service']
HOST_PAUSE = {'mjolnir-gateway.service', 'forgejo-runner.service'}
GUEST_READ = r'''set -eu
units=$(systemctl list-units --type=service --state=running --no-pager --no-legend --plain)
failed=$(systemctl --failed --type=service --no-pager --no-legend --plain)
printf '%s\n' "$units" | awk 'NF {print "RUNNING\t" $1}'
printf '%s\n' "$failed" | awk 'NF {print "FAILED\t" $1}'
if mountpoint -q /secrets; then printf 'SECRETS\tyes\n'; else printf 'SECRETS\tno\n'; fi
printf 'BOOT\t'; cat /proc/sys/kernel/random/boot_id
'''


class Refused(RuntimeError):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temp.exists():
            temp.unlink()


def config_defaults(raw):
    if sys.version_info < (3, 11):
        raise Refused('Python 3.11 or newer is required on client and host')
    if not isinstance(raw, dict):
        raise Refused('Configuration must be a JSON object')
    c = {
        'expected_kernel': '', 'state_dir': '/var/lib/mjolnir/state',
        'btrfs_root': '/var/lib/mjolnir/btrfs', 'escrow_dir': '/var/lib/mjolnir/escrow',
        'operator_socket': '/run/mjolnir/operator.sock',
        'pause_host_units': ['mjolnir-gateway.service'],
        'host_services': ['mjolnir.service', 'mjolnir-gateway.service',
                          'mjolnir-redis.service', 'mjolnir-blob-door.service'],
        'application_units': [], 'dependency_units': [], 'keep_guest_units': [],
        'backup_hooks': [], 'readiness_probes': [], 'http_urls': [],
        'host_backup_paths': ['/etc/mjolnir', '/var/lib/mjolnir/auth',
                              '/var/lib/mjolnir/biscuit-root', '/etc/fstab', '/etc/default/grub'],
        'guest_backup_paths': ['/etc', '/var/lib/mjolnir', '/var/lib/conduit',
                               '/var/lib/minio', '/var/lib/buzz', '/var/lib/redis', '/app/data'],
        'command_timeout': 120, 'sync_timeout': 60, 'plan_max_age': 1800,
        'prepared_max_age': 900, 'max_backup_bytes': 4 * 1024**3,
        'max_logical_bytes': 16 * 1024**3, 'reserve_bytes': 1024**3,
    }
    unknown = set(raw) - set(c)
    if unknown:
        raise Refused('Unknown configuration fields: ' + ', '.join(sorted(unknown)))
    c.update(raw)
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9_.-]+', c['expected_kernel']):
        raise Refused('expected_kernel must name the reviewed Ubuntu kernel')
    for key in ('command_timeout', 'sync_timeout', 'plan_max_age', 'prepared_max_age',
                'max_backup_bytes', 'max_logical_bytes', 'reserve_bytes'):
        if type(c[key]) is not int or c[key] <= 0:
            raise Refused(key + ' must be a positive integer')
    for key in ('state_dir', 'btrfs_root', 'escrow_dir', 'operator_socket'):
        absolute(c[key])
    for key in ('pause_host_units', 'host_services'):
        if not isinstance(c[key], list) or any(not UNIT.fullmatch(u) for u in c[key]):
            raise Refused('Invalid host service list')
    if not set(c['pause_host_units']) <= HOST_PAUSE:
        raise Refused('Only gateway/runner admission services may be paused on the host')
    for key in ('application_units', 'dependency_units', 'keep_guest_units'):
        if not isinstance(c[key], list) or any(not isinstance(u, str) or '/' in u or
                                              not u.endswith('.service') for u in c[key]):
            raise Refused('Invalid guest unit patterns')
    if not c['backup_hooks'] or not c['readiness_probes']:
        raise Refused('Configure backup hooks and dependency readiness probes explicitly')
    names = set()
    for hook in c['backup_hooks']:
        validate_hook(hook)
        if hook['name'] in names:
            raise Refused('Duplicate backup hook name')
        names.add(hook['name'])
        exports = hook.get('exports', [])
        if not exports or any(not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', x)
                              for x in exports):
            raise Refused('Backup hooks require basename-only exports')
    for probe in c['readiness_probes']:
        validate_hook(probe)
        if probe.get('phase', 'dependencies') not in ('dependencies', 'applications'):
            raise Refused('Invalid readiness probe phase')
        if 'stdout_pattern' in probe:
            re.compile(probe['stdout_pattern'])
    if c['max_logical_bytes'] < 1024 * sum(len(h['exports']) for h in c['backup_hooks']):
        raise Refused('Logical backup budget is too small for declared exports')
    for key in ('host_backup_paths', 'guest_backup_paths'):
        for path in c[key]:
            absolute(path)
    return c


def absolute(value):
    if not isinstance(value, str) or not value.startswith('/') or '..' in Path(value).parts or value == '/':
        raise Refused('Expected a non-root absolute path without traversal')
    return Path(value)


def anchored(root, relative, allow_final_symlink=False):
    """Never follow a guest symlink into the host namespace during export."""
    root = Path(root)
    relative = Path(relative)
    if relative.is_absolute() or '..' in relative.parts:
        raise Refused('Unsafe relative backup path')
    current = root
    for index, part in enumerate(relative.parts):
        current = current/part
        if current.is_symlink() and not (allow_final_symlink and index == len(relative.parts)-1):
            raise Refused('A guest backup path traverses a symlink')
    return current


def validate_hook(hook):
    if not isinstance(hook, dict) or not re.fullmatch(r'[A-Za-z0-9_-]{1,60}', hook.get('name', '')):
        raise Refused('Hooks/probes require a safe name')
    argv = hook.get('argv')
    if not isinstance(argv, list) or not argv or any(not isinstance(v, str) or '\0' in v for v in argv):
        raise Refused('Hooks/probes require an argv array')
    if sum(k in hook for k in ('vm', 'app')) > 1:
        raise Refused('Select at most one guest VM or registered app')
    if set(hook) - {'name', 'argv', 'exports', 'vm', 'app', 'phase', 'stdout_pattern'}:
        raise Refused('Unknown hook/probe fields')
    if 'vm' in hook and (not isinstance(hook['vm'], str) or not ID.fullmatch(hook['vm'])):
        raise Refused('Invalid guest selector')
    if 'app' in hook and (not isinstance(hook['app'], str) or not hook['app']):
        raise Refused('Invalid registered-app selector')


def matched(unit, patterns):
    return any(fnmatch.fnmatchcase(unit, pattern) for pattern in patterns)


def subvolume_ids(output, prefix='@vms'):
    """Parse one bounded metadata listing, never walk guest file contents."""
    result = {}
    for line in output.splitlines():
        match = re.search(r'(?:^| )uuid ([0-9a-fA-F-]{36}) path (.+)$', line)
        if not match:
            raise Refused('Unrecognized BTRFS subvolume metadata')
        path = Path(match[2].removeprefix('<FS_TREE>/'))
        if path.parent != Path(prefix) or not ID.fullmatch(path.name):
            continue
        if path.name in result:
            raise Refused('Ambiguous BTRFS guest-root identity')
        result[path.name] = str(uuid.UUID(match[1]))
    return result


def protected(unit):
    return matched(unit, KEEP)


def identity():
    return {'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
            'machine_id': hashlib.sha256(Path('/etc/machine-id').read_bytes()).hexdigest()}


def run(argv, timeout=120, output=True, size_limit=None):
    def limits():
        bound = size_limit or (2 * 1024**2 if output else None)
        if bound:
            resource.setrlimit(resource.RLIMIT_FSIZE, (bound, bound))
    try:
        # Bounded private files avoid both unbounded PIPE capture and inheriting
        # hook/probe diagnostics into normal output. Nothing is extracted/read
        # beyond the small metadata budget.
        with contextlib.ExitStack() as stack:
            stdout = stack.enter_context(tempfile.TemporaryFile()) if output else subprocess.DEVNULL
            stderr = stack.enter_context(tempfile.TemporaryFile()) if output else subprocess.DEVNULL
            p = subprocess.run(argv, stdout=stdout, stderr=stderr,
                               timeout=timeout, preexec_fn=limits if output or size_limit else None)
            if p.returncode:
                raise Refused('Command exited with status ' + str(p.returncode))
            if not output:
                return ''
            stdout.seek(0)
            data = stdout.read(2 * 1024**2 + 1)
    except (OSError, subprocess.TimeoutExpired):
        raise Refused('Command failed or exceeded its deadline') from None
    if len(data) > 2 * 1024**2:
        raise Refused('Command response exceeds the metadata limit')
    return data.decode()


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__('localhost', timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


class Host:
    def __init__(self, config, ops=OPS):
        self.c = config
        self.ops = Path(ops)
        self.j = None
        self.jpath = None
        self._mutex = threading.RLock()

    def api(self, path, body=None, timeout=20):
        sock = Path(self.c['operator_socket'])
        s = sock.stat()
        if not stat.S_ISSOCK(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o077:
            raise Refused('The root-only Unix operator socket is unavailable or has unsafe permissions')
        conn = UnixHTTP(str(sock), timeout)
        try:
            conn.request('POST' if body is not None else 'GET', path,
                         json.dumps(body) if body is not None else None,
                         {'Content-Type': 'application/json'})
            response = conn.getresponse()
            data = response.read(2 * 1024**2 + 1)
            if response.status != 200 or len(data) > 2 * 1024**2:
                raise Refused('Operator API returned an error or oversized response')
            return json.loads(data)
        finally:
            conn.close()

    def guest_exec(self, vm, command, timeout=None):
        if not ID.fullmatch(vm):
            raise Refused('Invalid VM identifier')
        seconds = timeout or self.c['command_timeout']
        wrapped = shlex.join(['timeout', '-k', '5', str(seconds), 'sh', '-c', command])
        result = self.api('/api/vms/' + vm + '/exec', {'command': wrapped}, seconds + 20)
        if result.get('exit_code', 0) != 0 or 'output' not in result:
            raise Refused('Guest command failed or timed out: ' + vm)
        return result['output']

    def guest_read(self, vm):
        output = self.guest_exec(vm, GUEST_READ, 20)
        data = {'running': [], 'failed': [], 'secrets_mounted': False}
        for line in output.splitlines():
            key, sep, value = line.partition('\t')
            if not sep:
                raise Refused('Unparseable guest inspection')
            if key in ('RUNNING', 'FAILED'):
                if not UNIT.fullmatch(value):
                    raise Refused('Invalid guest service metadata')
                data['running' if key == 'RUNNING' else 'failed'].append(value)
            elif key == 'BOOT':
                data['boot_id'] = str(uuid.UUID(value))
            elif key == 'SECRETS' and value in ('yes', 'no'):
                data['secrets_mounted'] = value == 'yes'
            else:
                raise Refused('Unknown guest inspection field')
        if not data.get('boot_id') or 'mjolnir-agent.service' not in data['running']:
            raise Refused('Guest agent or boot identity is unavailable')
        return data

    def host_unit(self, unit):
        if not UNIT.fullmatch(unit):
            raise Refused('Invalid unit')
        text = run(['systemctl', 'show', unit, '-p', 'ActiveState', '-p', 'UnitFileState', '-p', 'LoadState',
                    '-p', 'ActiveEnterTimestampMonotonic', '-p', 'InactiveEnterTimestampMonotonic', '-p', 'InvocationID'])
        return dict(line.split('=', 1) for line in text.splitlines() if '=' in line)

    def preflight(self):
        for name in ('systemctl', 'timeout', 'btrfs', 'findmnt', 'grub-script-check', 'grub-editenv',
                     'lsinitramfs', 'tar', 'gzip'):
            if not shutil.which(name):
                raise Refused('Required host utility is missing: ' + name)
        target = self.c['expected_kernel']
        run(['grub-script-check', '/boot/grub/grub.cfg'])
        env = run(['grub-editenv', '/boot/grub/grubenv', 'list'])
        if any(line.startswith(('next_entry=', 'saved_entry=')) and line.split('=', 1)[1]
               for line in env.splitlines()):
            raise Refused('GRUB has an override; review the boot selection manually')
        defaults = Path('/etc/default/grub').read_text()
        if not re.search(r'^GRUB_DEFAULT=[\'\"]?0[\'\"]?\s*$', defaults, re.M):
            raise Refused('Only reviewed GRUB_DEFAULT=0 boot selection is supported')
        grub = Path('/boot/grub/grub.cfg').read_text()
        selected = re.search(r'^\s*linux(?:efi)?\s+\S*vmlinuz-([^\s]+)', grub, re.M)
        if not selected or selected[1] != target:
            raise Refused('The first GRUB kernel does not match expected_kernel')
        if not Path('/boot/vmlinuz-' + target).is_file():
            raise Refused('Target kernel image is missing')
        run(['lsinitramfs', '/boot/initrd.img-' + target], output=False)
        alternatives = [p.name.removeprefix('vmlinuz-') for p in Path('/boot').glob('vmlinuz-*')
                        if p.name != 'vmlinuz-' + target and p.is_file()]
        fallback = next((v for v in alternatives if Path('/boot/initrd.img-' + v).is_file()), None)
        if not fallback:
            raise Refused('No fallback kernel/initramfs pair is installed')
        run(['lsinitramfs', '/boot/initrd.img-' + fallback], output=False)
        ssh = [self.host_unit('ssh.service'), self.socket_state()]
        if not any(s.get('ActiveState') == 'active' and s.get('UnitFileState') == 'enabled' for s in ssh):
            raise Refused('SSH service or socket must be active and enabled')
        return {'selected_kernel': target, 'fallback_kernel': fallback}

    def capacity(self, for_backup=True):
        path = self.ops
        while not path.exists():
            path = path.parent
        needed = self.c['reserve_bytes'] + (self.c['max_backup_bytes'] + self.c['max_logical_bytes'] if for_backup else 0)
        if shutil.disk_usage(path).free < needed:
            raise Refused('Insufficient host archive space/reserve; no power action is allowed')
        root = Path(self.c['btrfs_root'])
        data_needed = self.c['reserve_bytes'] + (self.c['max_logical_bytes'] if for_backup else 0)
        if root.exists() and shutil.disk_usage(root).free < data_needed:
            raise Refused('Insufficient BTRFS recovery-snapshot reserve')

    def socket_state(self):
        text = run(['systemctl', 'show', 'ssh.socket', '-p', 'ActiveState', '-p', 'UnitFileState'])
        return dict(line.split('=', 1) for line in text.splitlines() if '=' in line)

    def inspect(self):
        live = self.api('/api/vms')['vms']
        roots = Path(self.c['btrfs_root'])/'@vms'
        roots_by_id = {}
        if roots.is_dir():
            mount = json.loads(run(['findmnt', '-J', '-o', 'TARGET,FSROOT,FSTYPE', '--target', str(roots)]))['filesystems'][0]
            if mount.get('fstype') != 'btrfs' or not mount.get('fsroot', '').startswith('/'):
                raise Refused('Guest roots must reside on an identifiable BTRFS mount')
            relative = roots.resolve().relative_to(Path(mount['target']).resolve())
            prefix = Path(mount['fsroot'].lstrip('/'))/relative
            roots_by_id = subvolume_ids(run(['btrfs', 'subvolume', 'list', '-o', '-u', str(roots)]), str(prefix))
        records = {}
        for path in Path(self.c['state_dir']).glob('*.json'):
            if path.is_symlink():
                raise Refused('State files must not be symlinks')
            r = json.loads(path.read_text())
            vm = r.get('uuid', '')
            if not ID.fullmatch(vm):
                raise Refused('Invalid state-record identity')
            cfg = r.get('spawn_config', {})
            root = Path(self.c['btrfs_root']) / '@vms' / vm
            root_exists = root.is_dir() and not root.is_symlink()
            root_uuid = None
            if root_exists:
                root_uuid = roots_by_id.get(vm)
                if not root_uuid:
                    raise Refused('Original VM subvolume identity is unavailable')
            records[vm] = {'intent': r['intent'], 'restart': cfg.get('restart_policy', 'always'),
                           'managed': cfg.get('secrets_mode') == 'managed',
                           'root_exists': root_exists, 'root_uuid': root_uuid, 'spawn_hash': digest(cfg),
                           'escrow_exists': (Path(self.c['escrow_dir']) / vm).is_file()}
        vms = {}
        for vm in live:
            key = vm['id']
            if not ID.fullmatch(key) or key in vms:
                raise Refused('Invalid or duplicate live VM identity')
            if vm.get('metadata', {}).get('purpose') == 'ci':
                raise Refused('Active CI guests must be drained separately; exec would renew their leases')
            vms[key] = {'state': vm['state'], 'iroh': vm.get('iroh_node_id')}
        apps = {a['app_name']: a.get('service_vm_id')
                for a in self.api('/api/apps')['apps']}
        units = {u: self.host_unit(u) for u in set(self.c['host_services'] + self.c['pause_host_units'])}
        return {**identity(), 'kernel': os.uname().release, 'vms': vms,
                'records': records, 'apps': apps, 'host_units': units, 'time': time.time()}

    def plan(self):
        data = self.inspect()
        running = {k for k, v in data['records'].items() if v['intent'] == 'running'}
        if not running or running != set(data['vms']):
            raise Refused('Running-intent and live VM sets must match and be nonempty')
        for vm in running:
            r = data['records'][vm]
            if r['restart'] != 'always' or not r['root_exists'] or (r['managed'] and not r['escrow_exists']):
                raise Refused('A guest lacks automatic restart, original root or managed escrow')
            if data['vms'][vm]['state'] != 'running':
                raise Refused('All participating VMs must be running before maintenance')
        for unit in self.c['host_services']:
            if data['host_units'][unit].get('ActiveState') != 'active' or data['host_units'][unit].get('UnitFileState') != 'enabled':
                raise Refused('A required host service is not active and boot-enabled: ' + unit)
        self.capacity()
        data['preflight'] = self.preflight()
        data['guests'] = {}
        app_units = {}
        for name, vm in data['apps'].items():
            if vm in running and UNIT.fullmatch(name + '.service'):
                app_units.setdefault(vm, []).append(name + '.service')
        def inspect_guest(vm):
            g = self.guest_read(vm)
            if data['records'][vm]['managed'] and not g['secrets_mounted']:
                raise Refused('Managed secrets are not mounted at baseline')
            applications, dependencies, unknown = [], [], []
            for unit in g['running']:
                app = unit in app_units.get(vm, []) or matched(unit, self.c['application_units'])
                dependency = matched(unit, self.c['dependency_units'])
                if protected(unit):
                    if app or dependency:
                        raise Refused('Protected guest unit cannot be classified for stop')
                elif app and dependency:
                    raise Refused('A unit is both writer and dependency')
                elif dependency:
                    dependencies.append(unit)
                elif app:
                    applications.append(unit)
                elif not matched(unit, self.c['keep_guest_units']):
                    unknown.append(unit)
            if unknown:
                raise Refused('Unclassified active guest services in ' + vm + ': ' + ', '.join(unknown))
            observations = self.unit_observations(vm, applications + dependencies)
            if any(observations[u]['UnitFileState'] != 'enabled' for u in applications):
                raise Refused('Application units must be boot-enabled; manual/transient jobs need a separate plan')
            self.dependencies_enabled(vm, dependencies, observations)
            g.update(applications=applications, dependencies=dependencies)
            g['unit_observations'] = observations
            return vm, g
        # Bounded parallel reads keep fleet planning inside its SSH deadline.
        # Mutating maintenance phases remain serialized under the host lock.
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            data['guests'] = dict(pool.map(inspect_guest, sorted(running)))
        for hook in self.c['backup_hooks'] + self.c['readiness_probes']:
            self.resolve(hook, data)
        return data

    def dependencies_enabled(self, vm, units, observations):
        for unit in units:
            if observations[unit]['UnitFileState'] == 'enabled':
                continue
            if observations[unit]['UnitFileState'] != 'enabled-runtime':
                raise Refused('Dependency unit has an unsupported or masked activation state: ' + unit)
            # Debian/Ubuntu generates enabled-runtime PostgreSQL instance links
            # from start.conf=auto under an enabled postgresql.service umbrella.
            # Do not generalize static/generated units into proof of autostart.
            match = re.fullmatch(r'postgresql@([0-9]+)-([A-Za-z0-9_-]+)\.service', unit)
            if not match:
                raise Refused('Dependency unit is not boot-enabled: ' + unit)
            path = '/etc/postgresql/' + match[1] + '/' + match[2] + '/start.conf'
            command = ('test "$(systemctl is-enabled postgresql.service)" = enabled && '
                       "grep -Eq '^[[:space:]]*auto([[:space:]]*(#.*)?)?$' " + shlex.quote(path))
            self.guest_exec(vm, command, 20)

    def resolve(self, hook, baseline):
        vm = hook.get('vm')
        if 'app' in hook:
            vm = baseline['apps'].get(hook['app'])
            if not vm:
                raise Refused('Configured app selector does not resolve')
        if vm is not None and vm not in baseline['vms']:
            raise Refused('Hook/probe targets a guest outside this run')
        return vm

    def probes(self, baseline, phase=None):
        for p in self.c['readiness_probes']:
            if phase and p.get('phase', 'dependencies') != phase:
                continue
            vm = self.resolve(p, baseline)
            out = self.guest_exec(vm, shlex.join(p['argv']), 20) if vm else run(p['argv'], 25)
            if 'stdout_pattern' in p and not re.search(p['stdout_pattern'], out):
                raise Refused('Readiness probe failed: ' + p['name'])

    @contextlib.contextmanager
    def locked(self, request, create=False):
        if request.get('execute') is not True:
            raise Refused('This action requires --execute')
        run_id = str(uuid.UUID(request['run_id']))
        token = request['token']
        if not isinstance(token, str) or not re.fullmatch(r'[0-9a-f]{64}', token):
            raise Refused('Invalid maintenance ownership token')
        if self.ops.is_symlink():
            raise Refused('Unsafe maintenance directory')
        self.ops.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.ops.stat()
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise Refused('Maintenance directory must be private and owned by this operator')
        lock_path = self.ops/'operation.lock'
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Refused('Another maintenance operation is still executing') from None
            lease_path = self.ops/'active.json'
            owner = hashlib.sha256(token.encode()).hexdigest()
            lease = json.loads(lease_path.read_text()) if lease_path.exists() else None
            if lease and (lease.get('run_id') != run_id or not hmac.compare_digest(lease.get('owner', ''), owner)):
                raise Refused('Another run owns maintenance; leases are never stolen automatically')
            directory = self.ops/run_id
            if directory.is_symlink():
                raise Refused('Unsafe run directory')
            directory.mkdir(mode=0o700, exist_ok=True)
            self.jpath = directory/'journal.json'
            if self.jpath.exists():
                self.j = json.loads(self.jpath.read_text())
                if self.j['config_hash'] != digest(self.c) or self.j['owner'] != owner:
                    raise Refused('Journal configuration/owner mismatch')
                if not lease:
                    raise Refused('This completed/released run cannot be reused')
            elif create:
                if lease:
                    raise Refused('Lease has no recoverable journal')
                self.j = {'schema': 1, 'run_id': run_id, 'owner': owner, 'config_hash': digest(self.c),
                          'phase': 'preparing', 'baseline': request['baseline'], 'stops': [],
                          'snapshots': {}, 'hooks': {}, 'created': time.time()}
                self.save()
                atomic_json(lease_path, {'run_id': run_id, 'owner': owner})
            else:
                raise Refused('No maintenance journal')
            yield
        finally:
            os.close(fd)

    def save(self):
        with self._mutex:
            atomic_json(self.jpath, self.j)

    def original_boot(self, include_guests=False):
        b = self.j['baseline']
        now = identity()
        if any(now[k] != b[k] for k in ('machine_id', 'boot_id')):
            raise Refused('Host incarnation changed; use verify, never replay old stops')
        if include_guests:
            for vm, old in b['guests'].items():
                if self.guest_read(vm)['boot_id'] != old['boot_id']:
                    raise Refused('Guest incarnation changed; old stop ownership is invalid')

    def stable_inventory(self):
        current = self.inspect()
        old = self.j['baseline']
        if set(current['vms']) != set(old['vms']):
            raise Refused('VM membership changed')
        for vm, prior in old['vms'].items():
            r = current['records'].get(vm, {})
            if r != old['records'][vm] or current['vms'][vm]['state'] != 'running':
                raise Refused('VM state, policy, root or escrow changed')
            if prior['iroh'] and current['vms'][vm]['iroh'] != prior['iroh']:
                raise Refused('Known guest identity changed')
        for unit, prior in old['host_units'].items():
            if current['host_units'][unit].get('UnitFileState') != prior.get('UnitFileState'):
                raise Refused('Host service enablement changed')

    def unit_change(self, vm, units, verb):
        if not units:
            return
        if any(not UNIT.fullmatch(u) or (vm and protected(u)) for u in units):
            raise Refused('Unsafe service mutation')
        if vm:
            command = shlex.join(['systemctl', verb, *units])
            self.guest_exec(vm, command)
        else:
            if not set(units) <= HOST_PAUSE:
                raise Refused('Unsafe host service mutation')
            run(['systemctl', verb, *units], self.c['command_timeout'], output=False)

    def unit_observations(self, vm, units):
        if not units:
            return {}
        fields = ['ActiveState', 'ActiveEnterTimestampMonotonic', 'InactiveEnterTimestampMonotonic',
                  'InvocationID', 'UnitFileState']
        if not vm:
            rows = {u: self.host_unit(u) for u in units}
            return {u: {k: rows[u].get(k, '') for k in fields} for u in units}
        command = 'set -eu; ' + '; '.join(
            'printf ' + shlex.quote('UNIT\t'+u+'\n') + '; ' +
            shlex.join(['systemctl', 'show', u, *[arg for field in fields for arg in ['-p', field]]])
            for u in units)
        out = self.guest_exec(vm, command, 20)
        rows, current = {}, None
        for line in out.splitlines():
            if line.startswith('UNIT\t'):
                current = line.split('\t', 1)[1]
                if current not in units or current in rows:
                    raise Refused('Unexpected unit-state record')
                rows[current] = {}
            else:
                key, sep, value = line.partition('=')
                if not sep or current is None or key not in fields:
                    raise Refused('Invalid unit-state field')
                rows[current][key] = value
        if set(rows) != set(units) or any(set(row) != set(fields) for row in rows.values()):
            raise Refused('Incomplete unit-state inspection')
        return rows

    def unit_states(self, vm, units):
        return {u: row['ActiveState'] for u, row in self.unit_observations(vm, units).items()}

    def stop(self, vm, units, kind):
        for unit in units:
            key = (vm, unit)
            prior = next((s for s in self.j['stops'] if (s['vm'], s['unit']) == key), None)
            if prior:
                if prior['state'] != 'stopped':
                    raise Refused('Uncertain stop requires reconciliation before retry')
                continue
            record = {'vm': vm, 'unit': unit, 'kind': kind, 'state': 'requested'}
            self.j['stops'].append(record)
            self.save()
            baseline = self.j['baseline']
            if vm:
                if self.guest_read(vm)['boot_id'] != baseline['guests'][vm]['boot_id']:
                    raise Refused('Guest rebooted before stop; refusing a new incarnation')
                planned = baseline['guests'][vm]['unit_observations'][unit]
            else:
                self.original_boot()
                planned = {k: baseline['host_units'][unit].get(k, '') for k in
                           ('ActiveState', 'ActiveEnterTimestampMonotonic', 'InactiveEnterTimestampMonotonic', 'InvocationID', 'UnitFileState')}
            before = self.unit_observations(vm, [unit])[unit]
            if before['ActiveState'] != 'active' or before != planned:
                raise Refused('Service changed since planning; stop ownership is uncertain')
            self.unit_change(vm, [unit], 'stop')
            observation = self.unit_observations(vm, [unit])[unit]
            if observation['ActiveState'] != 'inactive' or observation['ActiveEnterTimestampMonotonic'] != before['ActiveEnterTimestampMonotonic']:
                raise Refused('Service did not stop cleanly')
            record['state'] = 'stopped'
            record['observation'] = observation
            self.save()

    def backup_hooks(self):
        file_limit = self.c['max_logical_bytes'] // sum(len(h['exports']) for h in self.c['backup_hooks'])
        for hook in self.c['backup_hooks']:
            self.quiescent()
            name = hook['name']
            if name in self.j['hooks']:
                raise Refused('Interrupted backup hooks are never rerun blindly')
            vm = self.resolve(hook, self.j['baseline'])
            root = (Path('/var/backups/mjolnir-maintenance')/self.j['run_id']/name) if vm else self.jpath.parent/('hook-'+name)
            substitutions = {'{run_dir}': str(root), '{guest_run_dir}': str(root)}
            argv = [a for a in hook['argv']]
            for marker, value in substitutions.items():
                argv = [a.replace(marker, value) for a in argv]
            self.j['hooks'][name] = {'state': 'requested', 'vm': vm, 'root': str(root)}
            self.save()
            started = time.time()
            if vm:
                quoted = shlex.quote(str(root))
                # POSIX shells use 512- or 1024-byte -f blocks. Choosing 1024
                # conservatively keeps either interpretation within the budget.
                self.guest_exec(vm, 'set -eu; umask 077; ulimit -f ' + str(file_limit // 1024) +
                                '; test ! -e ' + quoted +
                                '; test ! -L ' + quoted + '; mkdir -p ' + quoted + '; ' +
                                shlex.join(argv) + ' >/dev/null 2>&1')
                host_root = Path(self.c['btrfs_root'])/'@vms'/vm
                exports = [anchored(host_root, root.relative_to('/')/x) for x in hook['exports']]
            else:
                root.mkdir(mode=0o700)
                run(argv, self.c['command_timeout'], output=False, size_limit=file_limit)
                exports = [root/x for x in hook['exports']]
            for path in exports:
                if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= file_limit or path.stat().st_mtime < started - 2:
                    raise Refused('Backup export is absent, empty, stale or a symlink')
            self.j['hooks'][name].update(state='complete', exports=[str(p) for p in exports])
            self.save()

    def snapshots_and_archive(self):
        self.quiescent()
        root = Path(self.c['btrfs_root'])
        destination = root/'@snapshots'/('maintenance-'+self.j['run_id'])
        destination.mkdir(mode=0o700)
        selected = set()
        for vm in sorted(self.j['baseline']['vms']):
            self.guest_exec(vm, 'sync', self.c['sync_timeout'])
            source, dest = root/'@vms'/vm, destination/vm
            if dest.exists():
                raise Refused('Unrecognized existing snapshot; refusing to overwrite')
            run(['btrfs', 'subvolume', 'snapshot', '-r', str(source), str(dest)], output=False)
            if run(['btrfs', 'property', 'get', '-ts', str(dest), 'ro']).strip() != 'ro=true':
                raise Refused('Snapshot is not read-only')
            self.j['snapshots'][vm] = str(dest)
            self.save()
            for value in self.c['guest_backup_paths']:
                path = anchored(dest, value.lstrip('/'), allow_final_symlink=True)
                if path.exists() or path.is_symlink():
                    selected.add(path)
        self.quiescent()
        for value in self.c['host_backup_paths'] + [self.c['state_dir'], self.c['escrow_dir']]:
            path = absolute(value)
            if path == self.ops or path in self.ops.parents:
                raise Refused('Backup selection may not contain its own output directory')
            if not path.exists():
                raise Refused('A configured host backup path is missing')
            selected.add(path)
        for hook in self.j['hooks'].values():
            for raw in hook['exports']:
                p = Path(raw)
                if hook['vm']:
                    old_root = root/'@vms'/hook['vm']
                    p = Path(self.j['snapshots'][hook['vm']])/p.relative_to(old_root)
                selected.add(p)
        # No dereferencing: guest symlinks are archived as links, never read as
        # host paths. Only complete directory selections subsume children.
        paths = []
        for path in sorted(selected, key=lambda p: len(p.parts)):
            if not any(p in path.parents and not p.is_symlink() for p in paths):
                paths.append(path)
        logical = 0
        for path in paths:
            if path.is_symlink():
                continue
            if path.is_file():
                logical += path.stat().st_size
            else:
                for directory, dirs, files in os.walk(path, followlinks=False):
                    dirs[:] = [d for d in dirs if d not in ('node_modules', '.git', '.cache')]
                    for name in files:
                        p = Path(directory)/name
                        if not p.is_symlink() and p.is_file():
                            logical += p.stat().st_size
            if logical > self.c['max_logical_bytes']:
                raise Refused('Backup logical-size budget exceeded')
        listing = self.jpath.parent/'paths.nul'
        listing.write_bytes(b''.join(str(p.relative_to('/')).encode()+b'\0' for p in paths))
        archive = self.jpath.parent/'backup.tar.gz'
        self.capacity()
        run(['tar', '--sparse', '--exclude=*/node_modules', '--exclude=*/.git', '--exclude=*/.cache',
             '-czf', str(archive), '-C', '/', '--null', '-T', str(listing)],
            1800, output=False, size_limit=self.c['max_backup_bytes'])
        run(['gzip', '-t', str(archive)], 300, output=False)
        with archive.open('rb') as stream:
            sha = hashlib.file_digest(stream, 'sha256').hexdigest()
        self.j['archive'] = {'bytes': archive.stat().st_size, 'sha256': sha}
        self.quiescent()
        self.j['phase'] = 'export_ready'
        self.save()

    def prepare(self):
        if self.j['phase'] == 'export_ready':
            return self.j['archive']
        if self.j['phase'] != 'preparing':
            raise Refused('Preparation cannot reuse a resumed, failed or power-requested run')
        if self.j['stops'] or self.j['hooks'] or self.j['snapshots']:
            raise Refused('Interrupted preparation needs resume/reconciliation, then a fresh plan')
        self.original_boot()
        if time.time() - self.j['baseline']['time'] > self.c['plan_max_age']:
            raise Refused('Plan has expired')
        # Re-derive the read-only plan on the host; never trust edited client
        # classification lists as authority to leave a writer running.
        fresh = self.plan()
        prior = self.j['baseline']
        if digest({k:v for k,v in fresh.items() if k != 'time'}) != digest({k:v for k,v in prior.items() if k != 'time'}):
            raise Refused('Host/guest plan changed before preparation')
        self.probes(self.j['baseline'])
        b = self.j['baseline']
        try:
            for unit in self.c['pause_host_units']:
                if b['host_units'][unit].get('ActiveState') == 'active':
                    self.stop(None, [unit], 'ingress')
            for vm, before in b['guests'].items():
                self.stop(vm, before['applications'], 'application')
            self.backup_hooks()
            self.quiescent()
            for vm, before in b['guests'].items():
                self.stop(vm, before['dependencies'], 'dependency')
            self.snapshots_and_archive()
            return self.j['archive']
        except BaseException:
            try:
                self.resume()
            except BaseException:
                self.j['phase'] = 'resume_incomplete'
                self.save()
            raise

    def resume(self):
        if self.j['phase'] in ('action_requested', 'complete', 'resumed'):
            raise Refused('This run cannot replay old stops; verify after a power request')
        self.original_boot(include_guests=True)
        # Invalidate all power readiness before the first start, even on failure.
        self.j['phase'] = 'resuming'
        self.j.pop('export_receipt', None)
        self.save()
        failures = []
        for kind in ('dependency', 'application', 'ingress'):
            if kind == 'application':
                try:
                    self.probes(self.j['baseline'], 'dependencies')
                except Refused:
                    failures.append('dependency readiness')
            if failures and kind != 'dependency':
                break
            for stop in self.j['stops']:
                if stop['kind'] != kind:
                    continue
                try:
                    observation = self.unit_observations(stop['vm'], [stop['unit']])[stop['unit']]
                    if observation['ActiveState'] == 'active':
                        stop['state'] = 'restored'
                    elif stop['state'] == 'stopped' and observation == stop.get('observation'):
                        self.unit_change(stop['vm'], [stop['unit']], 'start')
                        if self.unit_states(stop['vm'], [stop['unit']])[stop['unit']] != 'active':
                            raise Refused('Service did not become active')
                        stop['state'] = 'restored'
                    else:
                        raise Refused('Uncertain inactive stop requires manual reconciliation')
                    self.save()
                except Refused:
                    failures.append(stop['unit'])
        if not failures:
            try:
                self.probes(self.j['baseline'])
            except Refused:
                failures.append('readiness')
        self.j['phase'] = 'resume_incomplete' if failures else 'resumed'
        self.save()
        if failures:
            raise Refused('Resume incomplete; inspect the private journal and reconcile uncertain stops')
        self.release()
        return {'phase': 'resumed'}

    def quiescent(self):
        groups = {}
        for stop in self.j['stops']:
            groups.setdefault(stop['vm'], []).append(stop)
        for vm, stops in groups.items():
            observations = self.unit_observations(vm, [s['unit'] for s in stops])
            for stop in stops:
                observation = observations[stop['unit']]
                if stop['state'] != 'stopped' or observation['ActiveState'] != 'inactive' or observation != stop.get('observation'):
                    raise Refused('Quiescence changed or a stop is uncertain')
        # A new/unclassified service is a writer too, even if it is absent from
        # the stop journal. Check the full set, including guests with no stops.
        for vm, before in self.j['baseline']['guests'].items():
            now = self.guest_read(vm)
            removed = {s['unit'] for s in self.j['stops'] if s['vm'] == vm and s['state'] == 'stopped'}
            if now['boot_id'] != before['boot_id'] or set(now['running']) != set(before['running']) - removed:
                raise Refused('Guest incarnation or active workload set changed during quiescence')
            if set(now['failed']) - set(before['failed']):
                raise Refused('New failed services appeared during quiescence')
            dependencies = before['dependencies']
            self.dependencies_enabled(vm, dependencies, self.unit_observations(vm, dependencies))

    def confirm(self, receipt):
        self.original_boot(include_guests=True)
        if self.j['phase'] != 'export_ready' or receipt != self.j.get('archive'):
            raise Refused('Off-host checksum receipt is missing or mismatched')
        self.stable_inventory()
        self.quiescent()
        self.j['export_receipt'] = receipt
        self.j['prepared_at'] = time.time()
        self.j['phase'] = 'prepared'
        self.save()
        return {'phase': 'prepared'}

    def power(self, action):
        if self.j['phase'] != 'prepared':
            raise Refused('A prepared, unresumed run is required')
        self.original_boot(include_guests=True)
        if time.time() - self.j.get('prepared_at', 0) > self.c['prepared_max_age']:
            raise Refused('Preparation has expired')
        self.stable_inventory()
        self.preflight()
        self.capacity(for_backup=False)
        if self.j.get('export_receipt') != self.j.get('archive') or set(self.j['snapshots']) != set(self.j['baseline']['vms']):
            raise Refused('Backup/snapshot evidence is incomplete')
        with (self.jpath.parent/'backup.tar.gz').open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != self.j['archive']['sha256']:
                raise Refused('The prepared archive changed')
        for path in self.j['snapshots'].values():
            if run(['btrfs', 'property', 'get', '-ts', path, 'ro']).strip() != 'ro=true':
                raise Refused('A recovery snapshot changed')
        if action not in ('reboot', 'poweroff'):
            raise Refused('Unsupported host action')
        self.stable_inventory()
        self.quiescent()
        self.j.update(phase='action_requested', action=action, action_time=time.time())
        self.save()
        # A timeout/disconnect/failed acknowledgement leaves action_requested.
        # It must never result in an automatic second dispatch or old-stop replay.
        run(['systemctl', action], 15, output=False)
        return {'phase': 'action_requested', 'action': action}

    def release(self):
        path = self.ops/'active.json'
        path.unlink()
        fd = os.open(self.ops, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def dispatch(request, host=None):
    c = config_defaults(request['config'])
    host = host or Host(c)
    action = request['action']
    if action == 'plan':
        return host.plan()
    if action == 'inspect':
        return host.inspect()
    if action == 'guest_read':
        return host.guest_read(request['vm'])
    if action == 'probes':
        host.probes(request['baseline'])
        return {'ready': True}
    if action == 'status':
        path = host.ops/str(uuid.UUID(request['run_id']))/'journal.json'
        j = json.loads(path.read_text())
        result = {k: j[k] for k in ('phase', 'archive', 'action', 'config_hash', 'verified_boot_id') if k in j}
        lease = host.ops/'active.json'
        result['lease_owned'] = lease.exists() and json.loads(lease.read_text()).get('run_id') == j['run_id']
        result['stopped_units'] = sum(s['state'] == 'stopped' for s in j['stops'])
        result['uncertain_stops'] = sum(s['state'] == 'requested' for s in j['stops'])
        result['snapshots'] = len(j['snapshots'])
        result['hooks'] = {name: h['state'] for name, h in j['hooks'].items()}
        return result
    if action == 'prepare' and request.get('execute') is True:
        now, before = identity(), request['baseline']
        if any(now[k] != before[k] for k in ('machine_id', 'boot_id')):
            raise Refused('The planned host incarnation changed before lease acquisition')
    with host.locked(request, create=action == 'prepare'):
        if action == 'prepare':
            return host.prepare()
        if action == 'confirm':
            return host.confirm(request['receipt'])
        if action == 'resume':
            return host.resume()
        if action == 'power':
            return host.power(request['power_action'])
        if action == 'stream':
            if host.j['phase'] not in ('export_ready', 'prepared'):
                raise Refused('No stable backup to export')
            with (host.jpath.parent/'backup.tar.gz').open('rb') as stream:
                shutil.copyfileobj(stream, sys.stdout.buffer)
            return None
        if action == 'complete':
            now = identity()
            b = host.j['baseline']
            if host.j['phase'] not in ('action_requested', 'complete') or now['machine_id'] != b['machine_id'] or now['boot_id'] == b['boot_id']:
                raise Refused('Completion requires the expected new host incarnation')
            if os.uname().release != c['expected_kernel'] or request.get('verification_ok') is not True:
                raise Refused('Recovery was not verified')
            if host.j['phase'] == 'complete' and host.j.get('verified_boot_id') != now['boot_id']:
                raise Refused('Completed receipt belongs to another host boot')
            host.j['phase'] = 'complete'
            host.j['verified_boot_id'] = now['boot_id']
            host.save()
            host.release()
            return {'phase': 'complete'}
        raise Refused('Unknown maintenance operation')


if __name__ == '__main__':
    os.umask(0o077)
    try:
        payload = json.load(sys.stdin)
        result = dispatch(payload)
        if payload['action'] != 'stream':
            print(json.dumps({'result': result}))
    except BaseException as exc:
        # Do not echo hook argv/output, database contents, tokens or environments.
        message = str(exc) if isinstance(exc, Refused) else type(exc).__name__
        print(json.dumps({'error': message}))
        sys.exit(1)
