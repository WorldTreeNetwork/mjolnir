"""Independent bounded Iroh check; existing binaries, local dummy signer only."""
import concurrent.futures as futures
import hashlib
from pathlib import Path
import subprocess as sp
import tempfile
import time

BASE = Path(__file__).resolve().parents[4]
BIN = BASE / 'native/mjolnir_relay/target/debug'
SPIKE, PAIR = BIN / 'open-room-kind-spike', BIN / 'iroh-pair'
OWNER = 'cGfHiC6Kgg3FpFZvgwGcswsCRtp4aBP2fzuXRQPizuN'
roots = [f't/{OWNER}/~open/standup', f't/{OWNER}/standup']
for binary in [SPIKE, PAIR]:
    print(binary.name, hashlib.sha256(binary.read_bytes()).hexdigest(), flush=True)
with tempfile.TemporaryDirectory(prefix='advise-pair-') as tmp:
    d = Path(tmp)
    procs = []
    handles = []
    def launch(args, name):
        out = open(d / name, 'w')
        handles.append(out)
        p = sp.Popen([str(a) for a in args], stdout=out, stderr=sp.STDOUT)
        procs.append(p)
        return p
    def wait_file(path):
        for _ in range(100):
            if path.exists():
                return
            time.sleep(.1)
        raise RuntimeError('readiness deadline: ' + path.name)
    try:
        launch([SPIKE, 'relay', d], 'relay.log')
        wait_file(d / 'iroh.txt')
        relay = (d / 'iroh.txt').read_text().strip()
        def sign(root, pub):
            return sp.check_output([str(SPIKE), 'sign', tmp, root, pub, '**', '180'], text=True).strip()
        tokens = [sign(root, '**') for root in roots]
        subs = [sign(root, '-') for root in roots]
        pubs = []
        for i in range(2):
            pubs.append(launch([PAIR, 'publish', relay, tokens[i], roots[i] + '/marker', '40', d / f'ready{i}', f'REVIEW-{i}'], f'pub{i}.log'))
        for i in range(2):
            wait_file(d / f'ready{i}')
        jobs = []
        for i in range(2):
            jobs += [(f'own-{i}', ['read', relay, tokens[i], roots[i] + '/marker', '6', '3']),
                     (f'cross-{i}', ['read', relay, tokens[i], roots[1-i] + '/marker', '6', '3']),
                     (f'announce-{i}', ['listen', relay, subs[i], '6'])]
        for i in range(2):
            pubs.append(launch([PAIR, 'publish', relay, tokens[i], roots[1-i] + '/stolen', '40', d / f'stolen{i}', f'STOLEN-{i}'], f'stolen{i}.log'))
            wait_file(d / f'stolen{i}')
            jobs.append((f'stolen-read-{i}', ['read', relay, tokens[1-i], roots[1-i] + '/stolen', '6', '3']))
        def run(job):
            name, args = job
            p = sp.run([str(PAIR), *args], capture_output=True, text=True, timeout=20)
            return name, p.returncode, p.stdout + p.stderr
        with futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(run, jobs))
        for name, code, output in results:
            print(f'\n{name} exit={code}\n{output}', flush=True)
        assert all(p.poll() is None for p in pubs), 'publisher exited before observations'
        print('All four publishers still alive after concurrent observations.', flush=True)
        for name, code, output in results:
            if name.startswith('own-'):
                assert code == 0 and f'first=REVIEW-{name[-1]}' in output
            elif name.startswith(('cross-', 'stolen-')):
                assert code == 124 and 'subscribe-timeout call=Node::subscribe' in output
            else:
                i = int(name[-1])
                assert code == 0 and roots[i] + '/marker' in output
                assert roots[1-i] not in output and '/stolen' not in output
        print('PASS: receipts, both-direction bounded non-observation, scoped announcements. No refusal claimed.')
    finally:
        (d / 'stop').touch()
        for p in reversed(procs):
            if p.poll() is None:
                p.terminate()
            try:
                p.wait(timeout=3)
            except sp.TimeoutExpired:
                p.kill()
                p.wait()
        for h in handles:
            h.close()
