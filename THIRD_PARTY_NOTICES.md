# 第三方组件声明

AndroidOnMac 的镜像和控制引擎来自 [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy)。本项目不是 Genymobile、Google 或 Apple 的官方产品。原生管理界面通过独立进程调用引擎；镜像视频不经过网页转码。

| 组件 | 锁定版本 | 许可及用途 |
| --- | --- | --- |
| scrcpy / scrcpy-server | 5.0.1 | Apache-2.0；Android 画面、音频和控制 |
| FFmpeg | 9.0.2 | LGPL-2.1-or-later；静态链接到 scrcpy 的音视频处理库 |
| libusb（scrcpy） | 1.0.30 | LGPL-2.1-or-later；静态链接到 scrcpy 的 USB 功能 |
| SDL | 3.4.18 | Zlib；窗口、输入、音频与渲染 |
| dav1d | 1.5.4 | BSD-2-Clause；AV1 解码 |
| zlib | 1.3.2 | Zlib；压缩支持 |
| Android Debug Bridge / Platform Tools | 37.0.1 | 官方预编译；Apache-2.0 及第三方许可，包含静态 libusb；设备连接 |
| libusb（ADB 内置） | 1.0.29（arm64 版本结构 nano 11982） | LGPL；精确 AOSP 提交、补丁与 ADB 构建对应关系未核实 |

scrcpy 的版权属于 Genymobile、Romain Vimont 及其贡献者；各依赖的版权和完整许可原文保留在 `.app/Contents/Resources/Licenses/`。ADB 的完整 `NOTICE.txt` 取自对应版本官方 Platform Tools 包，不能用 scrcpy 的 Apache 许可替代。源码中的单独文件可能附有其他兼容许可，以这些原文为准。

官方 macOS scrcpy 将 FFmpeg / libusb 静态链接，因此仅提供许可证或指向上游仓库的链接不够。本项目的每个二进制发行版必须同时提供 `*-third-party-sources.tar.gz`：包含 scrcpy 及其五个库的完整上游源文件、校验和、原始构建脚本，以及本项目的 scrcpy 重建入口。接收者可重新编译 scrcpy，并用修改后的 LGPL 库重新链接。详见 [源码与重新链接说明](docs/THIRD_PARTY_SOURCES.md)。

ADB 保持 Google 37.0.1 官方预编译版本，完整官方 NOTICE 逐字节保留。其[源码入口](https://android.googlesource.com/platform/packages/modules/adb/)和 [AOSP libusb 入口](https://android.googlesource.com/platform/external/libusb/)可供继续核对；目前没有核实该二进制的精确源码、补丁和构建对应关系。官方 NOTICE 不含 libusb 名称，本包另保留 libusb 的 LGPL 文本，但这不等同于补齐 ADB 的对应源码或重新链接材料。所附六个源码包和 `rebuild-engine.sh` 只覆盖 scrcpy 及其库，不承诺重建 ADB。本次交付为用户自己账户中的私有个人预览，公开再分发前仍需完成这项来源核实。

FFmpeg 的上游构建配置没有启用 `--enable-gpl` 或 `--enable-nonfree`。本项目不改变这些配置，不对使用者修改 LGPL 组件或调试这些修改施加额外限制。macOS 系统框架不随本应用重新分发。

此预览包仅对官方引擎执行必要的 ad-hoc 代码签名，未修改上游功能。原始包与源包的版本、来源和 SHA-256 固定在 `scripts/dependencies.lock.json`，禁止自动改用 latest。
