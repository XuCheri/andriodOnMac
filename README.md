# AndroidOnMac

在 Mac 上看见并操控自己的 Android 手机。原生 macOS 管理界面负责设备、无线配对和画质设置，scrcpy 负责独立镜像窗口中的实时画面、声音及键鼠操作。

**当前为 0.1.0 预览版**，面向 Apple Silicon、macOS 13 及以上。源码与安装包在 [XuCheri/andriodOnMac](https://github.com/XuCheri/andriodOnMac) 管理。真机画质、输入、音频及长时间稳定性须按 [验收清单](docs/ACCEPTANCE.md) 记录，不能把构建通过当成手机端验收通过。

## 使用方式

1. 从 [Releases](https://github.com/XuCheri/andriodOnMac/releases) 下载 arm64 预览 DMG，拖入“应用程序”。运行不需要终端或 Homebrew。
2. 在 Android 上开启开发者选项、USB 调试，通过数据线连接，解锁手机并允许这台 Mac 调试。
3. 打开 AndroidOnMac，选择已授权设备并开始镜像。在镜像窗口中点击、滑动和输入。
4. 无线使用需要同一局域网。Android 11+ 在手机“无线调试”中使用配对码，分别填写配对地址与连接地址；两者端口通常不同。

首次连接必须由手机所有者授权。具体步骤和未公证预览包的正常打开流程见 [安装与连接](docs/INSTALL.md)。

## 能力与边界

- USB 镜像与键鼠操控；同一局域网的 Android 无线调试配对和连接。
- 画质预设、音频、剪贴板与输入模式等会话选项。切换启动参数需要重新开始镜像。
- H.264 与自动硬件解码优先，减少额外缓冲；可调低分辨率/码率以适应网络。
- Android 5.0+ 可镜像；音频需 Android 11+；Android 11 启动音频时需解锁。
- 默认 SDK 输入兼容性广，但不能完整输入中文；UHID 使用手机端实体键盘/输入法。Mac 已输入的中文可通过复制粘贴传入，具体 App 需真机测试。
- 手机的受保护内容可能无法截屏；不能绕过锁屏、授权或应用自身限制。当前不提供跨公网连接或云端中继。

镜像性能取决于手机编码器、画质和链路。上游的 35–70 ms 是参考测量，不是本项目对所有设备的保证。

## 本地开发

开发环境：Apple Silicon Mac、Swift 6+、Python 3。包含 Swift Testing 的新版 Command Line Tools 即可，不要求安装完整 Xcode；本机已升级至 CLT 26.6 / Swift 6.3.3。应用运行要求仍为 macOS 13+。

```sh
bash scripts/fetch-engine.sh
bash scripts/test.sh
bash scripts/build-app.sh
open dist/AndroidOnMac.app
```

依赖仅从固定官方来源下载，并检查 `scripts/dependencies.lock.json` 中的 SHA-256。依赖缓存位于 `.cache/engine`，应用打包后位于 `Contents/Resources/engine`。

测试采用原生 Swift Testing，统一通过 `scripts/test.sh` 调用 `swift test`；独立 CLT 会自动补上所选 Apple 工具链自带的 Testing.framework 搜索与运行路径，完整 Xcode 不需要额外参数。本地与 CI 均使用 SwiftPM，脚本不会安装或修改系统工具。开发约定见 [贡献指南](CONTRIBUTING.md)。

```sh
bash scripts/package-release.sh
```

生成 `dist/` 中的 DMG、ZIP、SHA-256 以及必需的第三方源包。详情见 [构建与发布](docs/BUILD_RELEASE.md)。

## 第三方许可

此软件使用 scrcpy 和 FFmpeg 等开源组件。FFmpeg / libusb 静态链接所需的完整对应源码和重新链接入口，与每个二进制 Release 一同分发。使用者可在不访问本项目源码的情况下重建这些组件。详见 [第三方声明](THIRD_PARTY_NOTICES.md) 和 [源码附件说明](docs/THIRD_PARTY_SOURCES.md)。自有代码的权利范围见 [LICENSE](LICENSE)。
