import SwiftUI
import UIKit

/// 8 ramps de color per DS v3 §3.4 / v2 §2.4. Cada ramp expone 3 stops
/// semánticos (background, foreground, accent) que resuelven dinámicamente
/// según `userInterfaceStyle`. Implementados in-code via `Color(uiColor:)` —
/// las APIs de Asset Catalog requirirían 112 .colorset directories que
/// duplicarían lo mismo en JSON. Dynamic resolution via UIColor trait
/// closure es el patrón ya establecido por `RuulColors.swift`.
public enum GroupColorRamp: String, Sendable, CaseIterable {
    case teal, blue, purple, amber, green, coral, pink, gray

    /// Background del avatar (stop 50 light / 900 dark) — el más sutil.
    public var background: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rampHex: hexes.dark.bg)
                : UIColor(rampHex: hexes.light.bg)
        })
    }

    /// Foreground de iniciales (stop 800 light / 200 dark) — alto contraste.
    public var foreground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rampHex: hexes.dark.fg)
                : UIColor(rampHex: hexes.light.fg)
        })
    }

    /// Accent for borders / chips (stop 600 light / 400 dark).
    public var accent: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rampHex: hexes.dark.ac)
                : UIColor(rampHex: hexes.light.ac)
        })
    }

    private var hexes: (light: Stops, dark: Stops) {
        switch self {
        case .teal:
            return ((bg: 0xF0FDFA, fg: 0x115E59, ac: 0x0D9488),
                    (bg: 0x134E4A, fg: 0x99F6E4, ac: 0x2DD4BF))
        case .blue:
            return ((bg: 0xEFF6FF, fg: 0x1E40AF, ac: 0x2563EB),
                    (bg: 0x1E3A8A, fg: 0xBFDBFE, ac: 0x60A5FA))
        case .purple:
            return ((bg: 0xFAF5FF, fg: 0x6B21A8, ac: 0x9333EA),
                    (bg: 0x581C87, fg: 0xE9D5FF, ac: 0xC084FC))
        case .amber:
            return ((bg: 0xFFFBEB, fg: 0x92400E, ac: 0xD97706),
                    (bg: 0x78350F, fg: 0xFDE68A, ac: 0xFBBF24))
        case .green:
            return ((bg: 0xF0FDF4, fg: 0x166534, ac: 0x16A34A),
                    (bg: 0x14532D, fg: 0xBBF7D0, ac: 0x4ADE80))
        case .coral:
            return ((bg: 0xFFF5F3, fg: 0xA0341E, ac: 0xE85A3D),
                    (bg: 0x762314, fg: 0xFFC8BF, ac: 0xFF8A72))
        case .pink:
            return ((bg: 0xFDF2F8, fg: 0x9D174D, ac: 0xDB2777),
                    (bg: 0x831843, fg: 0xFBCFE8, ac: 0xF472B6))
        case .gray:
            return ((bg: 0xF9FAFB, fg: 0x1F2937, ac: 0x4B5563),
                    (bg: 0x111827, fg: 0xE5E7EB, ac: 0x9CA3AF))
        }
    }

    private typealias Stops = (bg: UInt32, fg: UInt32, ac: UInt32)
}

// MARK: - UIColor hex helper (file-private — `UIColor.init(rgb:)` en
// RuulColors.swift es `private`, por eso creamos uno propio con un selector
// distinto para evitar colisiones a nivel del módulo).

private extension UIColor {
    convenience init(rampHex: UInt32) {
        let r = CGFloat((rampHex >> 16) & 0xFF) / 255
        let g = CGFloat((rampHex >> 8) & 0xFF) / 255
        let b = CGFloat(rampHex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
