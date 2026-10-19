# 构建与发布 · 0.2.0-preview.1

## 构建环境与顺序

Mac 构建要求 Apple Silicon、Swift 6+、Python 3。包含 Swift Testing 的新版 Command Line Tools 即可，不要求完整 Xcode；Swift 源码使用 Swift 5 兼容模式，应用最低系统仍为 macOS 13。独立 CLT 缺少 Xcode PlatformPath 不会触发手动 swiftc 降级。

```sh
bash scripts/fetch-engine.sh
bash scripts/test.sh
bash scripts/build-android.sh
APP_VERSION=0.2.0 APP_BUILD=1 bash scripts/build-app.sh
bash scripts/package-release.sh
```

`test.sh` 在独立 CLT 上自动使用所选 Apple 工具链自带的 Testing.framework 搜索和运行路径；完整 Xcode 使用原生 SwiftPM 参数。测试工具链自身的最低运行系统要求，与最终 App 的 macOS 13 部署目标是不同事项。

## Android 命令行构建

无需 Android Studio。Apple Silicon 上的 `setup-android.sh` 将 JDK 17.0.15+6、Gradle 8.11.1、Android command line tools 19.0 下载到 `.cache/android-toolchain`，校验固定 SHA-256，并安装 Android SDK 35 / Build Tools 35.0.0。首次需要联网；脚本会接受 SDK 安装许可，执行前应了解所用 Android 工具的许可条件。环境只传给构建子进程，不修改全局 Java／SDK 配置。

其他主机通过 `ANDROIDONMAC_JAVA_HOME`、`ANDROIDONMAC_SDK_ROOT` 指定现有环境。`build-android.sh` 会调用环境准备，再运行 `testDebugUnitTest`、`lintRelease`、`assembleRelease`，随后 zipalign、签名及 APK 签名验证。Android 运行最低版本为 Android 11 / API 30。

直接依赖版本记录在 Android Gradle 文件中；解析后的依赖锁位于 `android/app/gradle.lockfile` 与 `android/buildscript-gradle.lockfile`，SHA-256 验证文件为 `android/gradle/verification-metadata.xml`。版本升级时应连同实际解析结果、许可材料和验证记录一起审查，不能仅修改显示出来的版本号。

### APK 持久签名身份

本项目的持久 PKCS#12 发布私钥及密码保存在仓库外的 `~/Library/Application Support/AndroidOnMac/android-signing/`，目录权限 0700，文件权限 0600。也可设置 `ANDROIDONMAC_SIGNING_DIR` 指向持有同一发布身份的仓库外目录。验证脚本固定了公开证书指纹；缺少密钥时必须恢复原密钥或注入同一身份，不自动生成新身份。构建脚本拒绝位于仓库内（含符号链接）的签名路径。

保留并安全备份这份身份。后续 APK 更新必须使用同一私钥；脚本不会覆盖已有私钥，缺少对应密码时会报错。不要把私钥、密码、签名目录或这些文件的副本提交到仓库、日志或 Release。

使用外部密钥时设置 `AOM_ANDROID_KEYSTORE`、`AOM_ANDROID_STORE_PASSWORD`、`AOM_ANDROID_KEY_PASSWORD`，别名默认为 `receiver`，可用 `AOM_ANDROID_KEY_ALIAS` 指定。密码通过权限受限的临时文件交给签名工具，任务结束删除；不要把明文密码写进命令历史或共享配置。

## Mac 打包与发行附件

`scripts/fetch-engine.sh` 固定使用官方 scrcpy v5.0.1 arm64 包，SHA-256 为 `33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b`。下载先校验再使用，不跟随 latest；引擎和对应源码来源记录在 `scripts/dependencies.lock.json`。

`build-app.sh` 用 SwiftPM release 构建主程序和 `VirtualDisplayHelper`，并编译受控进程启动器 `ProcessLauncher`。App 包含引擎、Android 接收端 APK、离线用户指南、DeskPad MIT 声明和 Android 组件许可。本地打包始终重新运行 Android 构建，避免沿用旧 APK；CI 以 `AOM_ANDROID_PREBUILT=1` 接收同一工作流的签名 APK，并在嵌入前核验签名、包名与版本。APK 先写临时文件，签名及验证全部成功后才原子替换发行路径。

图标由本机 AppKit 绘制。打包依次对嵌套可执行文件、主程序与 App 做 ad-hoc 签名；`verify-app.sh` 检查签名、arm64 架构、动态库路径、依赖、许可证和引擎版本，也核验内置 APK 的签名及应用标识。这些检查不会证明手机连接或音画同步正常。

本次产物命名如下；Mac Info.plist 使用数值版本 `0.2.0`，Git tag 与接收端版本使用 `0.2.0-preview.1`：

- `AndroidOnMac-0.2.0-preview-arm64.dmg`
- `AndroidOnMac-0.2.0-preview-arm64.zip`
- `AndroidOnMac-Receiver-0.2.0-preview.1.apk`
- `AndroidOnMac-0.2.0-preview-arm64-third-party-sources.tar.gz`
- `AndroidOnMac-0.2.0-preview-arm64-SHA256SUMS.txt`

校验文件覆盖 DMG、ZIP、源码附件与 APK。源码附件是交付的一部分，覆盖 scrcpy 及其 LGPL 等库的重建和重新链接；**不覆盖 Google 预编译 ADB 的精确构建源码映射**。ADB 的完整官方 NOTICE 已保留，但该对应关系尚未核实，不能宣称附件能够重建 ADB。详见 [第三方源码范围](THIRD_PARTY_SOURCES.md)。

## GitHub Actions

工作流为 `.github/workflows/build.yml`。Android job 在 Ubuntu 运行单元测试、Lint 和 release 构建；Mac job 在 `macos-15` 运行脚本检查、固定引擎集成测试、Swift Testing 和 release 构建，并明确检查 arm64 与 Swift 6+。

PR 只执行验证，不获取发行签名秘密、不发布安装包。`main` push 和手动运行会签名 APK 并构建完整 Mac 包，需要仓库配置以下 Actions Secrets：

| Secret | 内容 |
| --- | --- |
| `AOM_ANDROID_KEYSTORE_B64` | 同一持久 APK 私钥文件的 Base64 |
| `AOM_ANDROID_STORE_PASSWORD` | 密钥库密码 |
| `AOM_ANDROID_KEY_PASSWORD` | `receiver` 别名对应的密钥密码 |

工作流将私钥解码到 runner 临时目录，结束后删除；没有 Secret 时直接失败，不为每次构建生成新身份。CI 配置中别名固定为 `receiver`，应与提供的密钥一致。

`v*` tag 在检查与完整打包成功后创建 **Prerelease**，上传上述五类附件。现有工作流不会因 tag 叫 `v1.0.0` 就自动宣称正式稳定版。本仓库为公有仓库，发布的 Release 与附件对外可见；密钥和密码只能保存在受控签名目录或 Actions Secrets 中。

## Developer ID 与公证

当前 Mac 流程没有使用 Developer ID 或 Apple 公证。`codesign --verify` 只验证签名一致性，不等于已公证。后续公证需要有效 Developer ID、适当的 Hardened Runtime 配置、时间戳、notarytool 检查与 stapling；凭据只能由受控密钥链／发布 Secret 提供。

扩展副屏使用未公开的 macOS 接口。签名或公证不会消除其系统兼容性风险，不能据此承诺 Mac App Store 上架或所有系统版本稳定。正式发行前仍须完成 [真机验收](ACCEPTANCE.md)，尤其是最低系统、权限撤销、断线恢复与 30 分钟连续运行。
