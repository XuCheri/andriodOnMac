# 开发与验证

开发需要 Apple Silicon Mac、Swift 6+、Python 3 及 macOS SDK。包含 Swift Testing 的新版独立 Command Line Tools 可以完成 SwiftPM 构建和测试，不必安装完整 Xcode；当前本机工具链为 CLT 26.6 / Swift 6.3.3。应用最低运行版本仍是 macOS 13。

核心测试使用原生 Swift Testing 的 `@Test`、`#expect` 等接口，不依赖 XCTest。不要重新引入仅完整 Xcode 才具备的 XCTest 路径。新增行为应放在 `AndroidOnMacCore` 并为实际边界补充测试；界面与 AppKit 集成放在 `AndroidOnMac`。

```sh
bash scripts/fetch-engine.sh
bash scripts/test.sh
bash scripts/build-app.sh
bash scripts/package-release.sh
git diff --check
```

先获取固定引擎，确保引擎集成测试实际执行。`scripts/test.sh` 关闭 XCTest 运行器并开启 Swift Testing；它通过 `xcode-select -p` 判断所选工具链，仅对独立 CLT 自带的 Testing.framework 补充编译搜索路径、链接路径及 rpath，完整 Xcode 不加这些参数。不下载框架，不修改 Apple 工具链，也不硬编码开发者路径。

可给脚本追加 SwiftPM 参数，例如 `bash scripts/test.sh --filter DeviceParserTests`。旧 Swift 5.x 会明确报错，不靠手动编译绕过测试。不能把构建通过、模拟会话或自动检查等同于真机画面和操作验收。

所有设备操作必须明确选择设备。进程只能清理本应用拥有的会话与进程组，不得终止用户已有 ADB 服务。不要把配对码、ADB 密钥、剪贴板正文或手机内容写入日志、测试快照或仓库。

提交前核对变更范围，并记录实际通过的检查。发行时必须一起提供第三方对应源码和重新链接材料；工具链与发布步骤见 [构建与发布](docs/BUILD_RELEASE.md)。
