import SwiftUI

struct ErrorBanner: View {
    let message: String?
    let onDismiss: () -> Void

    var body: some View {
        if let message {
            HStack(alignment: .top, spacing: 10) {
                Text(message)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close error")
            }
            .padding(10)
            .background(.red.opacity(0.14))
            .foregroundStyle(.red)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}
