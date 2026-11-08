#!/usr/bin/env python3
"""Offline safety fixtures. No SSH, systemd mutation, database or live VM access."""
import contextlib
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import uuid

import controlled_reboot as cli
import maintenance_host as host


def config():
    return host.config_defaults({
        'expected_kernel': '6.8.0-147-generic',
        'application_units': ['web.service'], 'dependency_units': ['db.service'],
        'backup_hooks': [{'name': 'database', 'argv': ['/fixture-backup'], 'exports': ['db.sql.gz']}],
        'readiness_probes': [{'name': 'database-ready', 'argv': ['/fixture-ready']}],
        'http_urls': ['https://example.invalid/health'], 'max_backup_bytes': 1024**2,
        'max_logical_bytes': 1024**2, 'reserve_bytes': 1,
    })


def observation(state='active', stamp='10', enabled='enabled'):
    return {'ActiveState': state, 'ActiveEnterTimestampMonotonic': stamp,
            'InactiveEnterTimestampMonotonic': '5' if state == 'active' else '20',
            'InvocationID': 'invocation-' + stamp, 'UnitFileState': enabled}


class FixtureHost(host.Host):
    def __init__(self, c, ops):
        super().__init__(c, ops)
        self.host_boot = 'host-before'
        self.guest_boot = str(uuid.uuid4())
        self.machine = 'fixture-machine'
        self.kernel = '6.8.0-124-generic'
        self.events = []
        self.fail_backup = False
        self.fail_probe = False
        self.unknown_unit = False
        self.fail_start = False
        self.obs = {(None, 'mjolnir-gateway.service'): observation(),
                    ('vmA', 'web.service'): observation(), ('vmA', 'db.service'): observation()}

    def inspect(self):
        units = {u: {'ActiveState': 'active', 'UnitFileState': 'enabled', 'LoadState': 'loaded',
                     **self.obs.get((None, u), observation())}
                 for u in set(self.c['host_services'] + self.c['pause_host_units'])}
        return {'machine_id': self.machine, 'boot_id': self.host_boot, 'kernel': self.kernel,
                'vms': {'vmA': {'state': 'running', 'iroh': 'preserved-node'}},
                'records': {'vmA': {'intent': 'running', 'restart': 'always', 'managed': True,
                                    'root_exists': True, 'root_uuid': 'original-subvolume',
                                    'escrow_exists': True, 'spawn_hash': 'fixed'}},
                'apps': {'web': 'vmA'}, 'host_units': units, 'time': time.time()}

    def preflight(self):
        return {'selected_kernel': self.c['expected_kernel'], 'fallback_kernel': '6.8.0-124-generic'}

    def capacity(self, for_backup=True):
        return None

    def guest_read(self, vm):
        running = ['mjolnir-agent.service'] + [u for (v, u), o in self.obs.items()
                                                if v == vm and o['ActiveState'] == 'active']
        if self.unknown_unit:
            running.append('unclassified-writer.service')
        return {'running': running, 'failed': [], 'boot_id': self.guest_boot, 'secrets_mounted': True}

    def unit_observations(self, vm, units):
        return {u: copy.deepcopy(self.obs[(vm, u)]) for u in units}

    def unit_change(self, vm, units, verb):
        for unit in units:
            self.events.append((verb, vm, unit))
            if verb == 'start' and self.fail_start:
                raise host.Refused('fixture start failure')
            previous = self.obs[(vm, unit)]
            self.obs[(vm, unit)] = observation('active' if verb == 'start' else 'inactive',
                                               str(int(previous['ActiveEnterTimestampMonotonic']) + (1 if verb == 'start' else 0)))

    def probes(self, baseline, phase=None):
        self.events.append(('probe', phase))
        if self.fail_probe:
            raise host.Refused('fixture readiness failure')

    def backup_hooks(self):
        self.quiescent()
        self.events.append(('backup',))
        if self.fail_backup:
            raise host.Refused('fixture failed backup')
        self.j['hooks']['database'] = {'state': 'complete'}
        self.save()

    def snapshots_and_archive(self):
        self.quiescent()
        p = self.jpath.parent/'backup.tar.gz'
        with tarfile.open(p, 'w:gz') as stream:
            data = b'fixture database/configuration recovery data'
            member = tarfile.TarInfo('fixture.sql')
            member.size = len(data)
            stream.addfile(member, io.BytesIO(data))
        with p.open('rb') as stream:
            sha = hashlib.file_digest(stream, 'sha256').hexdigest()
        self.j.update(phase='export_ready', snapshots={'vmA': '/fixture/snapshot'},
                      archive={'bytes': p.stat().st_size, 'sha256': sha})
        self.save()


class FakeRemote:
    def __init__(self, h):
        self.h = h
        self.calls = []
        self.corrupt_copy = False

    def request(self, action, **values):
        self.calls.append(action)
        values.pop('_timeout', None)
        return host.dispatch({'action': action, 'config': self.h.c, **values}, self.h)

    def download(self, path, receipt, **values):
        data = (self.h.jpath.parent/'backup.tar.gz').read_bytes()
        Path(path).write_bytes(bytes([data[0] ^ 1])+data[1:] if self.corrupt_copy else data)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.c = config()
        self.h = FixtureHost(self.c, self.root/'remote')
        self.identity = patch.object(host, 'identity', side_effect=lambda: {'machine_id': self.h.machine, 'boot_id': self.h.host_boot})
        self.identity.start(); self.addCleanup(self.identity.stop)
        self.baseline = self.h.plan()
        self.request = {'run_id': str(uuid.uuid4()), 'token': 'a'*64, 'execute': True,
                        'baseline': self.baseline}
        self.remote = FakeRemote(self.h)

    @contextlib.contextmanager
    def locked(self):
        with self.h.locked(self.request, create=True):
            yield

    def prepared(self):
        with self.locked():
            receipt = self.h.prepare()
            self.h.confirm(receipt)
        return receipt

    def fake_run(self, argv, *args, **kwargs):
        if argv[:3] == ['btrfs', 'property', 'get']:
            return 'ro=true\n'
        if argv[:1] == ['systemctl']:
            self.assertEqual(self.h.j['phase'], 'action_requested')
            on_disk = json.loads(self.h.jpath.read_text())
            self.assertEqual(on_disk['phase'], 'action_requested')
            self.h.events.append(('power', argv[1]))
            return ''
        self.fail('Unexpected command: ' + repr(argv))


class ContractTests(Fixture):
    def test_fleet_plan_reads_are_bounded_but_not_sequential(self):
        baseline=self.h.inspect();vms=['vm'+str(i) for i in range(8)]
        baseline['vms']={vm:{'state':'running','iroh':None} for vm in vms}
        record=baseline['records']['vmA']
        baseline['records']={vm:{**record,'root_uuid':'root-'+vm} for vm in vms};baseline['apps']={}
        lock=threading.Lock();counts={'active':0,'peak':0}
        def read(vm):
            with lock:counts['active']+=1;counts['peak']=max(counts['peak'],counts['active'])
            time.sleep(.02)
            with lock:counts['active']-=1
            return {'running':['mjolnir-agent.service','web.service','db.service'],'failed':[],
                    'boot_id':str(uuid.uuid5(uuid.NAMESPACE_DNS,vm)),'secrets_mounted':True}
        with patch.object(self.h,'inspect',return_value=baseline),patch.object(self.h,'guest_read',side_effect=read),patch.object(self.h,'unit_observations',side_effect=lambda vm,units:{u:observation() for u in units}):
            result=self.h.plan()
        self.assertEqual(len(result['guests']),8);self.assertGreaterEqual(counts['peak'],2);self.assertLessEqual(counts['peak'],4)

    def test_cli_mutations_need_execute_before_any_remote_access(self):
        for command in ['prepare', 'reboot', 'shutdown', 'resume']:
            with self.subTest(command=command), self.assertRaises(host.Refused):
                cli.main([command, 'fixture', '--run-dir', str(self.root/'missing')],
                         remote_factory=lambda *_: self.fail('transport must not be constructed'))

    def test_reconfiguration_cannot_be_silently_ignored_by_execution(self):
        with self.assertRaises(host.Refused):
            cli.main(['reboot','fixture','--run-dir',str(self.root/'missing'),'--config','changed.json','--execute'],
                     remote_factory=lambda *_: self.fail('transport must not be constructed'))

    def test_host_backup_capacity_failure_is_readonly(self):
        with patch.object(self.h,'capacity',side_effect=host.Refused('fixture full disk')):
            with self.assertRaises(host.Refused):self.h.plan()
        self.assertEqual(self.h.events,[])
        with patch.object(host.shutil,'disk_usage',return_value=SimpleNamespace(free=0)):
            real=host.Host(self.c,self.root)
            with self.assertRaises(host.Refused):real.capacity()

    def test_bad_target_and_hook_typos_are_rejected(self):
        for name in ['-oProxyCommand=x', 'host;echo secret', 'host name']:
            with self.subTest(name=name), self.assertRaises(host.Refused):
                cli.SSHRemote(name, self.c)
        c = config(); c['backup_hooks'][0]['app_name'] = 'typo'
        with self.assertRaises(host.Refused): host.config_defaults(c)

    def test_plan_does_not_pause_back_up_or_create_remote_journal(self):
        self.h.plan()
        self.assertEqual(self.h.events, [])
        self.assertFalse(self.h.ops.exists())

    def test_unknown_or_protected_workload_blocks_plan(self):
        self.h.unknown_unit = True
        with self.assertRaises(host.Refused): self.h.plan()
        self.h.unknown_unit = False
        self.h.c['application_units'].append('mjolnir-agent.service')
        with self.assertRaises(host.Refused): self.h.plan()
        self.assertEqual(self.h.events, [])

    def test_disabled_application_or_dependency_blocks_plan(self):
        for unit in ['web.service', 'db.service']:
            self.h.obs[('vmA', unit)]['UnitFileState'] = 'disabled'
            with self.assertRaises(host.Refused): self.h.plan()
            self.h.obs[('vmA', unit)]['UnitFileState'] = 'enabled'

    def test_postgresql_exception_never_accepts_masked_or_unknown_units(self):
        unit='postgresql@16-main.service'
        with patch.object(self.h,'guest_exec',return_value='') as execute:
            for state in ['masked','masked-runtime','disabled','static','generated','unknown']:
                with self.subTest(state=state),self.assertRaises(host.Refused):
                    self.h.dependencies_enabled('vmA',[unit],{unit:observation(enabled=state)})
            execute.assert_not_called()
            self.h.dependencies_enabled('vmA',[unit],{unit:observation(enabled='enabled-runtime')})
            self.assertEqual(execute.call_count,1)

    def test_changed_host_rejected_before_lease_creation(self):
        self.h.host_boot = 'new-host'
        with self.assertRaises(host.Refused):
            self.remote.request('prepare', **self.request)
        self.assertFalse(self.h.ops.exists())

    def test_owner_token_and_same_run_mutex(self):
        with self.locked():
            with self.assertRaises(host.Refused):
                with self.h.locked(self.request): pass
        other = {**self.request, 'token': 'b'*64}
        with self.assertRaises(host.Refused):
            with self.h.locked(other): pass

    def test_lease_not_stolen_by_another_run(self):
        with self.locked(): pass
        other = {**self.request, 'run_id': str(uuid.uuid4()), 'token': 'b'*64}
        with self.assertRaises(host.Refused):
            with self.h.locked(other, create=True): pass

    def test_archive_receipt_required_and_power_intent_durable(self):
        with self.locked():
            self.h.prepare()
            with patch.object(host, 'run', side_effect=self.fake_run):
                with self.assertRaises(host.Refused): self.h.power('reboot')
                self.h.confirm(self.h.j['archive'])
                self.h.power('reboot')
        self.assertEqual([x for x in self.h.events if x[0]=='power'], [('power', 'reboot')])

    def test_missing_snapshot_or_checksum_change_blocks_power(self):
        self.prepared()
        with self.h.locked(self.request), patch.object(host, 'run', side_effect=self.fake_run):
            self.h.j['snapshots'] = {}
            with self.assertRaises(host.Refused): self.h.power('reboot')
            self.h.j['snapshots'] = {'vmA':'/fixture/snapshot'}
            (self.h.jpath.parent/'backup.tar.gz').write_bytes(b'corrupt')
            with self.assertRaises(host.Refused): self.h.power('reboot')
        self.assertFalse(any(x[0]=='power' for x in self.h.events))

    def test_changed_activation_detected_even_if_service_stopped_again(self):
        self.prepared()
        with self.h.locked(self.request):
            self.h.obs[('vmA','web.service')] = observation('inactive','999')
            with self.assertRaises(host.Refused): self.h.quiescent()
        self.assertFalse(any(x[0]=='power' for x in self.h.events))

    def test_new_writer_in_guest_with_no_owned_stop_is_detected(self):
        self.prepared()
        self.h.unknown_unit = True
        with self.h.locked(self.request):
            with self.assertRaises(host.Refused): self.h.quiescent()

    def test_guest_boot_or_unit_incarnation_changed_before_stop(self):
        with self.locked():
            self.h.guest_boot = str(uuid.uuid4())
            with self.assertRaises(host.Refused): self.h.stop('vmA',['web.service'],'application')
            self.assertEqual(self.h.events, [])
        self.h.guest_boot = self.baseline['guests']['vmA']['boot_id']
        with self.h.locked(self.request):
            self.h.j['stops'] = []
            self.h.obs[('vmA','web.service')]['ActiveEnterTimestampMonotonic'] = '99'
            with self.assertRaises(host.Refused): self.h.stop('vmA',['web.service'],'application')
            self.assertEqual(self.h.events, [])

    def test_backup_failure_restores_only_owned_units(self):
        self.h.fail_backup = True
        with self.locked():
            with self.assertRaises(host.Refused): self.h.prepare()
            self.assertEqual(self.h.j['phase'],'resumed')
        started = {(x[1],x[2]) for x in self.h.events if x[0]=='start'}
        self.assertEqual(started,{('vmA','web.service'),(None,'mjolnir-gateway.service')})
        self.assertFalse((self.h.ops/'active.json').exists())

    def test_resume_invalidates_power_before_starts_and_dependencies_first(self):
        self.prepared()
        original = self.h.unit_change
        def inspect_start(vm, units, verb):
            if verb=='start': self.assertEqual(json.loads(self.h.jpath.read_text())['phase'],'resuming')
            return original(vm,units,verb)
        with self.h.locked(self.request), patch.object(self.h,'unit_change',side_effect=inspect_start):
            self.h.resume()
            self.assertEqual(self.h.j['phase'],'resumed')
            self.assertNotIn('export_receipt',self.h.j)
            with self.assertRaises(host.Refused): self.h.power('reboot')
        started=[x[2] for x in self.h.events if x[0]=='start']
        self.assertEqual(started,['db.service','web.service','mjolnir-gateway.service'])

    def test_uncertain_inactive_stop_is_never_claimed_or_started(self):
        with self.locked():
            self.h.j['stops']=[{'vm':'vmA','unit':'db.service','kind':'dependency','state':'requested'}]
            self.h.obs[('vmA','db.service')]=observation('inactive')
            with self.assertRaises(host.Refused): self.h.resume()
            self.assertEqual(self.h.j['phase'],'resume_incomplete')
        self.assertFalse(any(x[0]=='start' for x in self.h.events))

    def test_uncertain_active_stop_needs_no_start(self):
        with self.locked():
            self.h.j['stops']=[{'vm':'vmA','unit':'web.service','kind':'application','state':'requested'}]
            self.h.resume()
            self.assertEqual(self.h.j['phase'],'resumed')
        self.assertFalse(any(x[0]=='start' for x in self.h.events))

    def test_partial_resume_is_failure_and_retains_lease(self):
        self.prepared(); self.h.fail_start=True
        with self.h.locked(self.request):
            with self.assertRaises(host.Refused): self.h.resume()
            self.assertEqual(self.h.j['phase'],'resume_incomplete')
        self.assertTrue((self.h.ops/'active.json').exists())

    def test_resume_refuses_new_host_or_guest_boot(self):
        self.prepared()
        for change in ['host','guest']:
            with self.subTest(change=change), self.h.locked(self.request):
                if change=='host': self.h.host_boot='host-after'
                else: self.h.guest_boot=str(uuid.uuid4())
                with self.assertRaises(host.Refused): self.h.resume()
                self.h.host_boot=self.baseline['boot_id']
                self.h.guest_boot=self.baseline['guests']['vmA']['boot_id']
        self.assertFalse(any(x[0]=='start' for x in self.h.events))

    def test_backup_copy_corruption_prevents_confirm_and_resumes(self):
        m=cli.Maintenance('fixture',self.root/'local',self.remote,http=lambda _:200)
        m.plan(self.c); self.remote.corrupt_copy=True
        with self.assertRaises(host.Refused): m.prepare()
        self.assertNotIn('confirm',self.remote.calls)
        self.assertEqual(m.j['phase'],'resumed')
        self.assertNotIn('power',self.remote.calls)

    def test_good_offhost_archive_confirms_then_host_can_be_requested_once(self):
        m=cli.Maintenance('fixture',self.root/'local',self.remote,http=lambda _:200)
        m.plan(self.c); m.prepare()
        self.assertEqual(m.j['phase'],'prepared')
        with patch.object(host,'run',side_effect=self.fake_run): m.power('poweroff',1)
        with self.assertRaises(host.Refused): m.power('poweroff',1)
        self.assertEqual(self.remote.calls.count('power'),1)

    def test_deleted_or_changed_offhost_copy_after_prepare_blocks_power(self):
        for damage in ['delete','corrupt']:
            c=config();h=FixtureHost(c,self.root/('remote-'+damage));self.h=h
            remote=FakeRemote(h);m=cli.Maintenance('fixture',self.root/('local-'+damage),remote,http=lambda _:200)
            m.plan(c);m.prepare();archive=m.directory/'backup.tar.gz'
            if damage=='delete':archive.unlink()
            else:
                data=archive.read_bytes();archive.write_bytes(bytes([data[0]^1])+data[1:])
            with self.assertRaises(host.Refused):m.power('poweroff',1)
            self.assertNotIn('power',remote.calls);self.assertEqual(m.j['phase'],'resumed')

    def test_remote_resume_cannot_be_mistaken_for_prepared_authority(self):
        m=cli.Maintenance('fixture',self.root/'local',self.remote,http=lambda _:200);m.plan(self.c);m.prepare()
        with self.h.locked({**m.values(),'execute':True}):self.h.resume()
        self.remote.calls=[]
        with self.assertRaises(host.Refused):m.power('poweroff',1)
        self.assertEqual(m.j['phase'],'resumed');self.assertNotIn('power',self.remote.calls)

    def test_other_client_power_intent_does_not_cause_a_second_dispatch(self):
        m=cli.Maintenance('fixture',self.root/'local',self.remote,http=lambda _:200);m.plan(self.c);m.prepare()
        with self.h.locked({**m.values(),'execute':True}),patch.object(host,'run',side_effect=self.fake_run):self.h.power('reboot')
        self.remote.calls=[];clock=[0.0];m.clock=lambda:clock[0];m.sleep=lambda n:clock.__setitem__(0,clock[0]+n)
        with self.assertRaises(host.Refused):m.power('reboot',1)
        self.assertNotIn('power',self.remote.calls)
        self.assertEqual([x for x in self.h.events if x[0]=='power'],[('power','reboot')])

    def test_frozen_target_or_config_cannot_be_reused(self):
        m=cli.Maintenance('fixture',self.root/'local',self.remote,http=lambda _:200);m.plan(self.c)
        with self.assertRaises(host.Refused): cli.Maintenance('other',m.directory).load()
        data=json.loads((m.directory/'run.json').read_text());data['config']['expected_kernel']='6.8.0-999-generic'
        host.atomic_json(m.directory/'run.json',data)
        with self.assertRaises(host.Refused): cli.Maintenance('fixture',m.directory).load()

    def test_existing_artifacts_and_guest_symlink_escape_are_refused(self):
        existing=self.root/'existing';existing.mkdir()
        with self.assertRaises(host.Refused):cli.Maintenance('fixture',existing,self.remote).plan(self.c)
        guest=self.root/'guest';guest.mkdir();(guest/'var').symlink_to(self.root,target_is_directory=True)
        with self.assertRaises(host.Refused): host.anchored(guest,'var/private/secret')

    def test_client_baseline_edits_are_refused(self):
        m=cli.Maintenance('fixture',self.root/'local',self.remote,http=lambda _:200);m.plan(self.c)
        data=json.loads((m.directory/'run.json').read_text());data['baseline']['guests']['vmA']['applications']=[]
        host.atomic_json(m.directory/'run.json',data)
        with self.assertRaises(host.Refused):cli.Maintenance('fixture',m.directory).load()

    def test_server_rederives_plan_instead_of_trusting_client_classification(self):
        edited=copy.deepcopy(self.baseline);edited['guests']['vmA']['applications']=[]
        with self.h.locked({**self.request,'baseline':edited},create=True):
            with self.assertRaises(host.Refused):self.h.prepare()
        self.assertEqual(self.h.events,[])

    def test_unknown_http_refuses_readonly_plan_without_creating_run(self):
        m=cli.Maintenance('fixture',self.root/'local',self.remote,http=lambda _:None)
        with self.assertRaises(host.Refused):m.plan(self.c)
        self.assertFalse(m.directory.exists());self.assertEqual(self.h.events,[])

    def test_missing_or_stale_hook_export_is_not_a_backup(self):
        self.h.c['backup_hooks']=[{'name':'empty','argv':[sys.executable,'-c','pass'],'exports':['missing.sql']}]
        with self.locked():
            self.h.stop(None,['mjolnir-gateway.service'],'ingress')
            self.h.stop('vmA',['web.service'],'application')
            with self.assertRaises(host.Refused):host.Host.backup_hooks(self.h)
            self.assertEqual(self.h.j['hooks']['empty']['state'],'requested')

    def test_duplicate_prepare_cannot_rerun_uncertain_backup(self):
        with self.locked():
            self.h.j['hooks']={'database':{'state':'requested'}};self.h.save()
            with self.assertRaises(host.Refused):self.h.prepare()
        self.assertNotIn(('backup',),self.h.events)

    def test_resume_does_not_override_later_stop_after_partial_restore(self):
        self.prepared(); original=self.h.unit_change
        def fail_ingress(vm,units,verb):
            if verb=='start' and vm is None:raise host.Refused('fixture ingress failure')
            return original(vm,units,verb)
        with self.h.locked(self.request),patch.object(self.h,'unit_change',side_effect=fail_ingress):
            with self.assertRaises(host.Refused):self.h.resume()
        self.h.events=[]
        self.h.obs[('vmA','web.service')]=observation('inactive','99')
        with self.h.locked(self.request):
            with self.assertRaises(host.Refused):self.h.resume()
        self.assertNotIn(('start','vmA','web.service'),self.h.events)

    def test_unknown_power_ack_is_not_reissued_and_old_stops_not_replayed(self):
        m=cli.Maintenance('fixture',self.root/'local',self.remote,http=lambda _:200);m.plan(self.c);m.prepare()
        clock=[0.0];m.clock=lambda:clock[0];m.sleep=lambda n:clock.__setitem__(0,clock[0]+n)
        def lost_ack(argv,*args,**kwargs):
            result=self.fake_run(argv,*args,**kwargs)
            if argv[:1]==['systemctl']:raise host.Refused('simulated lost acknowledgement')
            return result
        with patch.object(host,'run',side_effect=lost_ack):
            for _ in range(2):
                with self.assertRaises(host.Refused):m.power('reboot',1)
        self.assertEqual([x for x in self.h.events if x[0]=='power'],[('power','reboot')])
        self.assertEqual(m.j['phase'],'action_requested')
        with self.assertRaises(host.Refused):m.resume()

    def test_full_recovery_and_lost_completion_ack_are_idempotent(self):
        m=cli.Maintenance('fixture',self.root/'local',self.remote,http=lambda _:200);m.plan(self.c);m.prepare()
        original_request=self.remote.request
        dropped=[False]
        def request(action,**values):
            result=original_request(action,**values)
            if action=='complete' and not dropped[0]:
                dropped[0]=True;raise host.Refused('simulated lost completion reply')
            return result
        def reboot(argv,*args,**kwargs):
            result=self.fake_run(argv,*args,**kwargs)
            if argv[:1]==['systemctl']:
                self.h.host_boot='host-after';self.h.guest_boot=str(uuid.uuid4());self.h.kernel=self.c['expected_kernel']
                for key in self.h.obs:self.h.obs[key]=observation()
            return result
        with patch.object(self.remote,'request',side_effect=request),patch.object(host,'run',side_effect=reboot),patch.object(host.os,'uname',return_value=SimpleNamespace(release=self.c['expected_kernel'])):
            m.power('reboot',30)
            self.assertEqual(m.j['phase'],'complete')
            m.verify(30)
        self.assertEqual([x for x in self.h.events if x[0]=='power'],[('power','reboot')])
        self.assertFalse((self.h.ops/'active.json').exists())

    def test_probe_failure_keeps_recovery_failed_without_another_reboot(self):
        m=cli.Maintenance('fixture',self.root/'local',self.remote,http=lambda _:200);m.plan(self.c);m.prepare()
        clock=[0.0];m.clock=lambda:clock[0];m.sleep=lambda n:clock.__setitem__(0,clock[0]+n)
        def reboot(argv,*args,**kwargs):
            result=self.fake_run(argv,*args,**kwargs)
            if argv[:1]==['systemctl']:
                self.h.host_boot='host-after';self.h.guest_boot=str(uuid.uuid4());self.h.kernel=self.c['expected_kernel']
                for key in self.h.obs:self.h.obs[key]=observation()
                self.h.fail_probe=True
            return result
        with patch.object(host,'run',side_effect=reboot):
            with self.assertRaises(host.Refused):m.power('reboot',1)
        self.assertEqual(m.j['phase'],'action_requested')
        self.assertNotIn('complete',self.remote.calls)
        self.assertEqual([x for x in self.h.events if x[0]=='power'],[('power','reboot')])


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        c=config();self.h=FixtureHost(c,Path('/unused-fixture'))
        self.before=self.h.plan();self.current=copy.deepcopy(self.before)
        self.current.update(boot_id='host-after',kernel=c['expected_kernel'])
        self.guests=copy.deepcopy(self.before['guests']);self.guests['vmA']['boot_id']=str(uuid.uuid4())
        self.url='https://example.invalid/health'

    def errors(self, previous=200, status=200):
        return cli.check_recovery(self.before,self.current,self.guests,config()['expected_kernel'],
                                  {self.url:status},{self.url:previous})

    def test_complete_recovery(self): self.assertEqual(self.errors(),[])

    def test_each_missing_or_changed_fact_fails(self):
        cases=[('hostboot',lambda:setattr(self,'current',{**self.current,'boot_id':self.before['boot_id']})),
               ('kernel',lambda:self.current.update(kernel='unexpected')),
               ('identity',lambda:self.current['vms']['vmA'].update(iroh='changed')),
               ('root',lambda:self.current['records']['vmA'].update(root_uuid='new-empty-root')),
               ('guestboot',lambda:self.guests['vmA'].update(boot_id=self.before['guests']['vmA']['boot_id'])),
               ('secrets',lambda:self.guests['vmA'].update(secrets_mounted=False)),
               ('service',lambda:self.guests['vmA'].update(running=['mjolnir-agent.service'])),
               ('failed',lambda:self.guests['vmA'].update(failed=['web.service'])),
               ('partial',lambda:self.current['vms']['vmA'].update(state='recovering'))]
        for name,mutate in cases:
            with self.subTest(name=name):
                self.setUp();mutate();self.assertTrue(self.errors())

    def test_unknown_and_changed_bad_http_fail_without_hiding_baseline(self):
        self.assertTrue(self.errors(status=None))
        self.assertTrue(self.errors(previous=404,status=None))
        self.assertTrue(self.errors(previous=404,status=502))
        self.assertEqual(self.errors(previous=404,status=404),[])
        self.assertEqual(self.errors(previous=404,status=200),[])


class BoundaryTests(unittest.TestCase):
    def test_btrfs_root_identity_listing_is_unambiguous(self):
        value=str(uuid.uuid4())
        line='ID 256 gen 11 top level 5 uuid '+value+' path <FS_TREE>/@vms/vmA'
        self.assertEqual(host.subvolume_ids(line),{'vmA':value})
        with self.assertRaises(host.Refused):host.subvolume_ids(line+'\n'+line)
        with self.assertRaises(host.Refused):host.subvolume_ids('unknown output')
        self.assertEqual(host.subvolume_ids(line.replace('/@vms/','/@snapshots/')),{})
        other=line.replace('/@vms/','/other-instance/@vms/')
        self.assertEqual(host.subvolume_ids(other),{})
        self.assertEqual(host.subvolume_ids(other,prefix='other-instance/@vms'),{'vmA':value})

    def test_guest_probe_is_real_tsv_and_command_failure_is_not_clean(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);boot=root/'boot';boot.write_text(str(uuid.uuid4())+'\n')
            script=root/'systemctl'
            script.write_text('#!/bin/sh\nif [ "$1" = list-units ]; then echo "mjolnir-agent.service loaded active running Agent"; fi\n')
            script.chmod(0o700);mount=root/'mountpoint';mount.write_text('#!/bin/sh\nexit 0\n');mount.chmod(0o700)
            probe=host.GUEST_READ.replace('/proc/sys/kernel/random/boot_id',str(boot))
            p=subprocess.run(['sh','-c',probe],env={**os.environ,'PATH':str(root)+':/usr/bin:/bin'},capture_output=True,text=True)
            self.assertEqual(p.returncode,0)
            h=host.Host(config())
            with patch.object(h,'guest_exec',return_value=p.stdout):
                result=h.guest_read('vmA')
            self.assertTrue(result['secrets_mounted']);self.assertEqual(result['boot_id'],boot.read_text().strip())
            self.assertEqual(result['running'],['mjolnir-agent.service'])
            script.write_text('#!/bin/sh\nexit 1\n')
            p=subprocess.run(['sh','-c',probe],env={**os.environ,'PATH':str(root)+':/usr/bin:/bin'},capture_output=True,text=True)
            self.assertNotEqual(p.returncode,0)

    def test_command_errors_do_not_echo_sensitive_output_or_arguments(self):
        with self.assertRaises(host.Refused) as raised:
            host.run([sys.executable,'-c','import sys; print("private-token"); sys.exit(3)'])
        self.assertNotIn('private-token',str(raised.exception))

    def test_probe_output_is_bounded_while_command_is_running(self):
        with self.assertRaises(host.Refused):
            host.run([sys.executable,'-c','import sys; sys.stdout.buffer.write(b"x"*(3*1024*1024))'])

    def test_invalid_guest_identifier_never_reaches_api(self):
        h=host.Host(config())
        with patch.object(h,'api',side_effect=AssertionError('not allowed')):
            with self.assertRaises(host.Refused):h.guest_exec('vm;touch /tmp/unsafe','true')

    def test_operator_socket_never_falls_back_to_tcp(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'not-a-socket';path.write_text('fixture')
            c=config();c['operator_socket']=str(path);h=host.Host(c)
            with patch.object(host,'UnixHTTP') as connection:
                with self.assertRaises(host.Refused):h.api('/api/vms')
                connection.assert_not_called()

    def test_ci_guest_is_refused_before_exec_can_renew_lease(self):
        with tempfile.TemporaryDirectory() as d:
            c=config();c['state_dir']=d;c['btrfs_root']=d
            Path(d,'vmA.json').write_text(json.dumps({'uuid':'vmA','intent':'running','spawn_config':{}}))
            h=host.Host(c)
            with patch.object(h,'api',return_value={'vms':[{'id':'vmA','state':'running','metadata':{'purpose':'ci'}}]}),patch.object(h,'guest_exec') as execute:
                with self.assertRaises(host.Refused):h.inspect()
                execute.assert_not_called()

    def test_malformed_ssh_ack_does_not_echo_stderr_or_retry(self):
        calls=[]
        def runner(argv,**kwargs):
            calls.append(argv);return subprocess.CompletedProcess(argv,255,b'not-json',b'private-token')
        r=cli.SSHRemote('fixture',config(),runner=runner)
        with self.assertRaises(host.Refused) as error:r.request('power',execute=True)
        self.assertEqual(len(calls),1);self.assertNotIn('private-token',str(error.exception))

    def test_download_has_an_actual_file_size_limit(self):
        def runner(argv,**kwargs):
            return subprocess.run([sys.executable,'-c','import sys; sys.stdout.buffer.write(b"x"*100000)'],**kwargs)
        with tempfile.TemporaryDirectory() as d:
            r=cli.SSHRemote('fixture',config(),runner=runner)
            path=Path(d)/'backup'
            with self.assertRaises(host.Refused):r.download(path,{'bytes':128})
            self.assertLessEqual(path.stat().st_size,128)


class ExportAndLockTests(Fixture):
    def test_real_export_freshness_rejects_old_mtime_even_after_success(self):
        for stale in [False,True]:
            name='stale' if stale else 'fresh'
            code='import pathlib,sys,os; p=pathlib.Path(sys.argv[1]); p.write_bytes(b"fixture")'
            if stale:code+='; os.utime(p,(1,1))'
            c=config();c['backup_hooks']=[{'name':name,'argv':[sys.executable,'-c',code,'{run_dir}/db.sql'],'exports':['db.sql']}]
            self.h=FixtureHost(c,self.root/name);self.baseline=self.h.plan()
            self.request={**self.request,'run_id':str(uuid.uuid4()),'baseline':self.baseline}
            with self.h.locked(self.request,create=True):
                self.h.stop(None,['mjolnir-gateway.service'],'ingress');self.h.stop('vmA',['web.service'],'application')
                if stale:
                    with self.assertRaises(host.Refused):host.Host.backup_hooks(self.h)
                else:
                    host.Host.backup_hooks(self.h)
                    self.assertEqual(self.h.j['hooks'][name]['state'],'complete')

    def test_same_run_lock_is_exclusive_across_processes(self):
        child='''import json,sys
from pathlib import Path
import maintenance_host as m
h=m.Host(json.loads(sys.argv[2]),Path(sys.argv[1]))
try:
 with h.locked(json.loads(sys.argv[3])): print("INCORRECTLY ACQUIRED")
except m.Refused as e: print(str(e))
'''
        with self.locked():
            p=subprocess.run([sys.executable,'-c',child,str(self.h.ops),json.dumps(self.c),json.dumps(self.request)],
                             env={**os.environ,'PYTHONPATH':str(Path(__file__).resolve().parent)},capture_output=True,text=True,timeout=10)
        self.assertEqual(p.returncode,0)
        self.assertIn('Another maintenance operation is still executing',p.stdout)
        self.assertNotIn('INCORRECTLY ACQUIRED',p.stdout)


if __name__=='__main__':
    unittest.main()
