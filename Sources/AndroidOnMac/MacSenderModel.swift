import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import AndroidOnMacCore
import MacDisplayCapture
import MacDisplayTransport

enum SenderMode: String, Codable { case mirror, extended }
enum SenderTransport: String, Codable { case usb, wifi }
enum SenderQuality: String, Codable {
    case standard, smooth
    var dimension: Int { self == .standard ? 1920 : 1280 }
    var bitrate: Int { self == .standard ? 8_000_000 : 4_000_000 }
}
enum SenderPhase { case idle, preparing, waiting, streaming, reconnecting, failed }
struct SenderDisplay: Identifiable { let id: UInt32; let name: String; let width: Int; let height: Int }
struct PairingRequest: Identifiable { let id: UUID; let name: String }

private struct SenderPreferences: Codable {
    var mode = SenderMode.mirror
    var transport = SenderTransport.usb
    var quality = SenderQuality.standard
    var audio = false
    var input = true
}

@MainActor
final class MacSenderModel: ObservableObject {
    @Published var mode = SenderMode.mirror
    @Published var transport = SenderTransport.usb
    @Published var quality = SenderQuality.standard
    @Published var audioEnabled = false
    @Published var inputEnabled = true
    @Published var selectedDisplayID: UInt32?
    @Published var displays: [SenderDisplay] = []
    @Published var phase = SenderPhase.idle
    @Published var status = "选择画面来源，再连接手机接收端。"
    @Published var errorMessage: String?
    @Published var pairingPayload: String?
    @Published var pendingPairing: PairingRequest?
    @Published var selectedUSBSerial: String?
    @Published var usbDevices: [AndroidDevice] = []
    @Published var receiverName: String?
    @Published var statistics = ""
    @Published var externalSessionActive = false
    @Published var isInstallingReceiver = false
    @Published var screenCaptureAllowed = MacCaptureEngine.screenCaptureAllowed
    @Published var inputPermissionGranted = false

    private let processes = ProcessSupervisor()
    private let adb: ADBService?
    private let input = InputController()
    private var gate = ReverseSessionGate()
    private var server: DisplayServer?
    private var capture: MacCaptureEngine?
    private var captureAttempt: UUID?
    private var virtualHelper: ManagedChild?
    private var virtualDisplayID: UInt32?
    private var helperOutput = ""
    private var helperError: String?
    private var helperIdentity: UUID?
    private var activeDisplayID: UInt32?
    private var mapping: (serial: String, port: UInt16)?
    private var setupTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var captureStopTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var refreshing = false
    private var refreshingUSB = false
    private var closing = false
    private var sessionPreferences = SenderPreferences()
    private var startedAt: TimeInterval = 0
    private var lastStatsFrames = 0
    private var lastStatsTime: TimeInterval = 0
    private var firstFrameSeconds: Double?
    private var observers: [NSObjectProtocol] = []

    var hasActiveSession: Bool {
        switch phase { case .preparing, .waiting, .streaming, .reconnecting: return true; default: return false }
    }
    var ownedProcessCount: Int { processes.activeCount }
    var isShutdownComplete: Bool {
        closing && cleanupTask == nil && !isInstallingReceiver && ownedProcessCount == 0
    }

    init() {
        if let paths = EnginePaths.locate() { adb = ADBService(paths: paths, processes: processes) }
        else { adb = nil }
        inputPermissionGranted = input.permissionGranted
        if let data = UserDefaults.standard.data(forKey: "macSenderPreferences"),
           let preferences = try? JSONDecoder().decode(SenderPreferences.self, from: data) {
            mode = preferences.mode; transport = preferences.transport; quality = preferences.quality
            audioEnabled = preferences.audio; inputEnabled = preferences.input
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasActiveSession else { return }
                self.finish(error: "Mac 即将睡眠，已停止共享；唤醒后可重新开始。")
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasActiveSession else { return }
                self.finish(error: "Mac 已锁定或切换用户，已停止共享。")
            }
        })
    }

    private func refreshPermissions() {
        screenCaptureAllowed = MacCaptureEngine.screenCaptureAllowed
        inputPermissionGranted = input.permissionGranted
        if !inputPermissionGranted { input.releaseAll() }
    }

    func refreshSources() {
        refreshPermissions()
        guard !refreshing, !closing else { return }
        refreshing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshing = false }
            do {
                let sources: [SenderDisplay]
                if self.screenCaptureAllowed {
                    sources = try await MacCaptureEngine.displays().map { SenderDisplay(id: $0.id, name: $0.name, width: $0.width, height: $0.height) }
                } else {
                    sources = NSScreen.screens.compactMap { screen in
                        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
                        return SenderDisplay(id: id, name: screen.localizedName,
                                             width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
                    }
                }
                guard !self.closing else { return }
                self.displays = sources.filter { $0.id != self.virtualDisplayID }
                if !self.displays.contains(where: { $0.id == self.selectedDisplayID }) { self.selectedDisplayID = self.displays.first?.id }
            } catch { self.errorMessage = "无法获取显示器列表，请检查屏幕录制授权。" }
        }
    }

    func refreshUSBDevices() {
        guard !refreshingUSB, !closing, let adb else { return }
        refreshingUSB = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshingUSB = false }
            do {
                let devices = try await adb.devices().filter { $0.transport == .usb }
                guard !self.closing else { return }
                self.usbDevices = devices
                if !devices.contains(where: { $0.serial == self.selectedUSBSerial }) {
                    let ready = devices.filter(\.isReady)
                    self.selectedUSBSerial = ready.count == 1 ? ready[0].serial : nil
                }
            } catch { if self.transport == .usb { self.errorMessage = error.localizedDescription } }
        }
    }

    func requestScreenPermission() {
        MacCaptureEngine.requestScreenCapture()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        refreshPermissions()
    }
    func requestInputPermission() {
        input.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refreshPermissions()
    }
    func openDisplaySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) }

    func installReceiver() {
        guard !isInstallingReceiver, !hasActiveSession, !externalSessionActive, !closing,
              let adb, let serial = selectedUSBSerial,
              usbDevices.contains(where: { $0.serial == serial && $0.isReady }) else { return }
        isInstallingReceiver = true; errorMessage = nil; status = "正在安装 Android 接收端，请留意手机上的安装确认。"
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("AndroidOnMac-Receiver.apk"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/AndroidOnMac-Receiver-0.2.0-preview.1.apk")].compactMap { $0 }
        guard let apk = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            isInstallingReceiver = false; errorMessage = "安装包缺少 Android 接收端，请下载完整预览版。"; return
        }
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isInstallingReceiver = false }
            do { try await adb.installReceiver(serial: serial, apk: apk); self.status = "接收端已安装。USB 模式点击开始即可；Wi-Fi 模式请在手机打开 AndroidOnMac 接收端。" }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    func start() {
        guard !hasActiveSession, !externalSessionActive, !isInstallingReceiver, !closing else { return }
        refreshPermissions()
        guard screenCaptureAllowed else { errorMessage = "请先允许屏幕录制，然后刷新权限状态。"; return }
        guard mode == .extended || selectedDisplayID != nil else { errorMessage = "请选择要共享的 Mac 显示器。"; return }
        let serial = selectedUSBSerial
        if transport == .usb {
            guard adb != nil, let serial, usbDevices.contains(where: { $0.serial == serial && $0.isReady }) else {
                errorMessage = "请选择已授权的 USB 手机。"; return
            }
        }
        let localHost = transport == .wifi ? DisplayServer.localIPv4Addresses().first : "127.0.0.1"
        guard let localHost else { errorMessage = "没有发现可用的局域网地址，请连接同一 Wi-Fi 或改用 USB。"; return }
        sessionPreferences = SenderPreferences(mode: mode, transport: transport, quality: quality, audio: audioEnabled, input: inputEnabled)
        if let data = try? JSONEncoder().encode(sessionPreferences) { UserDefaults.standard.set(data, forKey: "macSenderPreferences") }
        let generation = gate.begin()
        phase = .preparing; errorMessage = nil; pairingPayload = nil; pendingPairing = nil; receiverName = nil
        statistics = ""; firstFrameSeconds = nil; lastStatsFrames = 0; lastStatsTime = 0
        activeDisplayID = mode == .mirror ? selectedDisplayID : nil
        startedAt = ProcessInfo.processInfo.systemUptime; status = "正在准备加密连接…"
        armTimeout(seconds: 60, generation: generation,
                   message: "准备连接超时，请先完成或取消系统钥匙串授权，并检查本地网络权限后重试。")
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try await TransportIdentity.load(processes: self.processes)
                guard self.gate.accepts(generation), !Task.isCancelled else { return }
                let server = DisplayServer(); self.server = server
                let connection = try await server.start(identity: identity, lan: self.sessionPreferences.transport == .wifi) { [weak self, weak server] event, epoch in
                    Task { @MainActor in
                        guard let self, let server, self.server === server,
                              server.connectionGeneration == epoch else { return }
                        self.handle(event, generation: generation, connectionEpoch: epoch)
                    }
                }
                guard self.gate.accepts(generation), !Task.isCancelled else { server.stop(); return }
                let bootstrap: [String: Any] = ["v": 1, "host": localHost, "port": Int(connection.port),
                                               "fingerprint": identity.fingerprint, "pairToken": connection.token]
                let data = try JSONSerialization.data(withJSONObject: bootstrap, options: [.sortedKeys])
                self.pairingPayload = String(data: data, encoding: .utf8)
                self.phase = .waiting
                self.status = self.sessionPreferences.transport == .usb ? "正在打开手机接收端…" : "请在手机接收端扫码，然后在 Mac 允许连接。"
                self.armTimeout(seconds: 300, generation: generation, message: "等待手机连接超时，请重新开始。")
                if self.sessionPreferences.transport == .usb, let serial, let adb = self.adb {
                    // This small transaction must report whether it succeeded.
                    // Cancelling its adb process could hide an already-created
                    // mapping. The unstructured task retains adb's own timeout;
                    // cleanup joins setup, records success, then removes it.
                    let reverse = Task {
                        try await adb.addReverse(serial: serial, devicePort: connection.port, hostPort: connection.port)
                    }
                    try await reverse.value
                    self.mapping = (serial, connection.port)
                    guard self.gate.accepts(generation), !Task.isCancelled else { return }
                    try await adb.openReceiver(serial: serial, bootstrap: data)
                }
            } catch is CancellationError { }
            catch { if self.gate.accepts(generation) { self.finish(error: error.localizedDescription) } }
        }
    }

    func approvePairing() {
        guard let pendingPairing else { return }
        server?.approve(pendingPairing.id); self.pendingPairing = nil
        status = "已允许手机，正在建立画面连接…"
    }
    func rejectPairing() {
        guard let pendingPairing else { return }
        server?.reject(pendingPairing.id); self.pendingPairing = nil
        status = "已拒绝连接，可以重新扫码或停止共享。"
    }

    private func handle(_ event: DisplayServerEvent, generation: UInt64, connectionEpoch: UInt64) {
        guard gate.accepts(generation), !closing else { return }
        switch event {
        case .pairing(let id, let name): pendingPairing = PairingRequest(id: id, name: name); status = "请确认是否允许这部手机查看并操作所选屏幕。"
        case .pairingCancelled(let id):
            if pendingPairing?.id == id { pendingPairing = nil; status = "手机已离开或配对超时，可重新扫码。" }
        case .receiverReady(let name):
            input.releaseAll()
            pendingPairing = nil; receiverName = name; pairingPayload = nil
            startCapture(generation: generation, connectionEpoch: connectionEpoch)
        case .firstFrame:
            guard capture != nil else { return }
            timeoutTask?.cancel(); phase = .streaming; gate.renderedFrame()
            if firstFrameSeconds == nil { firstFrameSeconds = ProcessInfo.processInfo.systemUptime - startedAt }
            status = sessionPreferences.mode == .extended ? "副屏已连接，可以将窗口拖到 Android 显示器。" : "手机正在显示所选 Mac 屏幕。"
            refreshPermissions()
        case .input(let object):
            guard phase == .streaming, sessionPreferences.input, let id = activeDisplayID else { return }
            input.handle(object, displayID: id)
        case .requestKeyFrame: capture?.requestKeyFrame()
        case .congestion: capture?.reduceBitrate(); capture?.requestKeyFrame()
        case .statistics(let frames, let depth):
            let now = ProcessInfo.processInfo.systemUptime
            let fps = lastStatsTime > 0 && frames >= lastStatsFrames ? Double(frames - lastStatsFrames) / max(0.1, now - lastStatsTime) : 0
            lastStatsTime = now; lastStatsFrames = frames
            let first = firstFrameSeconds.map { String(format: " · 首帧 %.1f 秒（含连接）", $0) } ?? ""
            statistics = String(format: "接收端 %.0f fps · 解码队列 %d", fps, depth) + first
            refreshPermissions()
        case .disconnected:
            captureAttempt = nil
            input.releaseAll(); pendingPairing = nil; phase = .reconnecting
            status = "连接中断，等待原手机按 1、2、4 秒重试；副屏暂时保留。"
            let old = capture; capture = nil; captureTask?.cancel()
            let previousStop = captureStopTask
            captureStopTask = Task {
                await previousStop?.value
                if let old { await old.stop() }
            }
            armTimeout(seconds: 35, generation: generation, message: "手机未能恢复连接，已停止共享并释放副屏。")
        case .stopped: stop()
        case .failure(let message): finish(error: message)
        }
    }

    private func startCapture(generation: UInt64, connectionEpoch: UInt64) {
        let previousCapture = captureTask, previousStop = captureStopTask
        captureTask?.cancel(); timeoutTask?.cancel()
        captureStopTask = nil
        let attempt = UUID(); captureAttempt = attempt
        phase = .preparing; status = "手机已连接，正在准备画面…"
        armTimeout(seconds: 20, generation: generation, message: "手机未能显示首帧，请停止后重新连接。")
        let old = capture; capture = nil
        captureTask = Task { [weak self] in
            guard let self else { return }
            await previousCapture?.value
            await previousStop?.value
            if let old { await old.stop() }
            do {
                guard self.gate.accepts(generation), !Task.isCancelled else { return }
                if self.sessionPreferences.mode == .extended {
                    try await self.createVirtualDisplay(generation: generation)
                }
                guard self.gate.accepts(generation), self.captureAttempt == attempt, !Task.isCancelled,
                      let id = self.activeDisplayID else { return }
                let engine = MacCaptureEngine(); self.capture = engine
                let activeServer = self.server
                try await engine.start(displayID: id, maxDimension: self.sessionPreferences.quality.dimension,
                    fps: 60, bitrate: self.sessionPreferences.quality.bitrate, audio: self.sessionPreferences.audio,
                    onPacket: { packet in
                            switch packet {
                            case .configuration(let object): if let frame = try? ReverseFrame.json(object) { activeServer?.send(frame, generation: connectionEpoch) }
                            case .video(let data, let pts, let key): activeServer?.send(.init(kind: .video, timestamp: pts, keyFrame: key, payload: data), generation: connectionEpoch)
                            case .audio(let data, let pts): activeServer?.send(.init(kind: .audio, timestamp: pts, payload: data), generation: connectionEpoch)
                        }
                    }, onError: { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.gate.accepts(generation), self.captureAttempt == attempt else { return }
                            // Audio degradation is reported while video continues; all
                            // other capture failures end the session explicitly.
                            if message.contains("视频仍在共享") { self.errorMessage = message }
                            else { self.finish(error: message) }
                        }
                    })
                guard self.gate.accepts(generation), self.captureAttempt == attempt, !Task.isCancelled else { await engine.stop(); return }
                if self.phase == .preparing { self.status = "正在等待手机显示第一帧…" }
            } catch is CancellationError { }
            catch { if self.gate.accepts(generation), self.captureAttempt == attempt, !Task.isCancelled { self.finish(error: error.localizedDescription) } }
        }
    }

    private func createVirtualDisplay(generation: UInt64) async throws {
        if virtualHelper == nil {
            helperOutput = ""; helperError = nil
            let identity = UUID(); helperIdentity = identity
            let executable = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("VirtualDisplayHelper")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw TransportFailure.message("虚拟显示辅助程序缺失，请安装完整应用。") }
            let width = sessionPreferences.quality.dimension, height = width * 9 / 16
            virtualHelper = try processes.launch(executable: executable,
            arguments: ["--run", "--width", String(width), "--height", String(height)],
            output: { [weak self] text in
                Task { @MainActor in
                    guard self?.helperIdentity == identity else { return }
                    self?.receiveHelper(text, generation: generation)
                }
            }, completion: { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.gate.accepts(generation), self.helperIdentity == identity else { return }
                    self.finish(error: "实验性虚拟显示器已停止，请重新连接或使用镜像模式。")
                }
            })
        }
        for _ in 0..<70 {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard gate.accepts(generation) else { throw CancellationError() }
            if let error = helperError { throw TransportFailure.message(error) }
            if let id = virtualDisplayID, CGDisplayIsActive(id) != 0 {
                let sources = try await MacCaptureEngine.displays()
                if sources.contains(where: { $0.id == id }) { activeDisplayID = id; return }
            }
        }
        throw TransportFailure.message("macOS 未及时识别虚拟显示器，已停止创建；可重试或选择镜像模式。")
    }

    private func receiveHelper(_ text: String, generation: UInt64) {
        guard gate.accepts(generation) else { return }
        helperOutput += text
        guard helperOutput.utf8.count <= 16384 else { helperError = "虚拟显示辅助程序返回无效数据。"; return }
        while let newline = helperOutput.firstIndex(of: "\n") {
            let line = String(helperOutput[..<newline]); helperOutput.removeSubrange(...newline)
            guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["type"] as? String == "created", let id = object["displayID"] as? UInt32 { virtualDisplayID = id }
            if object["type"] as? String == "error" { helperError = object["message"] as? String ?? "无法创建实验性副屏。" }
        }
    }

    private func armTimeout(seconds: Double, generation: UInt64, message: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard let self, self.gate.accepts(generation) else { return }
            self.finish(error: message)
        }
    }

    func stop() { finish(error: nil) }

    private func finish(error: String?) {
        guard gate.isActive else { return }
        gate.end(); let generation = gate.generation
        timeoutTask?.cancel(); timeoutTask = nil
        setupTask?.cancel(); captureTask?.cancel()
        let setup = setupTask, startingCapture = captureTask, stoppingCapture = captureStopTask, engine = capture
        captureStopTask = nil
        capture = nil; captureAttempt = nil; server?.stop(); server = nil; input.releaseAll()
        pairingPayload = nil; pendingPairing = nil
        phase = .preparing; status = "正在停止共享并清理连接…"
        if let error { errorMessage = error }
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            await setup?.value
            self.helperIdentity = nil; self.virtualHelper?.stop(); self.virtualHelper = nil
            self.virtualDisplayID = nil; self.activeDisplayID = nil
            if let mapping = self.mapping, let adb = self.adb {
                if self.closing { self.status = "正在退出：清理本次 USB 连接…" }
                await adb.removeReverse(serial: mapping.serial, devicePort: mapping.port, hostPort: mapping.port)
            }
            self.mapping = nil
            // Mapping removal must not wait on a slow ScreenCaptureKit stop.
            if self.closing { self.status = "正在退出：停止画面捕获…" }
            await startingCapture?.value; await stoppingCapture?.value
            if let engine { await engine.stop() }
            guard self.gate.generation == generation else { return }
            self.phase = error == nil ? .idle : .failed
            self.status = error == nil ? "已停止共享，副屏和本次 USB 映射已清理。" : "连接已停止，请根据提示处理后重试。"
            self.cleanupTask = nil
            if self.closing { self.processes.shutdown() }
        }
    }

    func shutdown() {
        guard !closing else { return }
        closing = true; installTask?.cancel(); finish(error: nil)
        server?.stop(); input.releaseAll(); virtualHelper?.stop()
        if cleanupTask == nil { processes.shutdown() }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Called only after the app's bounded graceful shutdown window expires.
    /// Invalidates future process launches and reaps this owner's children;
    /// it never stops an ADB server owned by another application.
    func forceShutdown() {
        shutdown()
        status = "清理等待已超时，正在关闭本应用的辅助进程…"
        setupTask?.cancel(); captureTask?.cancel(); captureStopTask?.cancel()
        cleanupTask?.cancel(); installTask?.cancel()
        server?.stop(); input.releaseAll(); virtualHelper?.stop()
        processes.shutdown()
    }
}
