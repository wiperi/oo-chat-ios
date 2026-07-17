import SwiftUI

struct StatusPill: View {
    let state: ConnectionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            sizingContent
                .hidden()

            statusContent
                .id(label)
                .transition(.opacity)
        }
        .font(.caption)
        .animation(statusTransition, value: label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection status: \(label)")
    }

    private var statusContent: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(label)
                .lineLimit(1)
        }
        .foregroundStyle(statusColor)
    }

    private var sizingContent: some View {
        HStack(spacing: 5) {
            Circle()
                .frame(width: 6, height: 6)

            Text("Reconnecting")
                .lineLimit(1)
        }
    }

    private var statusTransition: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : AppMotion.press
    }

    private var label: String {
        switch state {
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting"
        case .disconnected:
            return "Disconnected"
        }
    }

    private var statusColor: Color {
        switch state {
        case .connected:
            return .green
        case .reconnecting:
            return .orange
        case .disconnected:
            return .secondary
        }
    }
}
