import SwiftUI

// Liquid Glass surface to match the system tab bar; falls back to a solid
// fill on OS versions before the glass effect is available. Pass a `tint`
// for prominent controls (e.g. the send/add buttons).
extension View {
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(glassStyle(interactive: interactive, tint: tint), in: shape)
        } else {
            background(tint ?? Color(.secondarySystemBackground), in: shape)
        }
    }
}

@available(iOS 26.0, *)
private func glassStyle(interactive: Bool, tint: Color?) -> Glass {
    var glass: Glass = .regular
    if let tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}

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

    static let destructive = Color(uiColor: .systemRed)
}
