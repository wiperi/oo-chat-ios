import SwiftUI

struct ApprovalCard: View {
    let approval: PendingApproval
    var onAllowOnce: () -> Void
    var onTrustSession: () -> Void
    var onReject: () -> Void
    var onStop: () -> Void
    var onExplain: () -> Void

    private var request: ToolApprovalRequest {
        approval.request
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let description = request.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            argumentList

            if !request.batchRemaining.isEmpty {
                Text("\(request.batchRemaining.count) more action\(request.batchRemaining.count == 1 ? "" : "s") waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            actionRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission requested for \(request.tool)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(AppTheme.primary)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Permission requested")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(ToolActionSummary.requested(
                    toolName: request.tool,
                    arguments: request.arguments
                ))
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            }

            Spacer(minLength: 4)

            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Waiting for your decision")
        }
    }

    @ViewBuilder
    private var argumentList: some View {
        let details = ToolActionSummary.argumentsDescription(request.arguments)
        if !details.isEmpty {
            Text(details)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
    }

    private var actionRow: some View {
        VStack(spacing: 8) {
            Button {
                onAllowOnce()
            } label: {
                Label("Allow once", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
            .accessibilityIdentifier("approval.allowOnce.\(request.id)")

            HStack(spacing: 8) {
                Button {
                    onTrustSession()
                } label: {
                    Label("Trust for session", systemImage: "checkmark.shield.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("approval.trustSession.\(request.id)")

                Button(role: .destructive) {
                    onReject()
                } label: {
                    Label("Reject", systemImage: "xmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("approval.reject.\(request.id)")
            }

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    onStop()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("approval.stop.\(request.id)")

                Button {
                    onExplain()
                } label: {
                    Label("Explain", systemImage: "questionmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("approval.explain.\(request.id)")
            }
        }
    }
}
