#!/usr/bin/env bash
set -euo pipefail
# Never address physical devices or an existing developer AVD.
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]]
sdk="${ANDROID_HOME:?}"
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${RUNNER_TEMP:?}/xcoc-android-install"
mkdir -p "$output"
export ANDROID_USER_HOME="$(mktemp -d "$RUNNER_TEMP/xcoc-avd.XXXXXX")"
export ANDROID_AVD_HOME="$ANDROID_USER_HOME/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd="xcoc-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:-1}"
serial=emulator-5554
pid=""
adb() { timeout --kill-after=2s 20s "$sdk/platform-tools/adb" -s "$serial" "$@"; }
cleanup() {
  adb logcat -d > "$output/logcat.txt" 2>&1 || true
  # adb exec-out can return zero even when run-as prints an error. Never
  # create a diagnostic artifact for an uninstalled package or absent file.
  if adb shell pm path org.sarmg.xcoc 2>/dev/null | grep -q '^package:'; then
    for diagnostic in permission-ui.txt permission-ui.png; do
      if adb shell run-as org.sarmg.xcoc test -f "files/$diagnostic" 2>/dev/null; then
        if ! adb exec-out run-as org.sarmg.xcoc cat "files/$diagnostic" > "$output/$diagnostic" 2>/dev/null; then
          rm -f "$output/$diagnostic"
        fi
      fi
    done
  fi
  adb emu kill || true
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    for ((i=0; i<10; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  timeout 15s avdmanager delete avd -n "$avd" || true
}
trap cleanup EXIT
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "The disposable runner lacks existing read/write access to /dev/kvm; no device permissions were changed." >&2
  ls -l /dev/kvm >&2 || true
  id >&2
  exit 1
fi
printf 'no\n' | avdmanager create avd -n "$avd" -k 'system-images;android-36;google_apis;x86_64'
"$sdk/emulator/emulator" -avd "$avd" -port 5554 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect > "$output/emulator.log" 2>&1 &
pid=$!
booted=false
for ((i=0; i<120; i++)); do
  kill -0 "$pid" 2>/dev/null || { tail -100 "$output/emulator.log"; exit 1; }
  if [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then booted=true; break; fi
  sleep 3
done
[[ "$booted" == true ]]
[[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]]
adb logcat -c
# Use exactly the candidate APKs produced once by this job, with no Gradle rebuild.
adb install "$root/clients/android/app/build/outputs/apk/debug/app-debug.apk"
adb install "$root/clients/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
timeout --kill-after=5s 120s "$sdk/platform-tools/adb" -s "$serial" shell am instrument -w -r org.sarmg.xcoc.test/android.test.InstrumentationTestRunner | tee "$output/instrumentation.txt"
grep -Eq 'OK \(3 tests\)' "$output/instrumentation.txt"
for pass in 1 2; do
  adb shell am force-stop org.sarmg.xcoc
  adb shell am start -W -n org.sarmg.xcoc/.MainActivity | tee "$output/launch-$pass.txt"
  grep -q 'Status: ok' "$output/launch-$pass.txt"
  sleep 2
  adb shell pidof org.sarmg.xcoc | grep -Eq '[0-9]+'
  # am start -W can report the transient permission Activity even when Android
  # immediately applies the previous denial. Require the actual resumed and
  # focused main screen, without granting permissions or dismissing other UI.
  foreground=false
  foreground_deadline=$((SECONDS + 15))
  while ((SECONDS < foreground_deadline)); do
    adb shell dumpsys activity activities > "$output/activities-$pass.txt"
    adb shell dumpsys window > "$output/windows-$pass.txt"
    if grep -Eq '(mResumedActivity|topResumedActivity)[=:].*org\.sarmg\.xcoc/(\.MainActivity|org\.sarmg\.xcoc\.MainActivity)([[:space:]}]|$)' "$output/activities-$pass.txt" &&
       grep -Eq 'mCurrentFocus=.*org\.sarmg\.xcoc/(\.MainActivity|org\.sarmg\.xcoc\.MainActivity)([[:space:]}]|$)' "$output/windows-$pass.txt"; then
      foreground=true
      break
    fi
    sleep 1
  done
  [[ "$foreground" == true ]] || { echo "Cold start $pass did not resume and focus MainActivity within 15 seconds." >&2; exit 1; }
  adb shell dumpsys package org.sarmg.xcoc > "$output/permissions-$pass.txt"
  grep -Eq 'android\.permission\.POST_NOTIFICATIONS: granted=false' "$output/permissions-$pass.txt"
  echo "Cold start $pass resumed and focused MainActivity with notifications still denied."
done
adb logcat -d -b crash > "$output/crash.txt"
if grep -Eq 'FATAL EXCEPTION|Fatal signal|UnsatisfiedLinkError' "$output/crash.txt"; then cat "$output/crash.txt"; exit 1; fi
adb uninstall org.sarmg.xcoc.test
adb uninstall org.sarmg.xcoc
if adb shell pm list packages | tr -d '\r' | grep -Fxq 'package:org.sarmg.xcoc'; then exit 1; fi
echo 'Installed APK: Activity relaunch, device JNI, encrypted keystore, force-stop/restart, no crash and uninstall passed.'
