import SwiftUI

struct StatusPill: View {
    let state: ConnectionState

    var body: some View {
        Text(state.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch state {
        case .connected:
            return .green.opacity(0.22)
        case .reconnecting:
            return .orange.opacity(0.22)
        case .disconnected:
            return .yellow.opacity(0.24)
        }
    }
}
