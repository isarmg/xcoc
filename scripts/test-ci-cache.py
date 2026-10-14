#!/usr/bin/env python3
"""Regression guards for CI cache boundaries and the iOS aggregate result."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CacheContractTests(unittest.TestCase):
    def test_native_hit_preserves_source_and_rechecks_provisioning(self):
        action = (ROOT / '.github/actions/native-media/action.yml').read_text()
        for material in ('/xcoc-native/source', '/xcoc-native/installed', '/xcoc-native/vcpkg'):
            self.assertIn(material, action)
        self.assertNotIn('restore-keys:', action)
        self.assertNotIn('cache-hit', action)
        self.assertIn('packaging/native/**', action)
        self.assertIn('steps.image.outputs.version', action)
        self.assertIn('bash packaging/native/build-unix.sh', action)
        self.assertIn('build-windows.ps1 -WorkDirectory', action)

    def test_rust_cache_isolated_by_toolchain_target_and_native_inputs(self):
        action = (ROOT / '.github/actions/rust-build-cache/action.yml').read_text()
        for field in ('runner.os', 'runner.arch', 'env.RUSTUP_TOOLCHAIN', 'inputs.lane',
                      'Cargo.lock', 'packaging/native/**', 'steps.image.outputs.version'):
            self.assertIn(field, action)
        self.assertNotIn('restore-keys:', action)

    def test_aggregate_gate_rejects_failed_missing_and_cancelled_validation(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        gate = workflow.split('      - name: Require every iOS configuration\n', 1)[1].split('\n  native-build:', 1)[0]
        command = gate.split('        run: |\n', 1)[1]
        command = '\n'.join(line[10:] for line in command.splitlines())
        for scope, full, result, passed in [
            ('success', 'true', 'success', True),
            ('success', 'true', 'failure', False),
            ('success', 'true', 'skipped', False),
            ('success', 'true', 'cancelled', False),
            ('success', 'false', 'skipped', True),
            ('failure', '', 'success', False),
        ]:
            with self.subTest(scope=scope, full=full, result=result):
                run = subprocess.run(['bash', '-e', '-c', command], env={
                    'SCOPE_RESULT': scope, 'RUN_FULL': full, 'VALIDATION_RESULT': result})
                self.assertEqual(run.returncode == 0, passed)
        self.assertIn('configuration: [Debug, Release]', workflow)
        self.assertIn('needs: [scope, ios-validation]', workflow)
        self.assertIn('name: iOS native camera', workflow)
        self.assertIn('-parallel-testing-enabled NO', workflow)
        release = (ROOT / '.github/actions/package-ios-release/action.yml').read_text()
        self.assertIn('ENABLE_TESTABILITY=YES', release)
        self.assertIn('ENABLE_TESTABILITY=NO', release)
        self.assertIn('packaging/mobile/release.py ios', release)
        self.assertIn('-parallel-testing-enabled NO', release)


if __name__ == '__main__':
    unittest.main()
