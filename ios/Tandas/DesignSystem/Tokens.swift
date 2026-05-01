import SwiftUI

enum Brand {
    static let accent = Color(red: 0.611, green: 0.482, blue: 0.957)
    static let accent2 = Color(red: 0.957, green: 0.482, blue: 0.741)
    static let accent3 = Color(red: 0.482, green: 0.741, blue: 0.957)

    static let meshColors: [Color] = [
        Color(red: 0.06, green: 0.05, blue: 0.12),
        Color(red: 0.18, green: 0.10, blue: 0.30),
        Color(red: 0.30, green: 0.10, blue: 0.40),
        Color(red: 0.10, green: 0.16, blue: 0.32),
        Color(red: 0.20, green: 0.14, blue: 0.36),
        Color(red: 0.40, green: 0.20, blue: 0.50),
        Color(red: 0.08, green: 0.08, blue: 0.20),
        Color(red: 0.22, green: 0.12, blue: 0.34),
        Color(red: 0.16, green: 0.10, blue: 0.28)
    ]

    static let groupPalette: [Color] = [
        Color(red: 0.61, green: 0.48, blue: 0.96),
        Color(red: 0.96, green: 0.48, blue: 0.74),
        Color(red: 0.48, green: 0.74, blue: 0.96),
        Color(red: 0.96, green: 0.74, blue: 0.48),
        Color(red: 0.48, green: 0.96, blue: 0.74),
        Color(red: 0.74, green: 0.96, blue: 0.48),
        Color(red: 0.96, green: 0.48, blue: 0.48),
        Color(red: 0.48, green: 0.96, blue: 0.96),
        Color(red: 0.96, green: 0.96, blue: 0.48),
        Color(red: 0.74, green: 0.48, blue: 0.96),
        Color(red: 0.96, green: 0.61, blue: 0.74),
        Color(red: 0.61, green: 0.96, blue: 0.74)
    ]

    static func paletteColor(forGroupId id: UUID) -> Color {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        return groupPalette[sum % groupPalette.count]
    }

    enum Status {
        static let event = Color.green
        static let fine = Color.yellow
        static let vote = Color.cyan
        static let turn = Color.purple
    }

    enum Radius {
        static let card: CGFloat = 22
        static let pill: CGFloat = 999
        static let chip: CGFloat = 14
        static let field: CGFloat = 18
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
}
