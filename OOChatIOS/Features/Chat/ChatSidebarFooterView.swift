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
                    .background(Color(.tertiarySystemFill), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color(.separator).opacity(SidebarMetrics.settingsButtonStrokeOpacity), lineWidth: 0.5)
                    }
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .tint(Color(.label))
            .accessibilityLabel("Settings")
        }
        .padding(.top, SidebarMetrics.footerTopPadding)
        .padding(.horizontal, SidebarMetrics.outerLeading)
        .padding(.bottom, safeAreaInsets.bottom + SidebarMetrics.footerBottomPadding)
        .glassBackground(
            in: footerShape,
            tint: Color(.systemBackground).opacity(SidebarMetrics.footerGlassTintOpacity),
            fallback: Color(.systemBackground)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.separator).opacity(SidebarMetrics.footerEdgeOpacity))
                .frame(height: 0.5)
        }
        .shadow(
            color: .black.opacity(SidebarMetrics.footerShadowOpacity),
            radius: SidebarMetrics.footerShadowRadius,
            y: SidebarMetrics.footerShadowYOffset
        )
        .ignoresSafeArea(edges: .bottom)
    }

    private var footerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: SidebarMetrics.footerCornerRadius,
            topTrailingRadius: SidebarMetrics.footerCornerRadius,
            style: .continuous
        )
    }
}
