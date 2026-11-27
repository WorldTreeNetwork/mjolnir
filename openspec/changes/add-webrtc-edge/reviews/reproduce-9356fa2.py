#!/usr/bin/env python3
"""Run gateway review probes against an exact disposable source snapshot.
No product files or remote services are changed. Uses loopback ephemeral ports.
Mixed regression and defect-characterization assertions; see each test and report.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[4]
REV = '9356fa2dc80b9ea17dd6a7faf64e3baca85fc8e3'
with tempfile.TemporaryDirectory(prefix='mj-edge-review-') as temp:
    scratch = Path(temp)
    for prefix in ('native/mjolnir_relay/', 'native/vendor/moq-webrtc/'):
        files = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', REV, '--', prefix], cwd=ROOT, text=True).splitlines()
        for name in files:
            rel = name.removeprefix(prefix)
            if rel in ('Cargo.toml', 'Cargo.lock', 'rust-toolchain.toml') or rel.startswith(('src/', 'tests/')):
                dest = scratch / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(subprocess.check_output(['git', 'show', f'{REV}:{name}'], cwd=ROOT))
    crate = scratch / 'native/mjolnir_relay'
    env = dict(os.environ)
    env.setdefault('CARGO_TARGET_DIR', str(ROOT / 'native/target'))
    env['CARGO_BUILD_JOBS'] = '1'
    env['CARGO_INCREMENTAL'] = '0'
    if not env.get('MJ_REVIEW_SKIP_BASELINE'):
        print('EXACT CHECKED-IN LIBRARY', flush=True)
        subprocess.run(['cargo', '+1.95.0', 'test', '--offline', '--locked', '--lib', '--', '--test-threads=1'], cwd=crate, env=env, check=True, timeout=900)
    with (crate / 'src/edge.rs').open('a') as out:
        out.write(Path(__file__).with_suffix('.rs').read_text())
    with (crate / 'Cargo.toml').open('a') as out:
        out.write('\nstr0m = { version = "0.25", default-features = false }\nrind-str0m = "0.25.2"\n')
    print('INDEPENDENT APPENDED REVIEW PROBES', flush=True)
    subprocess.run(['cargo', '+1.95.0', 'test', '--offline', '--lib', sys.argv[1] if len(sys.argv) > 1 else 'edge::independent_review', '--', '--nocapture', '--test-threads=1'], cwd=crate, env=env, check=True, timeout=900)
