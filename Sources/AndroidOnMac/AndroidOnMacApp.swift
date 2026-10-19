import AppKit
import SwiftUI

@main
struct AndroidOnMacApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var senderModel = MacSenderModel()
    @State private var direction: WorkspaceDirection = .androidToMac
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        Window("AndroidOnMac", id: "device-manager") {
            WorkspaceView(model: model, sender: senderModel, direction: $direction)
                .frame(minWidth: 850, minHeight: 620)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.senderModel = senderModel
                    model.start()
                }
        }
        .defaultSize(width: 1040, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("AndroidOnMac 使用帮助") { model.openHelp() }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandMenu("设备") {
                Button("刷新设备") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isRefreshing)
                Button("手机 → Mac：无线连接…") {
                    direction = .androidToMac
                    model.showWirelessSheet = true
                }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("手机 → Mac：开始投屏") {
                    direction = .androidToMac
                    model.externalSessionActive = senderModel.hasActiveSession
                    model.connectSelected()
                }
                    .disabled(!model.canConnect)
                Button("Mac → 手机：开始投屏") {
                    direction = .macToAndroid
                    senderModel.externalSessionActive = model.hasActiveSession
                    senderModel.start()
                }
                    .disabled(model.hasActiveSession || senderModel.hasActiveSession || senderModel.isInstallingReceiver)
                Button("停止当前投屏") {
                    if senderModel.hasActiveSession { senderModel.stop() }
                    if model.hasActiveSession { model.disconnect() }
                }
                    .disabled(!model.hasActiveSession && !senderModel.hasActiveSession)
            }
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var senderModel: MacSenderModel?
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        let model = model, senderModel = senderModel
        senderModel?.shutdown()
        terminationTask = Task { @MainActor in
            // The original model may own the shared ADB server. Keep it alive
            // until reverse --list / --remove and sender cleanup have finished.
            // Each ADB command already has a 12-second timeout.
            let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 30
            while !(senderModel?.isShutdownComplete ?? true),
                  ProcessInfo.processInfo.systemUptime < cleanupDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !(senderModel?.isShutdownComplete ?? true) { senderModel?.forceShutdown() }
            model?.shutdown()
            let processDeadline = ProcessInfo.processInfo.systemUptime + 3
            while (model?.ownedProcessCount ?? 0) + (senderModel?.ownedProcessCount ?? 0) > 0,
                  ProcessInfo.processInfo.systemUptime < processDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension AppModel {
    var hasActiveSession: Bool {
        switch phase {
        case .starting, .running, .reconnecting: return true
        case .idle, .failed: return false
        }
    }

    var isSessionRunning: Bool {
        if case .running = phase { return true }
        return false
    }
}
