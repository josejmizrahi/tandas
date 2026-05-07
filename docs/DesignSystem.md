# ruul — Design System v2.0

> Documento autoritativo sobre cómo se ve y se siente ruul.
> Cualquier nueva pantalla, componente, o pattern visual debe
> consultarse contra este doc primero. Cualquier desviación
> requiere justificación documentada y update de este doc.
>
> Última actualización: 2026-05-07
> Versión: 2.0.0
> Mantenedor: founder + reviewer
> Stack: Swift 6, SwiftUI puro, iOS 26+, Liquid Glass nativo
>
> Cambios v1 → v2:
>   - Estructura de tabs corregida (Inicio · Grupo · Historial · Ajustes)
>   - Multi-group como arquitectura estructural desde V1
>   - Patrón híbrido: Home cross-grupos, otras tabs grupo-activo
>   - 5 componentes nuevos para multi-group support
>   - Color automático por categoría de template

---

## §0 Cómo usar este documento

**Si vas a construir una pantalla nueva**: leé §1 (filosofía), después §6 (catálogo de pantallas) y §5 (layout patterns). Si necesitás componente nuevo, leé §10.

**Si vas a construir un componente nuevo**: leé §1, §2 (tokens), §10 (reglas de evolución).

**Si vas a hacer revisión de código UI**: usá §11 (review checklist).

**Si sos founder revisando dirección**: leé §1, §4 (multi-group context), §13 (anti-patterns).

**Cuándo este doc se actualiza**: al cierre de cada fase mayor, o cuando se descubre decisión arquitectónica que invalide algo previo.

---

## §1 Filosofía de diseño

### §1.1 La identidad de ruul

ruul es **infraestructura de autogobierno para grupos**. La UI debe transmitir:

- **Autoridad amable**: serio sin ser frío, accesible sin ser informal
- **Predictibilidad**: el usuario siempre sabe qué pasa y por qué
- **Transparencia**: cada decisión tiene historial visible
- **Calma**: la app no compite por atención, espera al usuario
- **Multi-group nativo**: ningún usuario tiene un solo grupo, nunca

ruul NO se ve como:

- Notion / Linear (demasiado utilitario, sin personalidad)
- Headspace / Calm (demasiado emocional)
- Discord / Slack (demasiado social — aunque tomamos ideas de switcher)
- Splitwise / Venmo (demasiado transaccional)
- Luma (demasiado aspiracional)

ruul SÍ se ve como:

- Apple Wallet (autoridad amable, contenido focal)
- Apple Maps directions (jerarquía clara, información sin ruido)
- Things 3 (tipografía elegante, espacios respirados)
- Reeder 5 (combinación serif/sans bien hecha)

### §1.2 Principios de copy y tono

**Descriptivo, no acusatorio**:
- ❌ "Te multamos por llegar tarde"
- ✓ "Llegaste a las 9:35. Según la regla del grupo, eso aplica $250"

**Concreto, no aspiracional**:
- ❌ "¡Tu próxima cena épica te espera!"
- ✓ "Cena del martes 14 a las 20:00, casa de Daniel"

**Pasivo cuando es regla, activo cuando es acción humana**:
- "Se aplicó multa de $250" (sistema actuó)
- "Daniel canceló su asistencia" (humano actuó)

**Cero emojis en UI structural**. Emojis solo si el usuario los escribe en su contenido.

**Cero exclamaciones excepto confirmaciones críticas exitosas**.

### §1.3 Principios visuales

1. **Espacio respira**: usá todo el padding que parezca generoso, después agregá 4pt más
2. **Tipografía es jerarquía**: weights y sizes hacen el trabajo de bordes y colores en otras apps
3. **Color es semántico**: cada color tiene significado funcional, ninguno es decorativo
4. **Movimiento es feedback**: animaciones confirman acciones, nunca decoran
5. **Liquid Glass es chrome**: glass para UI infrastructure (toolbars, tab bar, sheets), surfaces sólidas para contenido
6. **Tap targets son generosos**: mínimo 44x44pt, target real (no solo icono)
7. **Multi-group es estructural**: cada item de Home muestra su grupo de origen claramente

---

## §2 Design tokens

### §2.1 Espaciado

Sistema de 4pt base. Múltiplos preferidos: 4, 8, 12, 16, 20, 24, 32, 48, 64.

```swift
public enum RuulSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16     // unidad base
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48

    // Aliases semánticos
    public static let cardPadding: CGFloat = md
    public static let screenPadding: CGFloat = lg
    public static let sectionGap: CGFloat = xxl
    public static let itemGap: CGFloat = sm
    public static let tabBarBottomSafeArea: CGFloat = 80  // espacio para tab bar flotante
}
```

### §2.2 Tipografía

```swift
public extension Font {
    // === Display === (títulos principales de pantalla)
    static let ruulDisplayLarge = Font.system(.largeTitle, design: .serif, weight: .semibold)
    static let ruulDisplayMedium = Font.system(.title, design: .serif, weight: .semibold)

    // === Headings === (titulares de sección, cards)
    static let ruulTitleLarge = Font.system(.title2, design: .default, weight: .semibold)
    static let ruulTitleMedium = Font.system(.title3, design: .default, weight: .semibold)
    static let ruulTitleSmall = Font.system(.headline, design: .default, weight: .semibold)

    // === Body === (texto principal)
    static let ruulBody = Font.system(.body, design: .default, weight: .regular)
    static let ruulBodyEmphasis = Font.system(.body, design: .default, weight: .semibold)

    // === Caption === (metadata, timestamps)
    static let ruulCaption = Font.system(.subheadline, design: .default, weight: .regular)
    static let ruulCaptionEmphasis = Font.system(.subheadline, design: .default, weight: .medium)
    static let ruulCaptionSmall = Font.system(.footnote, design: .default, weight: .regular)

    // === Numeric === (siempre tabular)
    static let ruulMoneyLarge = Font.system(.title, design: .default, weight: .semibold).monospacedDigit()
    static let ruulMoneyMedium = Font.system(.title3, design: .default, weight: .semibold).monospacedDigit()
    static let ruulMoneySmall = Font.system(.body, design: .default, weight: .semibold).monospacedDigit()

    // === Label === (botones, tab bar)
    static let ruulLabel = Font.system(.subheadline, design: .default, weight: .medium)
    static let ruulLabelSmall = Font.system(.caption, design: .default, weight: .medium)

    // === Microcopy === (legales, timestamps muy pequeños)
    static let ruulMicro = Font.system(.caption2, design: .default, weight: .regular)

    // === Group === (NEW v2: para nombre del grupo en items)
    static let ruulGroupLabel = Font.system(.caption, design: .default, weight: .medium)
}
```

### §2.3 Color

Sistema semántico, todo via Asset Catalog para soporte automático light/dark/accessibility.

```swift
public extension Color {
    // === Backgrounds ===
    static let ruulBackground = Color(.systemGroupedBackground)
    static let ruulSurface = Color(.secondarySystemGroupedBackground)
    static let ruulSurfaceElevated = Color(.tertiarySystemGroupedBackground)

    // === Text ===
    static let ruulTextPrimary = Color(.label)
    static let ruulTextSecondary = Color(.secondaryLabel)
    static let ruulTextTertiary = Color(.tertiaryLabel)
    static let ruulTextQuaternary = Color(.quaternaryLabel)

    // === Brand ===
    static let ruulAccent = Color("AccentColor")
    static let ruulAccentMuted = Color("AccentColorMuted")

    // === Semantic ===
    static let ruulPositive = Color(.systemGreen)
    static let ruulNegative = Color(.systemRed)
    static let ruulWarning = Color(.systemOrange)
    static let ruulInfo = Color(.systemBlue)
    static let ruulNeutral = Color(.systemGray)

    // === Borders ===
    static let ruulSeparator = Color(.separator)
    static let ruulSeparatorOpaque = Color(.opaqueSeparator)

    // === Semantic backgrounds ===
    static let ruulPositiveBackground = Color.ruulPositive.opacity(0.12)
    static let ruulNegativeBackground = Color.ruulNegative.opacity(0.12)
    static let ruulWarningBackground = Color.ruulWarning.opacity(0.12)
    static let ruulInfoBackground = Color.ruulInfo.opacity(0.12)
}
```

### §2.4 Group color ramps (NEW v2)

Mapping de categoría de template a color ramp del avatar del grupo.

**El color es automático según la categoría del template del grupo. NO se puede customizar por founder.**

```swift
public enum GroupCategory: String {
    case socialRecurring     // Cenas, clubes de lectura, tertulias
    case sharedResource      // Palcos, cabañas, yates, suscripciones
    case rotatingSavings     // Tandas, susu, hui, vaquitas
    case patrimonialFamily   // Consejos familiares, herencias
    case amateurTeam         // Bandas, equipos deportivos
    case groupTravel         // Squad trips, retreats, viajes
    case religiousCultural   // Comunidades religiosas, hermandades
    case professionalInformal // Cooperativas, mastermind, partnerships
    case digitalCommunity    // Servidores Discord, mod teams
    case commitmentPact      // Pactos de fitness, productividad

    public var ramp: GroupColorRamp {
        switch self {
        case .socialRecurring: .teal       // verde teal - sociable, calmo
        case .sharedResource: .blue        // azul - profesional, recurso
        case .rotatingSavings: .purple     // púrpura - financiero, ahorro
        case .patrimonialFamily: .amber    // amber - serio, patrimonial
        case .amateurTeam: .green          // verde - dinámico, deportivo
        case .groupTravel: .coral          // coral - aspiracional, viaje
        case .religiousCultural: .pink     // pink - cálido, comunidad
        case .professionalInformal: .gray  // gris - serio, formal
        case .digitalCommunity: .blue      // azul - digital, online
        case .commitmentPact: .green       // verde - crecimiento, hábito
        }
    }
}

public enum GroupColorRamp: String {
    case teal, blue, purple, amber, green, coral, pink, gray

    /// Background del avatar (el más claro del ramp)
    public var background: Color {
        Color("GroupRamp/\(rawValue)/50")
    }

    /// Foreground de las iniciales (el más oscuro del ramp)
    public var foreground: Color {
        Color("GroupRamp/\(rawValue)/800")
    }

    /// Para borders o accents del grupo (mid-ramp)
    public var accent: Color {
        Color("GroupRamp/\(rawValue)/600")
    }
}
```

**Asset Catalog setup requerido**:

```
Assets.xcassets/GroupRamp/
├── teal/50, 100, 200, 400, 600, 800, 900
├── blue/50, 100, 200, 400, 600, 800, 900
├── purple/50, 100, 200, 400, 600, 800, 900
├── amber/50, 100, 200, 400, 600, 800, 900
├── green/50, 100, 200, 400, 600, 800, 900
├── coral/50, 100, 200, 400, 600, 800, 900
├── pink/50, 100, 200, 400, 600, 800, 900
└── gray/50, 100, 200, 400, 600, 800, 900
```

Cada color tiene 7 stops (50 más claro → 900 más oscuro) con variantes light/dark mode.

### §2.5 Geometría

```swift
public enum RuulRadius {
    public static let small: CGFloat = 8       // chips, badges pequeños
    public static let medium: CGFloat = 12     // botones, inputs
    public static let large: CGFloat = 16      // cards normales
    public static let extraLarge: CGFloat = 20 // cards hero, modals
    public static let pill: CGFloat = 999      // capsules
}

public enum RuulBorder {
    public static let thin: CGFloat = 0.5
    public static let regular: CGFloat = 1.0
    public static let thick: CGFloat = 2.0
}
```

### §2.6 Sombras

```swift
public extension View {
    func ruulShadowSubtle() -> some View {
        self.shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
    }

    func ruulShadowMedium() -> some View {
        self.shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 4)
    }

    func ruulShadowElevated() -> some View {
        self.shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
    }
}
```

### §2.7 Animación

```swift
public extension Animation {
    static let ruulTap = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let ruulStateChange = Animation.smooth(duration: 0.3)
    static let ruulAppear = Animation.smooth(duration: 0.4)
    static let ruulSuccess = Animation.spring(response: 0.4, dampingFraction: 0.6)
    static let ruulSubtle = Animation.easeInOut(duration: 0.2)
    static let ruulGroupSwitch = Animation.smooth(duration: 0.4)  // NEW v2
}
```

### §2.8 Haptics

```swift
public enum RuulHaptic {
    case lightTap
    case mediumTap
    case success
    case warning
    case error
    case groupSwitch  // NEW v2: feedback al cambiar grupo activo

    public func trigger() {
        switch self {
        case .lightTap:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mediumTap:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .groupSwitch:
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
```

---

## §3 Componentes core

### §3.1 Componentes ya existentes

Sprint 0 entregó (asumiendo APIs alineadas con tokens de §2):

- `TemplatePickerCard`
- `ActionCard`
- `ResourceTabBar`
- `RuulMetricCard`
- `RuulTimelineItem`

### §3.2 RuulCard — container base

```swift
public struct RuulCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = RuulSpacing.cardPadding
    var background: Color = .ruulSurface

    public init(
        padding: CGFloat = RuulSpacing.cardPadding,
        background: Color = .ruulSurface,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.background = background
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large))
    }
}
```

### §3.3 RuulPillButton

```swift
public struct RuulPillButton: View {
    let symbol: String
    let action: () -> Void
    var size: Size = .regular

    public enum Size {
        case small, regular, large
        var dimension: CGFloat {
            switch self { case .small: 32; case .regular: 40; case .large: 48 }
        }
    }

    public var body: some View {
        Button {
            RuulHaptic.lightTap.trigger()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size == .small ? 14 : 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: size.dimension, height: size.dimension)
                .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
    }
}
```

### §3.4 RuulHeaderActions

```swift
public struct RuulHeaderActions<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 4)
        .frame(height: 40)
        .background(Capsule().fill(.regularMaterial))
    }
}
```

### §3.5 RuulButton

```swift
public struct RuulButton: View {
    let title: String
    let action: () -> Void
    var style: Style = .primary
    var size: Size = .regular
    var icon: String? = nil
    var isLoading: Bool = false
    var isDestructive: Bool = false

    public enum Style {
        case primary       // accent background, white text
        case secondary     // surface background, primary text
        case tertiary      // transparent, accent text
        case glass         // material background, primary text
    }

    public enum Size {
        case small, regular, large
        var height: CGFloat {
            switch self { case .small: 32; case .regular: 44; case .large: 56 }
        }
    }

    // body implementation: ver RuulButton.swift completo
}
```

### §3.6 RuulTabBar

```swift
public struct RuulTabBar<Tab: RuulTabItem>: View {
    @Binding var selected: Tab
    let tabs: [Tab]

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            Capsule().fill(.regularMaterial)
        }
        .padding(.horizontal, RuulSpacing.xl)
        .padding(.bottom, RuulSpacing.sm)
    }

    private func tabButton(for tab: Tab) -> some View {
        let isSelected = selected.id == tab.id
        return Button {
            RuulHaptic.lightTap.trigger()
            withAnimation(.ruulTap) {
                selected = tab
            }
        } label: {
            VStack(spacing: 2) {
                if let badge = tab.badge {
                    ZStack {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 20, weight: .regular))
                        // Badge dot for unread/pending count
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 8, y: -8)
                    }
                } else {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 20, weight: .regular))
                }
                Text(tab.label)
                    .font(.ruulLabelSmall)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule().fill(.quaternary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

public protocol RuulTabItem: Identifiable, Hashable {
    var label: String { get }
    var symbol: String { get }
    var badge: Int? { get }  // NEW v2: notification dot
}
```

### §3.7 RuulSubTabBar (NEW v2)

Sub-tabs horizontales dentro de la tab Grupo. Pills horizontales scrollables si hay muchas.

```swift
public struct RuulSubTabBar<Tab: RuulSubTabItem>: View {
    @Binding var selected: Tab
    let tabs: [Tab]

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.xs) {
                ForEach(tabs) { tab in
                    Button {
                        RuulHaptic.lightTap.trigger()
                        withAnimation(.ruulTap) {
                            selected = tab
                        }
                    } label: {
                        Text(tab.label)
                            .font(.ruulLabel)
                            .foregroundStyle(selected.id == tab.id ? .white : .primary)
                            .padding(.horizontal, RuulSpacing.md)
                            .padding(.vertical, RuulSpacing.xs)
                            .background {
                                if selected.id == tab.id {
                                    Capsule().fill(Color.ruulAccent)
                                } else {
                                    Capsule().fill(Color.ruulSurface)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
        }
    }
}

public protocol RuulSubTabItem: Identifiable, Hashable {
    var label: String { get }
}
```

### §3.8 RuulSectionHeader

```swift
public struct RuulSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil

    public var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.ruulTitleMedium)

            if let subtitle {
                Text("/")
                    .foregroundStyle(.tertiary)
                Text(subtitle)
                    .font(.ruulTitleMedium)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let trailing {
                trailing
            }
        }
        .padding(.horizontal, RuulSpacing.screenPadding)
    }
}
```

### §3.9 RuulMoneyView

```swift
public struct RuulMoneyView: View {
    let amount: Decimal
    let currency: String
    var size: Size = .medium
    var showSign: Bool = false
    var color: SemanticColor = .neutral

    public enum Size {
        case small, medium, large
        var font: Font {
            switch self {
            case .small: .ruulMoneySmall
            case .medium: .ruulMoneyMedium
            case .large: .ruulMoneyLarge
            }
        }
    }

    public enum SemanticColor {
        case neutral, positive, negative
        var color: Color {
            switch self {
            case .neutral: .ruulTextPrimary
            case .positive: .ruulPositive
            case .negative: .ruulNegative
            }
        }
    }

    public var body: some View {
        Text(formatted)
            .font(size.font)
            .foregroundStyle(color.color)
            .accessibilityLabel(accessibleLabel)
    }

    // formatted, accessibleLabel implementación: NumberFormatter
}
```

### §3.10 RuulPersonAvatar

Avatar de un miembro/persona. Distinto de RuulGroupAvatar (que es del grupo).

```swift
public struct RuulPersonAvatar: View {
    let initials: String
    let imageURL: URL?
    var size: Size = .medium
    var color: Color = .ruulAccent

    public enum Size {
        case xs, sm, md, lg, xl
        var dimension: CGFloat {
            switch self {
            case .xs: 24; case .sm: 32; case .md: 40; case .lg: 56; case .xl: 80
            }
        }
        var font: Font {
            switch self {
            case .xs: .ruulMicro; case .sm: .ruulCaptionSmall
            case .md: .ruulCaption; case .lg: .ruulBodyEmphasis
            case .xl: .ruulTitleMedium
            }
        }
    }

    public var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholderView
                }
            } else {
                placeholderView
            }
        }
        .frame(width: size.dimension, height: size.dimension)
        .clipShape(Circle())
    }

    private var placeholderView: some View {
        ZStack {
            Circle().fill(color.opacity(0.2))
            Text(initials.prefix(2).uppercased())
                .font(size.font.weight(.semibold))
                .foregroundStyle(color)
        }
    }
}
```

### §3.11 RuulGroupAvatar (NEW v2)

Avatar del grupo. Distinto de RuulPersonAvatar — usa color ramp automático según categoría.

```swift
public struct RuulGroupAvatar: View {
    let group: Group
    var size: Size = .medium

    public enum Size {
        case xs, sm, md, lg, xl
        var dimension: CGFloat {
            switch self {
            case .xs: 20; case .sm: 24; case .md: 32; case .lg: 40; case .xl: 56
            }
        }
        var font: Font {
            switch self {
            case .xs: .system(size: 9, weight: .semibold)
            case .sm: .system(size: 11, weight: .semibold)
            case .md: .system(size: 12, weight: .semibold)
            case .lg: .system(size: 14, weight: .semibold)
            case .xl: .system(size: 18, weight: .semibold)
            }
        }
    }

    public var body: some View {
        let ramp = group.category.ramp

        ZStack {
            if let imageURL = group.avatarURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholderView(ramp: ramp)
                }
            } else {
                placeholderView(ramp: ramp)
            }
        }
        .frame(width: size.dimension, height: size.dimension)
        .clipShape(Circle())
    }

    private func placeholderView(ramp: GroupColorRamp) -> some View {
        ZStack {
            Circle().fill(ramp.background)
            Text(group.initials.uppercased())
                .font(size.font)
                .foregroundStyle(ramp.foreground)
        }
    }
}
```

### §3.12 RuulOriginTag (NEW v2)

Tag pequeño que muestra de qué grupo viene un item en Home (cross-grupos).

```swift
public struct RuulOriginTag: View {
    let group: Group

    public var body: some View {
        HStack(spacing: 6) {
            RuulGroupAvatar(group: group, size: .sm)
            Text(group.name)
                .font(.ruulGroupLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
```

**Uso**:

```swift
// En cada ActionCard de Home
VStack(alignment: .leading, spacing: 8) {
    RuulOriginTag(group: action.originGroup)
    // ... resto del action card
}
```

### §3.13 RuulGroupSwitcher (NEW v2)

Pill button en header de tab Grupo, Historial, Ajustes. Muestra grupo activo, abre selector al tap.

```swift
public struct RuulGroupSwitcher: View {
    @Binding var activeGroup: Group
    let availableGroups: [Group]
    @State private var showSheet = false

    public var body: some View {
        Button {
            RuulHaptic.lightTap.trigger()
            showSheet = true
        } label: {
            HStack(spacing: 8) {
                RuulGroupAvatar(group: activeGroup, size: .sm)
                Text(activeGroup.name)
                    .font(.ruulTitleSmall)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            RuulGroupSwitcherSheet(
                activeGroup: $activeGroup,
                availableGroups: availableGroups
            )
        }
    }
}
```

### §3.14 RuulGroupSwitcherSheet (NEW v2)

Bottom sheet con lista de grupos. Tap en grupo lo activa.

```swift
public struct RuulGroupSwitcherSheet: View {
    @Binding var activeGroup: Group
    let availableGroups: [Group]
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: RuulSpacing.xs) {
                    ForEach(availableGroups) { group in
                        Button {
                            RuulHaptic.groupSwitch.trigger()
                            withAnimation(.ruulGroupSwitch) {
                                activeGroup = group
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: RuulSpacing.md) {
                                RuulGroupAvatar(group: group, size: .lg)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                        .font(.ruulTitleSmall)
                                        .foregroundStyle(.primary)
                                    Text(group.category.displayName)
                                        .font(.ruulCaption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if group.id == activeGroup.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.ruulAccent)
                                }
                            }
                            .padding(RuulSpacing.md)
                            .background(Color.ruulSurface)
                            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, RuulSpacing.screenPadding)
            }
            .navigationTitle("Tus grupos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // crear nuevo grupo
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
```

### §3.15 RuulBadge

```swift
public struct RuulBadge: View {
    let text: String
    var style: Style = .neutral
    var icon: String? = nil

    public enum Style {
        case neutral, positive, negative, warning, info

        var background: Color {
            switch self {
            case .neutral: .ruulNeutral.opacity(0.15)
            case .positive: .ruulPositiveBackground
            case .negative: .ruulNegativeBackground
            case .warning: .ruulWarningBackground
            case .info: .ruulInfoBackground
            }
        }
        var foreground: Color {
            switch self {
            case .neutral: .ruulTextSecondary
            case .positive: .ruulPositive
            case .negative: .ruulNegative
            case .warning: .ruulWarning
            case .info: .ruulInfo
            }
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.ruulMicro.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(style.foreground)
        .background(style.background)
        .clipShape(Capsule())
    }
}
```

### §3.16 RuulEmptyState

```swift
public struct RuulEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: ActionConfig? = nil

    public struct ActionConfig {
        let label: String
        let handler: () -> Void
    }

    public var body: some View {
        VStack(spacing: RuulSpacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.ruulTitleMedium)
                .foregroundStyle(.primary)

            Text(message)
                .font(.ruulBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            if let action {
                RuulButton(action.label, action: action.handler)
                    .frame(maxWidth: 240)
                    .padding(.top, RuulSpacing.sm)
            }
        }
        .padding(RuulSpacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

### §3.17 RuulErrorState, RuulLoadingState, RuulInlineMessage

(Implementación igual que v1, ver doc anterior)

---

## §4 Multi-group context (NEW v2)

Esta es la sección más importante de v2. Establece reglas de cómo el sistema maneja múltiples grupos.

### §4.1 Principio fundamental

**Un usuario puede pertenecer a 1-N grupos. Toda la UI debe funcionar correctamente con N=1 hasta N=20+.**

No es feature opcional. No es fase futura. Es estructura de V1.

### §4.2 Patrón híbrido de scope

Cada tab opera en uno de dos modos:

**Cross-grupos (todas las grupos del usuario)**:
- Tab **Inicio**: muestra contenido de todos los grupos del usuario, con avatar/nombre del grupo en cada item

**Grupo-activo (un grupo seleccionado a la vez)**:
- Tab **Grupo**: opera sobre el grupo activo, con switcher en header
- Tab **Historial**: idem
- Tab **Ajustes**: subseccciones globales (perfil, notificaciones del usuario) + grupo-activo (members, rules de ese grupo)

### §4.3 Concepto de "grupo activo"

El grupo activo es persistente por sesión. Cuando el usuario:

- **Abre la app**: vuelve al último grupo activo de la sesión anterior
- **Cambia grupo**: el cambio aplica a tabs grupo-específicas
- **Recibe push de otro grupo**: tap en push cambia el grupo activo automáticamente

### §4.4 Switcher behavior

- Vive en el header de tabs Grupo, Historial, Ajustes
- NO vive en Home (Home es cross-grupos)
- Tap abre `RuulGroupSwitcherSheet` (bottom sheet)
- Tap en grupo distinto: cambia activo + dismiss sheet + animación de transición

### §4.5 Items de Home con origen

Cada item en Home (hero, pendiente, activity) muestra `RuulOriginTag`:

- Avatar pequeño del grupo (color ramp)
- Nombre del grupo en caption
- Posicionado arriba del item

Esto NO es opcional. Es invariante de Home.

### §4.6 Caso 1 grupo solamente

Cuando el usuario tiene exactamente 1 grupo:

- Home: NO muestra `RuulOriginTag` en items (solo hay un grupo, redundante)
- Tabs grupo-específicas: switcher se muestra como solo lectura (no es interactivo, solo informa nombre)
- Cuando agrega segundo grupo: switcher se vuelve interactivo automáticamente, items de home empiezan a mostrar origen

### §4.7 Color ramp por categoría de template

Mapping fijo, no customizable por founder:

| Categoría | Ramp | Razón |
|---|---|---|
| socialRecurring | teal | Sociable, calmo |
| sharedResource | blue | Profesional, compartido |
| rotatingSavings | purple | Financiero, ahorro |
| patrimonialFamily | amber | Serio, patrimonial |
| amateurTeam | green | Dinámico, deportivo |
| groupTravel | coral | Aspiracional, viaje |
| religiousCultural | pink | Cálido, comunidad |
| professionalInformal | gray | Serio, formal |
| digitalCommunity | blue | Digital |
| commitmentPact | green | Crecimiento |

**Por qué automático**: si fuera elegible, todos los grupos del mismo dueño tenderían al mismo color personal. La distinción visual entre grupos se perdería. Color como feature funcional > color como expresión personal.

### §4.8 Iniciales del grupo

Cada grupo tiene dos campos:
- `name` (string largo): "Cuates de cenas martes"
- `initials` (string 1-3 chars): "CC"

Al crear grupo:
- Founder ingresa `name`
- Sistema sugiere `initials` automáticas (primeras letras de palabras significativas)
- Founder puede override antes de crear

Esto permite nombres descriptivos largos sin sacrificar avatares legibles.

### §4.9 Hero de Home — selección del item

Cuando hay múltiples grupos con eventos próximos, el hero muestra **el item de mayor urgencia temporal cross-grupos**.

Algoritmo de prioridad:
1. Items con deadline en <2h
2. Items con deadline en <24h
3. Items con deadline en <72h
4. Próximo evento cronológico

Empate se rompe por proximidad temporal directa.

Si no hay nada urgente: hero se reemplaza por sección "Próximos eventos" con lista cronológica cross-grupos.

### §4.10 Push notifications con multi-group

Toda push notification debe incluir:
- `group_id` en payload (para identificar grupo)
- `deeplink` que abra app con grupo-activo correcto

Tap en push:
- Cambia grupo activo si necesario (silenciosamente, sin haptic)
- Navega al item específico del push

---

## §5 Layout patterns

### §5.1 Estructura de pantalla principal con tab bar flotante

```swift
struct MainScreenLayout<Content: View>: View {
    let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.ruulBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header (sticky o scroll-away)
                screenHeader

                ScrollView {
                    VStack(spacing: RuulSpacing.sectionGap) {
                        content
                    }
                    .padding(.vertical, RuulSpacing.lg)
                    .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
                }
            }
        }
    }
}
```

### §5.2 Estructura de pantalla con grupo activo (Grupo, Historial, Ajustes)

```swift
struct GroupScopedScreenLayout<Content: View>: View {
    @Binding var activeGroup: Group
    let availableGroups: [Group]
    let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.ruulBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header con group switcher
                HStack {
                    RuulGroupSwitcher(
                        activeGroup: $activeGroup,
                        availableGroups: availableGroups
                    )
                    Spacer()
                    // acciones específicas de la tab
                }
                .padding(.horizontal, RuulSpacing.screenPadding)
                .padding(.vertical, RuulSpacing.md)

                content
            }
        }
    }
}
```

### §5.3 Estructura de tab Grupo con sub-tabs adaptativas

```swift
struct GroupTabView: View {
    @Binding var activeGroup: Group
    @State var selectedSubTab: GroupSubTab

    var availableSubTabs: [GroupSubTab] {
        // Adaptativo según template del grupo activo
        var tabs: [GroupSubTab] = []
        if activeGroup.template.hasEvents { tabs.append(.events) }
        if activeGroup.template.hasRotation { tabs.append(.rotation) }
        if activeGroup.template.hasSlots { tabs.append(.slots) }
        if activeGroup.template.hasFund { tabs.append(.fund) }
        if activeGroup.template.hasProposals { tabs.append(.proposals) }
        tabs.append(.rules)  // siempre
        tabs.append(.fines)  // siempre en V1
        return tabs
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header con switcher
            HStack {
                RuulGroupSwitcher(activeGroup: $activeGroup, availableGroups: ...)
                Spacer()
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.vertical, RuulSpacing.md)

            // Sub-tabs horizontales
            RuulSubTabBar(selected: $selectedSubTab, tabs: availableSubTabs)
                .padding(.bottom, RuulSpacing.md)

            // Content adaptativo según sub-tab
            switch selectedSubTab {
            case .events: EventsListView(group: activeGroup)
            case .rotation: RotationView(group: activeGroup)
            case .slots: SlotsView(group: activeGroup)
            case .fund: FundView(group: activeGroup)
            case .proposals: ProposalsView(group: activeGroup)
            case .rules: RulesView(group: activeGroup)
            case .fines: FinesView(group: activeGroup)
            }
        }
    }
}
```

### §5.4 Lista con secciones por día (cross-grupos)

```swift
struct DateSectionedListWithOrigin: View {
    let sections: [(date: DayHeader, items: [ItemWithOrigin])]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RuulSpacing.xl) {
                ForEach(sections, id: \.date) { section in
                    VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                        RuulSectionHeader(
                            title: section.date.primary,
                            subtitle: section.date.secondary
                        )

                        VStack(spacing: RuulSpacing.itemGap) {
                            ForEach(section.items) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    RuulOriginTag(group: item.group)
                                    // resto del item
                                }
                                .padding(RuulSpacing.cardPadding)
                                .background(Color.ruulSurface)
                                .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large))
                                .padding(.horizontal, RuulSpacing.screenPadding)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
    }
}
```

### §5.5 Sheet de creación

```swift
struct CreationSheet: View {
    var body: some View {
        NavigationStack {
            Form {
                Section { /* campos */ }
            }
            .formStyle(.grouped)
            .navigationTitle("Nueva regla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crear", action: submit).bold()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
```

---

## §6 Catálogo de pantallas

### §6.1 Onboarding flow

- `WelcomeView` — splash con CTA "Empezar"
- `AuthView` — verificación de número (WhatsApp OTP)
- `TemplateSelectorView` — elegir template
- `CreateGroupSheet` — datos básicos (incluye campo `initials` con sugerencia automática)
- `InviteMembersSheet` — invitar primeros miembros
- `GroupReadyView` — confirmación

### §6.2 Main tabs (corregido v2)

**Tab 1 — Inicio (cross-grupos)**:
- `HomeView` — overview cross-grupos con `RuulOriginTag` en cada item
  - Hero: item de mayor urgencia (cualquier grupo, cualquier tipo)
  - Section: pendientes de todos los grupos (con origen)
  - Section: actividad reciente cross-grupos

**Tab 2 — Grupo (grupo-activo, NEW v2)**:
- `GroupTabView` — header con switcher + sub-tabs adaptativas según template
  - Sub-tab: `EventsListView` (si template tiene events)
  - Sub-tab: `RotationView` (Fase 2+)
  - Sub-tab: `SlotsView` (Fase 3+)
  - Sub-tab: `FundView` (Fase 4+)
  - Sub-tab: `ProposalsView` (Fase 5+)
  - Sub-tab: `RulesView` (siempre)
  - Sub-tab: `FinesView` (siempre V1)

**Tab 3 — Historial (grupo-activo)**:
- `HistoryView` — timeline de SystemEvents del grupo activo
  - Header con switcher
  - Sectioned por día
  - Filtrable por tipo

**Tab 4 — Ajustes (dual scope)**:
- `SettingsView` — dual scope
  - Sección "Tu cuenta" (global): perfil, notificaciones del usuario
  - Sección "Este grupo" (grupo-activo, con switcher): members, governance, danger zone

### §6.3 Group switcher

- `RuulGroupSwitcherSheet` — bottom sheet con lista de grupos del usuario

### §6.4 Detail views

- `EventDetailView` — detalle de evento (cena u otro)
- `FineDetailView` — detalle de multa con opción apelar
- `VoteDetailView` — router a body por voteType
  - `FineAppealVoteBody`
  - `GeneralProposalVoteBody`
  - `RuleChangeVoteBody`
  - `GenericVoteBody`
- `RuleDetailView` — detalle de regla
- `MemberDetailView` — perfil de miembro

### §6.5 Sheets de acción

- `RSVPSheet`
- `AppealFineSheet`
- `VoteOnAppealSheet`
- `CreateGeneralProposalSheet`
- `CreateRuleChangeSheet`
- `EditRuleSheet`
- `EditMembersSheet`

---

## §7 Layouts adaptativos

### §7.1 iPhone (target principal V1)

- iPhone 15 (393pt) como base
- Verificar iPhone SE (375pt) y iPhone 16 Pro Max (430pt)
- Touch targets mínimos 44x44pt

### §7.2 iPad y macOS (V2+)

V1 funciona pero no se optimiza visualmente. Cuando se haga:
- iPad: split view con sidebar de grupos a la izquierda (mejor que bottom sheet en iPad)
- Mac: window resizable, sidebar persistente

### §7.3 Dynamic Type

- Toda tipografía respeta Dynamic Type
- Verificación obligatoria en AX5
- Tab bar labels NO escalan más allá de XL

### §7.4 Light vs Dark

- Asset Catalog con variants de cada color
- Liquid Glass auto-adapta
- Group color ramps tienen variants light/dark

---

## §8 Iconografía

### §8.1 Sistema

**SF Symbols only**. Pesos preferidos: `.regular` para context, `.medium` para acciones primarias.

### §8.2 Iconos canónicos por concepto

| Concepto | SF Symbol |
|---|---|
| Inicio | `house` |
| Grupo (tab) | `person.3` |
| Historial | `clock.arrow.circlepath` |
| Ajustes | `gear` |
| Atrás | `chevron.left` |
| Más opciones | `ellipsis` |
| Buscar | `magnifyingglass` |
| Crear | `plus` |
| Cerrar | `xmark` |
| Confirmar | `checkmark` |
| Eliminar | `trash` |
| Editar | `pencil` |
| Compartir | `square.and.arrow.up` |
| Notificación | `bell` |
| Cambiar grupo | `chevron.down` (en switcher) |
| Persona | `person.fill` |
| Grupo (concepto) | `person.3.fill` |
| Evento/cena | `fork.knife` o `calendar` |
| Multa | `exclamationmark.circle` |
| Dinero | `dollarsign.circle` |
| Voto | `checkmark.bubble` |
| Regla | `doc.text` |
| Tiempo | `clock` |
| Ubicación | `mappin.and.ellipse` |
| Anfitrión | `crown.fill` |
| Rotación | `arrow.triangle.2.circlepath` (NEW Fase 2) |
| Slot | `square.grid.3x1.below.line.grid.1x2` (NEW Fase 3) |
| Fondo | `banknote` (NEW Fase 4) |
| Activo | `building.columns` (NEW Fase 3) |
| Propuesta | `text.bubble` (NEW Fase 5) |

---

## §9 Accesibilidad

### §9.1 Mínimos no negociables

1. **VoiceOver completo**
2. **Dynamic Type AX5**
3. **Reduce Motion**
4. **Contraste WCAG AA** (4.5:1 normal, 3:1 grande)
5. **Touch targets 44x44pt**

### §9.2 Patterns críticos para multi-group

```swift
// RuulOriginTag debe leer claramente
RuulOriginTag(group: action.originGroup)
    .accessibilityLabel("Grupo \(group.name)")
    .accessibilityHint("Categoría: \(group.category.displayName)")

// RuulGroupSwitcher
RuulGroupSwitcher(...)
    .accessibilityLabel("Grupo activo: \(activeGroup.name)")
    .accessibilityHint("Toca para cambiar a otro grupo")
    .accessibilityAddTraits(.isButton)

// Item de Home con origen
ActionCard(...)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(group.name): \(action.title), \(action.subtitle)")
```

### §9.3 Reduce Motion

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

withAnimation(reduceMotion ? .none : .ruulGroupSwitch) {
    activeGroup = newGroup
}
```

---

## §10 Reglas de evolución

### §10.1 Cuándo agregar componente nuevo

Mismo criterio que v1: pattern aparece 3+ veces, no existe variante razonable, semánticamente distinto.

### §10.2 Evolución por fase

**Fase 1 (V1, actual)** - shipped:
- Componentes core §3 incluyendo multi-group support
- Patterns de §5 y §6
- 4 tabs base
- Tab Grupo solo con sub-tabs Events, Rules, Fines

**Fase 2 (Rotation universal)**: agregar
- `RuulRotationView` — visualización de orden de rotación
- `RuulPositionBadge` — posición en rotación
- Nueva sub-tab "Rotación" en GroupTabView
- Pattern: "alguien saltó turno"

**Fase 3 (Slot + Asset)**: agregar
- `RuulSlotCard` — slot asignable con CTA accept/decline
- `RuulAssetView` — vista del activo con calendar
- Nuevas sub-tabs "Activos" y "Slots"
- Pattern: cascada de asignación

**Fase 4 (Fund + Contribution + Cycle)**: agregar
- `RuulFundBalanceCard` — saldo con trend
- `RuulContributionRow` — aporte esperado/realizado
- `RuulCyclePhase` — indicador de fase
- Nueva sub-tab "Fondo"
- Pattern: settle up

**Fase 5 (Proposal + Comment + Roles)**: agregar
- `RuulProposalCard`
- `RuulCommentThread`
- `RuulRoleBadge`
- Nueva sub-tab "Propuestas"
- Filtros opcionales en Home (cuando user tiene 5+ grupos)

**Fase 6 (Editor + Commitment)**: agregar
- `RuulRuleBuilder`
- `RuulConditionRow`, `RuulConsequenceCard`
- `RuulCommitmentCard`
- Sub-tab "Compromisos"

### §10.3 Versionado del DS

**Major** (X.0.0): cambios breaking en componentes core o arquitectura
**Minor** (1.X.0): nuevos componentes, fases nuevas
**Patch** (1.1.X): clarificaciones, fixes

Estado actual: **DS v2.0.0** — cambios mayores respecto a v1 (estructura tabs, multi-group).

---

## §11 Review checklist

### §11.1 Tokens

- [ ] Spacing usa `RuulSpacing.*`
- [ ] Tipografía usa `Font.ruul*`
- [ ] Colores usan `Color.ruul*` o group color ramps
- [ ] Corner radius usa `RuulRadius.*`
- [ ] Animaciones usan `Animation.ruul*`

### §11.2 Componentes

- [ ] Reutiliza componentes existentes
- [ ] Componentes nuevos justificados
- [ ] Props opcionales con defaults razonables
- [ ] Accessibility labels presentes

### §11.3 Multi-group (NEW v2)

- [ ] Si la pantalla muestra contenido cross-grupos: cada item tiene `RuulOriginTag`
- [ ] Si la pantalla es grupo-activo: header tiene `RuulGroupSwitcher`
- [ ] Funciona correctamente con N=1 grupo (sin items redundantes de origen)
- [ ] Funciona correctamente con N=20 grupos (no se rompe el switcher)

### §11.4 Patterns

- [ ] Estructura sigue §5 patterns
- [ ] Empty/error/loading states explícitos
- [ ] Tap feedback (haptic donde corresponde)
- [ ] Dynamic Type funciona en AX5

### §11.5 Copy

- [ ] Tono descriptivo, no acusatorio
- [ ] Sin emojis estructurales
- [ ] Sin exclamaciones excepto confirmaciones críticas
- [ ] Concreto, no aspiracional

### §11.6 Performance

- [ ] LazyVStack para listas largas
- [ ] AsyncImage con placeholder
- [ ] No re-renders innecesarios

---

## §12 Anti-patterns

**❌ Tabs separadas para Pendientes/Notificaciones/Inbox**
→ Pendientes vive en Home con badge en tab bar.

**❌ Switcher de grupo en Home**
→ Home es cross-grupos por diseño. Switcher solo en otras tabs.

**❌ Items de Home sin indicar grupo de origen (multi-group user)**
→ Cada item de Home cross-grupos debe tener `RuulOriginTag`.

**❌ Color del avatar elegido por founder**
→ Color automático según categoría de template.

**❌ Sub-tabs en tab Grupo idénticas en todos los templates**
→ Sub-tabs son adaptativas según template del grupo activo.

**❌ Gradientes decorativos**
→ ruul es Wallet, no Stripe.

**❌ Cover images coloridas grandes en cada item**
→ Eso es Luma. Ruul usa SF Symbols o avatares chicos.

**❌ Animaciones bouncy exageradas**
→ Spring sutil sí.

**❌ Modo dark forzado siempre**
→ Respetar preferencia del sistema.

**❌ Skeleton screens animados en V1**
→ ProgressView simple.

**❌ Toasts/snackbars por cada acción**
→ Solo confirmaciones críticas.

**❌ Onboarding marketing-style con illustrations**
→ Onboarding funcional, máximo 3 pantallas.

**❌ Iconos custom mediocres**
→ SF Symbols.

**❌ Fonts custom no nativas**
→ SF Pro + New York.

**❌ Negro puro #000 background**
→ `systemGroupedBackground`.

**❌ TabView default**
→ `RuulTabBar` flotante.

**❌ NavigationView (deprecated)**
→ `NavigationStack`.

**❌ Combine para nuevos features**
→ async/await + @Observable.

**❌ UIKit en código nuevo**
→ SwiftUI puro.

**❌ Hardcoded strings**
→ Localizable desde V1.

**❌ Hex colors en código**
→ Asset Catalog only.

**❌ Mostrar nombre del grupo como prefijo en cada texto**
→ Usar `RuulOriginTag` que muestra avatar + nombre arriba del item.

---

## §13 Filosofía de excepciones

Este documento es autoritativo, pero no infalible.

**Cuándo es válido desviarse**:

1. La regla del DS produce resultado peor que ignorarla
2. El caso es genuinamente nuevo y el DS no lo cubre
3. Hay restricción técnica que fuerza alternativa

**Cuándo NO es válido**:

1. "Me parece más bonito"
2. "Es más rápido de implementar"
3. "Otros productos lo hacen así"

**Si te desviás**: documentá en el código por qué, abrí issue para evaluar update del DS.

---

## §14 Apéndices: ejemplos de pantallas completas

### §14.1 HomeView completa (cross-grupos)

```swift
struct HomeView: View {
    @State var coordinator = HomeCoordinator(...)

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Inicio")
                        .font(.ruulDisplayMedium)
                    Spacer()
                    RuulPillButton(symbol: "bell") {
                        coordinator.openNotifications()
                    }
                }
                .padding(.horizontal, RuulSpacing.screenPadding)
                .padding(.top, RuulSpacing.md)

                ScrollView {
                    VStack(alignment: .leading, spacing: RuulSpacing.sectionGap) {
                        // Hero
                        if let urgent = coordinator.mostUrgentItem {
                            heroSection(item: urgent)
                        }

                        // Pendientes cross-grupos
                        if !coordinator.pendingActions.isEmpty {
                            pendingsSection
                        }

                        // Activity reciente cross-grupos
                        if !coordinator.recentActivity.isEmpty {
                            activitySection
                        }
                    }
                    .padding(.vertical, RuulSpacing.lg)
                    .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
                }
                .refreshable {
                    await coordinator.refresh()
                }
            }
        }
        .task { await coordinator.load() }
    }

    private func heroSection(item: UrgentItem) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text("PRÓXIMO")
                .font(.ruulCaptionEmphasis)
                .foregroundStyle(.secondary)
                .tracking(1.5)
                .padding(.horizontal, RuulSpacing.screenPadding)

            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                RuulOriginTag(group: item.group)
                // resto del hero según tipo de item
            }
            .padding(RuulSpacing.lg)
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large))
            .padding(.horizontal, RuulSpacing.screenPadding)
        }
    }

    // pendingsSection, activitySection: similar structure
}
```

### §14.2 GroupTabView completa

```swift
struct GroupTabView: View {
    @Binding var activeGroup: Group
    let availableGroups: [Group]
    @State var selectedSubTab: GroupSubTab = .events

    var body: some View {
        VStack(spacing: 0) {
            // Header con switcher
            HStack {
                RuulGroupSwitcher(
                    activeGroup: $activeGroup,
                    availableGroups: availableGroups
                )
                Spacer()
                RuulPillButton(symbol: "ellipsis") {
                    // group settings shortcut
                }
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.vertical, RuulSpacing.md)

            // Sub-tabs adaptativas
            RuulSubTabBar(
                selected: $selectedSubTab,
                tabs: availableSubTabs(for: activeGroup)
            )
            .padding(.bottom, RuulSpacing.md)

            // Content
            switch selectedSubTab {
            case .events: EventsListView(group: activeGroup)
            case .rotation: RotationView(group: activeGroup)
            case .slots: SlotsView(group: activeGroup)
            case .fund: FundView(group: activeGroup)
            case .proposals: ProposalsView(group: activeGroup)
            case .rules: RulesView(group: activeGroup)
            case .fines: FinesView(group: activeGroup)
            }
        }
    }

    func availableSubTabs(for group: Group) -> [GroupSubTab] {
        var tabs: [GroupSubTab] = []
        if group.template.hasEvents { tabs.append(.events) }
        if group.template.hasRotation { tabs.append(.rotation) }
        if group.template.hasSlots { tabs.append(.slots) }
        if group.template.hasFund { tabs.append(.fund) }
        if group.template.hasProposals { tabs.append(.proposals) }
        tabs.append(.rules)
        tabs.append(.fines)
        return tabs
    }
}
```

---

## §15 Glosario

- **Token**: valor de design referenciado por nombre
- **Surface**: background level (background → surface → surfaceElevated)
- **Chrome**: UI infrastructure (toolbars, tab bar, sheets) — Liquid Glass
- **Content**: contenido del usuario — surfaces sólidas
- **Pattern**: combinación canónica de componentes
- **Liquid Glass**: material translúcido iOS 26
- **Group active**: el grupo seleccionado para tabs grupo-específicas (NEW v2)
- **Cross-group**: tab que muestra contenido de todos los grupos del usuario (NEW v2)
- **Origin tag**: avatar + nombre del grupo en items de Home (NEW v2)
- **Color ramp**: 7 stops de un mismo color para grupos (NEW v2)

---

## Changelog

**v2.0.0 (2026-05-07)**:
- BREAKING: Tab structure cambió de 4 (Inicio/Pendientes/Historial/Ajustes) a 4 distintas (Inicio/Grupo/Historial/Ajustes)
- BREAKING: Multi-group como arquitectura estructural V1
- Componentes nuevos: RuulGroupAvatar, RuulGroupSwitcher, RuulGroupSwitcherSheet, RuulSubTabBar, RuulOriginTag
- Token nuevo: GroupCategory + GroupColorRamp con 8 ramps
- Patterns nuevos: §4 Multi-group context, §5.2 Group-scoped layout, §5.3 GroupTabView
- Anti-patterns nuevos: 4 patterns relacionados a multi-group y tabs

**v1.0.0 (2026-05-06)**:
- Release inicial al cierre de Fase 1 (F0)

---

## Cómo este documento evoluciona

Cada cierre de fase mayor:
1. Lista componentes nuevos shipped
2. Documenta nuevos patterns identificados
3. Lista anti-patterns descubiertos
4. Update §10.2 con próxima fase

PRs a este documento requieren review de founder + reviewer.
