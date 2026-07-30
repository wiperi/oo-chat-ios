import SwiftUI

struct OfflineBanner: View {
    var isRetrying = false
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("You're offline. Messages will be queued.", systemImage: "wifi.slash")
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(isRetrying ? "Retrying…" : "Retry") {
                onRetry()
            }
            .font(.footnote.weight(.bold))
            .buttonStyle(AppPressButtonStyle())
            .disabled(isRetrying)
            .accessibilityLabel(isRetrying ? "Retrying connection" : "Retry connection")
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
            }
            .buttonStyle(AppPressButtonStyle())
            .accessibilityLabel("Dismiss offline banner")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 232.0 / 255.0, green: 93.0 / 255.0, blue: 117.0 / 255.0))
        .foregroundStyle(.white)
        .accessibilityIdentifier("offlineBanner")
    }
}
