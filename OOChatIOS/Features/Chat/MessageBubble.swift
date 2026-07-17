import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var onRetry: (() -> Void)? = nil

    var body: some View {
        switch message.role {
        case .user:
            userMessage
        case .agent:
            agentMessage
        case .thinking:
            thinkingMessage
        case .tool:
            toolMessage
        case .error:
            errorMessage
        }
    }

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        AppTheme.outgoingMessageBackground,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                deliveryStatus
            }
        }
    }

    private var agentMessage: some View {
        MarkdownMessageView(content: message.content)
    }

    private var thinkingMessage: some View {
        ClaudeCodeThinkingIndicator(text: message.content)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolMessage: some View {
        ToolCallView(message: message)
    }

    private var errorMessage: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message.content)
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .red.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    @ViewBuilder
    private var deliveryStatus: some View {
        switch message.deliveryState {
        case .sent:
            EmptyView()
        case .queued:
            Label("Queued", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 8) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Button("Retry") {
                    onRetry?()
                }
                .font(.caption2.weight(.semibold))
                .accessibilityLabel("Retry sending message")
            }
        case .cancelled:
            HStack(spacing: 8) {
                Label("Cancelled", systemImage: "stop.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    onRetry?()
                }
                .font(.caption2.weight(.semibold))
                .accessibilityLabel("Retry cancelled message")
            }
        }
    }
}
struct UlwCheckpointCard: View {
    let checkpoint: PendingUlwCheckpoint
    var onContinue: () -> Void
    var onAcceptEdits: () -> Void
    var onSafeMode: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Ultra Work checkpoint", systemImage: "bolt.fill")
                .font(.headline)
                .foregroundStyle(AppTheme.primary)

            Text("Completed \(checkpoint.request.turnsUsed) of \(checkpoint.request.maxTurns) turns")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Continue (+100 turns)", action: onContinue)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("ulw.continue.\(checkpoint.id)")

            HStack(spacing: 8) {
                Button("Accept Edits", action: onAcceptEdits)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("ulw.acceptEdits.\(checkpoint.id)")
                Button("Safe Mode", action: onSafeMode)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("ulw.safe.\(checkpoint.id)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

private struct ClaudeCodeThinkingIndicator: View {
    private static let glyphFrames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    private static let glyphFrameDuration = 0.12
    private static let shimmerFrameDuration = 0.2
    private static let shimmerBandWidth = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var startedAt = Date()

    let text: String

    var body: some View {
        if reduceMotion {
            content(glyph: "✻", shimmerFrame: nil)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                let glyphFrame = Int(elapsed / Self.glyphFrameDuration)
                let shimmerFrame = Int(elapsed / Self.shimmerFrameDuration)

                content(
                    glyph: Self.glyphFrames[glyphFrame % Self.glyphFrames.count],
                    shimmerFrame: shimmerFrame
                )
            }
        }
    }

    private func content(glyph: String, shimmerFrame: Int?) -> some View {
        HStack(spacing: 6) {
            Text(glyph)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            Text(shimmeredText(frame: shimmerFrame))
        }
    }

    private func shimmeredText(frame: Int?) -> AttributedString {
        var attributed = AttributedString(text)
        let characterCount = attributed.characters.count

        guard let frame, characterCount > 0 else {
            attributed.foregroundColor = AppTheme.primary
            return attributed
        }

        let cycleLength = characterCount + Self.shimmerBandWidth * 2
        let position = cycleLength - 1 - (frame % cycleLength)

        for (offset, index) in attributed.characters.indices.enumerated() {
            let nextIndex = attributed.characters.index(after: index)
            let distance = abs(offset - position)
            let amount = max(0, 1 - Double(distance) / Double(Self.shimmerBandWidth))
            attributed[index..<nextIndex].foregroundColor = shimmerColor(blending: amount)
        }

        return attributed
    }

    private func shimmerColor(blending amount: Double) -> Color {
        let clampedAmount = min(max(amount, 0), 1)
        let baseRGB = colorScheme == .dark
            ? (red: 139.0, green: 92.0, blue: 246.0)
            : (red: 109.0, green: 40.0, blue: 217.0)
        let highlightRGB = colorScheme == .dark
            ? (red: 196.0, green: 181.0, blue: 253.0)
            : (red: 139.0, green: 92.0, blue: 246.0)
        let red = baseRGB.red + (highlightRGB.red - baseRGB.red) * clampedAmount
        let green = baseRGB.green + (highlightRGB.green - baseRGB.green) * clampedAmount
        let blue = baseRGB.blue + (highlightRGB.blue - baseRGB.blue) * clampedAmount

        return Color(
            red: red / 255.0,
            green: green / 255.0,
            blue: blue / 255.0
        )
    }
}
