# ruul — Design System

> Documento autoritativo sobre cómo se ve y se siente ruul.
> Cualquier nueva pantalla, componente, o pattern visual debe
> consultarse contra este doc primero. Cualquier desviación
> requiere justificación documentada y update de este doc.
>
> Última actualización: 2026-05-07
> Mantenedor: founder + reviewer
> Stack: Swift 6, SwiftUI puro, iOS 26+, Liquid Glass nativo

---

## §0 Cómo usar este documento

**Si vas a construir una pantalla nueva**: leé §1 (filosofía), después saltá a §6 (patterns de pantallas) y buscá el pattern más cercano. Si no existe, leé §3 (componentes) para combinar piezas. Si necesitás componente nuevo, leé §10 (reglas de evolución).

**Si vas a construir un componente nuevo**: leé §1, §2 (tokens), §10 (reglas de evolución). Componentes nuevos se agregan a §3 con su API, ejemplos, y tests.

**Si vas a hacer revisión de código UI**: usá §11 (review checklist).

**Si sos founder revisando dirección**: leé §1 y §13 (anti-patterns).

---

## §1 Filosofía de diseño

### §1.1 La identidad de ruul

ruul es **infraestructura de autogobierno para grupos**. La UI debe transmitir:

- **Autoridad amable**: serio sin ser frío, accesible sin ser informal
- **Predictibilidad**: el usuario siempre sabe qué pasa y por qué
- **Transparencia**: cada decisión tiene historial visible
- **Calma**: la app no compite por atención, espera al usuario

ruul NO se ve como:

- Notion / Linear (demasiado utilitario, sin personalidad)
- Headspace / Calm (demasiado emocional)
- Discord / Slack (demasiado social)
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
    public static let cardPadding: CGFloat = md      // padding interno de cards
    public static let screenPadding: CGFloat = lg    // padding lateral de pantallas
    public static let sectionGap: CGFloat = xxl      // entre secciones de pantalla
    public static let itemGap: CGFloat = sm          // entre items en lista
}
```

**Reglas de aplicación**:

- Padding interno de cards: `cardPadding` (16pt)
- Padding lateral de pantallas: `screenPadding` (20pt)
- Gap entre items en lista: `itemGap` (12pt)
- Gap entre secciones: `sectionGap` (32pt)
- Padding superior debajo de header: `xl` (24pt)
- Padding inferior antes de tab bar flotante: `xxxl` (48pt)

### §2.2 Tipografía

Sistema basado en SF Pro (sans para body, UI) + New York (serif para títulos importantes). Todos respetan Dynamic Type.

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

    // === Caption === (metadata, timestamps, secondary info)
    static let ruulCaption = Font.system(.subheadline, design: .default, weight: .regular)
    static let ruulCaptionEmphasis = Font.system(.subheadline, design: .default, weight: .medium)
    static let ruulCaptionSmall = Font.system(.footnote, design: .default, weight: .regular)

    // === Numeric === (siempre tabular para alineación vertical)
    static let ruulMoneyLarge = Font.system(.title, design: .default, weight: .semibold).monospacedDigit()
    static let ruulMoneyMedium = Font.system(.title3, design: .default, weight: .semibold).monospacedDigit()
    static let ruulMoneySmall = Font.system(.body, design: .default, weight: .semibold).monospacedDigit()

    // === Label === (botones, tab bar, etiquetas estructurales)
    static let ruulLabel = Font.system(.subheadline, design: .default, weight: .medium)
    static let ruulLabelSmall = Font.system(.caption, design: .default, weight: .medium)

    // === Microcopy === (legales, timestamps muy pequeños)
    static let ruulMicro = Font.system(.caption2, design: .default, weight: .regular)
}
```

**Reglas de aplicación**:

- Hero de pantalla: `ruulDisplayMedium` o `ruulDisplayLarge`
- Título de card: `ruulTitleSmall` o `ruulTitleMedium`
- Body de contenido: `ruulBody`
- Metadata (fecha, ubicación): `ruulCaption`
- Section header (en uppercase con tracking): `ruulCaptionEmphasis`
- Cualquier monto en pesos: `ruulMoney*` (siempre tabular)
- Labels de tab bar: `ruulLabelSmall`

**NO usar**: `.font(.title)` directo. Siempre via tokens.

### §2.3 Color

Sistema semántico, todo via Asset Catalog para soporte automático light/dark/accessibility.

```swift
public extension Color {
    // === Backgrounds === (jerarquía de superficies)
    static let ruulBackground = Color(.systemGroupedBackground)
    static let ruulSurface = Color(.secondarySystemGroupedBackground)
    static let ruulSurfaceElevated = Color(.tertiarySystemGroupedBackground)

    // === Text === (jerarquía de contenido)
    static let ruulTextPrimary = Color(.label)
    static let ruulTextSecondary = Color(.secondaryLabel)
    static let ruulTextTertiary = Color(.tertiaryLabel)
    static let ruulTextQuaternary = Color(.quaternaryLabel)

    // === Brand === (definir en Assets.xcassets)
    static let ruulAccent = Color("AccentColor")          // azul-teal serio (#1B4D7A range)
    static let ruulAccentMuted = Color("AccentColorMuted") // tinte light del accent

    // === Semantic === (significado funcional, no decorativo)
    static let ruulPositive = Color(.systemGreen)         // confirmaciones, "going"
    static let ruulNegative = Color(.systemRed)           // multas, "not going", errores
    static let ruulWarning = Color(.systemOrange)         // pendientes, expiraciones próximas
    static let ruulInfo = Color(.systemBlue)              // info neutral
    static let ruulNeutral = Color(.systemGray)           // estados inactivos

    // === Borders & dividers ===
    static let ruulSeparator = Color(.separator)
    static let ruulSeparatorOpaque = Color(.opaqueSeparator)

    // === Semantic backgrounds === (tinted surfaces para estados)
    static let ruulPositiveBackground = Color.ruulPositive.opacity(0.12)
    static let ruulNegativeBackground = Color.ruulNegative.opacity(0.12)
    static let ruulWarningBackground = Color.ruulWarning.opacity(0.12)
    static let ruulInfoBackground = Color.ruulInfo.opacity(0.12)
}
```

**Reglas de aplicación**:

- Background de pantalla: `ruulBackground`
- Superficie de card: `ruulSurface`
- Card elevada (sheets, popovers): `ruulSurfaceElevated`
- Texto principal: `ruulTextPrimary`
- Metadata: `ruulTextSecondary`
- Disabled state: `ruulTextTertiary`
- CTA primario: background `ruulAccent`, foreground white
- Multa o error: `ruulNegative` con `ruulNegativeBackground`
- Confirmación exitosa: `ruulPositive`

**Asset Catalog setup requerido**:

```
Assets.xcassets/
├── AccentColor.colorset/
│   ├── Any (light): #1B4D7A (azul-teal serio)
│   └── Dark: #4A8FBF (versión más legible en dark)
└── AccentColorMuted.colorset/
    ├── Any: #1B4D7A @ 12% opacity sobre background
    └── Dark: #4A8FBF @ 16% opacity
```

**REGLA CRÍTICA**: nunca colores hardcoded fuera de Assets. `Color(red: ..., green: ..., blue: ...)` en código de View es prohibido.

### §2.4 Geometría

```swift
public enum RuulRadius {
    public static let small: CGFloat = 8       // chips, badges pequeños
    public static let medium: CGFloat = 12     // botones, inputs
    public static let large: CGFloat = 16      // cards normales
    public static let extraLarge: CGFloat = 20 // cards hero, modals
    public static let pill: CGFloat = 999      // capsules
}

public enum RuulBorder {
    public static let thin: CGFloat = 0.5      // separators sutiles
    public static let regular: CGFloat = 1.0   // borders de cards
    public static let thick: CGFloat = 2.0     // selección, focus
}
```

**Reglas de aplicación**:

- Cards: `RuulRadius.large` (16pt)
- Botones: `RuulRadius.medium` (12pt)
- Pills (back button, action groups): `RuulRadius.pill`
- Sheets y modals: `RuulRadius.extraLarge` (20pt) — Apple los usa así por default
- Avatars: `Circle()` (no radius)

### §2.5 Sombras

ruul usa sombras MUY sutiles. Si la sombra es visible obvia, está mal.

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

**Reglas**:

- Cards normales: `ruulShadowSubtle` o sin sombra (con border)
- Sheets flotantes: `ruulShadowMedium`
- Modales overlay: `ruulShadowElevated`
- Botones: sin sombra
- Tab bar flotante: sin sombra (Liquid Glass hace el trabajo)

### §2.6 Animación

```swift
public extension Animation {
    // === Para feedback de tap ===
    static let ruulTap = Animation.spring(response: 0.3, dampingFraction: 0.7)

    // === Para transiciones de estado (RSVP cambia, etc) ===
    static let ruulStateChange = Animation.smooth(duration: 0.3)

    // === Para aparición de elementos ===
    static let ruulAppear = Animation.smooth(duration: 0.4)

    // === Para feedback emocional positivo (confirmación) ===
    static let ruulSuccess = Animation.spring(response: 0.4, dampingFraction: 0.6)

    // === Para movimientos sutiles continuos (pull to refresh) ===
    static let ruulSubtle = Animation.easeInOut(duration: 0.2)
}
```

**Reglas**:

- Duración máxima: 0.5s (más se siente lento)
- Spring para feedback humano (tap, success)
- Smooth para transitions de sistema (cambio de pantalla, expand)
- EaseInOut para micro-animaciones (loading dots, etc)

**NO usar**: animaciones decorativas, bouncy exagerado, particles, confetti, shake, pulse continuo.

### §2.7 Haptics

```swift
public enum RuulHaptic {
    case lightTap      // tap en card importante, navegación
    case mediumTap     // selección de opción, toggle
    case success       // confirmación exitosa (RSVP, voto, multa apelada)
    case warning       // alerta de atención requerida
    case error         // acción falló

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
        }
    }
}
```

**Reglas críticas**:

- Haptic SOLO en acciones que el usuario inicia conscientemente
- NO haptic en cada scroll, cada appear, cada animación pasiva
- Success haptic: solo cuando algo importante se confirmó (no en cada tap)
- Error haptic: solo en errores reales del usuario (no en errores de red)

---

## §3 Componentes core

### §3.1 Componentes ya existentes (Sprint 0)

Tu reviewer ya construyó estos. Documentamos su API esperada:

- `TemplatePickerCard` — selección de template en onboarding
- `ActionCard` — item del Inbox con priority + action
- `ResourceTabBar` — tab bar de filtros dentro de un resource
- `RuulMetricCard` — número grande con label y trend
- `RuulTimelineItem` — item de history timeline

Si la implementación actual de estos diverge de lo descrito abajo, abrir issue para alinear.

### §3.2 RuulCard — container base

Container universal para cualquier item con datos.

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

**Uso**:

```swift
RuulCard {
    VStack(alignment: .leading, spacing: 8) {
        Text("Próxima cena").font(.ruulCaption).foregroundStyle(.secondary)
        Text("Martes 14, 8:00 pm").font(.ruulTitleSmall)
    }
}
```

**Variantes**:

- `RuulCard.elevated()` — con `ruulShadowSubtle()`
- `RuulCard.bordered()` — con border de `ruulSeparator` opacity 0.5

### §3.3 RuulPillButton — back button + acciones de header

```swift
public struct RuulPillButton: View {
    let symbol: String
    let action: () -> Void
    var size: Size = .regular

    public enum Size {
        case small  // 32x32
        case regular // 40x40
        case large   // 48x48

        var dimension: CGFloat {
            switch self {
            case .small: 32
            case .regular: 40
            case .large: 48
            }
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

**Uso típico**:

```swift
HStack {
    RuulPillButton(symbol: "chevron.left") { dismiss() }
    Spacer()
    RuulHeaderActions {
        RuulPillButton(symbol: "magnifyingglass") { showSearch() }
        RuulPillButton(symbol: "ellipsis") { showMore() }
    }
}
```

### §3.4 RuulHeaderActions — grupo de acciones en pill compartida

Cuando hay 2+ acciones en header, agruparlas en una sola pill.

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

### §3.5 RuulButton — botón estándar con variantes

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
        case primary    // accent background, white text
        case secondary  // surface background, primary text
        case tertiary   // transparent, accent text
        case glass      // material background, primary text (para sobre cover images)
    }

    public enum Size {
        case small      // 32 height, ruulCaptionEmphasis
        case regular    // 44 height, ruulLabel
        case large      // 56 height, ruulBody emphasis
    }

    public var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foregroundColor)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: iconSize, weight: .medium))
                }
                Text(title)
                    .font(labelFont)
            }
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(height: size.height)
            .background(backgroundView)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.medium))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    // Implementation details: foregroundColor, backgroundView, etc.
    // (omitido por brevedad — se construye en RuulButton.swift completo)
}
```

**Uso**:

```swift
// CTA primario en sheet
RuulButton("Confirmar asistencia", action: confirm)

// Acción secundaria
RuulButton("Cancelar", style: .secondary, action: cancel)

// Acción destructiva
RuulButton("Eliminar regla", style: .secondary, action: delete, isDestructive: true)

// Botón sobre cover image
RuulButton("Inscribirse", style: .glass, action: subscribe)

// Con icono
RuulButton("Crear evento", icon: "plus", action: create)
```

### §3.6 RuulTabBar — tab bar flotante con Liquid Glass

Componente principal de navegación. Reemplaza `TabView` default.

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
            Capsule()
                .fill(.regularMaterial)
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
                Image(systemName: tab.symbol)
                    .font(.system(size: 20, weight: .regular))
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
}
```

**Uso en MainTabView**:

```swift
enum MainTab: String, RuulTabItem {
    case home, inbox, history, settings

    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: "Inicio"
        case .inbox: "Pendientes"
        case .history: "Historial"
        case .settings: "Ajustes"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .inbox: "tray"
        case .history: "clock.arrow.circlepath"
        case .settings: "gear"
        }
    }
}

struct MainTabView: View {
    @State private var selected: MainTab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            // Content por tab
            switch selected {
            case .home: HomeView()
            case .inbox: InboxView()
            case .history: HistoryView()
            case .settings: SettingsView()
            }

            RuulTabBar(selected: $selected, tabs: MainTab.allCases)
        }
    }
}
```

**Notas**:

- La tab bar NO usa `TabView` de SwiftUI porque queremos control total del visual
- El contenido debajo no necesita padding bottom — la tab bar flota encima con margen
- Cada pantalla principal debe asegurar `safeAreaInset` o padding inferior de ~80pt para que el último item no quede oculto

### §3.7 RuulSectionHeader — headers de sección en listas

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

**Uso**:

```swift
RuulSectionHeader(title: "Hoy", subtitle: "martes")
RuulSectionHeader(title: "Multas pendientes")
```

### §3.8 RuulMoneyView — montos consistentes

Cualquier display de dinero usa este componente. Asegura tabular numbers, formato consistente, accesibilidad.

```swift
public struct RuulMoneyView: View {
    let amount: Decimal
    let currency: String  // "MXN", "USD", etc
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

    private var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        let prefix = showSign && amount > 0 ? "+" : ""
        return prefix + (formatter.string(from: amount as NSNumber) ?? "")
    }

    private var accessibleLabel: String {
        // "250 pesos" en vez de "$250" para VoiceOver
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "es_MX")
        return (formatter.string(from: amount as NSNumber) ?? "") + " \(currency)"
    }
}
```

### §3.9 RuulAvatarView — avatares consistentes

```swift
public struct RuulAvatarView: View {
    let initials: String
    let imageURL: URL?
    var size: Size = .medium
    var color: Color = .ruulAccent

    public enum Size {
        case xs, sm, md, lg, xl

        var dimension: CGFloat {
            switch self {
            case .xs: 24
            case .sm: 32
            case .md: 40
            case .lg: 56
            case .xl: 80
            }
        }

        var font: Font {
            switch self {
            case .xs: .ruulMicro
            case .sm: .ruulCaptionSmall
            case .md: .ruulCaption
            case .lg: .ruulBodyEmphasis
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

### §3.10 RuulBadge — pequeñas etiquetas de estado

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

**Uso**:

```swift
RuulBadge(text: "Pendiente", style: .warning, icon: "clock")
RuulBadge(text: "Confirmado", style: .positive, icon: "checkmark")
RuulBadge(text: "Multa", style: .negative)
```

### §3.11 RuulEmptyState — estados vacíos

Cualquier lista o pantalla con contenido vacío usa este componente.

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

**Empty states canónicos por contexto**:

```swift
// Inbox vacío
RuulEmptyState(
    symbol: "checkmark.circle",
    title: "Todo al día",
    message: "No hay acciones pendientes en tu grupo."
)

// Sin eventos
RuulEmptyState(
    symbol: "calendar",
    title: "Sin próximos eventos",
    message: "Crea el primer evento del grupo.",
    action: .init(label: "Crear evento", handler: { ... })
)

// Sin multas
RuulEmptyState(
    symbol: "checkmark.shield",
    title: "Sin multas",
    message: "Tu grupo está al corriente."
)

// Sin votaciones
RuulEmptyState(
    symbol: "checkmark.bubble",
    title: "Sin votos abiertos",
    message: "Tu grupo no tiene decisiones pendientes."
)

// Sin historial
RuulEmptyState(
    symbol: "clock.arrow.circlepath",
    title: "Sin historial todavía",
    message: "El historial del grupo aparecerá aquí cuando ocurran eventos."
)
```

### §3.12 RuulErrorState — estados de error

```swift
public struct RuulErrorState: View {
    let title: String
    let message: String
    var retryAction: (() -> Void)? = nil

    public var body: some View {
        VStack(spacing: RuulSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.ruulWarning)

            Text(title)
                .font(.ruulTitleMedium)

            Text(message)
                .font(.ruulBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            if let retryAction {
                RuulButton("Reintentar", style: .secondary, action: retryAction)
                    .frame(maxWidth: 200)
            }
        }
        .padding(RuulSpacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**Variants comunes**:

```swift
// Sin conexión
RuulErrorState(
    title: "Sin conexión",
    message: "Verifica tu conexión a internet e intenta de nuevo.",
    retryAction: refresh
)

// Error de servidor
RuulErrorState(
    title: "Algo salió mal",
    message: "No pudimos cargar la información. Intenta de nuevo en un momento.",
    retryAction: refresh
)

// Sin permisos
RuulErrorState(
    title: "Sin permiso",
    message: "No tienes permiso para realizar esta acción. Contacta al fundador del grupo."
)
```

### §3.13 RuulLoadingState — estados de carga

```swift
public struct RuulLoadingState: View {
    var message: String? = nil

    public var body: some View {
        VStack(spacing: RuulSpacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(.ruulAccent)

            if let message {
                Text(message)
                    .font(.ruulCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**Reglas**:

- Para cargas <1 segundo: NO mostrar loading state, solo dejar pantalla en blanco brevemente
- Para cargas 1-3 segundos: ProgressView sin mensaje
- Para cargas >3 segundos: ProgressView con mensaje informativo
- Para refresh de lista existente: usar `.refreshable` standard, no overlay

### §3.14 RuulInlineMessage — mensajes contextuales

Para alertas o información dentro del flujo, no como sheet ni como toast.

```swift
public struct RuulInlineMessage: View {
    let text: String
    var style: Style = .info
    var icon: String? = nil
    var action: ActionConfig? = nil

    public enum Style {
        case info, success, warning, error

        var background: Color {
            switch self {
            case .info: .ruulInfoBackground
            case .success: .ruulPositiveBackground
            case .warning: .ruulWarningBackground
            case .error: .ruulNegativeBackground
            }
        }

        var foreground: Color {
            switch self {
            case .info: .ruulInfo
            case .success: .ruulPositive
            case .warning: .ruulWarning
            case .error: .ruulNegative
            }
        }

        var defaultIcon: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    public struct ActionConfig {
        let label: String
        let handler: () -> Void
    }

    public var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: icon ?? style.defaultIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(style.foreground)

            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.ruulCaption)
                    .foregroundStyle(.primary)

                if let action {
                    Button(action.label, action: action.handler)
                        .font(.ruulCaptionEmphasis)
                        .foregroundStyle(style.foreground)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.medium))
    }
}
```

---

## §4 Patterns de UX

### §4.1 RSVP states (5 estados)

Decisión locked: 5 estados de RSVP. Visual consistente:

| Estado | Color | Icon | Copy |
|---|---|---|---|
| pending | ruulNeutral | "questionmark.circle" | "Sin responder" |
| going | ruulPositive | "checkmark.circle.fill" | "Voy" |
| maybe | ruulInfo | "questionmark.diamond.fill" | "Tal vez" |
| declined | ruulTextSecondary | "xmark.circle" | "No voy" |
| waitlisted | ruulWarning | "clock.fill" | "Lista de espera" |

Cualquier vista que muestre RSVP usa estos mismos colors + icons + copy.

### §4.2 Vote states

| Estado | Color | Icon | Copy |
|---|---|---|---|
| open | ruulInfo | "circle.dashed" | "Abierto" |
| closing_soon | ruulWarning | "clock.badge.exclamationmark" | "Cierra pronto" |
| resolved_passed | ruulPositive | "checkmark.circle.fill" | "Aprobado" |
| resolved_rejected | ruulNegative | "xmark.circle.fill" | "Rechazado" |
| expired | ruulTextSecondary | "clock.badge.xmark" | "Expirado" |

### §4.3 Fine states

| Estado | Color | Icon | Copy |
|---|---|---|---|
| proposed | ruulWarning | "clock.fill" | "Propuesta" |
| confirmed | ruulNegative | "exclamationmark.circle" | "Confirmada" |
| paid | ruulPositive | "checkmark.circle.fill" | "Pagada" |
| appealed | ruulInfo | "questionmark.bubble" | "En apelación" |
| forgiven | ruulTextSecondary | "checkmark.circle" | "Perdonada" |

### §4.4 Member states

| Estado | Color | Icon |
|---|---|---|
| active | ruulPositive | "person.fill.checkmark" |
| invited | ruulInfo | "person.badge.clock" |
| suspended | ruulWarning | "person.fill.xmark" |
| removed | ruulTextTertiary | "person.fill.xmark" |

---

## §5 Layout patterns

### §5.1 Estructura de pantalla principal (con tab bar flotante)

```swift
struct MainScreenLayout: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color.ruulBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header (puede ser sticky o scroll-away)
                screenHeader

                // Contenido principal
                ScrollView {
                    VStack(spacing: RuulSpacing.sectionGap) {
                        // Secciones aquí
                    }
                    .padding(.vertical, RuulSpacing.lg)
                    .padding(.bottom, 80) // espacio para tab bar
                }
            }
        }
    }
}
```

### §5.2 Estructura de detail view

```swift
struct DetailScreenLayout: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color.ruulBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header con back button
                detailHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: RuulSpacing.sectionGap) {
                        // Hero (datos principales del item)
                        heroSection

                        // Acción primaria (si aplica)
                        primaryActionSection

                        // Metadata secundaria
                        metadataSection

                        // Timeline o sub-content
                        timelineSection
                    }
                    .padding(.horizontal, RuulSpacing.screenPadding)
                    .padding(.vertical, RuulSpacing.lg)
                }
            }
        }
        .navigationBarHidden(true) // usamos custom header
    }
}
```

### §5.3 Estructura de sheet de creación

```swift
struct CreationSheet: View {
    var body: some View {
        NavigationStack {
            Form {
                Section { /* campos */ }
                Section { /* más campos */ }
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

### §5.4 Lista con secciones por día

```swift
struct DateSectionedList<Content: View>: View {
    let sections: [(date: DayHeader, items: [Item])]
    let row: (Item) -> Content

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
                                row(item)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, RuulSpacing.lg)
            .padding(.bottom, 80)
        }
    }
}
```

---

## §6 Catálogo de pantallas (Fase 1 V1)

Todas las pantallas que existen al cierre de F0. Documentadas como referencias canónicas.

### §6.1 Onboarding flow

- **WelcomeView** — splash con CTA "Empezar"
- **AuthView** — verificación de número (WhatsApp OTP)
- **TemplateSelectorView** — elegir template (Cena recurrente, etc)
- **CreateGroupSheet** — datos básicos del grupo
- **InviteMembersSheet** — invitar primeros miembros
- **GroupReadyView** — confirmación de grupo creado

**Pattern común**: cada paso es 1 pantalla con 1 acción primaria. NO progressdisclosure complejo. NO onboarding marketing-style con illustrations.

### §6.2 Main tabs

**Tab 1 — Inicio**:
- `HomeView` — overview del grupo
  - Hero: próximo evento
  - Section: acciones pendientes (preview, link a Inbox)
  - Section: actividad reciente (preview, link a Historial)

**Tab 2 — Pendientes (Inbox)**:
- `ActionInboxView` — lista de UserActions
  - Sectioned por priority (urgent first)
  - Tap → respective detail view

**Tab 3 — Historial**:
- `HistoryView` — timeline de SystemEvents
  - Sectioned por día
  - Filtrable por tipo (RSVP, multa, voto, etc)

**Tab 4 — Ajustes**:
- `SettingsView` — configuración
  - Sub: GroupSettingsView, RulesView, MembersView, ProfileView

### §6.3 Detail views

- `EventDetailView` — detalle de cena con RSVP, lista de going, host info
- `FineDetailView` — detalle de multa con razón, monto, opción apelar
- `VoteDetailView` — router a body por voteType
  - `FineAppealVoteBody`
  - `GeneralProposalVoteBody`
  - `RuleChangeVoteBody`
  - `GenericVoteBody`
- `RuleDetailView` — detalle de regla del grupo
- `MemberDetailView` — perfil de miembro con stats

### §6.4 Sheets de acción

- `RSVPSheet` — confirmar/cancelar asistencia
- `AppealFineSheet` — apelar multa
- `VoteOnAppealSheet` — votar en apelación
- `CreateGeneralProposalSheet` — proponer al grupo
- `CreateRuleChangeSheet` — proponer cambio de regla
- `EditRuleSheet` — editar regla (founder only)
- `EditMembersSheet` — gestionar miembros

---

## §7 Layouts adaptativos

### §7.1 iPhone (target principal V1)

Todas las pantallas se diseñan primero para iPhone 15 (393 width). Verificar también:
- iPhone SE (375 width) — minimum support
- iPhone 16 Pro Max (430 width) — máximo

**Reglas**:
- Touch targets mínimos 44x44pt
- Contenido nunca extiende a bordes (mínimo 16pt padding lateral)
- Tab bar flotante respeta safe area inferior
- Headers respetan safe area superior

### §7.2 iPad y macOS (V2+)

V1 NO optimiza para iPad/Mac. La app funciona pero no se optimiza visualmente. Cuando se haga en V2+:
- iPad: split view con sidebar para nav
- Mac: window resizable, sidebar persistente

### §7.3 Dynamic Type

Toda la tipografía usa `.system(.style)` que respeta Dynamic Type. Casos especiales:
- Números monetarios: respetan Dynamic Type pero mantienen tabular
- Tab bar labels: NO escalan más allá de XL para no romper layout

Test obligatorio: cada pantalla debe verificarse en Dynamic Type AX5 (más grande). Si rompe, se ajusta layout.

### §7.4 Light vs Dark

Todo el sistema funciona en ambos modos via Asset Catalog y `.systemColors`.

**Reglas para dark mode**:
- Fondos NUNCA son negro puro (#000) — usar `systemGroupedBackground` que es near-black
- Surfaces tienen mayor contraste con fondo en dark que en light
- Liquid Glass se ajusta automáticamente
- Accent color tiene variant más legible para dark

---

## §8 Iconografía

### §8.1 Sistema de iconos

**SF Symbols only** para toda iconografía estructural. Ningún custom icon en V1.

Pesos preferidos: `.regular` para iconos en context, `.medium` para acciones primarias, `.semibold` solo en badges pequeños.

### §8.2 Iconos canónicos por concepto

| Concepto | SF Symbol |
|---|---|
| Inicio/home | `house` |
| Inbox/pendientes | `tray` |
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
| Persona | `person.fill` |
| Grupo | `person.3.fill` |
| Evento/cena | `fork.knife` o `calendar` |
| Multa | `exclamationmark.circle` |
| Dinero | `dollarsign.circle` |
| Voto | `checkmark.bubble` |
| Regla | `doc.text` |
| Tiempo | `clock` |
| Ubicación | `mappin.and.ellipse` |
| Anfitrión | `crown.fill` |

**Regla**: si necesitás un concepto nuevo, buscá primero en SF Symbols (5000+ disponibles). Solo si no existe, considerá custom — y eso requiere update de este doc.

---

## §9 Accesibilidad

### §9.1 Mínimos no negociables

Cualquier pantalla que no cumpla estos mínimos es feature roto:

1. **VoiceOver completo**: todo elemento interactivo tiene label, hint cuando aplica, traits correctos
2. **Dynamic Type**: layout funciona en AX5
3. **Reduce Motion**: animaciones se reducen cuando el usuario lo activa en Settings
4. **Contraste WCAG AA**: 4.5:1 mínimo para texto normal, 3:1 para texto grande
5. **Touch targets**: 44x44pt mínimo

### §9.2 Patterns de accesibilidad

```swift
// Cards complejos: combinar children
ActionCard(...)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(subtitle), \(priority)")
    .accessibilityHint("Toca para ver detalles")
    .accessibilityAddTraits(.isButton)

// Imágenes decorativas
Image(systemName: "calendar")
    .accessibilityHidden(true)

// Imágenes informativas
RuulAvatarView(...)
    .accessibilityLabel("Foto de \(memberName)")

// Money con lectura humana
RuulMoneyView(amount: 250, currency: "MXN")
// label automático: "250 pesos"

// Estados visuales que dependen de color
RuulBadge(text: "Pendiente", style: .warning)
    .accessibilityLabel("Pendiente, requiere atención")
```

### §9.3 Reduce Motion

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

withAnimation(reduceMotion ? .none : .ruulStateChange) {
    // cambio de estado
}
```

---

## §10 Reglas de evolución del Design System

### §10.1 Cuándo agregar componente nuevo

Agregar componente nuevo cuando:

1. **Mismo pattern aparece 3+ veces** en pantallas distintas
2. **No existe variante razonable** de componente existente que cubra el caso
3. **Es semánticamente distinto** (no solo visualmente)

**NO agregar componente** cuando:
- Solo difiere en padding, color, font de uno existente (usá variantes)
- Es one-off de una sola pantalla (mantenelo local)
- Es experimento (probalo local primero, evaluá en review)

### §10.2 Cuándo modificar componente existente

**Cambios menores** (compatible, no breaking):
- Agregar variante nueva (ej: `.glass` style en RuulButton)
- Agregar prop opcional con default
- Agregar size nuevo

**Cambios mayores** (breaking):
- Cambiar API public
- Cambiar comportamiento default
- Eliminar variante o prop

Cualquier cambio mayor requiere:
1. Issue documentando motivo
2. Migration guide en este doc
3. Update de todos los call sites en el mismo PR

### §10.3 Evolución por fase

**Fase 1 (V1, actual)**:
- Componentes core de §3
- Patterns de §5 y §6
- iconografía SF Symbols

**Fase 2 (Rotation universal)**: agregar
- `RuulRotationView` — visualización de orden actual y próximos turnos
- `RuulPositionBadge` — posición en rotación
- patterns de "perdiste tu turno" / "tu turno se acerca"

**Fase 3 (Slot + Asset)**: agregar
- `RuulSlotCard` — slot asignable con CTA accept/decline
- `RuulAssetView` — vista del asset compartido con calendar
- patterns de cascada de asignación

**Fase 4 (Fund + Contribution + Cycle)**: agregar
- `RuulFundBalanceCard` — saldo del fondo con trend
- `RuulContributionRow` — aporte esperado/realizado
- `RuulCyclePhase` — indicador de fase actual del ciclo
- patterns de settle up

**Fase 5 (Proposal + Comment + Roles)**: agregar
- `RuulProposalCard` — propuesta con lifecycle
- `RuulCommentThread` — discusión asociada a un objeto
- `RuulRoleBadge` — rol de miembro en contexto
- patterns de governance profunda

**Fase 6 (Editor custom + Commitment)**: agregar
- `RuulRuleBuilder` — editor visual de reglas
- `RuulConditionRow`, `RuulConsequenceCard`, `RuulFlowConnector`
- `RuulCommitmentCard` — promesa con auto-reporte

### §10.4 Versionado del DS

Este documento tiene version semver implícito:
- **Major** (X.0.0): cambios breaking en componentes core
- **Minor** (1.X.0): nuevos componentes, fases nuevas
- **Patch** (1.1.X): clarificaciones, ejemplos, fixes

Estado actual: **DS v1.0.0** (release inicial al cierre de F0).

---

## §11 Review checklist

Cuando se haga code review de UI, verificar:

### §11.1 Tokens

- [ ] Spacing usa `RuulSpacing.*`, no valores hardcoded
- [ ] Tipografía usa `Font.ruul*`, no `.title`/`.body` directos
- [ ] Colores usan `Color.ruul*`, no `Color(red:green:blue:)`
- [ ] Corner radius usa `RuulRadius.*`
- [ ] Animaciones usan `Animation.ruul*`

### §11.2 Componentes

- [ ] Reutiliza componentes existentes en lugar de inline custom
- [ ] Componentes nuevos justificados según §10.1
- [ ] Props opcionales con defaults razonables
- [ ] Accessibility labels presentes

### §11.3 Patterns

- [ ] Estructura de pantalla sigue §5 patterns
- [ ] Empty/error/loading states explícitos
- [ ] Tap feedback (haptic donde corresponde)
- [ ] Dynamic Type funciona en AX5

### §11.4 Copy

- [ ] Tono descriptivo, no acusatorio
- [ ] Sin emojis estructurales
- [ ] Sin exclamaciones excepto confirmaciones críticas
- [ ] Concreto, no aspiracional

### §11.5 Performance

- [ ] LazyVStack/LazyHStack para listas largas
- [ ] AsyncImage con placeholder y caching
- [ ] No re-renders innecesarios (verificar @Observable scope)

---

## §12 Anti-patterns explícitos

Cosas que en algún momento alguien va a querer hacer y NO debe hacerse:

**❌ Gradientes decorativos en backgrounds o cards**
→ ruul es Wallet, no Stripe.

**❌ Cover images coloridas grandes en cada item de lista**
→ Eso es Luma. Ruul usa SF Symbols o avatares chicos.

**❌ Animaciones de bounce/elastic exageradas**
→ Spring sutil sí. Bounce dramático no.

**❌ Modo dark forzado siempre**
→ Respetar preferencia del sistema.

**❌ Skeleton screens animados**
→ ProgressView simple en V1. Skeleton es refinement de F5+.

**❌ Toasts/snackbars por cada acción**
→ Solo para confirmaciones críticas. Usar inline state changes para resto.

**❌ Onboarding de 5 pantallas con illustrations**
→ Onboarding ruul es funcional, máximo 3 pantallas.

**❌ Iconos custom mediocres**
→ SF Symbols hasta que tengamos illustrator senior dedicado.

**❌ Fonts custom (Tiempos, GT Sectra, etc)**
→ SF Pro + New York que vienen con iOS son excelentes.

**❌ Negro puro #000 como background**
→ `systemGroupedBackground` que es near-black y consistente.

**❌ TabView default de SwiftUI**
→ `RuulTabBar` flotante con Liquid Glass.

**❌ NavigationView (deprecated)**
→ `NavigationStack` con value-typed paths.

**❌ Combine para nuevos features**
→ async/await + @Observable.

**❌ UIKit en código nuevo**
→ SwiftUI puro. Solo legacy puede tener UIKit, y se migra cuando se toca.

**❌ Hardcoded strings en UI**
→ Localizable strings desde el día 1, aunque V1 sea solo español.

**❌ Hex colors en código**
→ Asset Catalog only.

---

## §13 Filosofía de excepciones

Este documento es autoritativo, pero no infalible. Habrá casos donde la regla correcta sea romperse.

**Cuándo es válido desviarse**:

1. La regla del DS produce resultado peor que ignorarla en este caso específico
2. El caso es genuinamente nuevo y el DS aún no lo cubre
3. Hay restricción técnica (rendimiento, accessibility, hardware) que fuerza alternativa

**Cuándo NO es válido desviarse**:

1. "Me parece más bonito hacerlo distinto"
2. "Es más rápido de implementar"
3. "Otros productos lo hacen así"

**Si te desviás**:

1. Documentá en el código por qué
2. Abrí issue para evaluar update del DS
3. Si la desviación gana, actualizá este doc en el mismo PR

---

## §14 Apéndice: ejemplos completos de pantalla

### §14.1 HomeView completa

```swift
struct HomeView: View {
    @State var coordinator = HomeCoordinator(
        eventRepo: .live,
        actionRepo: .live
    )

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

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: RuulSpacing.sectionGap) {
                        // Hero: próximo evento
                        if let nextEvent = coordinator.nextEvent {
                            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                                Text("PRÓXIMA CENA")
                                    .font(.ruulCaptionEmphasis)
                                    .foregroundStyle(.secondary)
                                    .tracking(0.5)
                                    .padding(.horizontal, RuulSpacing.screenPadding)

                                EventHeroCard(event: nextEvent)
                                    .padding(.horizontal, RuulSpacing.screenPadding)
                            }
                        } else {
                            RuulEmptyState(
                                symbol: "calendar",
                                title: "Sin próximos eventos",
                                message: "Crea el primer evento del grupo.",
                                action: .init(
                                    label: "Crear evento",
                                    handler: coordinator.createEvent
                                )
                            )
                        }

                        // Acciones pendientes preview
                        if !coordinator.pendingActions.isEmpty {
                            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                                RuulSectionHeader(title: "Pendientes para vos")

                                VStack(spacing: RuulSpacing.itemGap) {
                                    ForEach(coordinator.pendingActions.prefix(3)) { action in
                                        ActionCard(
                                            title: action.title,
                                            subtitle: action.subtitle,
                                            priority: action.priority,
                                            action: { coordinator.openAction(action) }
                                        )
                                        .padding(.horizontal, RuulSpacing.screenPadding)
                                    }

                                    if coordinator.pendingActions.count > 3 {
                                        Button("Ver todas (\(coordinator.pendingActions.count))") {
                                            coordinator.openInbox()
                                        }
                                        .font(.ruulCaptionEmphasis)
                                        .foregroundStyle(.ruulAccent)
                                        .padding(.horizontal, RuulSpacing.screenPadding)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, RuulSpacing.lg)
                    .padding(.bottom, 80) // espacio para tab bar
                }
                .refreshable {
                    await coordinator.refresh()
                }
            }
        }
        .task { await coordinator.load() }
    }
}
```

### §14.2 Detail view completa (FineDetailView)

```swift
struct FineDetailView: View {
    let fineId: FineID
    @State var coordinator: FineDetailCoordinator

    var body: some View {
        ZStack(alignment: .top) {
            Color.ruulBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Custom header
                HStack {
                    RuulPillButton(symbol: "chevron.left") {
                        coordinator.dismiss()
                    }
                    Spacer()
                }
                .padding(.horizontal, RuulSpacing.md)
                .padding(.top, RuulSpacing.md)

                ScrollView {
                    VStack(alignment: .leading, spacing: RuulSpacing.sectionGap) {
                        // Hero: monto + razón
                        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                            RuulBadge(text: "Multa", style: .negative)

                            RuulMoneyView(
                                amount: coordinator.fine.amount,
                                currency: "MXN",
                                size: .large,
                                color: .negative
                            )

                            Text(coordinator.fine.reason)
                                .font(.ruulTitleLarge)

                            Text(coordinator.fine.detailDescription)
                                .font(.ruulBody)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Action
                        if coordinator.canAppeal {
                            VStack(spacing: RuulSpacing.sm) {
                                RuulButton(
                                    "Apelar esta multa",
                                    style: .primary,
                                    action: coordinator.openAppeal
                                )

                                Text("Tu grupo votará si la apelación es justa")
                                    .font(.ruulCaption)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }

                        // Metadata
                        VStack(alignment: .leading, spacing: RuulSpacing.md) {
                            RuulSectionHeader(title: "Detalles")

                            RuulCard {
                                VStack(alignment: .leading, spacing: RuulSpacing.md) {
                                    metadataRow(label: "Aplicada", value: coordinator.fine.appliedAt.formatted())
                                    Divider()
                                    metadataRow(label: "Regla", value: coordinator.fine.ruleName)
                                    Divider()
                                    metadataRow(label: "Evento", value: coordinator.fine.eventName)
                                }
                            }
                        }

                        // Timeline
                        VStack(alignment: .leading, spacing: RuulSpacing.md) {
                            RuulSectionHeader(title: "Historia")

                            VStack(spacing: 0) {
                                ForEach(coordinator.timeline) { event in
                                    RuulTimelineItem(event: event)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, RuulSpacing.screenPadding)
                    .padding(.vertical, RuulSpacing.lg)
                    .padding(.bottom, 80)
                }
            }
        }
        .navigationBarHidden(true)
        .task { await coordinator.load() }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.ruulCaption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.ruulCaption)
        }
    }
}
```

---

## §15 Glosario

- **Token**: valor de design (color, spacing, font) referenciado por nombre en lugar de literal
- **Surface**: background level (background → surface → surfaceElevated en jerarquía)
- **Chrome**: UI infrastructure (toolbars, tab bar, sheets) — donde va Liquid Glass
- **Content**: contenido del usuario (cards, listas, detail) — surfaces sólidas
- **Pattern**: combinación canónica de componentes para resolver caso recurrente
- **Liquid Glass**: material translúcido de iOS 26 con blur dinámico que reacciona al contenido detrás

---

## Cómo este documento evoluciona

Cada cierre de fase mayor:

1. Lista los componentes nuevos shipped
2. Documenta nuevos patterns identificados
3. Lista anti-patterns descubiertos
4. Update §10.3 con próxima fase

Pull requests a este documento requieren review de founder + reviewer.

Versión actual: **v1.0.0** — DS inicial al cierre de Fase 1 (F0).
