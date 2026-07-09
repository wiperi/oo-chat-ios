import SwiftUI

enum AppTheme {
    /// Brand purple, adaptive: deep violet in light mode, brighter violet in
    /// dark mode so it stays visible against dark backgrounds.
    static let primary = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 139.0 / 255.0, green: 92.0 / 255.0, blue: 246.0 / 255.0, alpha: 1)
        } else {
            return UIColor(red: 109.0 / 255.0, green: 40.0 / 255.0, blue: 217.0 / 255.0, alpha: 1)
        }
    })
}
