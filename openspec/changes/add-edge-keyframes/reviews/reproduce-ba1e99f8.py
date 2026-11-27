#!/usr/bin/env python3
"""Run independent ba1e99f8 session reproductions in a disposable source copy.

Tests assert observed bugs as well as corrected transitions: six passing tests
are reproduction evidence, NOT six passing product regression requirements.
Set CARGO_TARGET_DIR to an existing compatible cache to avoid a duplicate build.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
REV = 'ba1e99f8a80127e557de34835abd468191c35d46'
PREFIX = 'native/vendor/moq-webrtc/'
with tempfile.TemporaryDirectory(prefix='mj-ba1-review-') as temp:
    crate = Path(temp)
    files = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', REV, '--', PREFIX], cwd=ROOT, text=True).splitlines()
    for name in files:
        relative = name.removeprefix(PREFIX)
        if relative in ('Cargo.toml', 'Cargo.lock') or relative.startswith('src/'):
            dest = crate / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(subprocess.check_output(['git', 'show', f'{REV}:{name}'], cwd=ROOT))
    with (crate / 'src/session.rs').open('a') as out:
        out.write(Path(__file__).with_suffix('.rs').read_text())
    env = dict(os.environ)
    env.setdefault('CARGO_TARGET_DIR', str(crate / 'target'))
    env.update(CARGO_PROFILE_TEST_DEBUG='0', CARGO_PROFILE_DEV_DEBUG='0', CARGO_BUILD_JOBS='2')
    subprocess.run(['cargo', 'test', '--locked', '--offline', '--lib', '--manifest-path', str(crate / 'Cargo.toml'), 'independent_review'], env=env, check=True)
