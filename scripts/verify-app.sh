#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:-$TASK_ROOT/dist/AndroidOnMac.app}"
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
for task_binary in "$APP_DIR/Contents/MacOS/AndroidOnMac" \
  "$APP_DIR/Contents/MacOS/ProcessLauncher" \
  "$APP_DIR/Contents/MacOS/VirtualDisplayHelper" \
  "$APP_DIR/Contents/Resources/engine/scrcpy" "$APP_DIR/Contents/Resources/engine/adb"; do
  lipo "$task_binary" -verify_arch arm64
  # Direct dependencies must be system frameworks/libraries; reject Homebrew or
  # developer-machine paths so the downloadable app can run independently.
  python3 - "$task_binary" <<'PY'
import subprocess, sys
binary = sys.argv[1]
lines = subprocess.check_output(['otool', '-L', binary], text=True).splitlines()
for line in lines[1:]:
    if not line.startswith('\t'):
        continue  # universal-binary architecture header
    path = line.strip().split(' (')[0]
    if not path.startswith(('/usr/lib/', '/System/Library/')):
        raise SystemExit(f'Non-system dynamic dependency: {binary}: {path}')
print(f'arm64 / system dependencies verified: {binary}')
PY
done
test -s "$APP_DIR/Contents/Resources/engine/scrcpy-server"
test -s "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -s "$APP_DIR/Contents/Resources/AndroidOnMac-Receiver.apk"
test -s "$APP_DIR/Contents/Resources/Licenses/deskpad/LICENSE.txt"
bash "$TASK_ROOT/scripts/verify-android.sh" "$APP_DIR/Contents/Resources/AndroidOnMac-Receiver.apk"
for task_component in scrcpy ffmpeg sdl libusb dav1d zlib adb; do
  test -d "$APP_DIR/Contents/Resources/Licenses/$task_component"
done
"$APP_DIR/Contents/Resources/engine/scrcpy" --version
"$APP_DIR/Contents/Resources/engine/adb" version
