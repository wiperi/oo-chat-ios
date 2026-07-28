import SwiftUI
import UIKit

struct ChatScreenBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ChatSurfacePalette.backgroundBase

            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        ChatSurfacePalette.darkTopWash,
                        ChatSurfacePalette.darkMidnight,
                        ChatSurfacePalette.darkLowerInk
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [
                        AppTheme.primary.opacity(0.14),
                        AppTheme.primary.opacity(0.05),
                        AppTheme.primary.opacity(0)
                    ],
                    center: UnitPoint(x: 0.50, y: 0.40),
                    startRadius: 18,
                    endRadius: 320
                )
                .blendMode(.screen)

                RadialGradient(
                    colors: [
                        ChatSurfacePalette.darkWarmLift,
                        ChatSurfacePalette.darkWarmLift.opacity(0)
                    ],
                    center: UnitPoint(x: 0.18, y: 0.16),
                    startRadius: 10,
                    endRadius: 260
                )
                .blendMode(.screen)
            }
        }
    }
}

enum ChatSurfacePalette {
    static let backgroundBase = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 7.0 / 255.0, green: 6.0 / 255.0, blue: 10.0 / 255.0, alpha: 1)
        } else {
            return .systemBackground
        }
    })

    static let darkTopWash = Color(red: 13.0 / 255.0, green: 10.0 / 255.0, blue: 18.0 / 255.0)
    static let darkMidnight = Color(red: 6.0 / 255.0, green: 5.0 / 255.0, blue: 9.0 / 255.0)
    static let darkLowerInk = Color(red: 3.0 / 255.0, green: 3.0 / 255.0, blue: 5.0 / 255.0)
    static let darkWarmLift = Color(red: 76.0 / 255.0, green: 48.0 / 255.0, blue: 128.0 / 255.0)
        .opacity(0.07)
}
