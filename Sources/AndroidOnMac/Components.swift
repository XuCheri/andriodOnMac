import SwiftUI
import AndroidOnMacCore

struct SectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusBadge: View {
    let text: String
    var color: Color = .secondary
    var symbol: String = "circle.fill"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.09), in: Capsule())
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct MessageBanner: View {
    let message: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.accentColor)
                .accessibilityHidden(true)
            Text(message).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("关闭提示")
            .accessibilityLabel("关闭提示")
        }
        .padding(14)
        .background((isError ? Color.orange : Color.accentColor).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

struct InstructionStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(number)).font(.caption.weight(.semibold))
                .frame(width: 21, height: 21)
                .background(Color.primary.opacity(0.06), in: Circle())
                .accessibilityHidden(true)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}

extension AndroidDevice {
    var uiStateLabel: String {
        switch state {
        case .ready: return "已授权"
        case .unauthorized: return "等待手机授权"
        case .offline: return "设备离线"
        case .unknown: return "暂不可用"
        }
    }

    var uiTransportLabel: String { transport.displayName }

    var uiTransportIcon: String { transport == .usb ? "cable.connector" : "wifi" }
}
