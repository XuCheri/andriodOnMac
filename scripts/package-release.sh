#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
APP_DIR="$TASK_ROOT/dist/AndroidOnMac.app"
[[ -d "$APP_DIR" ]] || { echo 'Run scripts/build-app.sh first.' >&2; exit 1; }
bash scripts/verify-app.sh "$APP_DIR"
python3 scripts/fetch-dependencies.py --compliance
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
RELEASE_BASE="AndroidOnMac-$APP_VERSION-preview-arm64"
RECEIVER_APK="AndroidOnMac-Receiver-0.2.0-preview.1.apk"
test -s "dist/$RECEIVER_APK"
cmp "dist/$RECEIVER_APK" "$APP_DIR/Contents/Resources/AndroidOnMac-Receiver.apk"
PACKAGE_STAGE="$(mktemp -d "$TASK_ROOT/.cache/package.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
ditto "$APP_DIR" "$PACKAGE_STAGE/AndroidOnMac.app"
ln -s /Applications "$PACKAGE_STAGE/Applications"
cp docs/USER_GUIDE.md "$PACKAGE_STAGE/安装说明.md"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "dist/$RELEASE_BASE.zip"
hdiutil create -volname AndroidOnMac -srcfolder "$PACKAGE_STAGE" -ov -format UDZO "dist/$RELEASE_BASE.dmg"
COPYFILE_DISABLE=1 tar -czf "dist/$RELEASE_BASE-third-party-sources.tar.gz" -C .cache compliance
(
  cd dist
  shasum -a 256 "$RELEASE_BASE.zip" "$RELEASE_BASE.dmg" "$RELEASE_BASE-third-party-sources.tar.gz" "$RECEIVER_APK" > "$RELEASE_BASE-SHA256SUMS.txt"
)
printf 'Packaged preview binaries and matching third-party sources: dist/%s*\n' "$RELEASE_BASE"
