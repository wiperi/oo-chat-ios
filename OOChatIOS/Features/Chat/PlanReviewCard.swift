import SwiftUI

struct PlanReviewCard: View {
    let review: PendingPlanReview
    var onApprove: () -> Void
    var onRequestChanges: (String?) -> Void

    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Review implementation plan", systemImage: "list.bullet.clipboard")
                .font(.headline)
                .foregroundStyle(AppTheme.primary)

            ScrollView {
                Text(review.request.planContent)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .padding(10)
            .background(
                Color(.tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            TextField("Feedback for changes (optional)", text: $feedback, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            Button("Approve & Implement", action: onApprove)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("plan.approve.\(review.id)")

            Button("Request Changes") {
                onRequestChanges(feedback)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("plan.requestChanges.\(review.id)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}
