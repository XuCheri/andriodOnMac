import AppKit
import SwiftUI
import AndroidOnMacCore

enum SessionPhase: Equatable { case idle, starting, running, reconnecting, failed }

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var selectedSerial: String?
    @Published var services: [MDNSService] = []
    @Published var savedDevices: [SavedDevice] = []
    @Published var settings = MirrorSettings()
    @Published var phase: SessionPhase = .idle
    @Published var busy = false
    @Published var isRefreshing = false
    @Published var isPairing = false
    @Published var isConnectingWiFi = false
    @Published var message: String?
    @Published var isError = false
    @Published var logs = ""
    @Published var host = ""
    @Published var pairingPort = ""
    @Published var connectionPort = ""
    @Published var pairingCode = ""
    @Published var showWirelessSheet = false
    @Published var externalSessionActive = false

    private let processes = ProcessSupervisor()
    private let paths: EnginePaths?
    private let adb: ADBService?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var wirelessTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var keyTasks: [UUID: Task<Void, Never>] = [:]
    private var mirror: ManagedChild?
    private var policy = SessionPolicy()
    private var sessionDevice: AndroidDevice?
    private var sessionIdentity: WirelessSessionIdentity?
    private var missingDeviceObservations = 0
    private var sessionSettings = MirrorSettings()
    private var sessionOutput = ""
    private var lastDiscoveryError: String?
    private var closing = false
    private var started = false

    var selectedDevice: AndroidDevice? { devices.first { $0.serial == selectedSerial } }
    var canConnect: Bool { selectedDevice?.isReady == true && !hasActiveSession && !externalSessionActive && !busy && paths != nil }
    var engineStatus: String {
        paths == nil ? "连接引擎缺失，请重新安装完整应用。" : "scrcpy 5.0.1 · ADB 37.0.1 · 已内置"
    }
    var phaseLabel: String {
        switch phase {
        case .idle: return "等待连接"
        case .starting: return "正在启动投屏"
        case .running: return "投屏窗口已启动"
        case .reconnecting: return "正在恢复连接"
        case .failed: return "连接需要处理"
        }
    }

    init() {
        paths = EnginePaths.locate()
        if let paths { adb = ADBService(paths: paths, processes: processes) }
        else { adb = nil }
        if let data = UserDefaults.standard.data(forKey: "mirrorSettings"),
           let value = try? JSONDecoder().decode(MirrorSettings.self, from: data) { settings = value }
        if let data = UserDefaults.standard.data(forKey: "savedDevices"),
           let value = try? JSONDecoder().decode([SavedDevice].self, from: data) { savedDevices = value }
    }

    func start() {
        guard !started else { return }
        started = true
        guard adb != nil else { show("连接引擎缺失，请下载完整安装包后重试。", error: true); return }
        appendLog("应用已启动，正在查找 USB 与同网无线设备。")
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
                guard let self, !self.closing else { break }
                self.refresh(silent: true)
            }
        }
    }

    func refresh() { refresh(silent: false) }

    private func refresh(silent: Bool) {
        guard !closing, !isRefreshing, let adb else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshing = false }
            do {
                let devices = try await adb.devices()
                try Task.checkCancellation()
                guard !self.closing else { return }
                self.applyDevices(devices)
                let services = (try? await adb.discover()) ?? []
                try Task.checkCancellation()
                guard !self.closing else { return }
                self.services = services
                self.refreshSavedEndpoints(services)
                self.lastDiscoveryError = nil
                if !silent { self.appendLog("发现 \(devices.count) 台设备、\(services.count) 个无线服务。") }
            } catch is CancellationError { }
            catch {
                guard !self.closing else { return }
                let detail = error.localizedDescription
                if !silent || self.lastDiscoveryError != detail { self.show(detail, error: true) }
                self.lastDiscoveryError = detail
            }
        }
    }

    private func applyDevices(_ incoming: [AndroidDevice]) {
        devices = incoming
        if !hasActiveSession, selectedSerial == nil || !incoming.contains(where: { $0.serial == selectedSerial }) {
            let ready = incoming.filter(\.isReady)
            if ready.count == 1 { selectedSerial = ready[0].serial }
            else if incoming.count == 1 { selectedSerial = incoming[0].serial }
            else if !hasActiveSession { selectedSerial = nil }
        }
        guard let active = sessionDevice, hasActiveSession else { return }
        let current = incoming.first(where: { $0.serial == active.serial })
        if current?.state == .unauthorized {
            failSession(generation: policy.generation, reason: .unauthorized,
                        detail: "手机撤销了调试授权。请解锁手机重新允许此 Mac。")
        } else if phase == .running {
            missingDeviceObservations = current?.isReady == true ? 0 : missingDeviceObservations + 1
            // A single stale poll must not interrupt a live session. Two
            // consecutive missing/offline snapshots also recover a hung engine.
            if missingDeviceObservations >= 2 {
                failSession(generation: policy.generation, reason: .connectionLost,
                            detail: "手机已离线，正在尝试恢复连接。")
            }
        }
    }

    func connectSelected() {
        guard canConnect, let device = selectedDevice else { return }
        savePreferences()
        sessionDevice = device
        sessionIdentity = device.transport == .wifi
            ? WirelessSessionIdentity(serial: device.serial, savedDevices: savedDevices, services: services) : nil
        missingDeviceObservations = 0
        sessionSettings = settings
        let generation = policy.begin()
        phase = .starting
        message = nil
        launchSession(device: device, generation: generation)
    }

    private func launchSession(device: AndroidDevice, generation: UInt64) {
        guard let adb, let paths, policy.accepts(generation: generation), !closing else { return }
        startupTask?.cancel()
        startupTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let self, self.policy.accepts(generation: generation), !self.closing,
                  self.phase == .starting || self.phase == .reconnecting else { return }
            self.failSession(generation: generation,
                             reason: self.phase == .reconnecting ? .connectionLost : .launchFailed,
                             detail: "投屏启动超时。请检查手机授权和连接，然后重试。")
        }
        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await adb.ensureServer()
                var actual = device
                var reconnectEndpoint: WirelessEndpoint?
                var discovered: [MDNSService] = []
                if device.transport == .wifi, self.phase == .reconnecting {
                    discovered = (try? await adb.discover()) ?? []
                    guard self.policy.accepts(generation: generation), !Task.isCancelled else { return }
                    self.refreshSavedEndpoints(discovered)
                    if let endpoint = self.sessionIdentity?.reconnectEndpoint(savedDevices: self.savedDevices, services: discovered) {
                        reconnectEndpoint = endpoint
                        try await adb.connect(endpoint: endpoint)
                    } else if self.sessionIdentity?.serviceName != nil {
                        self.failSession(generation: generation, reason: .connectionLost,
                                         detail: "尚未重新发现原手机的无线服务。请确认手机无线调试已开启。")
                        return
                    }
                }
                let current = try await adb.devices()
                guard self.policy.accepts(generation: generation), !Task.isCancelled, !self.closing else { return }
                self.applyDevices(current)
                guard self.policy.accepts(generation: generation) else { return }
                let fresh: AndroidDevice?
                if let endpoint = reconnectEndpoint {
                    fresh = WirelessIdentity.device(endpoint: endpoint, services: discovered, devices: current)
                } else {
                    fresh = current.first(where: { $0.serial == actual.serial })
                }
                if fresh?.state == .unauthorized {
                    self.failSession(generation: generation, reason: .unauthorized,
                                     detail: "手机撤销了调试授权。请解锁手机重新允许此 Mac。")
                    return
                }
                if let fresh, fresh.isReady {
                    actual = fresh
                } else {
                    self.failSession(generation: generation, reason: .connectionLost, detail: "手机连接暂时中断。")
                    return
                }
                self.sessionDevice = actual
                self.missingDeviceObservations = 0
                self.selectedSerial = actual.serial
                self.sessionOutput = ""
                let args = CommandBuilder.scrcpy(serial: actual.serial, settings: self.sessionSettings)
                    + ["--window-title=AndroidOnMac · \(actual.displayName)", "--no-terminal-title"]
                self.mirror = try self.processes.launch(executable: paths.scrcpy, arguments: args,
                    environment: paths.environment, outputMode: .lineBufferedTerminal, output: { [weak self] chunk in
                        Task { @MainActor [weak self] in self?.receiveOutput(chunk, generation: generation) }
                    }, completion: { [weak self] result in
                        Task { @MainActor [weak self] in self?.sessionEnded(result, generation: generation) }
                    })
                self.appendLog("投屏引擎已启动（\(actual.transport.displayName)）。")
            } catch is CancellationError { }
            catch {
                guard self.policy.accepts(generation: generation), !self.closing else { return }
                self.failSession(generation: generation, reason: self.phase == .reconnecting ? .connectionLost : .launchFailed,
                                 detail: error.localizedDescription)
            }
        }
    }

    private func receiveOutput(_ chunk: String, generation: UInt64) {
        guard policy.accepts(generation: generation), !closing else { return }
        sessionOutput += chunk
        sessionOutput = String(sessionOutput.suffix(16_384))
        if SessionDiagnostics.inputPermissionDenied(sessionOutput) {
            failSession(generation: generation, reason: .launchFailed,
                        detail: "手机拒绝输入控制。请在手机开启“USB 调试（安全设置）”并重启后重新连接。")
            return
        }
        // Renderer initialization indicates a window exists, not a measured first-frame latency.
        if sessionOutput.contains("Texture:") || sessionOutput.contains("Renderer:") {
            if phase != .running {
                startupTask?.cancel(); startupTask = nil
                phase = .running
                _ = policy.markConnected(generation: generation)
                appendLog("投屏窗口已初始化。画面与操作效果请以实际手机窗口为准。")
            }
        }
        if chunk.localizedCaseInsensitiveContains("audio disabled") {
            show("手机音频暂不可用，投屏继续运行。Android 11 请先解锁手机再连接。", error: false)
        }
    }

    private func sessionEnded(_ result: Result<ProcessResult, Error>, generation: UInt64) {
        guard policy.accepts(generation: generation), !closing else { return }
        startupTask?.cancel(); startupTask = nil
        mirror = nil
        switch result {
        case .success(let result) where result.exitCode == 0:
            _ = policy.finish(generation: generation)
            phase = .idle
            sessionDevice = nil
            sessionIdentity = nil
            cancelKeys()
            appendLog("投屏窗口已关闭。")
        case .success(let result):
            let text = result.combined.lowercased()
            if text.contains("unauthorized") {
                failSession(generation: generation, reason: .unauthorized, detail: "请在手机重新确认 USB 调试授权。")
            } else if SessionDiagnostics.inputPermissionDenied(text) {
                failSession(generation: generation, reason: .launchFailed,
                            detail: "手机拒绝输入控制。部分机型需额外开启“USB 调试（安全设置）”并重启。")
            } else if text.contains("disconnected") || text.contains("device offline") || text.contains("device not found") {
                failSession(generation: generation, reason: .connectionLost, detail: "手机连接中断，正在尝试恢复。")
            } else {
                let detail = text.contains("uhid") ? "手机不支持当前 UHID 键盘模式，请切换标准输入后重试。" :
                    "投屏引擎未能完成会话。可尝试流畅画质、关闭音频，并检查手机调试授权。"
                failSession(generation: generation, reason: .launchFailed, detail: detail)
            }
        case .failure(let error):
            failSession(generation: generation, reason: .launchFailed, detail: error.localizedDescription)
        }
    }

    private func failSession(generation: UInt64, reason: SessionFailure, detail: String) {
        let decision = policy.failure(generation: generation, reason: reason)
        if decision != .ignore {
            startupTask?.cancel(); startupTask = nil
            cancelKeys()
            missingDeviceObservations = 0
        }
        switch decision {
        case .ignore: return
        case .retry(let delay, let attempt, let next):
            mirror?.stop(); mirror = nil
            phase = .reconnecting
            show("\(detail) 将进行第 \(attempt)/3 次重连。", error: false)
            sessionTask?.cancel()
            sessionTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard let self, self.policy.accepts(generation: next), !self.closing,
                      let device = self.sessionDevice else { return }
                self.launchSession(device: device, generation: next)
            }
        case .stop(let reason):
            let wireless = sessionDevice?.transport == .wifi
            mirror?.stop(); mirror = nil
            sessionTask?.cancel()
            phase = .failed
            sessionDevice = nil
            sessionIdentity = nil
            let recovery = wireless
                ? "无线重连未成功。请在手机确认“无线调试”仍开启，并保持同一 Wi-Fi；若开关已关闭，请重新开启，再从已保存设备重新连接。"
                : "重连未成功。请检查 USB 数据线，并在手机确认调试授权。"
            show(reason == .retryLimitReached ? recovery : detail, error: true)
        }
    }

    func disconnect() {
        policy.stop()
        startupTask?.cancel(); startupTask = nil
        cancelKeys()
        sessionTask?.cancel(); sessionTask = nil
        mirror?.stop(); mirror = nil
        sessionDevice = nil
        sessionIdentity = nil
        missingDeviceObservations = 0
        phase = .idle
        appendLog("已停止本次投屏。")
    }

    func pairWireless() {
        guard !busy, let adb else { return }
        do {
            let endpoint = try WirelessEndpoint(host: host, port: pairingPort)
            let code = pairingCode
            isPairing = true; busy = true
            wirelessTask = Task { [weak self] in
                guard let self else { return }
                defer { self.isPairing = false; self.busy = false; self.pairingCode = "" }
                do {
                    try await adb.pair(endpoint: endpoint, code: code)
                    try Task.checkCancellation()
                    self.show("配对成功。请填写无线调试主页面上的连接端口，再点击连接。", error: false)
                    self.refresh(silent: true)
                } catch { if !self.closing { self.show(error.localizedDescription, error: true) } }
            }
        } catch { show(error.localizedDescription, error: true) }
    }

    func connectWireless() {
        guard !busy, !hasActiveSession, let adb else { return }
        do {
            let endpoint = try WirelessEndpoint(host: host, port: connectionPort)
            isConnectingWiFi = true; busy = true
            wirelessTask = Task { [weak self] in
                guard let self else { return }
                defer { self.isConnectingWiFi = false; self.busy = false }
                do {
                    try await adb.connect(endpoint: endpoint)
                    let devices = try await adb.devices()
                    try Task.checkCancellation()
                    guard !self.closing else { return }
                    self.applyDevices(devices)
                    guard let device = WirelessIdentity.device(endpoint: endpoint, services: self.services, devices: devices), device.isReady else {
                        self.show("网络连接已建立，但设备尚未就绪。请在手机确认调试授权后刷新设备。", error: true)
                        return
                    }
                    self.selectedSerial = device.serial
                    self.remember(endpoint: endpoint, device: device)
                    self.showWirelessSheet = false
                    self.show("无线设备已就绪，点击“开始投屏”即可操控。", error: false)
                } catch { if !self.closing { self.show(error.localizedDescription, error: true) } }
            }
        } catch { show(error.localizedDescription, error: true) }
    }

    func useService(_ service: MDNSService) {
        host = service.host
        if service.kind == .pairing { pairingPort = String(service.port) }
        else { connectionPort = String(service.port) }
    }

    func reconnect(_ saved: SavedDevice) {
        guard !busy, !hasActiveSession, !closing, let adb else { return }
        busy = true; isConnectingWiFi = true
        wirelessTask = Task { [weak self] in
            guard let self else { return }
            do {
                let discovered = (try? await adb.discover()) ?? []
                try Task.checkCancellation()
                self.busy = false; self.isConnectingWiFi = false
                guard !self.closing else { return }
                self.services = discovered
                self.refreshSavedEndpoints(discovered)
                guard let endpoint = WirelessIdentity.reconnectEndpoint(saved: saved, services: discovered) else {
                    self.host = saved.host; self.connectionPort = String(saved.port)
                    self.showWirelessSheet = true
                    self.show("尚未发现这台手机的无线服务。请刷新设备或在手机确认当前连接地址。", error: true)
                    return
                }
                self.host = endpoint.host
                self.connectionPort = String(endpoint.port)
                self.showWirelessSheet = true
                self.connectWireless()
            } catch {
                self.busy = false; self.isConnectingWiFi = false
                if !self.closing { self.show(error.localizedDescription, error: true) }
            }
        }
    }

    private func remember(endpoint: WirelessEndpoint, device: AndroidDevice) {
        let serviceName = services.first { $0.kind == .connect && $0.host == endpoint.host && $0.port == endpoint.port }?.name
        if let index = WirelessIdentity.savedIndex(endpoint: endpoint, serviceName: serviceName, savedDevices: savedDevices) {
            savedDevices[index].name = device.displayName
            savedDevices[index].port = endpoint.port
            savedDevices[index].host = endpoint.host
            if let serviceName { savedDevices[index].serviceName = serviceName }
        } else {
            savedDevices.append(SavedDevice(name: device.displayName, host: endpoint.host, port: endpoint.port, serviceName: serviceName))
        }
        savePreferences()
    }

    private func refreshSavedEndpoints(_ services: [MDNSService]) {
        var changed = false
        for index in savedDevices.indices {
            let saved = savedDevices[index]
            if let service = services.first(where: { $0.kind == .connect && (saved.serviceName != nil ? $0.name == saved.serviceName : ($0.host == saved.host && $0.port == saved.port)) }) {
                if saved.host != service.host || saved.port != service.port || saved.serviceName != service.name {
                    savedDevices[index].host = service.host
                    savedDevices[index].port = service.port
                    savedDevices[index].serviceName = service.name
                    changed = true
                }
            }
        }
        if changed { savePreferences() }
    }

    func forget(_ saved: SavedDevice) { savedDevices.removeAll { $0.id == saved.id }; savePreferences() }

    func savePreferences() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "mirrorSettings") }
        if let data = try? JSONEncoder().encode(savedDevices) { UserDefaults.standard.set(data, forKey: "savedDevices") }
    }

    func sendKey(_ code: Int) {
        guard phase == .running, !closing, let device = sessionDevice, let adb else { return }
        let generation = policy.generation
        let id = UUID()
        keyTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.keyTasks.removeValue(forKey: id) }
            guard self.policy.accepts(generation: generation), !self.closing, !Task.isCancelled else { return }
            do {
                try Task.checkCancellation()
                try await adb.key(serial: device.serial, code: code)
            }
            catch {
                guard self.policy.accepts(generation: generation), !Task.isCancelled else { return }
                self.show(error.localizedDescription, error: true)
            }
        }
    }

    private func cancelKeys() {
        keyTasks.values.forEach { $0.cancel() }
        keyTasks.removeAll()
    }

    func clearMessage() { message = nil }

    private func show(_ text: String, error: Bool) {
        guard !closing else { return }
        message = text; isError = error
        appendLog(text)
    }

    private func appendLog(_ text: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        logs += "[\(formatter.string(from: Date()))] \(text)\n"
        logs = String(logs.suffix(24_000))
    }

    func openHelp() {
        if let local = Bundle.main.resourceURL?.appendingPathComponent("docs/USER_GUIDE.md"),
           FileManager.default.fileExists(atPath: local.path) { NSWorkspace.shared.open(local) }
        else { NSWorkspace.shared.open(URL(string: "https://github.com/XuCheri/andriodOnMac#readme")!) }
    }

    func shutdown() {
        guard !closing else { return }
        closing = true
        policy.stop()
        startupTask?.cancel(); cancelKeys()
        pollTask?.cancel(); refreshTask?.cancel(); wirelessTask?.cancel(); sessionTask?.cancel()
        mirror?.stop()
        processes.shutdown()
        pairingCode = ""
    }

    var ownedProcessCount: Int { processes.activeCount }
}
