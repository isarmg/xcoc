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

    def test_android_install_candidate_is_isolated_from_shipping_artifacts(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        job = workflow.split('  android-installed-smoke:\n', 1)[1].split('  ios-validation:', 1)[0]
        self.assertIn('needs: scope', job)
        self.assertNotIn('needs: android', job)
        self.assertIn('XCOC_ANDROID_ABI=x86_64', job)
        self.assertIn('-PxcocEmulatorTests=true', job)
        self.assertNotIn('package-android-release', job)
        self.assertNotIn('native-media', job)
        self.assertEqual(job.count('sudo '), 1)
        self.assertIn('sudo setfacl -m \"u:$(id -u):rw\" /dev/kvm', job)
        self.assertIn('[[ -c /dev/kvm && ! -L /dev/kvm ]]', job)
        self.assertIn('\"$RUNNER_ENVIRONMENT\" == github-hosted', job)
        self.assertNotIn('chmod', job)
        self.assertNotIn('chown', job)
        acl = job.split('      - name: Permit this disposable runner user to use KVM\n', 1)[1].split('      - name:', 1)[0]
        command = acl.split('        run: |\n', 1)[1]
        command = '\n'.join(line[10:] for line in command.splitlines())
        for github, environment in [('false', 'github-hosted'), ('true', 'self-hosted')]:
            run = subprocess.run(['bash', '-eu', '-c', command], env={
                'GITHUB_ACTIONS': github, 'RUNNER_ENVIRONMENT': environment})
            self.assertNotEqual(run.returncode, 0)
        self.assertIn('upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a', job)
        script = (ROOT / 'scripts/test-android-install.sh').read_text()
        self.assertIn('RUNNER_ENVIRONMENT:-', script)
        self.assertIn('github-hosted', script)
        self.assertIn('mktemp -d', script)
        self.assertIn('"$sdk/platform-tools/adb" -s "$serial"', script)
        self.assertIn('OK \\(3 tests\\)', script)
        self.assertIn('am force-stop', script)
        self.assertIn('adb uninstall org.sarmg.xcoc', script)
        self.assertNotIn('gradle ', script)
        helper = (ROOT / 'scripts/build-android-rust.sh').read_text()
        self.assertIn('XCOC_ANDROID_ABI:-arm64-v8a', helper)
        build = (ROOT / 'clients/android/app/build.gradle.kts').read_text()
        self.assertIn('src/emulatorTest/java', build)

    def test_android_diagnostics_do_not_fabricate_files_after_uninstall(self):
        import tempfile
        script = (ROOT / 'scripts/test-android-install.sh').read_text()
        capture = script.split("  # adb exec-out can return zero", 1)[1].split("  adb emu kill", 1)[0]
        capture = "  # adb exec-out can return zero" + capture
        for installed, present in [('false', 'false'), ('true', 'false'), ('true', 'true')]:
            with self.subTest(installed=installed, present=present), tempfile.TemporaryDirectory() as output:
                mock = r'''adb() {
  if [[ "$*" == "shell pm path org.sarmg.xcoc" ]]; then
    [[ "$installed" == true ]] && echo package:/fixture/base.apk
  elif [[ "$*" == shell\ run-as* ]]; then
    [[ "$present" == true ]]
  elif [[ "$*" == exec-out* ]]; then
    echo genuine-private-diagnostic
  else
    return 1
  fi
}
'''
                result = subprocess.run(['bash', '-eu', '-c', mock + capture], env={
                    'output': output, 'installed': installed, 'present': present})
                self.assertEqual(result.returncode, 0)
                for name in ['permission-ui.txt', 'permission-ui.png']:
                    self.assertEqual((pathlib.Path(output) / name).exists(),
                                     installed == 'true' and present == 'true')

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
