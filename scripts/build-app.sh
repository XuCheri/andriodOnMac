#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Build on an Apple Silicon Mac.' >&2; exit 1; }
TASK_SWIFT_MAJOR="$(swift --version | sed -nE 's/.*Swift version ([0-9]+).*/\1/p')"
if [[ ! "$TASK_SWIFT_MAJOR" =~ ^[0-9]+$ ]] || (( TASK_SWIFT_MAJOR < 6 )); then
  echo 'Swift 6 or newer is required. Install a current Command Line Tools or Xcode toolchain.' >&2
  exit 1
fi
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
APP_DIR="$TASK_ROOT/dist/AndroidOnMac.app"
TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
python3 scripts/fetch-dependencies.py --engine --compliance
# Swift 6+ supports SwiftPM with current standalone Command Line Tools. The
# absence of Xcode's PlatformPath must not route this build to a manual fallback.
swift build -c release --arch arm64 --product AndroidOnMac
EXECUTABLE_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/engine"
cp "$EXECUTABLE_DIR/AndroidOnMac" "$APP_DIR/Contents/MacOS/AndroidOnMac"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -O2 -arch arm64 \
  -isysroot "$TASK_SDK" -mmacosx-version-min=13.0 \
  Sources/ProcessLauncher/main.c -o "$APP_DIR/Contents/MacOS/ProcessLauncher"
cp .cache/engine/* "$APP_DIR/Contents/Resources/engine/"
cp -R .cache/compliance/licenses "$APP_DIR/Contents/Resources/Licenses"
cp -R docs "$APP_DIR/Contents/Resources/docs"
cp THIRD_PARTY_NOTICES.md LICENSE "$APP_DIR/Contents/Resources/"
swift scripts/generate-icon.swift "$APP_DIR/Contents/Resources/AppIcon.icns"
python3 - "$APP_DIR" "$APP_VERSION" "$APP_BUILD" <<'PY'
import pathlib, plistlib, re, sys
app, version, build = sys.argv[1:]
if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not build.isdigit():
    raise SystemExit('APP_VERSION must be x.y.z and APP_BUILD must be numeric')
data = {
    'CFBundleName': 'AndroidOnMac', 'CFBundleDisplayName': 'AndroidOnMac',
    'CFBundleIdentifier': 'chat.xucheri.AndroidOnMac',
    'CFBundleExecutable': 'AndroidOnMac', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version, 'CFBundleVersion': build,
    'CFBundleIconFile': 'AppIcon', 'CFBundleDevelopmentRegion': 'zh_CN',
    'CFBundleLocalizations': ['zh_CN'], 'LSMinimumSystemVersion': '13.0',
    'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
    'NSLocalNetworkUsageDescription': '通过同一局域网发现、配对和连接您授权的 Android 手机，以显示画面并用键鼠操控。',
    'NSBonjourServices': ['_adb-tls-pairing._tcp', '_adb-tls-connect._tcp', '_adb._tcp'],
    'NSHumanReadableCopyright': 'Copyright © 2026 XuCheri. Third-party components retain their licenses.',
    'AndroidOnMacReleaseChannel': 'preview',
}
pathlib.Path(app, 'Contents', 'Info.plist').write_bytes(plistlib.dumps(data))
PY
plutil -lint "$APP_DIR/Contents/Info.plist"
# These are ad-hoc signatures for integrity, not Developer ID/notarization.
codesign --force --sign - "$APP_DIR/Contents/Resources/engine/adb"
codesign --force --sign - "$APP_DIR/Contents/Resources/engine/scrcpy"
codesign --force --sign - "$APP_DIR/Contents/MacOS/ProcessLauncher"
codesign --force --sign - "$APP_DIR/Contents/MacOS/AndroidOnMac"
codesign --force --sign - "$APP_DIR"
bash scripts/verify-app.sh "$APP_DIR"
printf 'Preview app built: %s\n' "$APP_DIR"
