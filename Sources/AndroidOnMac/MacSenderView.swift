import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import AndroidOnMacCore

struct MacSenderView: View {
    @ObservedObject var model: MacSenderModel
    @State private var showWiFiInstaller = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading
                if model.externalSessionActive {
                    Label("手机 → Mac 正在运行。可以先查看设置；开始前请用顶部按钮停止当前投屏。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }
                if let error = model.errorMessage {
                    MessageBanner(message: error, isError: true, dismiss: { model.errorMessage = nil })
                }
                sessionControls
                if model.transport == .wifi, model.hasActiveSession { pairingPanel }
                sourceSettings
                receiverSettings
                permissions
                Text("“手机 → Mac”无需安装手机 App；“Mac → 手机”需要安装 AndroidOnMac 接收端。一次只运行一个投屏会话。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshSources()
            model.refreshUSBDevices()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.refreshSources()
                    model.refreshUSBDevices()
                } label: {
                    Label("刷新来源与设备", systemImage: "arrow.clockwise")
                }
                .disabled(model.hasActiveSession || model.isInstallingReceiver)
                Button(action: { model.openDisplaySettings() }) {
                    Label("显示器设置", systemImage: "display")
                }
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("把 Mac 带到手机上").font(.system(size: 27, weight: .bold))
                Text("镜像当前屏幕，或将 Android 作为独立的扩展副屏。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusBadge(text: phaseTitle, color: isStreaming ? .green : .secondary,
                        symbol: isStreaming ? "checkmark.circle.fill" : "circle.dotted")
        }
    }

    private var sessionControls: some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: model.mode == .extended ? "display.2" : "display")
                        .font(.system(size: 37, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 58).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.mode == .extended ? "独立扩展桌面" : "Mac 屏幕镜像")
                            .font(.title3.weight(.semibold))
                        Text(model.status.isEmpty ? "选好画面来源和连接方式后，开始投屏。" : model.status)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if model.hasActiveSession {
                        Button(action: { model.stop() }) {
                            Label("停止投屏", systemImage: "stop.fill")
                        }
                        .controlSize(.large)
                    } else {
                        Button(action: { model.start() }) {
                            Label("开始投屏", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!canStart)
                    }
                }
                if showsProgress {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(phaseTitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let receiver = model.receiverName, !receiver.isEmpty {
                    Label(receiver, systemImage: "iphone").font(.callout)
                }
                if !model.statistics.isEmpty {
                    Text(model.statistics).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if model.inputEnabled && !model.inputPermissionGranted {
                    Label("当前只读：可正常观看画面。授予辅助功能权限后，重新开始即可使用手机触控。", systemImage: "hand.tap")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sourceSettings: some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "画面来源", subtitle: model.hasActiveSession
                               ? "停止当前投屏后，可调整画面来源和传输偏好。"
                               : "镜像会显示已有屏幕；扩展模式会创建一块新的桌面。")
                VStack(alignment: .leading, spacing: 16) {
                    Picker("显示模式", selection: $model.mode) {
                        Text("镜像屏幕").tag(SenderMode.mirror)
                        Text("扩展副屏").tag(SenderMode.extended)
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 400)
                    if model.mode == .mirror {
                        HStack(spacing: 12) {
                            Text("选择屏幕").frame(width: 80, alignment: .leading)
                            Picker("选择 Mac 屏幕", selection: $model.selectedDisplayID) {
                                Text(model.displays.isEmpty ? "暂无可用屏幕" : "请选择屏幕").tag(UInt32?.none)
                                ForEach(model.displays, id: \.id) { display in
                                    Text("\(display.name) · \(display.width) × \(display.height)")
                                        .tag(Optional(display.id))
                                }
                            }
                            .labelsHidden()
                            Button("刷新") { model.refreshSources() }
                        }
                    } else {
                        Label("连接后，可在系统显示器设置中调整副屏排列，并将窗口拖入扩展桌面。", systemImage: "rectangle.on.rectangle")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    HStack(spacing: 12) {
                        Text("画质偏好").frame(width: 80, alignment: .leading)
                        Picker("传输画质", selection: $model.quality) {
                            Text("标准画质").tag(SenderQuality.standard)
                            Text("流畅优先").tag(SenderQuality.smooth)
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 340)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 28) {
                        Toggle("传输 Mac 音频", isOn: $model.audioEnabled)
                        Toggle("允许手机触控", isOn: $model.inputEnabled)
                        Spacer(minLength: 0)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }
                .disabled(model.hasActiveSession)
                Text("遇到网络波动时可尝试流畅优先。触控需单独授予 Mac 辅助功能权限，未授权时仍可观看。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var receiverSettings: some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "连接 Android 接收端", subtitle: "首次使用需要安装 AndroidOnMac 接收端。")
                Picker("连接方式", selection: $model.transport) {
                    Text("USB 数据线").tag(SenderTransport.usb)
                    Text("同一 Wi-Fi").tag(SenderTransport.wifi)
                }
                .pickerStyle(.segmented).frame(maxWidth: 400)
                .disabled(model.hasActiveSession || model.isInstallingReceiver)
                if model.transport == .usb {
                    usbInstaller
                    Text("手机需开启 USB 调试并允许这台 Mac。安装后在手机打开接收端，再点击“开始投屏”。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        InstructionStep(number: 1, text: "让手机与 Mac 连接同一 Wi-Fi，打开手机接收端。")
                        InstructionStep(number: 2, text: "在 Mac 点击“开始投屏”，再用接收端扫描配对二维码。")
                        InstructionStep(number: 3, text: "在 Mac 确认接收设备，即可开始观看。")
                    }
                    Label("此方向的 Wi-Fi 连接无需开启 Android 无线调试。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("首次安装接收端（通过 USB）", isExpanded: $showWiFiInstaller) {
                        VStack(alignment: .leading, spacing: 12) {
                            usbInstaller
                            Text("安装完成后可拔下数据线，使用同一 Wi-Fi 连接。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 12)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var usbInstaller: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("USB 手机", selection: $model.selectedUSBSerial) {
                    Text(model.usbDevices.isEmpty ? "未发现 USB 手机" : "请选择 USB 手机").tag(String?.none)
                    ForEach(model.usbDevices) { device in
                        Text("\(device.displayName) · \(device.uiStateLabel)").tag(Optional(device.serial))
                    }
                }
                .disabled(model.hasActiveSession || model.isInstallingReceiver)
                Button("刷新设备") { model.refreshUSBDevices() }
                    .disabled(model.isInstallingReceiver)
            }
            HStack(spacing: 10) {
                Button(action: { model.installReceiver() }) {
                    Label(model.isInstallingReceiver ? "正在安装…" : "安装 Android 接收端", systemImage: "square.and.arrow.down")
                }
                .disabled(model.hasActiveSession || model.externalSessionActive || model.isInstallingReceiver || !hasReadyUSBDevice)
                if model.isInstallingReceiver {
                    ProgressView().controlSize(.small).accessibilityLabel("正在安装 Android 接收端")
                }
                Text("手机出现安装确认时，请在手机上允许。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var pairingPanel: some View {
        Surface {
            HStack(alignment: .center, spacing: 24) {
                if let payload = model.pairingPayload, !payload.isEmpty {
                    PairingQRCode(payload: payload)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: isStreaming ? "checkmark.shield" : "qrcode")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Color.accentColor)
                        Text(isStreaming ? "接收端已连接" : "正在准备连接")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 176, height: 176)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(isStreaming ? "画面正在发送" : "用手机接收端扫码").font(.headline)
                    Text(isStreaming
                         ? "在 Android 接收端查看画面。需要更换设备或显示模式时，先停止当前投屏。"
                         : "打开 AndroidOnMac 接收端的扫码入口。扫描后，请在这台 Mac 上确认允许连接。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("二维码包含本次连接凭据，请勿分享给他人。", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var permissions: some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Mac 权限", subtitle: "仅在使用相应功能时授权；可以随时在系统设置中撤销。")
                permissionRow(title: "屏幕录制", detail: "用于把选中的 Mac 画面发送到 Android。",
                              granted: model.screenCaptureAllowed, action: { model.requestScreenPermission() })
                Divider()
                permissionRow(title: "辅助功能", detail: "用于将手机触控转换为 Mac 操作；不授权也能观看。",
                              granted: model.inputPermissionGranted, action: { model.requestInputPermission() })
                Button("已完成授权，刷新状态") { model.refreshSources() }
                    .font(.callout).disabled(model.hasActiveSession)
            }
        }
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: granted ? "checkmark.shield" : "lock.shield")
                .font(.title3).foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if granted {
                Text("已授权").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("授予权限", action: action).accessibilityLabel("授予\(title)权限")
            }
        }
    }

    private var hasReadyUSBDevice: Bool {
        model.usbDevices.contains { $0.serial == model.selectedUSBSerial && $0.isReady }
    }

    private var canStart: Bool {
        !model.hasActiveSession && !model.externalSessionActive && !model.isInstallingReceiver && model.screenCaptureAllowed
            && (model.mode == .extended || model.selectedDisplayID != nil)
            && (model.transport == .wifi || hasReadyUSBDevice)
    }

    private var isStreaming: Bool { if case .streaming = model.phase { return true }; return false }
    private var showsProgress: Bool {
        switch model.phase { case .preparing, .reconnecting: return true; default: return false }
    }
    private var phaseTitle: String {
        switch model.phase {
        case .idle: return "尚未开始"
        case .preparing: return "正在准备投屏"
        case .waiting: return "等待手机连接"
        case .streaming: return "正在传输画面"
        case .reconnecting: return "正在恢复连接"
        case .failed: return "连接需要处理"
        }
    }
}

private struct PairingQRCode: View {
    let payload: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).interpolation(.none).resizable()
                    .scaledToFit().padding(10)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "qrcode").font(.largeTitle)
                    Text("二维码暂不可用").font(.caption)
                }
                .foregroundStyle(.black)
            }
        }
        .frame(width: 176, height: 176)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("使用 AndroidOnMac 接收端扫描此二维码配对")
        .task(id: payload) { image = makeQRCode(payload) }
    }

    private func makeQRCode(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
