import SwiftUI

struct ErrorBanner: View {
    let message: String?
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let message {
            HStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(AppPressButtonStyle())
                .accessibilityLabel("Close error")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(red: 198.0 / 255.0, green: 55.0 / 255.0, blue: 75.0 / 255.0))
            .foregroundStyle(.white)
            .accessibilityIdentifier("errorBanner")
            .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
        }
    }
}
