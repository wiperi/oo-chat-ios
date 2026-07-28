import SwiftUI
import UIKit

enum EmptyChatPalette {
    static let heading = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 214.0 / 255.0, green: 199.0 / 255.0, blue: 246.0 / 255.0, alpha: 1)
        } else {
            return UIColor(red: 122.0 / 255.0, green: 92.0 / 255.0, blue: 166.0 / 255.0, alpha: 1)
        }
    })

    static let chipText = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 225.0 / 255.0, green: 216.0 / 255.0, blue: 239.0 / 255.0, alpha: 1)
        } else {
            return UIColor(red: 60.0 / 255.0, green: 53.0 / 255.0, blue: 72.0 / 255.0, alpha: 1)
        }
    })

    static let chipIcon = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 188.0 / 255.0, green: 158.0 / 255.0, blue: 248.0 / 255.0, alpha: 1)
        } else {
            return UIColor(red: 124.0 / 255.0, green: 73.0 / 255.0, blue: 222.0 / 255.0, alpha: 0.72)
        }
    })

    static let chipFill = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 40.0 / 255.0, green: 36.0 / 255.0, blue: 49.0 / 255.0, alpha: 0.76)
        } else {
            return UIColor(red: 250.0 / 255.0, green: 248.0 / 255.0, blue: 253.0 / 255.0, alpha: 0.78)
        }
    })

    static let chipStroke = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 189.0 / 255.0, green: 154.0 / 255.0, blue: 248.0 / 255.0, alpha: 0.18)
        } else {
            return UIColor(red: 126.0 / 255.0, green: 88.0 / 255.0, blue: 208.0 / 255.0, alpha: 0.08)
        }
    })

    static let chipPressedFill = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 129.0 / 255.0, green: 84.0 / 255.0, blue: 228.0 / 255.0, alpha: 0.18)
        } else {
            return UIColor(red: 124.0 / 255.0, green: 73.0 / 255.0, blue: 222.0 / 255.0, alpha: 0.10)
        }
    })

    static let chipPressedStroke = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 178.0 / 255.0, green: 143.0 / 255.0, blue: 247.0 / 255.0, alpha: 0.28)
        } else {
            return UIColor(red: 124.0 / 255.0, green: 73.0 / 255.0, blue: 222.0 / 255.0, alpha: 0.22)
        }
    })

    static let chipShadow = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0, alpha: 0.28)
        } else {
            return UIColor(white: 0, alpha: 0.02)
        }
    })

    static let logoBacklightCore = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 222.0 / 255.0, green: 208.0 / 255.0, blue: 255.0 / 255.0, alpha: 0.14)
        } else {
            return UIColor(white: 1, alpha: 0)
        }
    })

    static let logoBacklightEdge = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 152.0 / 255.0, green: 111.0 / 255.0, blue: 244.0 / 255.0, alpha: 0.06)
        } else {
            return UIColor(white: 1, alpha: 0)
        }
    })

    static let logoShadow = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 182.0 / 255.0, green: 146.0 / 255.0, blue: 255.0 / 255.0, alpha: 1)
        } else {
            return UIColor(red: 109.0 / 255.0, green: 40.0 / 255.0, blue: 217.0 / 255.0, alpha: 1)
        }
    })
}

enum EmptyChatMetrics {
    static let sectionSpacing: CGFloat = 22
    static let headingSpacing: CGFloat = 6
    static let topOffset: CGFloat = 58
    static let verticalPadding: CGFloat = 36
    static let logoStageSize: CGFloat = 132
    static let logoSize: CGFloat = 72
    static let logoImageVerticalOffset: CGFloat = 1
    static let logoOuterAuraSize: CGFloat = 230
    static let logoOuterAuraStartRadius: CGFloat = 24
    static let logoOuterAuraEndRadius: CGFloat = 124
    static let logoOuterAuraBlur: CGFloat = 38
    static let logoAuraSize: CGFloat = 168
    static let logoAuraStartRadius: CGFloat = 12
    static let logoAuraEndRadius: CGFloat = 92
    static let logoAuraBlur: CGFloat = 28
    static let logoBacklightSize: CGFloat = 104
    static let logoBacklightStartRadius: CGFloat = 5
    static let logoBacklightEndRadius: CGFloat = 56
    static let logoBacklightBlur: CGFloat = 11
    static let logoIdleShadowRadius: CGFloat = 10
    static let logoActiveShadowRadius: CGFloat = 16
    static let logoIdleShadowOffset: CGFloat = 4
    static let logoActiveShadowOffset: CGFloat = 6
    static let logoPulseDuration: TimeInterval = 3.4
    static let headingMaximumWidth: CGFloat = 280
    static let suggestionGroupMaximumWidth: CGFloat = 344
    static let chipSpacing: CGFloat = 7
    static let chipContentSpacing: CGFloat = 6
    static let chipMinimumHeight: CGFloat = 36
    static let chipHorizontalPadding: CGFloat = 12
    static let chipIconSize: CGFloat = 15
    static let chipCornerRadius: CGFloat = 16
    static let chipShadowRadius: CGFloat = 8
    static let chipShadowOffset: CGFloat = 2

    static func logoImageOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.96 : 0.88
    }

    static func logoOuterAuraCoreOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.085 : 0.055
    }

    static func logoOuterAuraEdgeOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.035 : 0.025
    }

    static func logoAuraCoreOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.17 : 0.13
    }

    static func logoAuraEdgeOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.065 : 0.055
    }

    static func logoShadowOpacity(isActive: Bool, colorScheme: ColorScheme) -> Double {
        if colorScheme == .dark {
            return isActive ? 0.20 : 0.13
        }

        return isActive ? 0.12 : 0.07
    }
}
