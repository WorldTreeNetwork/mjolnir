#!/usr/bin/env python3
"""Filesystem, activation failure, and actual deploy.sh orchestration regressions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release_control', Path(__file__).with_name('release_control.py'))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
REPO = Path(__file__).resolve().parent.parent


class FakeHost:
    def __init__(self, active, fail=None):
        self.active = active
        self.fail = fail
        self.restarts = []
        self.verifies = []

    def snapshot(self):
        if self.fail == 'baseline':
            raise RuntimeError('guest unavailable before activation')
        return {'release': 'old', 'processes': {'guest': 123}, 'guests': {'guest': {'BOOT': 'same'}}}

    def quiesce(self):
        if self.fail == 'transaction':
            raise RuntimeError('active database transaction')

    def install_unit(self, candidate):
        pass

    def restore_unit(self):
        pass

    def restart(self):
        self.restarts.append(self.active.resolve().name)
        if self.fail == 'restart' and len(self.restarts) == 1:
            raise RuntimeError('candidate did not start')

    def wait_ready(self, expected, before, candidate):
        self.verifies.append(expected)
        if expected == 'new' and self.fail in ['health', 'pid', 'boot', 'mount', 'dependency']:
            raise RuntimeError(self.fail)
        if self.fail == 'rollback' or (self.fail == 'baseline-mismatch' and expected == 'old'):
            raise RuntimeError('rollback unavailable')


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.releases = self.base / 'releases'
        self.releases.mkdir()
        self.old = self.make_release('old')
        self.new = self.make_release('new')
        self.active = self.base / 'current'
        self.active.symlink_to(self.old)
        self.state = self.base / 'state'
        self.state.mkdir()

    def make_release(self, name):
        root = self.releases / name
        binary = root / '_build/prod/rel/mjolnir/bin/mjolnir'
        binary.parent.mkdir(parents=True)
        binary.write_text('#!/bin/sh\nexit 0\n')
        binary.chmod(0o755)
        (root / 'priv').mkdir()
        (root / 'priv/release_id').write_text(name)
        return root

    def activate(self, fail=None, candidate=None):
        host = FakeHost(self.active, fail)
        release.activate(candidate or self.new, self.active, self.releases, self.state, host)
        return host

    def test_success_changes_link_then_restarts_and_verifies(self):
        host = self.activate()
        self.assertEqual(self.active.resolve(), self.new)
        self.assertEqual(host.restarts, ['new'])
        self.assertEqual(json.loads((self.state / 'activation.json').read_text())['phase'], 'verified')

    def test_all_candidate_failures_restore_original_link_and_verify_rollback(self):
        for failure in ['restart', 'health', 'pid', 'boot', 'mount', 'dependency']:
            with self.subTest(failure=failure):
                release.atomic_link(self.active, self.old)
                host = FakeHost(self.active, failure)
                with self.assertRaises(RuntimeError):
                    release.activate(self.new, self.active, self.releases, self.state, host)
                self.assertEqual(self.active.resolve(), self.old)
                self.assertEqual(host.restarts, ['new', 'old'])
                self.assertEqual(host.verifies[-1], 'old')
                self.assertEqual(json.loads((self.state / 'activation.json').read_text())['phase'], 'rolled_back')

    def test_bad_baseline_or_active_transaction_never_switches_or_restarts(self):
        for failure in ['baseline', 'transaction']:
            host = FakeHost(self.active, failure)
            with self.assertRaises(RuntimeError):
                release.activate(self.new, self.active, self.releases, self.state, host)
            self.assertEqual(self.active.resolve(), self.old)
            self.assertEqual(host.restarts, [])

    def test_rollback_failure_remains_explicit_and_keeps_old_target(self):
        with self.assertRaises(RuntimeError):
            self.activate('rollback')
        self.assertEqual(self.active.resolve(), self.old)
        self.assertEqual(json.loads((self.state / 'activation.json').read_text())['phase'], 'rollback_requested')

    def test_refuses_non_versioned_target(self):
        with self.assertRaises(ValueError):
            self.activate(candidate=self.base)
        self.assertEqual(self.active.resolve(), self.old)

    def test_refuses_legacy_directory(self):
        self.active.unlink()
        self.active.mkdir()
        with self.assertRaises(ValueError):
            self.activate()

    def test_refuses_missing_binary_or_stamp(self):
        (self.new / 'priv/release_id').unlink()
        with self.assertRaises(ValueError):
            self.activate()
        self.assertEqual(self.active.resolve(), self.old)

    def test_activation_lock_refuses_second_writer(self):
        with release.activation_lock(self.state):
            with self.assertRaises(BlockingIOError):
                with release.activation_lock(self.state):
                    self.fail('Concurrent activation acquired the lock')
        with release.activation_lock(self.state):
            pass

    def test_stage_is_a_copy_not_a_hardlink_and_never_overwrites_existing(self):
        (self.old / 'deps').mkdir()
        original = self.old / 'deps/dep'
        original.write_text('old')
        staged = release.stage(self.releases, self.active, 'staged')
        (staged / 'deps/dep').write_text('new')
        self.assertEqual(original.read_text(), 'old')
        self.assertNotEqual(original.stat().st_ino, (staged / 'deps/dep').stat().st_ino)
        with self.assertRaises(FileExistsError):
            release.stage(self.releases, self.active, 'staged')
        for invalid in ['../escape', '/absolute', 'two words', "x';bad"]:
            with self.assertRaises(ValueError):
                release.stage(self.releases, self.active, invalid)

    def test_stage_keeps_installed_helpers_without_copying_cargo_dependency_cache(self):
        for relative in ['bin/helper', 'native/target/release/mjolnir-agent', 'native/target/release/deps/huge']:
            path = self.old / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('executable')
            path.chmod(0o755)
        staged = release.stage(self.releases, self.active, 'staged')
        self.assertTrue((staged / 'bin/helper').exists())
        self.assertTrue((staged / 'native/target/release/mjolnir-agent').exists())
        self.assertFalse((staged / 'native/target/release/deps/huge').exists())

    def test_new_vms_do_not_invalidate_preserved_baseline(self):
        host = release.Host(self.state, self.active)
        before = {'host_boot': 'host', 'processes': {'vm': 123}, 'guests': {'vm': {'BOOT': 'same'}}}
        with patch.object(host, 'health', return_value='new'), \
             patch.object(host, 'processes', return_value={'vm': 123, 'new-vm': 456}), \
             patch.object(host, 'guests', return_value=before['guests']) as guests, \
             patch.object(host, 'public_status', return_value={}), \
             patch.object(host, 'verify_runtime'), patch.object(Path, 'read_text', return_value='host'), \
             patch.object(release, 'run'):
            host.ready('new', before, self.new)
            guests.assert_called_once_with(before['processes'])

    def test_public_endpoint_regression_fails_before_runtime_rpc(self):
        host = release.Host(self.state, self.active)
        before = {'host_boot': 'host', 'processes': {}, 'guests': {},
                  'http': {'https://example.com/': '200'}}
        with patch.object(host, 'health', return_value='new'), \
             patch.object(host, 'processes', return_value={}), \
             patch.object(host, 'guests', return_value={}), \
             patch.object(host, 'public_status', return_value={'https://example.com/': '502'}), \
             patch.object(Path, 'read_text', return_value='host'), patch.object(release, 'run') as command:
            with self.assertRaisesRegex(RuntimeError, 'Public endpoint regression'):
                host.ready('new', before, self.new)
            command.assert_not_called()

    def test_runtime_verifier_rejects_guest_pid_boot_mount_and_package_regressions(self):
        host = release.Host(self.state, self.active)
        before = {'processes': {'vm': 123}, 'host_boot': 'host',
                  'guests': {'vm': {'BOOT': 'boot', 'SECRETS': 'yes'}}}
        for case in ['health', 'pid', 'host', 'boot', 'mount', 'dependency']:
            with self.subTest(case=case), patch.object(host, 'health', return_value='wrong' if case == 'health' else 'new'), \
                 patch.object(host, 'processes', return_value={'vm': 456 if case == 'pid' else 123}), \
                 patch.object(host, 'guests', return_value={'vm': {'BOOT': 'wrong' if case == 'boot' else 'boot', 'SECRETS': 'no' if case == 'mount' else 'yes'}}), \
                 patch.object(Path, 'read_text', return_value='wrong' if case == 'host' else 'host'), \
                 patch.object(release, 'run', side_effect=lambda args, **kw: '' if args[0] == 'pg_isready' else 'RPC_FAILED'):
                with self.assertRaises(RuntimeError):
                    host.ready('new', before, self.new)


class DeployProcedureTests(unittest.TestCase):
    def invoke(self, flags=(), failure=''):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        calls = base / 'calls'
        calls.write_text('')
        # Execute the real deploy.sh; fake only remote transport/commands.
        stub = '''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['CALLS'],'a') as f:f.write(json.dumps([os.path.basename(sys.argv[0]),*sys.argv[1:]])+'\\n')
command=' '.join(sys.argv[1:])
fail=os.environ.get('FAIL','')
if (fail=='layout' and 'test -L /opt/mjolnir' in command) or (fail=='build' and 'scripts/build-release.sh' in command) or (fail=='activation' and 'scripts/cutover-release.sh' in command):sys.exit(1)
if os.path.basename(sys.argv[0])=='git':print('0123456789ab')
if 'python3 - stage' in command:sys.stdin.read()
'''
        for name in ['ssh', 'rsync', 'git']:
            path = base / name
            path.write_text(stub)
            path.chmod(0o755)
        env = dict(os.environ, PATH=str(base) + os.pathsep + os.environ['PATH'], CALLS=str(calls), FAIL=failure)
        result = subprocess.run(['bash', str(REPO / 'scripts/deploy.sh'), 'fixture', *flags],
                                env=env, capture_output=True, text=True)
        return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_full_deploy_builds_before_activation_then_installs_sidecars(self):
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [' '.join(call) for call in calls]
        build = next(i for i,c in enumerate(commands) if 'scripts/build-release.sh' in c)
        activate = next(i for i,c in enumerate(commands) if 'scripts/cutover-release.sh' in c)
        install = next(i for i,c in enumerate(commands) if 'install-blob-door.sh' in c)
        self.assertLess(build, activate)
        self.assertLess(activate, install)
        sync = next(call for call in calls if call[0] == 'rsync')
        self.assertIn(':/opt/mjolnir-releases/', sync[-1])
        self.assertNotIn(':/opt/mjolnir/', sync[-1])

    def test_gateway_only_never_builds_or_activates_controller_or_sidecars(self):
        result, calls = self.invoke(['--gateway'])
        self.assertEqual(result.returncode, 0, result.stderr)
        text = str(calls)
        for unexpected in ['build-release.sh', 'cutover-release.sh', 'install-blob-door.sh', 'install-redis.sh']:
            self.assertNotIn(unexpected, text)
        self.assertIn('systemctl restart mjolnir-gateway', text)

    def test_app_only_uses_same_build_activation_without_sidecars(self):
        result, calls = self.invoke(['--app-only'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('build-release.sh', str(calls))
        self.assertIn('cutover-release.sh', str(calls))
        self.assertNotIn('install-blob-door.sh', str(calls))

    def test_gateway_full_builds_and_activates_controller(self):
        result, calls = self.invoke(['--gateway', '--full'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('cutover-release.sh', str(calls))
        self.assertIn('systemctl restart mjolnir-gateway', str(calls))

    def test_failed_build_never_activates_or_installs(self):
        result, calls = self.invoke(failure='build')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('cutover-release.sh', str(calls))
        self.assertNotIn('install-blob-door.sh', str(calls))

    def test_failed_activation_stops_deploy_before_sidecars(self):
        result, calls = self.invoke(failure='activation')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('install-blob-door.sh', str(calls))

    def test_legacy_layout_fails_before_rsync(self):
        result, calls = self.invoke(failure='layout')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('rsync', str(calls))

    def test_ambiguous_options_fail_before_ssh(self):
        for flags in [['--gateway', '--agent'], ['--app-only', '--gateway'], ['--unknown']]:
            result, calls = self.invoke(flags)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, [])


class BuildProcedureTests(unittest.TestCase):
    def test_build_and_audit_failures_prevent_packaging(self):
        for failure in ['', 'deps.get', 'compile', 'findings']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                (base / 'priv').mkdir()
                stub = base / 'mise'
                stub.write_text('''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
with open(os.environ['BUILD_CALLS'],'a') as f:f.write(' '.join(args)+'\\n')
fail=os.environ['BUILD_FAIL']
if fail and fail in args:sys.exit(1)
if 'hex.audit' in args:
 with open('.release-audit.json','w') as f:json.dump({'runs':[{'results':[{'ruleId':'retired'}] if fail=='findings' else []}]},f)
''')
                stub.chmod(0o755)
                calls = base / 'calls'
                env = dict(os.environ, PATH=str(base) + os.pathsep + os.environ['PATH'],
                           BUILD_CALLS=str(calls), BUILD_FAIL=failure, MJOLNIR_BUILD_CACHE=str(base / 'cache'))
                result = subprocess.run(['bash', str(REPO / 'scripts/build-release.sh'), str(base), 'new'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, failure == '', result.stderr)
                self.assertEqual('mix release' in calls.read_text(), failure == '')


if __name__ == '__main__':
    unittest.main()
