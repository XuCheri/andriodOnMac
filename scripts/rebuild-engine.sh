#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 XuCheri. See REBUILD_MATERIALS_LICENSE.txt in the source bundle.
# Rebuild scrcpy and its libraries only, not the separately shipped Google ADB.
# Run from the unpacked third-party source bundle. Does not install any tooling.
set -euo pipefail
SOURCE_BUNDLE="$(cd "$(dirname "$0")" && pwd)"
REBUILD_DIR="${REBUILD_DIR:-$SOURCE_BUNDLE/rebuild}"
for task_tool in cmake meson ninja pkg-config autoconf automake libtoolize make python3; do
  if ! command -v "$task_tool" >/dev/null 2>&1; then
    if [[ "$task_tool" == libtoolize ]] && command -v glibtoolize >/dev/null 2>&1; then
      continue
    fi
    printf 'Missing build tool: %s (see README.md)\n' "$task_tool" >&2
    exit 1
  fi
done
[[ "$(uname -m)" == arm64 ]] || { echo 'Use an Apple Silicon Mac.' >&2; exit 1; }
cd "$SOURCE_BUNDLE"
shasum -a 256 -c SHA256SUMS.txt
mkdir -p "$REBUILD_DIR"
SCRCPY_SOURCE="$REBUILD_DIR/scrcpy-5.0.1"
[[ -d "$SCRCPY_SOURCE" ]] || tar -xzf sources/scrcpy-v5.0.1.tar.gz -C "$REBUILD_DIR"
mkdir -p "$SCRCPY_SOURCE/app/deps/work/sources"
cp sources/ffmpeg-9.0.2.tar.xz sources/sdl-3.4.18.tar.gz \
   sources/libusb-1.0.30.tar.gz sources/dav1d-1.5.4.tar.xz \
   "$SCRCPY_SOURCE/app/deps/work/sources/"
cd "$SCRCPY_SOURCE"
# Use the supplied, unmodified source scripts; no Java/Android SDK needed to
# rebuild the host executable. The server remains the matching v5.0.1 artifact.
app/deps/sdl.sh macos native static
app/deps/dav1d.sh macos native static
DEPS_INSTALL_DIR="$SCRCPY_SOURCE/app/deps/work/install/macos-native-static"
[[ -d "$REBUILD_DIR/zlib-1.3.2" ]] || tar -xzf "$SOURCE_BUNDLE/sources/zlib-1.3.2.tar.gz" -C "$REBUILD_DIR"
(
  cd "$REBUILD_DIR/zlib-1.3.2"
  ./configure --static --prefix="$DEPS_INSTALL_DIR"
  make -j"$(getconf _NPROCESSORS_ONLN)"
  make install
)
app/deps/ffmpeg.sh macos native static
app/deps/libusb.sh macos native static
unset PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR="$DEPS_INSTALL_DIR/lib/pkgconfig"
if [[ ! -f "$REBUILD_DIR/client/build.ninja" ]]; then
  meson setup "$REBUILD_DIR/client" \
      -Dc_args="-I$DEPS_INSTALL_DIR/include" \
      -Dc_link_args="-L$DEPS_INSTALL_DIR/lib" \
      --buildtype=release --strip -Db_lto=true \
      -Dcompile_server=false -Dportable=true -Dstatic=true
fi
ninja -C "$REBUILD_DIR/client"
printf 'Rebuilt executable: %s/client/app/scrcpy\n' "$REBUILD_DIR"
printf 'ADB is an official prebuilt; this script does not rebuild or relink ADB. See README.md.\n'
