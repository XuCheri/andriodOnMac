AndroidOnMac 预览版：在 Apple Silicon Mac 上通过 USB / 同一局域网查看并操控自己授权的 Android 手机，内置 scrcpy 5.0.1 和 ADB。

- 要求 macOS 13+，当前仅 arm64；无需 Homebrew。
- Android 11+ 无线配对请区分配对端口与连接端口。
- 包含 DMG、ZIP、SHA-256 和配套第三方完整源包；FFmpeg / libusb 等重新链接材料在源包中。
- 当前为 ad-hoc 签名，未获 Apple 公证；按安装文档使用系统“隐私与安全性 → 仍要打开”，不关闭 Gatekeeper。
- 真机的性能、中文输入、音频和长期稳定性以验收记录为准；构建检查不能替代真机验收。
- 当前不支持跨公网远控，未部署 ECS 或公网 ADB 服务。

此软件使用 FFmpeg（LGPL-2.1-or-later）等组件。完整对应源码、许可和重建入口可在本 Release 的 `*-third-party-sources.tar.gz` 下载。
