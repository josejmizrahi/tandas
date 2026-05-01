import SwiftUI

enum Brand {
    // Luma's signature warm orange — used for primary CTAs only ("+", "Suscribirse").
    static let accent = Color(red: 0.97, green: 0.49, blue: 0.16)        // #F77D29 — orange/peach
    static let accent2 = Color(red: 0.55, green: 0.55, blue: 0.58)       // mid-gray, secondary
    static let accent3 = Color(red: 0.30, green: 0.30, blue: 0.33)       // dark gray, tertiary

    // No mesh real: 9 muestras del mismo near-black con micro variaciones para
    // que MeshGradient no produzca artefactos pero el resultado sea casi flat.
    static let meshColors: [Color] = Array(
        repeating: Color(red: 0.063, green: 0.063, blue: 0.071),
        count: 9
    )

    // Luma cards no son multi-color — todos comparten el mismo surface neutro,
    // con variación sutil (alpha) para que cada card se distinga del fondo
    // sin saturar visualmente.
    static let groupPalette: [Color] = [
        Color(red: 0.10, green: 0.10, blue: 0.11),
        Color(red: 0.11, green: 0.11, blue: 0.12),
        Color(red: 0.12, green: 0.12, blue: 0.13),
        Color(red: 0.10, green: 0.10, blue: 0.12),
        Color(red: 0.11, green: 0.11, blue: 0.13)
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
        // Luma-tight: cards 14, field 12, chip 8.
        static let card: CGFloat = 14
        static let pill: CGFloat = 999
        static let chip: CGFloat = 8
        static let field: CGFloat = 12
    }

    enum Surface {
        // Luma-style adaptive: light=puro blanco, dark=puro negro.
        static let canvas = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.0, alpha: 1.0)
                : UIColor(white: 1.0, alpha: 1.0)
        })
        // Surface alternativo (slight elevation) — usado raramente.
        static let card = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.10, alpha: 1.0)
                : UIColor(white: 0.97, alpha: 1.0)
        })
        // Card press state.
        static let cardPressed = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.14, alpha: 1.0)
                : UIColor(white: 0.93, alpha: 1.0)
        })
        // Border sutil — Luma uses very light gray in light mode.
        static let border = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.08)
                : UIColor(white: 0.0, alpha: 0.08)
        })
        // Text en canvas: high contrast vs background.
        static let textPrimary = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 1.0)
                : UIColor(white: 0.0, alpha: 1.0)
        })
        static let textSecondary = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.55)
                : UIColor(white: 0.0, alpha: 0.55)
        })
        static let textTertiary = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.35)
                : UIColor(white: 0.0, alpha: 0.35)
        })
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
