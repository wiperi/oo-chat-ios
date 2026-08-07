import SwiftUI

struct StatusPill: View {
    let isOnline: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            sizingContent
                .hidden()

            statusContent
                .id(label)
                .transition(.opacity)
        }
        .font(.caption)
        .animation(statusTransition, value: label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent status: \(label)")
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

            Text("Offline")
                .lineLimit(1)
        }
    }

    private var statusTransition: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : AppMotion.press
    }

    private var label: String {
        isOnline ? "Online" : "Offline"
    }

    private var statusColor: Color {
        isOnline ? .green : .secondary
    }
}
