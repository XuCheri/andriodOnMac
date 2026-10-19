#!/bin/bash
# Validate a release artifact without needing the private signing key.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="${1:-$ROOT/dist/AndroidOnMac-Receiver-0.2.0-preview.1.apk}"
if [ "$#" -gt 1 ] || [ ! -f "$APK" ] || [ ! -s "$APK" ]; then
  echo 'Usage: verify-android.sh [nonempty APK file]' >&2
  exit 1
fi
APK="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$APK")"
CACHE="$ROOT/.cache/android-toolchain"
bash "$ROOT/scripts/setup-android.sh"
TASK_JAVA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["java"])' "$CACHE/environment.json")"
TASK_SDK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sdk"])' "$CACHE/environment.json")"
BUILD_TOOLS="$TASK_SDK/build-tools/35.0.0"
# This public certificate digest deliberately pins the existing update identity.
# A different certificate requires an explicit release/migration decision.
EXPECTED_CERT='a2f06c0ce3442717f88d47d5ed8d6ff8615ee6e6b985df377652c029881e5973'
CERTIFICATES="$(env JAVA_HOME="$TASK_JAVA" "$BUILD_TOOLS/apksigner" verify --print-certs "$APK")"
printf '%s\n' "$CERTIFICATES" | python3 -c '
import re, sys
digests = re.findall(r"^Signer #[0-9]+ certificate SHA-256 digest: ([0-9a-fA-F]+)$", sys.stdin.read(), re.M)
if [value.lower() for value in digests] != [sys.argv[1]]:
    raise SystemExit("APK release certificate mismatch: refusing an unknown signing identity.")
' "$EXPECTED_CERT"
"$BUILD_TOOLS/zipalign" -c -p 4 "$APK"
"$BUILD_TOOLS/aapt" dump badging "$APK" | python3 -c '
import re, sys
text = sys.stdin.read()
expected = {
    "package name": (r"^package: name=\x27([^\x27]+)\x27", "chat.xucheri.androidonmac.receiver"),
    "versionCode": (r"^package: .*\bversionCode=\x27([^\x27]+)\x27", "2"),
    "versionName": (r"^package: .*\bversionName=\x27([^\x27]+)\x27", "0.2.0-preview.1"),
    "minSdk": (r"^sdkVersion:\x27([^\x27]+)\x27", "30"),
    "targetSdk": (r"^targetSdkVersion:\x27([^\x27]+)\x27", "35"),
    "launchable activity": (r"^launchable-activity: name=\x27([^\x27]+)\x27", "chat.xucheri.androidonmac.receiver.MainActivity"),
}
for name, (pattern, value) in expected.items():
    match = re.search(pattern, text, re.M)
    if not match or match.group(1) != value:
        raise SystemExit("APK " + name + " mismatch: release artifact rejected.")
'
printf 'Verified Android receiver: release signature, package, version 0.2.0-preview.1 (2), SDK 30/35, launcher and alignment.\n'
