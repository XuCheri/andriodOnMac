AndroidOnMac 预览版：在 Apple Silicon Mac 上通过 USB / 同一局域网查看并操控自己授权的 Android 手机，内置 scrcpy 5.0.1 和 ADB。

- 要求 macOS 13+，当前仅 arm64；无需 Homebrew。
- Android 11+ 无线配对请区分配对端口与连接端口。
- 包含 DMG、ZIP、SHA-256 和配套第三方完整源包；FFmpeg / libusb 等重新链接材料在源包中。
- 当前为 ad-hoc 签名，未获 Apple 公证；按安装文档使用系统“隐私与安全性 → 仍要打开”，不关闭 Gatekeeper。
- 真机的性能、中文输入、音频和长期稳定性以验收记录为准；构建检查不能替代真机验收。
- 当前不支持跨公网远控，未部署 ECS 或公网 ADB 服务。

本次验证：Mac mini M2 / macOS 26.4.1 与 Xiaomi 23117RK66C / Android 16。用户已确认 USB 和 Wi-Fi 的画面、点击滑动正常，并反馈中文粘贴正常；音频暂未测试。52 项自动测试、release 构建与本地应用签名/内置依赖检查通过。精确时延、持续帧率、30 分钟稳定性及剩余真机项目见 [验收记录](https://github.com/XuCheri/andriodOnMac/blob/main/docs/ACCEPTANCE.md)。

已知真机问题：该手机短时无线会话后出现过无线调试开关自行关闭，Mac 检测到服务消失后有限重试并停止。触发原因仍待复现，无线稳定性尚未通过验收；需要持续使用可先选择 USB。

此软件使用 FFmpeg（LGPL-2.1-or-later）等组件。完整对应源码、许可和重建入口可在本 Release 的 `*-third-party-sources.tar.gz` 下载。

源码附件覆盖 scrcpy 及其库；Google 预编译 ADB 的完整官方 NOTICE 已保留，但精确构建源码映射仍未核实，详见 [来源范围](https://github.com/XuCheri/andriodOnMac/blob/main/docs/THIRD_PARTY_SOURCES.md)。当前仅交付个人私有预览。
