#!/usr/bin/env python3
"""Exercise release preflight failures without signing keys or network access."""
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

class ReleasePreflight(unittest.TestCase):
    def run_release(self, extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('SOTTO_', 'APPLE_', 'RELEASE_TAG'))}
        env.update(extra)
        result = subprocess.run([str(ROOT / 'scripts/release.sh')], cwd=ROOT, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        return result.stderr

    def test_missing_identity(self):
        self.assertIn('Missing Developer ID', self.run_release({}))

    def test_missing_notarization_credentials(self):
        self.assertIn('Missing Apple ID', self.run_release({'SOTTO_SIGNING_IDENTITY': 'Developer ID Application: Test'}))

    def test_adhoc_cannot_publish(self):
        self.assertIn('Release requires a Developer ID', self.run_release({
            'SOTTO_SIGNING_IDENTITY': '-', 'APPLE_ID': 'test', 'APPLE_TEAM_ID': 'test', 'APPLE_APP_PASSWORD': 'test'}))

    def test_tag_mismatch(self):
        self.assertIn('tag does not match VERSION', self.run_release({
            'SOTTO_SIGNING_IDENTITY': 'Developer ID Application: Test', 'APPLE_ID': 'test',
            'APPLE_TEAM_ID': 'test', 'APPLE_APP_PASSWORD': 'test', 'RELEASE_TAG': 'v999.0.0'}))

    def test_explicit_adhoc_mode_needs_no_apple_credentials(self):
        env = {'PATH': os.environ['PATH'], 'RELEASE_TAG': 'v999.0.0'}
        result = subprocess.run([str(ROOT / 'scripts/release.sh'), '--adhoc'], cwd=ROOT, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('tag does not match VERSION', result.stderr)
        self.assertNotIn('Missing Developer ID', result.stderr)

    def test_unknown_release_mode_fails(self):
        result = subprocess.run([str(ROOT / 'scripts/release.sh'), '--unknown'], cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Usage:', result.stderr)

if __name__ == '__main__':
    unittest.main()
