import SwiftUI

struct OfflineBanner: View {
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("You're offline. Messages will be queued.", systemImage: "wifi.slash")
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                onRetry()
            }
            .font(.footnote.weight(.bold))
            .buttonStyle(.plain)
            .accessibilityLabel("Retry connection")
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss offline banner")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 232.0 / 255.0, green: 93.0 / 255.0, blue: 117.0 / 255.0))
        .foregroundStyle(.white)
        .accessibilityIdentifier("offlineBanner")
    }
}
