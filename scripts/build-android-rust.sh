#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to an installed Android NDK (r28 or newer)}"
abi="${XCOC_ANDROID_ABI:-arm64-v8a}"
case "$abi" in arm64-v8a|x86_64) ;; *) echo "Unsupported Android ABI: $abi" >&2; exit 2 ;; esac
cargo ndk -t "$abi" -o clients/android/app/src/main/jniLibs build -p xcoc-mobile-ffi --release --locked
