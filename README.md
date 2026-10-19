# AndroidOnMac

在 Mac 与 Android 之间双向传输画面：用 Mac 查看、操控 Android；也可以把 Mac 屏幕送到 Android，或将 Android 用作实验性扩展副屏。

**当前为 0.2.0-preview.1 预览版。** Mac 端要求 Apple Silicon、macOS 13+；接收 Mac 画面的 Android App 要求 Android 11+。源码与发行包由 [XuCheri/andriodOnMac](https://github.com/XuCheri/andriodOnMac) 管理。Mac → 手机的 USB 镜像、点击拖动、独立副屏已获真机确认；Wi-Fi 拔掉 USB 后的画面与触控也已确认。最新接收端的横屏全屏、缩放和平移、手机键盘中文直输及回车退格已由用户确认正常；音频与长期稳定性仍待验收。

| 使用方向 | 连接方式 | 手机需要安装 App 吗 |
| --- | --- | --- |
| 手机 → Mac | USB；Android 11+ 无线调试 | 不需要；由内置 scrcpy 显示画面并提供键鼠控制 |
| Mac → 手机：镜像屏幕 | USB；同一 Wi-Fi 扫码 | 需要 AndroidOnMac 接收端，Android 11+ |
| Mac → 手机：扩展副屏 | 与镜像相同 | 需要接收端；虚拟显示功能为实验性功能 |

## 开始使用

1. 从 [Releases](https://github.com/XuCheri/andriodOnMac/releases) 下载 Mac DMG，拖入“应用程序”。无需 Homebrew。
2. 查看手机画面：选择“手机 → Mac”，用数据线连接手机、开启 USB 调试并授权，然后开始镜像。
3. 查看 Mac 画面：选择“Mac → 手机”，先通过 USB“安装接收端”，并在系统设置中授予 Mac 屏幕录制权限。选择镜像屏幕或实验性扩展副屏后开始投屏。
4. 接收端安装完成后，也可以拔线并选择“同一 Wi-Fi”，用手机接收端扫描 Mac 二维码，再在 Mac 确认新设备。**这条扫码连接不使用 Android 无线调试，也不需要配对端口。**

Mac → 手机的触控需要 Mac 辅助功能权限；未授权仍可观看。Mac 音频传输默认关闭，可在开始前开启。一次只运行一个方向的会话。完整步骤与正常打开未公证预览包的方法见 [用户指南](docs/USER_GUIDE.md)。

## 能力与边界

- Mac → 手机采用原生 ScreenCaptureKit、硬件 H.264 编码和 Android 原生解码；可选 AAC 系统声音、触控与快捷键。接收端提供手机键盘直接输入，中文在输入法确认组词后进入 Mac；本机已验证中文、回车和退格，其他输入法兼容性仍待验证。
- 竖屏保留“键盘”、“横屏”和“更多”；横屏自动全屏，仅保留小菜单入口。双指捏合放大文字，放大后双指平移，单指始终操作 Mac。已在本机 USB 副屏会话中获得用户确认。
- 扩展副屏是独立桌面，可以拖入窗口；依赖未公开的 macOS 虚拟显示接口，兼容性可能随系统更新变化。失败时可改用镜像屏幕。
- Mac → 手机连接使用 TLS、固定证书指纹和设备配对；新设备必须由 Mac 确认。仅处理用户主动开始的会话。
- 接收端进入后台、锁屏或停止时结束共享；Mac 锁定或睡眠也停止共享。短暂断线只进行有限重连，不提供无人值守访问。
- 手机 → Mac 仍支持 Android 5.0+ 镜像；声音需 Android 11+。SDK 逐键输入的中文有限制，中文粘贴和 UHID 的区别见指南。
- 当前仅支持 USB 与同一局域网，没有公网中继或 ECS 服务。不能绕过系统锁屏、授权或受保护内容限制。

延迟和流畅度取决于设备、分辨率及链路，不承诺所有设备达到固定毫秒数或持续 60 fps。本机 USB 短时 ACK 快照约 56–58 fps、接收队列为 0，这不能证明长期性能。0.1 版的 USB／Wi-Fi 画面与旧无线调试不稳定记录、新版实测范围，均保存在 [验收记录](docs/ACCEPTANCE.md)；**30 分钟稳定性尚未通过验收**。

## 本地开发

Mac 使用 Swift 6+、Swift 5 兼容模式与 Swift Testing；包含 Testing.framework 的新版 Command Line Tools 即可，不要求完整 Xcode。Android 构建使用仓库内缓存的 JDK 17、Gradle 和 Android SDK，不要求安装 Android Studio。

```sh
bash scripts/fetch-engine.sh
bash scripts/test.sh
bash scripts/build-android.sh
bash scripts/build-app.sh
open dist/AndroidOnMac.app
```

`build-android.sh` 首次会下载固定版本工具并安装所需 SDK；正式预览包必须使用维护者保存在**仓库外**的原始签名身份，缺少密钥时构建会停止，不会生成替代身份。自行开发可构建 debug APK；不要提交或上传私钥与密码。环境、签名和 CI Secret 的说明见 [构建与发布](docs/BUILD_RELEASE.md)。

```sh
bash scripts/package-release.sh
```

发行交付包含 Mac DMG／ZIP、Android APK、校验和及第三方源包。开发约定见 [贡献指南](CONTRIBUTING.md)。

## 第三方许可

scrcpy 及其 FFmpeg、libusb 等库的对应源码和重建／重新链接入口随 Release 提供。**此范围不包括 Google 预编译 ADB：其完整官方 NOTICE 已保留，但精确源码、补丁和构建映射仍未核实，不能宣称附件可重建 ADB。**

虚拟显示辅助程序保留 DeskPad MIT 声明；Android 接收端包含 Kotlin、AndroidX、ZXing 等 Apache-2.0 组件声明，可在手机“连接选项 → 开源许可”查看。详见 [第三方声明](THIRD_PARTY_NOTICES.md)、[源码附件范围](docs/THIRD_PARTY_SOURCES.md) 和自有代码的 [LICENSE](LICENSE)。
