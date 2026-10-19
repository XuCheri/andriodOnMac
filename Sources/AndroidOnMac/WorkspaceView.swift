import SwiftUI

enum WorkspaceDirection: String, CaseIterable {
    case androidToMac
    case macToAndroid

    var title: String { self == .androidToMac ? "手机 → Mac" : "Mac → 手机" }
}

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sender: MacSenderModel
    @Binding var direction: WorkspaceDirection
    @State private var showPairingConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Picker("投屏方向", selection: $direction) {
                    ForEach(WorkspaceDirection.allCases, id: \.rawValue) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .help("切换方向可以查看设置；同一时间仅运行一个投屏会话。")
                Spacer(minLength: 8)
                if model.hasActiveSession || sender.hasActiveSession {
                    Label(model.hasActiveSession ? "手机 → Mac 会话进行中" : "Mac → 手机会话进行中",
                          systemImage: "dot.radiowaves.left.and.right")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("停止投屏", role: .destructive) {
                        if sender.hasActiveSession { sender.stop() }
                        if model.hasActiveSession { model.disconnect() }
                    }
                    .help("停止当前正在运行的投屏会话")
                } else {
                    Text("双向连接，自由选择").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background(.bar)
            Divider()
            Group {
                if direction == .androidToMac {
                    MainView(model: model)
                } else {
                    MacSenderView(model: sender)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            synchronizeSessions()
            showPairingConfirmation = sender.pendingPairing != nil
        }
        // Published phase values arrive synchronously, before a later UI render.
        // This closes the brief window in which two rapid start actions could
        // both pass their model's guard while onChange was still pending.
        .onReceive(model.$phase) { phase in
            switch phase {
            case .starting, .running, .reconnecting: sender.externalSessionActive = true
            case .idle, .failed: sender.externalSessionActive = false
            }
        }
        .onReceive(sender.$phase) { phase in
            switch phase {
            case .preparing, .waiting, .streaming, .reconnecting: model.externalSessionActive = true
            case .idle, .failed: model.externalSessionActive = false
            }
        }
        .onChange(of: sender.pendingPairing?.id) { requestID in showPairingConfirmation = requestID != nil }
        .confirmationDialog("允许这台手机连接吗？", isPresented: $showPairingConfirmation, titleVisibility: .visible) {
            Button("允许连接") { sender.approvePairing() }
            Button("拒绝", role: .cancel) { sender.rejectPairing() }
        } message: {
            Text(pairingMessage)
        }
    }

    private var pairingMessage: String {
        let name = sender.pendingPairing?.name ?? "Android 接收端"
        let control = sender.inputEnabled && sender.inputPermissionGranted
            ? "连接后可查看画面，并使用手机触控操作 Mac。"
            : "连接后可查看你选择的 Mac 画面。"
        return "“\(name)”请求连接。\(control)\n请仅允许你正在使用的设备。"
    }

    private func synchronizeSessions() {
        model.externalSessionActive = sender.hasActiveSession
        sender.externalSessionActive = model.hasActiveSession
    }
}
