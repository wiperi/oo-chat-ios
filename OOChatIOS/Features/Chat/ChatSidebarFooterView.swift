import SwiftUI

struct ChatSidebarFooterView: View {
    let safeAreaInsets: EdgeInsets
    let onAddAgent: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack {
            Button(action: onAddAgent) {
                Label("New Agent", systemImage: "person.badge.plus")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SidebarMetrics.footerButtonHorizontalPadding)
                    .frame(height: SidebarMetrics.footerButtonSize)
                    .background(AppTheme.primary, in: Capsule())
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .accessibilityLabel("Add Agent")

            Spacer()

            Button(action: onSettings) {
                SidebarIconButtonLabel(
                    systemName: "gearshape",
                    foregroundColor: Color(.label),
                    size: SidebarMetrics.footerButtonSize,
                    font: .system(size: 22, weight: .regular)
                )
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .tint(Color(.label))
            .accessibilityLabel("Settings")
        }
        .padding(.top, SidebarMetrics.footerTopPadding)
        .padding(.horizontal, SidebarMetrics.outerLeading)
        .padding(.bottom, safeAreaInsets.bottom + SidebarMetrics.footerBottomPadding)
    }
}
