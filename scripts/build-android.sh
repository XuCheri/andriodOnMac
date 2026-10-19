#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache/android-toolchain"
# Resolve symlinks before touching signing material. Ignoring a path in Git does
# not make it an appropriate place to keep a release key or password.
require_outside_checkout() {
  python3 - "$ROOT" "$1" <<'PY_PATH'
from pathlib import Path
import sys
root, candidate = (Path(value).resolve() for value in sys.argv[1:])
if candidate == root or root in candidate.parents:
    raise SystemExit('Android signing material must be stored outside the repository (including symlink targets).')
PY_PATH
}
SIGN_DIR="${ANDROIDONMAC_SIGNING_DIR:-$HOME/Library/Application Support/AndroidOnMac/android-signing}"
require_outside_checkout "$SIGN_DIR"
if [ -n "${AOM_ANDROID_KEYSTORE:-}" ]; then
  KEYSTORE="$AOM_ANDROID_KEYSTORE"
  require_outside_checkout "$KEYSTORE"
  [ -f "$KEYSTORE" ] || { echo 'AOM_ANDROID_KEYSTORE must reference a readable keystore file.' >&2; exit 1; }
else
  if [ -n "${CI:-}" ]; then echo 'CI release builds require AOM_ANDROID_KEYSTORE and signing secrets.' >&2; exit 1; fi
  KEYSTORE="$SIGN_DIR/receiver-release.p12"
  PASSFILE="$SIGN_DIR/receiver-release.password"
  require_outside_checkout "$KEYSTORE"
  require_outside_checkout "$PASSFILE"
  if [ ! -f "$KEYSTORE" ] || [ ! -f "$PASSFILE" ]; then
    echo 'Restore the existing release keystore and its password file, or provide AOM_ANDROID_KEYSTORE and signing secrets. Release signing identity is pinned; a new key is never generated automatically.' >&2
    exit 1
  fi
fi
SIGN_TMP_ROOT="${TMPDIR:-/tmp}"
require_outside_checkout "$SIGN_TMP_ROOT"
TEMP_SIGN=""
TEMP_APK=""
cleanup() {
  if [ -n "$TEMP_SIGN" ]; then rm -rf "$TEMP_SIGN"; fi
  if [ -n "$TEMP_APK" ]; then rm -f "$TEMP_APK" "$TEMP_APK.idsig"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bash "$ROOT/scripts/setup-android.sh"
TASK_JAVA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["java"])' "$CACHE/environment.json")"
TASK_SDK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sdk"])' "$CACHE/environment.json")"
env JAVA_HOME="$TASK_JAVA" ANDROID_HOME="$TASK_SDK" GRADLE_USER_HOME="$CACHE/gradle-home" \
  "$CACHE/gradle-8.11.1/bin/gradle" -p "$ROOT/android" --no-daemon testDebugUnitTest lintRelease assembleRelease "$@"
KEY_ALIAS="${AOM_ANDROID_KEY_ALIAS:-receiver}"
TEMP_SIGN="$(mktemp -d "$SIGN_TMP_ROOT/aom-android-signing.XXXXXX")"
if [ -n "${AOM_ANDROID_KEYSTORE:-}" ]; then
  PASSFILE="$TEMP_SIGN/store.password"
  KEYPASSFILE="$TEMP_SIGN/key.password"
  python3 - "$PASSFILE" "$KEYPASSFILE" <<'PY_SECRET'
import os, sys
store = os.environ.get('AOM_ANDROID_STORE_PASSWORD', '')
key = os.environ.get('AOM_ANDROID_KEY_PASSWORD', store)
if not store or not key: raise SystemExit('Android signing passwords are required for the supplied keystore.')
for path, value in zip(sys.argv[1:], [store, key]):
    with open(path, 'w') as f: f.write(value + '\n')
    os.chmod(path, 0o600)
PY_SECRET
else
  chmod 700 "$SIGN_DIR"
  chmod 600 "$KEYSTORE" "$PASSFILE"
  # apksigner consumes password files as streams; store/key must use separate files.
  KEYPASSFILE="$TEMP_SIGN/key.password"
  cp "$PASSFILE" "$KEYPASSFILE"
  chmod 600 "$KEYPASSFILE"
fi
mkdir -p "$ROOT/dist"
APK="$ROOT/dist/AndroidOnMac-Receiver-0.2.0-preview.1.apk"
# Keep the last verified release intact until every step succeeds. The staging
# file is on the destination filesystem so the final rename is atomic.
TEMP_APK="$(mktemp "$ROOT/dist/.receiver-release.XXXXXX")"
"$TASK_SDK/build-tools/35.0.0/zipalign" -f -p 4 "$ROOT/android/app/build/outputs/apk/release/app-release-unsigned.apk" "$TEMP_APK"
env JAVA_HOME="$TASK_JAVA" "$TASK_SDK/build-tools/35.0.0/apksigner" sign --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" \
  --ks-pass "file:$PASSFILE" --key-pass "file:$KEYPASSFILE" --v4-signing-enabled false "$TEMP_APK"
bash "$ROOT/scripts/verify-android.sh" "$TEMP_APK"
chmod 644 "$TEMP_APK"
mv -f "$TEMP_APK" "$APK"
TEMP_APK=""
shasum -a 256 "$APK"
printf 'Signed APK: %s\n' "$APK"
