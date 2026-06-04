import SwiftUI
import RuulCore

/// Sistema de diseño unificado de Ruul.
///
/// **Doctrina (Apple HIG + Liquid Glass):**
/// - 8pt grid para spacing.
/// - `RoundedCornerStyle.continuous` siempre (curva Apple-native).
/// - Standard Materials (`Color(uiColor: .secondarySystemGroupedBackground)`)
///   para el **content layer** (cards, rows, sheets internos).
/// - Liquid Glass (`glassEffect`, `.buttonStyle(.glassProminent)`) reservado
///   para CTAs prominentes y elementos funcionales (toolbars/tab bars los hace
///   automáticamente el sistema). NUNCA en cards.
/// - Tipografía 100% Dynamic Type — sin sizes hardcoded para texto.
/// - SF Symbols con `Theme.IconSize.*` para tamaños de ícono (NO usar
///   `.font(.system(size:))` para íconos: es la causa más común de drift).
///
/// El catálogo semántico de íconos+tints por `action_key` vive en
/// `ActionPresentationCatalog` y es complementario a este Theme.
public enum Theme {

    // MARK: - Spacing (8pt grid)

    /// Spacing tokens basados en escala 8pt de Apple HIG.
    /// Cubre ~95% de los casos. Si necesitas un valor intermedio,
    /// prefiere subir al token mayor antes que crear un one-off.
    public enum Spacing {
        public static let xxs: CGFloat = 2     // micro (badge inner padding)
        public static let xs:  CGFloat = 4     // tight (chip horizontal padding)
        public static let sm:  CGFloat = 8     // small (HStack icon+text)
        public static let md:  CGFloat = 12    // medium (row vertical, card inner)
        public static let lg:  CGFloat = 16    // standard (card padding, list horizontal)
        public static let xl:  CGFloat = 24    // section gap
        public static let xxl: CGFloat = 32    // hero padding, empty-state vertical
        /// Alineación leading de divisores que arrancan tras un ícono+gap (HIG estándar).
        public static let dividerLeading: CGFloat = 56
    }

    // MARK: - Corner Radius (siempre .continuous)

    public enum Radius {
        public static let chip:     CGFloat = 8   // chips, segmented selection
        public static let inset:    CGFloat = 12  // inline info rows, small badges
        public static let card:     CGFloat = 16  // card estándar
        public static let cardHero: CGFloat = 20  // hero card (Wallet/Stocks style)
    }

    /// Forma de tarjeta estándar con corner continuo (Apple-native curve).
    public static func cardShape(_ radius: CGFloat = Radius.card) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    // MARK: - Icon Sizes

    /// Tamaños fijos para SF Symbols (cuando el ícono vive en su propio frame,
    /// como hero icons o avatars). Para íconos inline con texto, prefiere
    /// `.font(.body)` + `.imageScale(.medium)`.
    public enum IconSize {
        public static let xs:   CGFloat = 22   // chip / list trailing
        public static let sm:   CGFloat = 28   // section header icon
        public static let md:   CGFloat = 32   // icon badge (hero pequeño)
        public static let lg:   CGFloat = 44   // detail screen hero
        public static let hero: CGFloat = 80   // empty-state / standalone hero
    }

    // MARK: - Surface (Standard Materials)

    /// Capa de superficies. **NO** uses Liquid Glass aquí — HIG:
    /// "Don't use Liquid Glass in the content layer."
    public enum Surface {
        /// Background plano (`systemBackground`): para pantallas que no son
        /// grouped lists — auth, modales custom, hero pages.
        public static let appBackground:       Color = Color(uiColor: .systemBackground)
        /// Background secundario plano — útil para sticky bars sobre `appBackground`.
        public static let secondaryBackground: Color = Color(uiColor: .secondarySystemBackground)
        /// Background grouped (`systemGroupedBackground`): para Forms y listas
        /// agrupadas. Es el background detrás de `card`.
        public static let background:          Color = Color(uiColor: .systemGroupedBackground)
        /// Color canónico de tarjetas (`secondarySystemGroupedBackground`).
        public static let card:                Color = Color(uiColor: .secondarySystemGroupedBackground)
        /// Card elevated — para chips/badges dentro de una `card`.
        public static let cardElevated:        Color = Color(uiColor: .tertiarySystemGroupedBackground)
        /// Opacidad estándar para fills tintados (badges, hero icons sobre Capsule/Circle).
        public static let badgeFill:       Double = 0.15
        public static let badgeFillSubtle: Double = 0.12
    }

    // MARK: - Shadow

    /// Sombra única y sutil. Mantén la app *flat by default* — Liquid Glass
    /// + Standard Materials ya aportan profundidad sin shadows ad-hoc.
    public enum Shadow {
        public static let subtleRadius:  CGFloat = 2
        public static let subtleY:       CGFloat = 1
        public static let subtleOpacity: Double  = 0.08
    }

    // MARK: - Status tints (semántica por dominio)

    /// Tints semánticos por dominio. La misma palabra ("approved", "open") tiene
    /// significado distinto entre dominios, por eso hay funciones separadas.
    public enum Status {
        /// Decisiones: open=blue, approved=green, rejected=red, executed=purple, cancelled=gray.
        public static func decision(_ raw: String) -> Color {
            switch raw {
            case "open":      return .blue
            case "approved":  return .green
            case "rejected":  return .red
            case "executed":  return .purple
            case "cancelled": return .gray
            default:          return .secondary
            }
        }

        /// Reservaciones: requested=orange, approved=blue, confirmed=green,
        /// rejected/cancelled=red, completed=gray.
        public static func reservation(_ raw: String) -> Color {
            switch raw {
            case "requested":             return .orange
            case "approved":              return .blue
            case "confirmed":             return .green
            case "rejected", "cancelled": return .red
            case "completed":             return .gray
            default:                      return .secondary
            }
        }

        /// Obligaciones: open/accepted/in_progress=orange, completed/settled=green,
        /// expired/forgiven/cancelled=gray, disputed=red.
        public static func obligation(_ raw: String) -> Color {
            switch raw {
            case "open", "accepted", "in_progress":  return .orange
            case "completed", "settled":             return .green
            case "expired", "forgiven", "cancelled": return .gray
            case "disputed":                         return .red
            default:                                 return .secondary
            }
        }
    }

    // MARK: - Feed source tints (R.3A — Mi Actividad)

    public enum Source {
        public static func tint(_ source: FeedSource) -> Color {
            switch source {
            case .subscription: return .blue
            case .ownership:    return .orange
            case .membership:   return .green
            }
        }
    }
}

// MARK: - Convenience extensions

public extension Color {
    /// Opacidad estándar para fills tintados (badges sobre Capsule/Circle).
    /// `Color.orange.badgeFill` ≡ `Color.orange.opacity(Theme.Surface.badgeFill)`.
    var badgeFill: Color { opacity(Theme.Surface.badgeFill) }

    /// Variante sutil del badgeFill (12%).
    var badgeFillSubtle: Color { opacity(Theme.Surface.badgeFillSubtle) }
}

public extension View {
    /// Aplica la sombra estándar sutil de Ruul (radius 2, y 1, opacity 0.08).
    /// Úsala con moderación — la app es flat by default.
    func subtleShadow() -> some View {
        shadow(
            color: Color.black.opacity(Theme.Shadow.subtleOpacity),
            radius: Theme.Shadow.subtleRadius,
            x: 0,
            y: Theme.Shadow.subtleY
        )
    }
}
