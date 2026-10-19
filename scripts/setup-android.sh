#!/bin/bash
# Downloads are confined to this checkout. No global Java/Android configuration is changed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache/android-toolchain"
mkdir -p "$CACHE/downloads"
fetch() {
  local url="$1" file="$2" expected="$3"
  if [ ! -f "$file" ]; then curl -fLsS --retry 3 "$url" -o "$file.part"; mv "$file.part" "$file"; fi
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then echo "SHA-256 mismatch: $(basename "$file")" >&2; exit 1; fi
}
fetch 'https://services.gradle.org/distributions/gradle-8.11.1-bin.zip' "$CACHE/downloads/gradle.zip" 'f397b287023acdba1e9f6fc5ea72d22dd63669d59ed4a289a29b1a76eee151c6'
if [ ! -x "$CACHE/gradle-8.11.1/bin/gradle" ]; then unzip -q "$CACHE/downloads/gradle.zip" -d "$CACHE"; fi
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
  fetch 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.15%2B6/OpenJDK17U-jdk_aarch64_mac_hotspot_17.0.15_6.tar.gz' "$CACHE/downloads/jdk.tar.gz" '1a2fa2bb9ea059cf2c1ab3e296a98e006fb6fdad2bd19ce52df48794eaa1836a'
  if [ ! -d "$CACHE/jdk-17.0.15+6" ]; then tar -xzf "$CACHE/downloads/jdk.tar.gz" -C "$CACHE"; fi
  TASK_JAVA="$CACHE/jdk-17.0.15+6/Contents/Home"
  fetch 'https://dl.google.com/android/repository/commandlinetools-mac-13114758_latest.zip' "$CACHE/downloads/commandline.zip" '5673201e6f3869f418eeed3b5cb6c4be7401502bd0aae1b12a29d164d647a54e'
  TASK_SDK="$CACHE/sdk"
  if [ ! -x "$TASK_SDK/cmdline-tools/19.0/bin/sdkmanager" ]; then
    mkdir -p "$TASK_SDK/cmdline-tools"
    unzip -q "$CACHE/downloads/commandline.zip" -d "$TASK_SDK/cmdline-tools"
    mv "$TASK_SDK/cmdline-tools/cmdline-tools" "$TASK_SDK/cmdline-tools/19.0"
  fi
else
  TASK_JAVA="${ANDROIDONMAC_JAVA_HOME:-${JAVA_HOME:-}}"
  TASK_SDK="${ANDROIDONMAC_SDK_ROOT:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}}"
  if [ ! -x "$TASK_JAVA/bin/java" ] || [ ! -d "$TASK_SDK" ]; then
    echo 'On this host provide JDK 17+ and Android SDK through ANDROIDONMAC_JAVA_HOME / ANDROIDONMAC_SDK_ROOT.' >&2; exit 1
  fi
fi
if [ ! -d "$TASK_SDK/platforms/android-35" ] || [ ! -d "$TASK_SDK/build-tools/35.0.0" ]; then
  SDKMANAGER="$TASK_SDK/cmdline-tools/19.0/bin/sdkmanager"
  [ -x "$SDKMANAGER" ] || SDKMANAGER="$TASK_SDK/cmdline-tools/latest/bin/sdkmanager"
  set +o pipefail
  yes | env JAVA_HOME="$TASK_JAVA" "$SDKMANAGER" --sdk_root="$TASK_SDK" --licenses > "$CACHE/licenses.log" 2>&1
  set -o pipefail
  env JAVA_HOME="$TASK_JAVA" "$SDKMANAGER" --sdk_root="$TASK_SDK" 'platforms;android-35' 'build-tools;35.0.0' > "$CACHE/sdk-install.log" 2>&1
fi
python3 - "$CACHE/environment.json" "$TASK_JAVA" "$TASK_SDK" <<'PY'
import json, sys
with open(sys.argv[1], 'w') as f: json.dump({'java':sys.argv[2], 'sdk':sys.argv[3]}, f)
PY
printf 'Android toolchain ready: JDK 17, Gradle 8.11.1, Android 35 / Build Tools 35.0.0\n'
