# AndroidOnMac

- 默认中文交流与提交信息；只提交本任务内已验证的变更。
- Swift 6+ 工具链（Swift 5 语言兼容模式）/ macOS 13+；核心逻辑放 AndroidOnMacCore，界面与 AppKit 集成放 AndroidOnMac。
- scrcpy / adb 依赖锁定版本和 SHA-256，不自动拉取 latest。
- 所有进程使用 executableURL 与参数数组；ADB 操作必须选择设备。
- 禁止全局 adb kill-server、pkill 或终止用户既有进程；只清理应用拥有的进程。
- 不把配对码、ADB 密钥、剪贴板或手机内容写入日志/仓库。
- 真机未验证时明确写待验收；首版只支持 USB 与同一局域网。
- 必要检查：bash scripts/test.sh、swift build -c release、git diff --check；发布前验证包内依赖与签名。
