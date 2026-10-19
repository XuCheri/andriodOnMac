import AppKit
import SwiftUI

@main
struct AndroidOnMacApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        Window("AndroidOnMac", id: "device-manager") {
            MainView(model: model)
                .frame(minWidth: 850, minHeight: 620)
                .onAppear {
                    appDelegate.model = model
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
                Button("无线连接…") { model.showWirelessSheet = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("开始投屏") { model.connectSelected() }
                    .disabled(!model.canConnect)
                Button("停止投屏") { model.disconnect() }
                    .disabled(!model.hasActiveSession)
            }
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shutdown()
        Task { @MainActor in
            for _ in 0..<30 {
                if (model?.ownedProcessCount ?? 0) == 0 { break }
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
