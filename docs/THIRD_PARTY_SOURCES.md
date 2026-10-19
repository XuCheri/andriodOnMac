# 对应源码与重新链接

每个 AndroidOnMac 预览二进制发行版必须在同一 GitHub Release 附上 `AndroidOnMac-<版本>-preview-arm64-third-party-sources.tar.gz`。这个附件供接收者复制、修改、重建和替换第三方组件，不要求访问 AndroidOnMac 的私有源码仓库。请勿只转发二进制而遗漏此附件。

附件解压后的 `compliance/` 包含：

- `sources/`：scrcpy 5.0.1、FFmpeg 9.0.2、SDL 3.4.18、libusb 1.0.30、dav1d 1.5.4、zlib 1.3.2 的完整上游源码压缩包。
- `licenses/`：源包内许可证，以及 ADB 37.0.1 官方 Platform Tools 的完整 NOTICE。
- `dependencies.lock.json`、`SHA256SUMS.txt`：固定下载来源、版本和 SHA-256。
- `rebuild-engine.sh`：编译并重新链接主机 scrcpy 的入口；scrcpy 源包自身含全部原始构建脚本。
- `REBUILD_MATERIALS_LICENSE.txt`：本项目提供的重建脚本、附件说明和清单使用 MIT 许可，可以复制和修改；各上游源码仍使用各自许可。

FFmpeg / libusb 使用 LGPL。提供其完整对应源代码，以及使用这些库的 scrcpy 完整源代码和构建材料，是 scrcpy 部分的静态重新链接方案。Swift 管理器独立调用 scrcpy，不链接 FFmpeg / libusb。此方案不覆盖 Google 预编译 ADB 自身的静态依赖。

## ADB 来源与未核实范围

ADB 37.0.1 使用 Google 官方预编译版本，二进制与官方 Platform Tools ZIP 中的 `adb` 完全一致，SHA-256 为 `1811e253b21b12cbfda7201ebaf86c10e7ddcb5c606a7a81f7c82b4c429c2d3b`。1,152,421 字节的官方完整 `NOTICE.txt` 原样保留，SHA-256 为 `356cc66516060e4da6bdc53e6f0bbb8e8101673f326b73c68d535eddd04dd7b1`。下载脚本独立校验这两个成员。

2026-10-19 的静态检查发现 ADB arm64 含 libusb 实现，`libusb_get_version()` 指向的版本结构为 1.0.29、nano 11982；`otool -L` 只列系统库。它与本包中为 scrcpy 提供的 libusb 1.0.30 源码不是同一版本。Google [37.0.1 发布说明](https://developer.android.com/tools/releases/platform-tools)也说明 macOS 可通过 `ADB_LIBUSB=1` 启用该后端。

可继续核实的官方来源：

- [ADB 源码及开发文档](https://android.googlesource.com/platform/packages/modules/adb/)
- [AOSP libusb 源码、补丁及构建文件](https://android.googlesource.com/platform/external/libusb/)
- [AOSP 构建 manifest](https://android.googlesource.com/platform/manifest/)

当日三个仓库的公开 refs 返回的 `platform-tools-*` 版本最高为 35.0.2，未发现 37.0.1 对应标签；`sdk-release` 分支的 libusb 版本文件为 1.0.27，也不能作为此二进制的对应源码。我们未核实 ADB 37.0.1 精确提交、所含 libusb 补丁及完整重新链接材料，不能用通用仓库入口或 scrcpy 源包替代这些证据。完整官方 NOTICE 不含 libusb 名称；本附件保留 LGPL 文本，但不声称已经填补 ADB 来源缺口。

当前附件支持用户个人私有预览的来源核对；`rebuild-engine.sh` 仅重建 scrcpy，不重建或重新链接 ADB。公开再分发前需另行补齐 ADB 的精确对应材料，或审查由使用者直接获取官方 ADB 的交付方式；当前实现没有改变依赖版本或获取流程。

## 构建条件

需要 Apple Silicon Mac、Xcode Command Line Tools、Python 3，以及 CMake、Meson、Ninja、pkg-config、autoconf、automake、GNU libtool。例如可由开发者自行使用 Homebrew 准备：

```sh
brew install cmake meson ninja pkg-config autoconf automake libtool
```

应用的日常运行不需要这些工具。脚本不自动安装工具，不写系统目录；库与产物都留在附件目录内。使用系统 Apple SDK 和工具链可能造成二进制差异，本项目不声称与上游的 CI 输出逐字节一致。

```sh
tar -xzf AndroidOnMac-<版本>-preview-arm64-third-party-sources.tar.gz
cd compliance
shasum -a 256 -c SHA256SUMS.txt
bash rebuild-engine.sh
```

默认产物是 `compliance/rebuild/client/app/scrcpy`。`REBUILD_DIR` 环境变量可指定另一个构建目录。原始构建方式见 `sources/scrcpy-v5.0.1.tar.gz` 内的 `release/build_macos.sh`、`app/deps/*.sh` 和 `doc/build.md`；入口使用相同库版本和静态链接配置，预先编译 zlib 至本地依赖前缀，避免依赖本机 Homebrew 的 zlib 版本。

要修改库，先解压和编辑对应源包，保存自己的修改和许可声明，再从更新后的本地源目录构建；不要把修改后的源码冒充校验和匹配的原始发行档。可直接复用解压后 `scrcpy-5.0.1/app/deps/work/sources/` 内的库源码，删除相应 build/install 目录并重跑对应上游脚本，然后重新链接主机客户端。

将重建后的 scrcpy 放进一份应用副本的 `Contents/Resources/engine/scrcpy`，保留匹配版本的 `scrcpy-server`。修改内容会使原签名失效，需要对该二进制和应用副本重新 ad-hoc 签名：

```sh
codesign --force --sign - /你的路径/AndroidOnMac.app/Contents/Resources/engine/scrcpy
codesign --force --sign - /你的路径/AndroidOnMac.app
```

这些命令不关闭 Gatekeeper，也不等同于 Developer ID 签名或 Apple 公证。配套 server 可保持官方 5.0.1；其完整源代码同样在 scrcpy 源档中，若重建 Android server 需按上游文档另备 Java / Android SDK。

## 来源依据与当前验证边界

FFmpeg、SDL、libusb、dav1d 的版本和校验和来自 scrcpy v5.0.1 的固定构建脚本。zlib 1.3.2 来自该官方二进制中的版本标识，与 [zlib 官方发布及校验和](https://zlib.net/) 对应。二进制 `otool -L` 检查不依赖 Homebrew 动态库。

六个 scrcpy 及库源码包的下载、校验、许可提取及附件生成由打包脚本执行并验证。首次预览没有把“完整重新编译所有第三方库”作为已完成测试；若构建环境产生兼容问题，应保留日志并修复入口，不把拥有源码等同于已经完成重建回归。ADB 来源范围以本页上方的单独说明为准。
