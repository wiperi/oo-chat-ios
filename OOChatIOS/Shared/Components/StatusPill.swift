import SwiftUI

struct StatusPill: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(state.rawValue)
        }
        .font(.subheadline)
        .foregroundStyle(statusColor)
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
