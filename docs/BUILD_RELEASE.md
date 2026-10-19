# 构建与发布

## 依赖与产物

`scripts/fetch-engine.sh` 从官方 scrcpy v5.0.1 下载 arm64 静态包，SHA-256 为 `33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b`。下载先写临时文件、校验后替换；解压只复制预期的普通文件。版本不跟随 latest。

`scripts/build-app.sh` 要求 Swift 6+，统一使用 SwiftPM release 构建。包含 Swift Testing 的新版独立 Command Line Tools 即可，不要求完整 Xcode；独立 CLT 没有 Xcode PlatformPath 不会触发降级。旧工具链会明确报错，不再使用手动 swiftc 构建。产物架构与最低运行系统仍为 arm64 / macOS 13。

构建生成原生 AppKit 绘制图标、Info.plist 和中文本地网络权限说明，内置完整引擎与许可。依次为嵌套可执行文件、主程序和 `.app` ad-hoc 签名。`verify-app.sh` 检查签名、arm64 架构、系统动态库路径、依赖与许可证，并运行引擎版本命令；这些检查不建立手机连接。

`Sources/ProcessLauncher/main.c` 由系统 clang 编译为同目录的 `Contents/MacOS/ProcessLauncher`，目标同样为 arm64 / macOS 13，无额外运行库。这个受控进程启动器负责清理本应用会话拥有的进程组，随主程序一起签名和验证。

```sh
bash scripts/fetch-engine.sh
bash scripts/test.sh
APP_VERSION=0.1.0 APP_BUILD=1 bash scripts/build-app.sh
bash scripts/package-release.sh
```

发布文件：

- `AndroidOnMac-0.1.0-preview-arm64.dmg`
- `AndroidOnMac-0.1.0-preview-arm64.zip`
- `AndroidOnMac-0.1.0-preview-arm64-third-party-sources.tar.gz`
- `AndroidOnMac-0.1.0-preview-arm64-SHA256SUMS.txt`

最后两项是发行交付的一部分。发布源包让 scrcpy 及其 LGPL 库的接收者能够重新构建和链接，不用获得私有 Swift 管理器源码访问权。Google 预编译 ADB 的精确源码/构建对应关系尚未核实，不能把此源包表述为覆盖 ADB 的重新链接方案；当前交付为个人私有预览。详见 [对应源码说明及 ADB 范围](THIRD_PARTY_SOURCES.md)。

## GitHub Actions

`main` push / PR 运行 Bash / Python 语法检查，先获取固定引擎，再通过 `scripts/test.sh` 运行 Swift Testing（含引擎集成测试）、release 构建和打包校验。测试脚本只在独立 CLT 环境补充所选工具链内的 Testing.framework 路径；完整 Xcode 使用原生 SwiftPM 参数。`macos-15` 当前是 GitHub 官方 arm64 runner 标签，工作流还检查架构与 Swift 6+ 工具链，避免标签变化时生成错误产物。

`v*` tag 在上述检查成功后创建 **Prerelease** 并上传四类文件。即使 tag 名为 `v1.0.0`，现有工作流也不会自动宣称正式稳定发布。升级正式版之前需要完成真机验收、明确已验证的机型/系统、完成发行签名策略，再单独修改发布策略。

私有仓库中的 Release 仍受仓库访问权限约束。发布到 GitHub 不等于对所有人公开源码或安装包。

## Developer ID 与公证

当前流程未使用 Developer ID，也未调用 Apple 公证服务。不能把 `codesign --verify` 成功表述为已公证；它只验证包内签名一致性。

后续正式分发需要有效 Developer ID、Hardened Runtime 和时间戳，对全部可执行内容签名，以 `notarytool` 上传并审查结果，再 stapling。凭据只能由发布环境的受控密钥链/Secret 提供，不进入仓库。当前代码不会搜索、读取或自动使用开发者私钥。
