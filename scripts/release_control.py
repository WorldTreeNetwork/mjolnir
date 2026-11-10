#!/usr/bin/env python3
"""Stage and activate versioned Mjolnir trees. Host-only, Python standard library."""
import argparse
import concurrent.futures
import contextlib
import fcntl
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time


class UnixHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect('/run/mjolnir/operator.sock')


def run(args, timeout=90):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        # Environment files and RPC output can contain credentials.
        raise RuntimeError('Command failed: ' + args[0])
    return result.stdout


def atomic_link(link, target):
    tmp = link.with_name(link.name + '.next-' + str(os.getpid()))
    try:
        tmp.symlink_to(target)
        os.replace(tmp, link)
    finally:
        tmp.unlink(missing_ok=True)


@contextlib.contextmanager
def activation_lock(directory):
    with (directory / 'activation.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def stage(releases, active, name):
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]{0,100}', name):
        raise ValueError('Invalid release name')
    releases.mkdir(parents=True, exist_ok=True)
    destination = releases / name
    destination.mkdir(mode=0o700)  # Never reuse a published or partial tree.
    if active.exists():
        active = active.resolve(strict=True)
        # Copies, never hardlinks: compilation must not mutate the active release.
        for part in ['bin', 'deps', '_build']:
            source = active / part
            if source.exists():
                shutil.copytree(source, destination / part, symlinks=True)
        # Preserve installed Rust helpers, not disposable cargo build/dependency state.
        native = active / 'native'
        for pattern in ['target/release/*', 'target/*/release/*',
                        '*/target/release/*', '*/target/*/release/*']:
            for target in native.glob(pattern):
                if target.is_file() and os.access(target, os.X_OK):
                    dest = destination / target.relative_to(active)
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(target, dest)
    return destination


class Host:
    def __init__(self, state, active):
        self.state = state
        self.active = active

    def api(self, method, path, payload=None):
        connection = UnixHTTP('operator', timeout=35)
        try:
            connection.request(method, path, json.dumps(payload) if payload else None,
                               {'Content-Type': 'application/json'})
            response = connection.getresponse()
            body = response.read(2_000_000)
            if response.status != 200:
                raise RuntimeError('Operator API failed: ' + path)
            return json.loads(body)
        finally:
            connection.close()

    def health(self):
        return self.api('GET', '/api/health')['release']

    def processes(self):
        result = {}
        for proc in Path('/proc').iterdir():
            if not proc.name.isdigit():
                continue
            try:
                if (proc / 'comm').read_text().strip() != 'cloud-hyperviso':
                    continue
                args = (proc / 'cmdline').read_bytes().decode().split('\0')
                vm = Path(args[args.index('--api-socket') + 1]).stem
                result[vm] = int(proc.name)
            except (FileNotFoundError, ProcessLookupError):
                continue
        return result

    def guests(self, ids):
        command = ("printf 'BOOT='; cat /proc/sys/kernel/random/boot_id; "
                   "printf 'AGENT='; systemctl is-active mjolnir-agent 2>/dev/null || true; "
                   "printf 'SECRETS='; if mountpoint -q /secrets; then echo yes; else echo no; fi")
        def check(vm):
            body = self.api('POST', '/api/vms/' + vm + '/exec', {'command': command})
            fields = dict(line.split('=', 1) for line in body.get('output', '').splitlines() if '=' in line)
            if not fields.get('BOOT') or fields.get('AGENT') != 'active':
                raise RuntimeError('Guest not ready: ' + vm)
            return vm, fields
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            return dict(pool.map(check, sorted(ids)))

    def public_status(self):
        config = Path('/etc/mjolnir/release-checks.json')
        urls = json.loads(config.read_text()).get('urls', []) if config.exists() else []
        def probe(url):
            if not url.startswith('https://') or any(c.isspace() for c in url):
                raise ValueError('Release checks require HTTPS URLs')
            result = subprocess.run(['curl', '--silent', '--output', '/dev/null', '--max-time', '8',
                                     '--write-out', '%{http_code}', url], capture_output=True, text=True, timeout=12)
            return url, result.stdout.strip() if result.returncode == 0 else '000'
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            return dict(pool.map(probe, urls))

    def snapshot(self):
        unit = run(['systemctl', 'show', 'mjolnir', '-p', 'ExecStart', '--value'])
        if 'path=/opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir ;' not in unit:
            raise RuntimeError('Systemd must select the stable /opt/mjolnir release path')
        processes = self.processes()
        return {'host_boot': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                'processes': processes, 'guests': self.guests(processes), 'release': self.health(),
                'http': self.public_status()}

    def ready(self, expected, before, candidate):
        if self.health() != expected:
            raise RuntimeError('Release health mismatch')
        if Path('/proc/sys/kernel/random/boot_id').read_text().strip() != before['host_boot']:
            raise RuntimeError('Host boot changed')
        current = self.processes()
        if current != before['processes']:
            raise RuntimeError('VM process set changed')
        if self.guests(current) != before['guests']:
            raise RuntimeError('Guest boot, agent or secret mount changed')
        http = self.public_status()
        for url, status in before.get('http', {}).items():
            if status != '000' and int(status) < 500 and http.get(url) != status:
                raise RuntimeError('Public endpoint regression: ' + url)
        run(['pg_isready', '-h', '10.200.0.1', '-p', '5432'], timeout=10)
        self.verify_runtime(candidate)

    def verify_runtime(self, candidate):
        # Check every packaged application version and code root, not just a health stamp.
        script = 'expected_root = ' + json.dumps(str(candidate / '_build/prod/rel/mjolnir')) + '\n' + '''true = Path.expand(System.get_env("RELEASE_ROOT")) == expected_root
root = Path.join(expected_root, "lib")
checks = Enum.map(Path.wildcard(Path.join(root, "*")), fn dir ->
  [app, version] = Regex.run(~r/^(.*)-([0-9].*)$/, Path.basename(dir), capture: :all_but_first)
  actual = Application.spec(String.to_atom(app), :vsn)
  {app, (is_list(actual) and to_string(actual) == version) or (app == "iex" and actual == nil)}
end)
true = Enum.all?(checks, &elem(&1, 1))
true = File.dir?(Path.join(expected_root, "erts-" <> to_string(:erlang.system_info(:version))))
true = String.starts_with?(to_string(:code.which(Mjolnir.Release)), Path.expand(root) <> "/")
IO.puts("RELEASE_VERIFIED=" <> System.version())
'''
        check = self.state / 'verify-runtime.exs'
        check.write_text(script)
        import shlex
        expression = 'Code.eval_file(' + json.dumps(str(check)) + ')'
        shell = 'set -a; . /etc/mjolnir/env; set +a; unset RELEASE_ROOT; exec ' + shlex.join([
            str(candidate / '_build/prod/rel/mjolnir/bin/mjolnir'), 'rpc', expression])
        output = run(['bash', '-c', shell])
        if 'RELEASE_VERIFIED=' not in output:
            raise RuntimeError('Live dependency verification failed')

    def quiesce(self):
        query = ("SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' "
                 "AND pid<>pg_backend_pid() AND xact_start IS NOT NULL")
        for _ in range(60):
            if run(['psql', '-X', '-h', '/run/mjolnir', '-U', 'mjolnir_admin', '-d', 'postgres',
                    '-At', '-c', query], timeout=10).strip() == '0':
                return
            time.sleep(1)
        raise RuntimeError('Database transactions did not quiesce')

    def install_unit(self, candidate):
        destination = Path('/etc/systemd/system/mjolnir.service')
        shutil.copy2(destination, self.state / 'mjolnir.service.previous')
        temporary = destination.with_suffix('.service.next')
        shutil.copyfile(candidate / 'systemd/mjolnir.service', temporary)
        temporary.chmod(0o644)
        os.replace(temporary, destination)
        run(['systemctl', 'daemon-reload'])

    def restore_unit(self):
        backup = self.state / 'mjolnir.service.previous'
        if backup.exists():
            shutil.copyfile(backup, '/etc/systemd/system/mjolnir.service')
            run(['systemctl', 'daemon-reload'])

    def restart(self):
        run(['systemctl', 'reset-failed', 'mjolnir'])
        run(['systemctl', 'restart', 'mjolnir'])

    def wait_ready(self, expected, before, candidate):
        deadline = time.monotonic() + 300
        error = None
        for _ in range(24):
            try:
                self.ready(expected, before, candidate)
                return
            except Exception as exc:
                error = exc
                if time.monotonic() >= deadline:
                    break
                time.sleep(3)
        raise RuntimeError('Release verification failed') from error


def activate(candidate, active, releases, state, host):
    candidate = candidate.resolve(strict=True)
    if candidate.parent != releases.resolve(strict=True):
        raise ValueError('Candidate must be a direct versioned release directory')
    if not active.is_symlink():
        raise ValueError('Active path must already be a symlink; migrate legacy installs first')
    previous = active.resolve(strict=True)
    binary = candidate / '_build/prod/rel/mjolnir/bin/mjolnir'
    stamp = candidate / 'priv/release_id'
    if not binary.is_file() or not os.access(binary, os.X_OK) or not stamp.is_file():
        raise ValueError('Candidate is not a built release')
    expected = stamp.read_text().strip()
    if not expected:
        raise ValueError('Empty release stamp')
    before = host.snapshot()  # Includes working guest exec before stopping anything.
    journal = {'candidate': str(candidate), 'previous': str(previous), 'before': before}
    def record(phase):
        journal['phase'] = phase
        temporary = state / 'activation.json.tmp'
        temporary.write_text(json.dumps(journal, indent=2) + '\n')
        os.replace(temporary, state / 'activation.json')
    record('preflight')
    host.quiesce()
    atomic_link(active, candidate)
    try:
        record('switched')
        host.install_unit(candidate)
        host.restart()
        host.wait_ready(expected, before, candidate)
        record('verified')
    except BaseException as exc:
        journal['failure'] = type(exc).__name__
        atomic_link(active, previous)
        record('rollback_requested')
        host.restore_unit()
        host.restart()
        host.wait_ready(before['release'], before, previous)
        record('rolled_back')
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['stage', 'activate'])
    parser.add_argument('value', help='New unique release name, or candidate directory')
    parser.add_argument('--active', type=Path, default=Path('/opt/mjolnir'))
    parser.add_argument('--releases', type=Path, default=Path('/opt/mjolnir-releases'))
    args = parser.parse_args()
    os.umask(0o077)
    # Builds use unique trees; activation alone is serialized across deployments.
    if args.operation == 'stage':
        print(stage(args.releases, args.active, args.value))
    else:
        state = Path('/var/lib/mjolnir/releases') / (str(time.time_ns()) + '-' + str(os.getpid()))
        state.mkdir(parents=True, mode=0o700)
        with activation_lock(state.parent):
            activate(Path(args.value), args.active, args.releases, state, Host(state, args.active))
        print('Release verified; evidence: ' + str(state))


if __name__ == '__main__':
    main()
