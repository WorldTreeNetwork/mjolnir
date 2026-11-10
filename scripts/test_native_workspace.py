#!/usr/bin/env python3
"""Core deployment builds must load without optional sibling source checkouts."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class NativeWorkspaceTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('cargo'), 'Rust toolchain required')
    def test_core_workspace_resolves_in_an_unrelated_directory_without_siblings(self):
        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory() as temporary:
            native = Path(temporary) / 'native'
            shutil.copytree(root / 'native', native,
                            ignore=shutil.ignore_patterns('target', 'mjolnir_lan_files'))
            result = subprocess.run(['cargo', 'metadata', '--manifest-path', str(native / 'Cargo.toml'),
                                     '--offline', '--locked', '--no-deps', '--format-version', '1'],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            packages = {p['name'] for p in json.loads(result.stdout)['packages']}
            self.assertTrue({'mjolnir-blob-door', 'mjolnir-guest-agent', 'mjolnir-gateway'} <= packages)
            self.assertNotIn('mjolnir-lan-files', packages)


if __name__ == '__main__':
    unittest.main()
