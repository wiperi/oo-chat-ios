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
                Image(systemName: "gearshape")
                    .imageScale(.large)
                    .foregroundStyle(.primary)
                    .frame(width: SidebarMetrics.footerButtonSize, height: SidebarMetrics.footerButtonSize)
                    .glassBackground(in: Circle(), interactive: true, tint: Color(.systemBackground))
                    .overlay {
                        Circle()
                            .stroke(Color(.separator).opacity(SidebarMetrics.settingsButtonStrokeOpacity), lineWidth: 0.5)
                    }
                    .shadow(
                        color: Color(.label).opacity(SidebarMetrics.settingsButtonShadowOpacity),
                        radius: SidebarMetrics.settingsButtonShadowRadius,
                        x: 0,
                        y: SidebarMetrics.settingsButtonShadowYOffset
                    )
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .tint(Color(.label))
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, SidebarMetrics.outerLeading)
        .padding(.bottom, safeAreaInsets.bottom + SidebarMetrics.footerBottomPadding)
        .background {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }
}
