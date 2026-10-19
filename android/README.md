# AndroidOnMac 原生接收端

Android 11+；包名 `chat.xucheri.androidonmac.receiver`。原生 Activity + SurfaceView，H.264 MediaCodec / AAC MediaCodec + AudioTrack。实现协议见 [`../docs/REVERSE_PROTOCOL.md`](../docs/REVERSE_PROTOCOL.md)。

## 构建

在仓库根目录运行 `bash scripts/build-android.sh`。Apple Silicon Mac 会将固定版本 JDK 17.0.15+6、Gradle 8.11.1、Android command line tools 19.0 下载到 `.cache/android-toolchain` 并校验 SHA-256，再安装 Android SDK 35 / Build Tools 35.0.0。不会改全局 Java 或 SDK 配置。首次运行需要网络并接受 Android SDK 许可。

其他主机可提供 `ANDROIDONMAC_JAVA_HOME` 和 `ANDROIDONMAC_SDK_ROOT`；脚本只在子进程设置环境。脚本执行协议单元测试、Android Lint、Release 构建和 APK 签名验证。Android 依赖版本在 Gradle 文件内锁定，校验信息在 `gradle/verification-metadata.xml`。

APK 输出：`dist/AndroidOnMac-Receiver-0.2.0-preview.1.apk`。持久发布签名私钥与密码保存在用户 `Library/Application Support/AndroidOnMac/android-signing`，权限 0700 / 0600；可以用 `ANDROIDONMAC_SIGNING_DIR` 指定外部安全目录。CI 使用 `AOM_ANDROID_KEYSTORE`（已解码的文件路径）、`AOM_ANDROID_STORE_PASSWORD`、`AOM_ANDROID_KEY_PASSWORD`、`AOM_ANDROID_KEY_ALIAS`；CI 缺少发布签名时直接失败，不自动创建新身份。密码只经权限受限的临时文件传给签名工具，结束即删除。后续更新必须保留同一私钥；验证脚本固定公开证书指纹，密钥缺失时须恢复原身份，不自动生成新身份。脚本拒绝仓库内（含符号链接）的签名路径，绝不覆盖已有私钥；APK 仅在签名验证通过后原子替换。不要将该目录、密钥或密码提交到仓库或发布资产。

## 连接

- 同一 Wi-Fi：在 Mac 开始共享，扫描其二维码，在 Mac 确认新设备。
- USB：打开 USB 调试并授权 Mac，由 Mac 为选中设备建立 ADB reverse 后启动接收端。`connection` intent 支持原始 bootstrap JSON 或 `aom:` 加 URL-safe、无 padding 的 Base64(JSON)。
- 已配对局域网设备通过 `_aom-display._tcp` 的 TXT `fingerprint` 与 `v=1` 找回变化后的地址/端口，随后仍须通过 TLS 指纹验证；不按显示名称选择设备。USB 回环地址只允许由 Mac 重新启动连接，不复用旧端口。
- 配对凭据及证书指纹由 Android Keystore AES-GCM 加密保存，禁用 Android 备份。重连不会替换已配对的证书身份，也不会接受任意证书。
- 视频画面轻点为点击，双击、长按右键，单指拖动，双指滚动。连接后仅常驻“键盘 / 横屏（竖屏）/ 更多”。点“键盘”直接输入到 Mac；中文组词只在手机上进行，确认候选后提交，回车和删除等动作直接生效。组合键收在“更多”内，不默认同步剪贴板。
- 进入后台、锁屏、返回或主动停止会结束会话；重新回到 App 不会自动恢复共享。可以手动固定横屏或竖屏，不改变 Mac 副屏分辨率；若前台旋转导致 Surface 重建，会保留同一连接身份并有限恢复，旧输入回调失效。连接失败最多等待 1/2/4 秒进行三次恢复，真正渲染首帧后才重置恢复预算。

## 验证边界

单元测试覆盖线格式、边界与截断、严格 UTF-8、USB bootstrap、证书精确匹配、端点校验、有限重试和画面坐标。纯测试不替代实机 MediaCodec、AudioTrack、相机扫码、旋转及 TLS/USB 联调。待真机验收：声音同步与延迟、不同芯片低延迟能力、前后台恢复、断 USB / 切 Wi-Fi 和控制权限撤销。仅在硬件解码器明确宣告低延迟支持时启用；不承诺固定端到端毫秒数。
