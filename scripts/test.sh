#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_SWIFT_MAJOR="$(swift --version | sed -nE 's/.*Swift version ([0-9]+).*/\1/p')"
if [[ ! "$TASK_SWIFT_MAJOR" =~ ^[0-9]+$ ]] || (( TASK_SWIFT_MAJOR < 6 )); then
  echo 'Swift Testing requires Swift 6 or newer.' >&2
  exit 1
fi
TASK_DEVELOPER_DIR="$(xcode-select -p)"
TASK_TEST_ARGS=(--arch arm64 --disable-xctest --enable-swift-testing)
if [[ "$TASK_DEVELOPER_DIR" == */CommandLineTools ]]; then
  TASK_TEST_FRAMEWORKS="$TASK_DEVELOPER_DIR/Library/Developer/Frameworks"
  TASK_TEST_RUNTIME="$TASK_DEVELOPER_DIR/Library/Developer/usr/lib"
  if [[ ! -d "$TASK_TEST_FRAMEWORKS/Testing.framework" ]]; then
    echo 'The selected Command Line Tools do not include Testing.framework. Use a current Apple toolchain.' >&2
    exit 1
  fi
  if [[ ! -f "$TASK_TEST_RUNTIME/lib_TestingInterop.dylib" ]]; then
    echo 'The selected Command Line Tools do not include lib_TestingInterop.dylib. Use a complete current Apple toolchain.' >&2
    exit 1
  fi
  # Standalone CLT ships Apple's Testing.framework, but SwiftPM may not add its
  # search path automatically. Use the selected toolchain without modifying it.
  TASK_TEST_ARGS+=(
    -Xswiftc -F -Xswiftc "$TASK_TEST_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$TASK_TEST_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$TASK_TEST_RUNTIME"
    -Xlinker "-F$TASK_TEST_FRAMEWORKS"
  )
  printf 'Swift Testing: using framework from selected Command Line Tools.\n'
fi
exec swift test "${TASK_TEST_ARGS[@]}" "$@"
