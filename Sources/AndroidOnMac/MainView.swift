import SwiftUI
import AndroidOnMacCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showLogs = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 246, max: 290)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heading
                    if let message = model.message {
                        MessageBanner(message: message, isError: model.isError, dismiss: { model.clearMessage() })
                    }
                    if let device = model.selectedDevice {
                        selectedDevice(device)
                    } else {
                        introduction
                    }
                    mirrorSettings
                    diagnostics
                }
                .padding(28)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isRefreshing {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                        .accessibilityLabel("正在刷新设备")
                }
                Button(action: { model.refresh() }) {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .help("刷新设备（⌘R）")
                Button { model.showWirelessSheet = true } label: {
                    Label("无线连接", systemImage: "wifi")
                }
                .help("连接同一局域网内的手机")
            }
        }
        .sheet(isPresented: $model.showWirelessSheet) {
            WirelessConnectionView(model: model)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.title2).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AndroidOnMac").font(.headline)
                    Text("让手机触手可及").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 22)

            List(selection: $model.selectedSerial) {
                Section("已发现设备 · \(model.devices.count)") {
                    if model.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("等待连接设备", systemImage: "cable.connector")
                                .font(.callout)
                            Text("插入 USB 数据线，或使用无线连接。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 12)
                    }
                    ForEach(model.devices) { device in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "iphone")
                                .font(.title2).padding(.top, 2).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(device.displayName).font(.body.weight(.medium)).lineLimit(1)
                                HStack(spacing: 5) {
                                    Image(systemName: device.uiTransportIcon).accessibilityHidden(true)
                                    Text("\(device.uiTransportLabel) · \(device.uiStateLabel)")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .tag(device.serial)
                        .accessibilityLabel("\(device.displayName)，\(device.uiTransportLabel)，\(device.uiStateLabel)")
                    }
                }
                if !model.savedDevices.isEmpty {
                    Section("已保存的无线设备") {
                        ForEach(model.savedDevices) { device in
                            HStack {
                                Button { model.reconnect(device) } label: {
                                    Label(device.name, systemImage: "wifi")
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .disabled(model.busy || model.hasActiveSession)
                                Spacer(minLength: 4)
                                Menu {
                                    Button("重新连接") { model.reconnect(device) }
                                        .disabled(model.busy || model.hasActiveSession)
                                    Button("从列表移除", role: .destructive) { model.forget(device) }
                                } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).frame(width: 20)
                                .help("无线设备选项").accessibilityLabel("\(device.name)的选项")
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(model.hasActiveSession)
            Spacer(minLength: 0)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("USB / 同一 Wi-Fi", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Button(action: { model.openHelp() }) {
                    Label("使用帮助", systemImage: "questionmark.circle")
                }
                .buttonStyle(.plain).font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("手机工作台").font(.system(size: 27, weight: .bold))
                Text("在 Mac 上查看和操控你的 Android 手机。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(text: model.phaseLabel,
                        color: model.isSessionRunning ? .green : .secondary,
                        symbol: model.isSessionRunning ? "checkmark.circle.fill" : "circle.dotted")
        }
    }

    private var introduction: some View {
        Surface {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.accentColor.opacity(0.08)).frame(width: 76, height: 76)
                        Image(systemName: "display.and.arrow.down")
                            .font(.system(size: 32, weight: .light)).foregroundStyle(Color.accentColor)
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("从连接第一台手机开始").font(.title3.weight(.semibold))
                        Text("无需 root，无需安装手机 App。首次连接需要在手机上开启调试并授权。")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("USB 连接", systemImage: "cable.connector").font(.headline)
                        InstructionStep(number: 1, text: "在开发者选项中打开 USB 调试。")
                        InstructionStep(number: 2, text: "使用支持数据传输的 USB 线连接 Mac。")
                        InstructionStep(number: 3, text: "在手机确认授权，再选择左侧设备。")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Wi-Fi 连接", systemImage: "wifi").font(.headline)
                        Text("Android 11 及以上，在同一局域网内开启无线调试，完成一次配对后连接。")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { model.showWirelessSheet = true } label: {
                            Label("设置无线连接", systemImage: "arrow.right")
                        }
                        .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func selectedDevice(_ device: AndroidDevice) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "iphone")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 58).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.displayName).font(.title2.weight(.semibold))
                        Text(device.serial).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(2)
                        HStack(spacing: 8) {
                            StatusBadge(text: device.uiTransportLabel, symbol: device.uiTransportIcon)
                            StatusBadge(text: device.uiStateLabel, color: device.isReady ? .green : .orange,
                                        symbol: device.isReady ? "checkmark.shield" : "exclamationmark.shield")
                        }
                    }
                    Spacer(minLength: 8)
                    if model.hasActiveSession {
                        Button(action: { model.disconnect() }) {
                            Label("停止投屏", systemImage: "stop.fill")
                        }
                        .controlSize(.large)
                    } else {
                        Button(action: { model.connectSelected() }) {
                            Label("开始投屏", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.canConnect)
                    }
                }
                if !device.isReady {
                    Label(device.uiStateLabel == "等待手机授权"
                          ? "解锁手机，在弹窗中允许 USB 调试，然后刷新设备。"
                          : "请检查数据线或无线调试连接，然后刷新设备。",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.hasActiveSession {
                    Divider()
                    HStack(spacing: 10) {
                        if !model.isSessionRunning {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isSessionRunning ? "手机画面已在独立窗口打开。" : model.phaseLabel)
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                    }
                    HStack(spacing: 10) {
                        keyButton("返回", symbol: "chevron.backward", key: 4)
                        keyButton("主页", symbol: "house", key: 3)
                        keyButton("最近任务", symbol: "square.on.square", key: 187)
                        Spacer()
                        Text("⌥ 为手机窗口快捷键修饰键")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func keyButton(_ title: String, symbol: String, key: Int) -> some View {
        Button { model.sendKey(key) } label: { Label(title, systemImage: symbol) }
            .disabled(!model.isSessionRunning)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<MirrorSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: {
            model.settings[keyPath: keyPath] = $0
            model.savePreferences()
        })
    }

    private var mirrorSettings: some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "投屏偏好", subtitle: model.hasActiveSession
                               ? "停止当前投屏后，可调整以下设置。"
                               : "启动时应用这些设置，也会记住你的选择。")
                VStack(spacing: 16) {
                    HStack {
                        Label("画质", systemImage: "slider.horizontal.3").frame(width: 100, alignment: .leading)
                        Picker("画质", selection: setting(\.quality)) {
                            ForEach(QualityPreset.allCases, id: \.rawValue) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340)
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Label("键盘", systemImage: "keyboard").frame(width: 100, alignment: .leading)
                        Picker("键盘模式", selection: setting(\.keyboard)) {
                            ForEach(KeyboardMode.allCases, id: \.rawValue) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden().frame(maxWidth: 340)
                        Spacer(minLength: 0)
                    }
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 16) {
                        GridRow {
                            Toggle("传输手机音频", isOn: setting(\.audio))
                            Toggle("同步剪贴板", isOn: setting(\.clipboard))
                        }
                        GridRow {
                            Toggle("投屏时关闭手机屏幕", isOn: setting(\.screenOff))
                            Toggle("手机窗口置顶", isOn: setting(\.alwaysOnTop))
                        }
                        GridRow {
                            Toggle("以全屏方式打开", isOn: setting(\.fullscreen))
                            Color.clear.frame(height: 1)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.hasActiveSession)
                Text("中文推荐复制后粘贴到手机。音频需要设备与 Android 版本支持；关闭剪贴板同步后，复制内容不会自动互传。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $showLogs) {
                ScrollView([.vertical, .horizontal]) {
                    Text(model.logs.isEmpty ? "暂无诊断记录。" : model.logs)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .frame(height: 170)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
            } label: {
                Label("连接诊断", systemImage: "terminal").font(.callout.weight(.medium))
            }
            Text(model.engineStatus).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct WirelessConnectionView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    private enum Field { case host, pairingPort, pairingCode, connectionPort }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "wifi").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("无线连接").font(.title2.weight(.bold))
                    Text("Android 11+ · 手机与 Mac 在同一局域网")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isPairing || model.isConnectingWiFi)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let message = model.message {
                        MessageBanner(message: message, isError: model.isError, dismiss: { model.clearMessage() })
                    }
                    Text("在手机「开发者选项 → 无线调试」中开启无线调试。首次使用先配对，已配对的手机可直接连接。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.services.isEmpty { discovery }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("手机 IP 地址").font(.callout.weight(.medium))
                        TextField("例如 192.168.1.20", text: $model.host)
                            .textFieldStyle(.roundedBorder).focused($focusedField, equals: .host)
                            .disabled(isWorking)
                            .accessibilityLabel("手机 IP 地址")
                    }
                    Surface {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeading(title: "1. 配对手机", subtitle: "点击手机上的「使用配对码配对设备」，填写弹窗里的配对端口与六位配对码。")
                            HStack(alignment: .top, spacing: 16) {
                                field("配对端口", placeholder: "配对弹窗中的端口", value: $model.pairingPort, focus: .pairingPort)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("配对码").font(.callout.weight(.medium))
                                    SecureField("六位数字", text: $model.pairingCode)
                                        .textFieldStyle(.roundedBorder)
                                        .focused($focusedField, equals: .pairingCode)
                                        .disabled(isWorking)
                                        .accessibilityLabel("手机显示的六位配对码")
                                }
                            }
                            HStack {
                                Button(action: { model.pairWireless() }) {
                                    Text(model.isPairing ? "正在配对…" : "配对手机")
                                }
                                .disabled(isWorking || model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.pairingPort.isEmpty || model.pairingCode.isEmpty)
                                if model.isPairing { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                    Surface {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeading(title: "2. 连接设备", subtitle: "返回手机的「无线调试」主页面，填写「IP 地址和端口」中的连接端口。它通常与配对端口不同。")
                            HStack(alignment: .bottom, spacing: 16) {
                                field("连接端口", placeholder: "无线调试主页面中的端口", value: $model.connectionPort, focus: .connectionPort)
                                Button(action: { model.connectWireless() }) {
                                    Text(model.isConnectingWiFi ? "正在连接…" : "连接设备")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isWorking || model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.connectionPort.isEmpty)
                                if model.isConnectingWiFi { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                    Label("连接后在设备列表中选择手机，点击「开始投屏」。网络切换后端口可能变化。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
        }
        .frame(width: 590, height: 690)
        .onAppear { focusedField = .host; model.refresh() }
    }

    private var isWorking: Bool { model.isPairing || model.isConnectingWiFi || model.hasActiveSession }

    private func field(_ label: String, placeholder: String, value: Binding<String>, focus: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.callout.weight(.medium))
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: focus)
                .disabled(isWorking)
                .accessibilityLabel(label)
        }
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自动发现").font(.callout.weight(.semibold))
                Spacer()
                Button("刷新") { model.refresh() }.disabled(model.isRefreshing)
            }
            ForEach(model.services) { service in
                Button { model.useService(service) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi").accessibilityHidden(true)
                        Text(service.name).lineLimit(1)
                        Spacer()
                        Text(service.kind == .pairing ? "填入配对地址" : "填入连接地址")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.down.left").accessibilityHidden(true)
                    }
                    .font(.callout).padding(9)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).disabled(isWorking)
            }
        }
    }
}
