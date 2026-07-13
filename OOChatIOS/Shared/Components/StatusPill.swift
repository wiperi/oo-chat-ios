import SwiftUI

struct StatusPill: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(label)
        }
        .font(.subheadline)
        .foregroundStyle(statusColor)
        .accessibilityLabel("Connection status: \(label)")
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
