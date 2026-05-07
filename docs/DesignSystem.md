# ruul Design System — v3.0

> **Documento autoritativo**. Cualquier pantalla, componente o pattern visual
> debe consultarse contra este doc primero. Desviaciones requieren justificación
> documentada y update de este doc.
>
> **Última actualización**: 2026-05-07
> **Versión**: 3.0.0
> **Stack**: Swift 6, SwiftUI puro estricto, iOS 26+, Liquid Glass nativo
> **Arquitectura**: 3 packages SPM (Core, UI, Features)
> **Mantenedor**: founder + reviewer
> **Status**: Authoritative — supersede v1.0 y v2.0

---

## Índice

- §0 — Cómo usar este documento
- §1 — Filosofía de diseño
- §2 — Arquitectura del proyecto
- §3 — Design tokens
- §4 — Multi-group context (estructural)
- §5 — Componentes core
- §6 — Layout patterns
- §7 — Catálogo de pantallas
- §8 — Adaptación responsiva
- §9 — Iconografía
- §10 — Accesibilidad
- §11 — SwiftUI best practices (iOS 26)
- §12 — Concurrencia (Swift 6)
- §13 — Liquid Glass (iOS 26)
- §14 — Reglas de evolución
- §15 — Review checklist
- §16 — Anti-patterns
- §17 — Testing visual
- §18 — Migration v2 → v3
- §19 — Changelog
- §20 — Glosario
- §21 — Apéndice: ejemplos completos

---

## §0 Cómo usar este documento

**Si vas a construir una pantalla nueva**:
1. Leé §1 (filosofía)
2. Decidí scope: cross-grupos (Home) o grupo-activo (otras tabs) — §4
3. Encontrá el layout pattern correspondiente — §6
4. Elegí componentes existentes — §5
5. Si necesitás componente nuevo, leé §14 (reglas de evolución)
6. Mirá pantallas similares — §7

**Si vas a construir un componente nuevo**:
1. Leé §1, §3 (tokens), §11 (SwiftUI best practices)
2. Justificá necesidad según §14
3. Implementá con preview + accessibility según §10
4. Agregá test visual según §17

**Si vas a hacer code review**:
1. Usá checklist de §15

**Si sos founder revisando dirección**:
1. Leé §1, §2, §4, §16

**Cuándo actualizar este doc**:
- Cierre de fase mayor (V1 → V2 → ...)
- Decisión arquitectónica nueva
- Componente nuevo agregado al sistema
- Anti-pattern descubierto

---

## §1 Filosofía de diseño

### §1.1 Identidad

ruul es **infraestructura de autogobierno para grupos**. La UI debe transmitir:

- **Autoridad amable**: serio sin ser frío
- **Predictibilidad**: el usuario siempre sabe qué pasa y por qué
- **Transparencia**: cada decisión tiene historial visible
- **Calma**: la app no compite por atención
- **Multi-group nativo**: ningún usuario tiene un solo grupo, nunca

### §1.2 Referencias visuales

**Sí se ve como**:
- Apple Wallet (autoridad amable, contenido focal)
- Apple Maps directions (jerarquía clara, información sin ruido)
- Apple Sports (switcher contextual, color ambient)
- Things 3 (tipografía elegante, espacios respirados)
- Reeder (combinación serif/sans bien hecha)

**No se ve como**:
- Notion / Linear (demasiado utilitario, sin personalidad)
- Headspace / Calm (demasiado emocional)
- Discord / Slack (demasiado social — aunque tomamos ideas de switcher)
- Splitwise / Venmo (demasiado transaccional)
- Luma (demasiado aspiracional)

### §1.3 Principios de copy

**Descriptivo, no acusatorio**:
- ❌ "Te multamos por llegar tarde"
- ✓ "Llegaste a las 9:35. Según la regla del grupo, eso aplica $250"

**Concreto, no aspiracional**:
- ❌ "¡Tu próxima cena épica te espera!"
- ✓ "Cena del martes 14 a las 20:00, casa de Daniel"

**Pasivo cuando es regla, activo cuando es acción humana**:
- "Se aplicó multa de $250" (sistema)
- "Daniel canceló su asistencia" (humano)

**Cero emojis en UI estructural**.
**Cero exclamaciones excepto confirmaciones críticas**.

### §1.4 Principios visuales

1. **Espacio respira**: usá todo el padding que parezca generoso, después agregá 4pt más
2. **Tipografía es jerarquía**: weights y sizes hacen el trabajo de bordes y colores en otras apps
3. **Color es semántico**: cada color tiene significado funcional, ninguno es decorativo
4. **Movimiento es feedback**: animaciones confirman acciones, nunca decoran
5. **Liquid Glass es chrome, no contenido**: glass para UI infrastructure (toolbars, tab bar, sheets), surfaces sólidas para contenido
6. **Tap targets generosos**: mínimo 44x44pt, target real (no solo icono)
7. **Multi-group es estructural**: cada item de Home muestra su grupo de origen

---

## §2 Arquitectura del proyecto

### §2.1 Estructura de packages (SPM)

```
ruul/
├── App/                        # Xcode app target
│   ├── ruulApp.swift          # @main entry point
│   ├── AppCoordinator.swift   # Top-level navigation
│   └── Resources/
│       ├── Assets.xcassets    # Colors, images
│       ├── Localizable.strings
│       └── Info.plist
│
├── Packages/
│   ├── RuulCore/              # Models, business logic, networking
│   │   ├── Sources/
│   │   │   ├── Models/        # Group, Member, Resource, etc
│   │   │   ├── Repositories/  # Supabase clients
│   │   │   ├── Services/      # Business logic
│   │   │   └── Extensions/
│   │   └── Tests/
│   │
│   ├── RuulUI/                # Design system + reusable components
│   │   ├── Sources/
│   │   │   ├── Tokens/        # Spacing, Typography, Color
│   │   │   ├── Components/    # All Ruul* views
│   │   │   ├── Modifiers/     # Reusable view modifiers
│   │   │   └── Previews/      # Catalog views for testing
│   │   └── Tests/
│   │
│   └── RuulFeatures/          # Feature modules
│       ├── Sources/
│       │   ├── Home/
│       │   ├── Group/
│       │   ├── History/
│       │   └── Settings/
│       └── Tests/
```

### §2.2 Dependencias

```swift
// Package.swift de RuulUI
dependencies: [],  // Cero deps externas — solo Foundation + SwiftUI

// Package.swift de RuulCore
dependencies: [
    .package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0"),
],

// Package.swift de RuulFeatures
dependencies: [
    .package(path: "../RuulCore"),
    .package(path: "../RuulUI"),
],
```

**Regla**: RuulUI no depende de nada externo. Si necesitás una lib, hacelo en RuulFeatures.

### §2.3 Reglas de organización

- **Un componente por archivo** en RuulUI/Components/
- **Una feature por carpeta** en RuulFeatures/
- **Models inmutables** (`struct` con propiedades `let`)
- **State mutable solo en `@Observable`** (no en views)
- **Views nunca contienen lógica de negocio** — siempre delegan a `@Observable` coordinator

### §2.4 Naming conventions

```swift
// Views: RuulXxx (UI components) o XxxView (feature screens)
RuulButton, RuulCard, RuulGroupAvatar  // Components in RuulUI
HomeView, GroupTabView                 // Screens in Features

// Coordinators: XxxCoordinator
@Observable
final class HomeCoordinator { ... }

// Tokens: RuulXxx enum o Color.ruulXxx static
RuulSpacing.md
Color.ruulBackground

// Repositories: XxxRepository
final class GroupRepository { ... }

// Errors: XxxError enum
enum GroupError: Error { ... }
```

---

## §3 Design tokens

### §3.1 Espaciado

Sistema de 4pt base.

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
    public static let tabBarBottomSafeArea: CGFloat = 100
}
```

**Regla**: nunca usar literales. Si necesitás 18pt, no es un valor del sistema, usá 16 o 20.

### §3.2 Tipografía

```swift
public extension Font {
    // === Display === (títulos principales de pantalla)
    static let ruulDisplayLarge = Font.system(
        .largeTitle, design: .serif, weight: .semibold
    )
    static let ruulDisplayMedium = Font.system(
        .title, design: .serif, weight: .semibold
    )

    // === Headings === (titulares de sección, cards)
    static let ruulTitleLarge = Font.system(
        .title2, design: .default, weight: .semibold
    )
    static let ruulTitleMedium = Font.system(
        .title3, design: .default, weight: .semibold
    )
    static let ruulTitleSmall = Font.system(
        .headline, design: .default, weight: .semibold
    )

    // === Body === (texto principal)
    static let ruulBody = Font.system(
        .body, design: .default, weight: .regular
    )
    static let ruulBodyEmphasis = Font.system(
        .body, design: .default, weight: .semibold
    )

    // === Caption === (metadata, timestamps)
    static let ruulCaption = Font.system(
        .subheadline, design: .default, weight: .regular
    )
    static let ruulCaptionEmphasis = Font.system(
        .subheadline, design: .default, weight: .medium
    )
    static let ruulCaptionSmall = Font.system(
        .footnote, design: .default, weight: .regular
    )

    // === Numeric === (siempre tabular)
    static let ruulMoneyLarge = Font.system(
        .title, design: .default, weight: .semibold
    ).monospacedDigit()
    static let ruulMoneyMedium = Font.system(
        .title3, design: .default, weight: .semibold
    ).monospacedDigit()
    static let ruulMoneySmall = Font.system(
        .body, design: .default, weight: .semibold
    ).monospacedDigit()

    // === Label === (botones, tab bar)
    static let ruulLabel = Font.system(
        .subheadline, design: .default, weight: .medium
    )
    static let ruulLabelSmall = Font.system(
        .caption, design: .default, weight: .medium
    )

    // === Microcopy === (legales, timestamps muy pequeños)
    static let ruulMicro = Font.system(
        .caption2, design: .default, weight: .regular
    )

    // === Group context === (nombre del grupo en items cross-grupos)
    static let ruulGroupLabel = Font.system(
        .caption, design: .default, weight: .medium
    )
}
```

**Reglas**:
- Display fonts solo para títulos de pantalla principales
- Money fonts siempre `.monospacedDigit()` para alineación tabular
- Toda tipografía respeta Dynamic Type automáticamente (system fonts)

### §3.3 Color base

```swift
public extension Color {
    // === Backgrounds (3 niveles) ===
    static let ruulBackground = Color(.systemGroupedBackground)
    static let ruulSurface = Color(.secondarySystemGroupedBackground)
    static let ruulSurfaceElevated = Color(.tertiarySystemGroupedBackground)

    // === Text (4 niveles) ===
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

**Regla**: nunca usar Color literals (#hex). Todo via Asset Catalog para soporte automático light/dark.

### §3.4 Group color ramps

Color del grupo asignado automáticamente según categoría de template.

```swift
public enum GroupCategory: String, CaseIterable, Sendable {
    case socialRecurring     // Cenas, clubes de lectura
    case sharedResource      // Palcos, cabañas, suscripciones
    case rotatingSavings     // Tandas, susu, hui
    case patrimonialFamily   // Consejos familiares, herencias
    case amateurTeam         // Bandas, equipos deportivos
    case groupTravel         // Squad trips, retreats
    case religiousCultural   // Comunidades religiosas
    case professionalInformal // Cooperativas, mastermind
    case digitalCommunity    // Servidores Discord
    case commitmentPact      // Pactos de fitness, hábitos

    public var ramp: GroupColorRamp {
        switch self {
        case .socialRecurring: .teal
        case .sharedResource: .blue
        case .rotatingSavings: .purple
        case .patrimonialFamily: .amber
        case .amateurTeam: .green
        case .groupTravel: .coral
        case .religiousCultural: .pink
        case .professionalInformal: .gray
        case .digitalCommunity: .blue
        case .commitmentPact: .green
        }
    }

    public var displayName: String {
        switch self {
        case .socialRecurring: "Encuentros sociales"
        case .sharedResource: "Recurso compartido"
        case .rotatingSavings: "Ahorro rotativo"
        case .patrimonialFamily: "Patrimonio familiar"
        case .amateurTeam: "Equipo amateur"
        case .groupTravel: "Viaje en grupo"
        case .religiousCultural: "Comunidad cultural"
        case .professionalInformal: "Cooperativa informal"
        case .digitalCommunity: "Comunidad digital"
        case .commitmentPact: "Pacto de compromiso"
        }
    }
}

public enum GroupColorRamp: String, Sendable {
    case teal, blue, purple, amber, green, coral, pink, gray

    /// Background del avatar (ramp/50)
    public var background: Color {
        Color("GroupRamp/\(rawValue)/50")
    }

    /// Foreground de iniciales (ramp/800)
    public var foreground: Color {
        Color("GroupRamp/\(rawValue)/800")
    }

    /// Accent del grupo, para borders y highlights (ramp/600)
    public var accent: Color {
        Color("GroupRamp/\(rawValue)/600")
    }

    /// Tint contextual sutil para backgrounds (ramp/50 con opacity)
    public var contextualTint: Color {
        background.opacity(0.4)
    }
}
```

**Asset Catalog setup requerido**:

```
Assets.xcassets/GroupRamp/
├── teal/
│   ├── 50.colorset    (light: #E1F5EE, dark: #0F2E26)
│   ├── 100.colorset   (light: #C7EBDF, dark: #14403A)
│   ├── 200.colorset   (light: #94D8C2, dark: #1B5550)
│   ├── 400.colorset   (light: #4FB39A, dark: #389082)
│   ├── 600.colorset   (light: #2A8C76, dark: #5BB5A0)
│   ├── 800.colorset   (light: #0F6E56, dark: #82D5BC)
│   └── 900.colorset   (light: #084833, dark: #B0EAD8)
├── blue/...
├── purple/...
├── amber/...
├── green/...
├── coral/...
├── pink/...
└── gray/...
```

8 ramps × 7 stops × 2 modes (light/dark) = 112 colors.

**Setup script** (genera todos via Python al CI/CD):

Disponible en `Scripts/generate-group-ramps.py`. Toma definición YAML y produce todos los `.colorset` files.

### §3.5 Geometría

```swift
public enum RuulRadius {
    public static let small: CGFloat = 8       // chips, badges
    public static let medium: CGFloat = 12     // botones, inputs
    public static let large: CGFloat = 16      // cards normales
    public static let extraLarge: CGFloat = 20 // cards hero
    public static let pill: CGFloat = 999      // capsules
}

public enum RuulBorder {
    public static let thin: CGFloat = 0.5
    public static let regular: CGFloat = 1.0
    public static let thick: CGFloat = 2.0
}
```

### §3.6 Sombras

```swift
public extension View {
    func ruulShadowSubtle() -> some View {
        shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
    }

    func ruulShadowMedium() -> some View {
        shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 4)
    }

    func ruulShadowElevated() -> some View {
        shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
    }
}
```

**Regla**: usar shadows con moderación. iOS 26 prefiere depth via Liquid Glass + spacing.

### §3.7 Animación

```swift
public extension Animation {
    static let ruulTap = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let ruulStateChange = Animation.smooth(duration: 0.3)
    static let ruulAppear = Animation.smooth(duration: 0.4)
    static let ruulSuccess = Animation.spring(response: 0.4, dampingFraction: 0.6)
    static let ruulSubtle = Animation.easeInOut(duration: 0.2)
    static let ruulGroupSwitch = Animation.smooth(duration: 0.4)
}
```

**Regla**: respetar `@Environment(\.accessibilityReduceMotion)`. Cuando sea `true`, animation es `.none`.

### §3.8 Haptics

```swift
public enum RuulHaptic {
    case lightTap
    case mediumTap
    case success
    case warning
    case error
    case groupSwitch

    @MainActor
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

## §4 Multi-group context (estructural)

Sección crítica del DS. Establece reglas de cómo el sistema maneja múltiples grupos.

### §4.1 Principio fundamental

**Un usuario puede pertenecer a 1-N grupos. Toda la UI debe funcionar correctamente con N=1 hasta N=20+.**

No es feature opcional. No es fase futura. Es estructura V1.

### §4.2 Patrón híbrido de scope

| Tab | Scope | Switcher | Background |
|---|---|---|---|
| Inicio | Cross-grupos | NO | Neutral |
| Grupo | Grupo activo | SÍ (header) | Tinte 5% del ramp |
| Historial | Grupo activo | SÍ (header) | Tinte 5% del ramp |
| Ajustes | Dual scope | SÍ (en sección grupo) | Neutral en globales, tinte en grupo |

### §4.3 Concepto de "grupo activo"

El grupo activo es state global persistente.

```swift
@Observable
@MainActor
final class SessionState {
    var activeGroup: Group?
    var availableGroups: [Group] = []

    func setActiveGroup(_ group: Group) {
        activeGroup = group
        UserDefaults.standard.set(group.id.uuidString, forKey: "activeGroupID")
        RuulHaptic.groupSwitch.trigger()
    }

    var hasMultipleGroups: Bool {
        availableGroups.count > 1
    }
}
```

**Persistencia**:
- Recordado en `UserDefaults` por sesión
- Al abrir app: vuelve al último grupo activo
- Al recibir push de otro grupo: cambia activo automáticamente

### §4.4 Switcher behavior

- Vive en header de tabs Grupo, Historial, Ajustes (sección grupo)
- NO vive en Home
- Tap → abre `RuulGroupSwitcherSheet` (bottom sheet)
- Tap en grupo distinto → cambia activo + dismiss + animación

### §4.5 Items de Home con origen

Cada item en Home muestra `RuulOriginTag`:

- Avatar del grupo (color ramp)
- Nombre del grupo
- Posicionado arriba del item

Esto NO es opcional. Es invariante de Home cuando `hasMultipleGroups == true`.

### §4.6 Caso N=1 grupo

Cuando user tiene exactamente 1 grupo:

- Home: NO muestra `RuulOriginTag` (redundante)
- Tabs grupo-específicas: switcher se muestra como solo lectura (no chevron)
- Cuando agrega segundo grupo: switcher se vuelve interactivo, items de Home empiezan a mostrar origen

### §4.7 Color ramp por categoría

Mapping fijo, no customizable:

| Categoría | Ramp |
|---|---|
| socialRecurring | teal |
| sharedResource | blue |
| rotatingSavings | purple |
| patrimonialFamily | amber |
| amateurTeam | green |
| groupTravel | coral |
| religiousCultural | pink |
| professionalInformal | gray |
| digitalCommunity | blue |
| commitmentPact | green |

**Por qué automático**: si fuera elegible, todos los grupos del mismo dueño tenderían al mismo color personal. La distinción visual entre grupos se perdería. Color como feature funcional > expresión personal.

### §4.8 Iniciales del grupo

Cada grupo tiene dos campos separados:
- `name` (string largo): "Cuates de cenas martes"
- `initials` (string 1-3 chars): "CC"

Al crear grupo:
- Founder ingresa `name`
- Sistema sugiere `initials` automáticas (primeras letras de palabras significativas)
- Founder puede override antes de crear

### §4.9 Hero de Home — selección del item

Algoritmo de prioridad cross-grupos:

```swift
extension HomeCoordinator {
    var mostUrgentItem: HomeItem? {
        items
            .sorted { lhs, rhs in
                // 1. Items con deadline en <2h primero
                // 2. Luego <24h
                // 3. Luego <72h
                // 4. Luego cronológico
                lhs.urgencyScore > rhs.urgencyScore
            }
            .first
    }
}
```

Si no hay nada urgente: hero se reemplaza por sección "Próximos eventos" cronológica.

### §4.10 Push notifications con multi-group

Toda push notification debe incluir:

```json
{
  "aps": {...},
  "group_id": "uuid",
  "deeplink": "ruul://groups/{id}/items/{itemId}"
}
```

Tap en push:
- Cambia grupo activo si necesario (silenciosamente, sin haptic)
- Navega al item específico

### §4.11 Background contextual

En tabs grupo-activas, el background tiene tinte sutil del ramp del grupo:

```swift
struct GroupScopedBackground: ViewModifier {
    let group: Group?

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Color.ruulBackground
                    if let group {
                        LinearGradient(
                            colors: [
                                group.category.ramp.background.opacity(0.3),
                                group.category.ramp.background.opacity(0.1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .ignoresSafeArea()
            }
    }
}
```

**Opacidad**: 30% del background ramp (que ya es light/50 del color), resultando en tint efectivo de ~5%.

En light mode casi imperceptible, en dark mode más visible.

### §4.12 Caso edge: salir de grupo

Cuando user sale o es removido de un grupo:

```swift
extension SessionState {
    func handleGroupRemoval(_ groupID: UUID) {
        availableGroups.removeAll { $0.id == groupID }

        if activeGroup?.id == groupID {
            // Si era el activo, cambiar al primero disponible
            activeGroup = availableGroups.first
        }

        // Notificar UI de cambio
    }
}
```

---

## §5 Componentes core

Cada componente en archivo propio bajo `RuulUI/Sources/Components/`.

### §5.1 RuulCard

Container base para contenido agrupado.

```swift
public struct RuulCard<Content: View>: View {
    let content: Content
    var padding: CGFloat
    var background: Color
    var radius: CGFloat

    public init(
        padding: CGFloat = RuulSpacing.cardPadding,
        background: Color = .ruulSurface,
        radius: CGFloat = RuulRadius.large,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.background = background
        self.radius = radius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

#Preview("RuulCard") {
    VStack(spacing: 16) {
        RuulCard {
            Text("Contenido del card")
                .font(.ruulBody)
        }

        RuulCard(background: .ruulSurfaceElevated) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Card elevado").font(.ruulTitleSmall)
                Text("Con más jerarquía").font(.ruulCaption)
            }
        }
    }
    .padding()
    .background(Color.ruulBackground)
}
```

### §5.2 RuulButton

Botón principal del sistema. 4 estilos × 3 tamaños.

```swift
public struct RuulButton: View {
    let title: String
    let action: () -> Void
    var style: Style
    var size: Size
    var icon: String?
    var isLoading: Bool
    var isDestructive: Bool

    public init(
        _ title: String,
        style: Style = .primary,
        size: Size = .regular,
        icon: String? = nil,
        isLoading: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.size = size
        self.icon = icon
        self.isLoading = isLoading
        self.isDestructive = isDestructive
        self.action = action
    }

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

        var horizontalPadding: CGFloat {
            switch self { case .small: 12; case .regular: 16; case .large: 20 }
        }

        var font: Font {
            switch self {
            case .small: .ruulLabelSmall
            case .regular: .ruulLabel
            case .large: .ruulBodyEmphasis
            }
        }
    }

    public var body: some View {
        Button {
            RuulHaptic.lightTap.trigger()
            action()
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foregroundColor)
                } else if let icon {
                    Image(systemName: icon)
                        .font(size.font.weight(.medium))
                }
                Text(title)
                    .font(size.font)
            }
            .foregroundStyle(foregroundColor)
            .frame(height: size.height)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, size.horizontalPadding)
            .background(backgroundView)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .primary:
            (isDestructive ? Color.ruulNegative : Color.ruulAccent)
        case .secondary:
            Color.ruulSurface
        case .tertiary:
            Color.clear
        case .glass:
            Rectangle().fill(.regularMaterial)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary: .white
        case .secondary, .glass: .ruulTextPrimary
        case .tertiary: isDestructive ? .ruulNegative : .ruulAccent
        }
    }
}
```

### §5.3 RuulPillButton

Botón circular con icono. Usado en headers para acciones secundarias.

```swift
public struct RuulPillButton: View {
    let symbol: String
    let action: () -> Void
    var size: Size

    public init(
        symbol: String,
        size: Size = .regular,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.size = size
        self.action = action
    }

    public enum Size {
        case small, regular, large

        var dimension: CGFloat {
            switch self { case .small: 32; case .regular: 40; case .large: 48 }
        }

        var iconSize: CGFloat {
            switch self { case .small: 14; case .regular: 18; case .large: 22 }
        }
    }

    public var body: some View {
        Button {
            RuulHaptic.lightTap.trigger()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size.iconSize, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: size.dimension, height: size.dimension)
                .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
    }
}
```

### §5.4 RuulTabBar

Tab bar inferior flotante con Liquid Glass.

```swift
public struct RuulTabBar<Tab: RuulTabItem>: View {
    @Binding var selected: Tab
    let tabs: [Tab]
    var activeTint: Color

    public init(
        selected: Binding<Tab>,
        tabs: [Tab],
        activeTint: Color = .ruulAccent
    ) {
        self._selected = selected
        self.tabs = tabs
        self.activeTint = activeTint
    }

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
                .overlay(
                    Capsule().stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
        .padding(.horizontal, RuulSpacing.xl)
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
                ZStack {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 20, weight: .regular))
                    if tab.hasBadge {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 10, y: -8)
                    }
                }
                Text(tab.label)
                    .font(.ruulLabelSmall)
            }
            .foregroundStyle(isSelected ? activeTint : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule().fill(activeTint.opacity(0.12))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isSelected ? "Seleccionado" : "")
    }
}

public protocol RuulTabItem: Identifiable, Hashable {
    var label: String { get }
    var symbol: String { get }
    var hasBadge: Bool { get }
}
```

**Uso en MainTabView**:

```swift
enum MainTab: String, CaseIterable, RuulTabItem {
    case home, group, history, settings

    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: "Inicio"
        case .group: "Grupo"
        case .history: "Historial"
        case .settings: "Ajustes"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .group: "person.3"
        case .history: "clock.arrow.circlepath"
        case .settings: "gear"
        }
    }
    var hasBadge: Bool {
        // calculado por coordinator
        false
    }
}
```

### §5.5 RuulSubTabBar

Sub-tabs horizontales scrollables dentro de tab Grupo.

```swift
public struct RuulSubTabBar<Tab: RuulSubTabItem>: View {
    @Binding var selected: Tab
    let tabs: [Tab]
    var activeColor: Color

    public init(
        selected: Binding<Tab>,
        tabs: [Tab],
        activeColor: Color = .ruulAccent
    ) {
        self._selected = selected
        self.tabs = tabs
        self.activeColor = activeColor
    }

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
                            .foregroundStyle(
                                selected.id == tab.id
                                    ? .white
                                    : .ruulTextPrimary
                            )
                            .padding(.horizontal, RuulSpacing.md)
                            .padding(.vertical, RuulSpacing.xs)
                            .background {
                                if selected.id == tab.id {
                                    Capsule().fill(activeColor)
                                } else {
                                    Capsule()
                                        .fill(.regularMaterial)
                                        .overlay(
                                            Capsule()
                                                .stroke(
                                                    Color.ruulSeparator,
                                                    lineWidth: 0.5
                                                )
                                        )
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

### §5.6 RuulGroupAvatar

Avatar del grupo con iniciales + color ramp por categoría.

```swift
public struct RuulGroupAvatar: View {
    let group: Group
    var size: Size

    public init(group: Group, size: Size = .medium) {
        self.group = group
        self.size = size
    }

    public enum Size: CGFloat {
        case xs = 20
        case sm = 24
        case md = 32
        case lg = 40
        case xl = 56
        case xxl = 80

        var fontSize: CGFloat {
            switch self {
            case .xs: 9
            case .sm: 11
            case .md: 12
            case .lg: 14
            case .xl: 18
            case .xxl: 26
            }
        }
    }

    public var body: some View {
        let ramp = group.category.ramp

        ZStack {
            if let imageURL = group.avatarURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure, .empty:
                        placeholderView(ramp: ramp)
                    @unknown default:
                        placeholderView(ramp: ramp)
                    }
                }
            } else {
                placeholderView(ramp: ramp)
            }
        }
        .frame(width: size.rawValue, height: size.rawValue)
        .clipShape(Circle())
        .accessibilityLabel("Grupo \(group.name)")
    }

    private func placeholderView(ramp: GroupColorRamp) -> some View {
        ZStack {
            Circle().fill(ramp.background)
            Text(group.initials.uppercased())
                .font(.system(size: size.fontSize, weight: .semibold))
                .foregroundStyle(ramp.foreground)
        }
    }
}
```

### §5.7 RuulPersonAvatar

Avatar de un miembro/persona. Distinto de GroupAvatar.

```swift
public struct RuulPersonAvatar: View {
    let initials: String
    let imageURL: URL?
    var size: Size
    var color: Color

    public init(
        initials: String,
        imageURL: URL? = nil,
        size: Size = .medium,
        color: Color = .ruulAccent
    ) {
        self.initials = initials
        self.imageURL = imageURL
        self.size = size
        self.color = color
    }

    public enum Size: CGFloat {
        case xs = 24
        case sm = 32
        case md = 40
        case lg = 56
        case xl = 80

        var fontSize: CGFloat {
            switch self {
            case .xs: 10
            case .sm: 12
            case .md: 14
            case .lg: 18
            case .xl: 26
            }
        }
    }

    public var body: some View {
        ZStack {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        placeholderView
                    }
                }
            } else {
                placeholderView
            }
        }
        .frame(width: size.rawValue, height: size.rawValue)
        .clipShape(Circle())
    }

    private var placeholderView: some View {
        ZStack {
            Circle().fill(color.opacity(0.2))
            Text(initials.prefix(2).uppercased())
                .font(.system(size: size.fontSize, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}
```

### §5.8 RuulOriginTag

Tag pequeño que muestra de qué grupo viene un item en Home.

```swift
public struct RuulOriginTag: View {
    let group: Group

    public init(group: Group) {
        self.group = group
    }

    public var body: some View {
        HStack(spacing: 6) {
            RuulGroupAvatar(group: group, size: .sm)
            Text(group.name)
                .font(.ruulGroupLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Del grupo \(group.name)")
    }
}
```

### §5.9 RuulGroupSwitcher

Pill button con avatar + nombre del grupo activo. Tap abre sheet.

```swift
public struct RuulGroupSwitcher: View {
    let activeGroup: Group
    let availableGroups: [Group]
    let onChange: (Group) -> Void
    @State private var showSheet = false

    public init(
        activeGroup: Group,
        availableGroups: [Group],
        onChange: @escaping (Group) -> Void
    ) {
        self.activeGroup = activeGroup
        self.availableGroups = availableGroups
        self.onChange = onChange
    }

    public var body: some View {
        Button {
            guard availableGroups.count > 1 else { return }
            RuulHaptic.lightTap.trigger()
            showSheet = true
        } label: {
            HStack(spacing: 10) {
                RuulGroupAvatar(group: activeGroup, size: .sm)
                Text(activeGroup.name)
                    .font(.ruulTitleSmall)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if availableGroups.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.regularMaterial)
                    .overlay(
                        Capsule()
                            .stroke(
                                activeGroup.category.ramp.accent.opacity(0.2),
                                lineWidth: 0.5
                            )
                    )
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            RuulGroupSwitcherSheet(
                activeGroup: activeGroup,
                availableGroups: availableGroups,
                onSelect: { newGroup in
                    onChange(newGroup)
                    showSheet = false
                }
            )
        }
        .accessibilityLabel("Grupo activo: \(activeGroup.name)")
        .accessibilityHint(
            availableGroups.count > 1
                ? "Toca para cambiar a otro grupo"
                : ""
        )
    }
}
```

### §5.10 RuulGroupSwitcherSheet

Bottom sheet con lista de grupos del usuario.

```swift
public struct RuulGroupSwitcherSheet: View {
    let activeGroup: Group
    let availableGroups: [Group]
    let onSelect: (Group) -> Void
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: RuulSpacing.xs) {
                    ForEach(availableGroups) { group in
                        groupRow(group)
                    }

                    Button {
                        // delegate to coordinator: createNewGroup
                    } label: {
                        HStack(spacing: RuulSpacing.md) {
                            ZStack {
                                Circle().fill(Color.ruulSurface)
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 40, height: 40)

                            Text("Crear nuevo grupo")
                                .font(.ruulBody)
                                .foregroundStyle(.primary)

                            Spacer()
                        }
                        .padding(RuulSpacing.md)
                        .background(Color.ruulSurface)
                        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, RuulSpacing.screenPadding)
                .padding(.vertical, RuulSpacing.md)
            }
            .navigationTitle("Tus grupos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func groupRow(_ group: Group) -> some View {
        Button {
            RuulHaptic.groupSwitch.trigger()
            withAnimation(.ruulGroupSwitch) {
                onSelect(group)
            }
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
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(group.category.ramp.accent)
                }
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large))
        }
        .buttonStyle(.plain)
    }
}
```

### §5.11 RuulSectionHeader

Encabezado de sección con título + opcional subtitle + acción.

```swift
public struct RuulSectionHeader: View {
    let title: String
    var subtitle: String?
    var trailing: AnyView?

    public init(
        _ title: String,
        subtitle: String? = nil,
        trailing: AnyView? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.ruulTitleMedium)
                .foregroundStyle(.primary)

            if let subtitle {
                Text(subtitle)
                    .font(.ruulCaption)
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

### §5.12 RuulMoneyView

Display de dinero con formato y semántica de color.

```swift
public struct RuulMoneyView: View {
    let amount: Decimal
    let currency: String
    var size: Size
    var showSign: Bool
    var semantic: SemanticColor

    public init(
        amount: Decimal,
        currency: String = "MXN",
        size: Size = .medium,
        showSign: Bool = false,
        semantic: SemanticColor = .neutral
    ) {
        self.amount = amount
        self.currency = currency
        self.size = size
        self.showSign = showSign
        self.semantic = semantic
    }

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
            .foregroundStyle(semantic.color)
            .accessibilityLabel(accessibleLabel)
    }

    private var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2

        let prefix = showSign && amount > 0 ? "+" : ""
        return prefix + (formatter.string(from: amount as NSDecimalNumber) ?? "")
    }

    private var accessibleLabel: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: amount as NSDecimalNumber) ?? ""
    }
}
```

### §5.13 RuulBadge

Badge pequeño con texto + opcional icono.

```swift
public struct RuulBadge: View {
    let text: String
    var style: Style
    var icon: String?

    public init(
        _ text: String,
        style: Style = .neutral,
        icon: String? = nil
    ) {
        self.text = text
        self.style = style
        self.icon = icon
    }

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

### §5.14 RuulEmptyState

Estado vacío estandarizado.

```swift
public struct RuulEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: ActionConfig?

    public init(
        symbol: String,
        title: String,
        message: String,
        action: ActionConfig? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }

    public struct ActionConfig {
        let label: String
        let handler: () -> Void

        public init(label: String, handler: @escaping () -> Void) {
            self.label = label
            self.handler = handler
        }
    }

    public var body: some View {
        VStack(spacing: RuulSpacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.ruulTitleMedium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

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

### §5.15 RuulErrorState

Estado de error con opción de retry.

```swift
public struct RuulErrorState: View {
    let title: String
    let message: String
    var retryAction: (() -> Void)?

    public init(
        title: String = "Algo salió mal",
        message: String,
        retryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.retryAction = retryAction
    }

    public var body: some View {
        VStack(spacing: RuulSpacing.md) {
            Image(systemName: "exclamationmark.circle")
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
                RuulButton("Reintentar", action: retryAction)
                    .frame(maxWidth: 240)
                    .padding(.top, RuulSpacing.sm)
            }
        }
        .padding(RuulSpacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

### §5.16 RuulLoadingState

Estado de loading minimal.

```swift
public struct RuulLoadingState: View {
    var message: String?

    public init(message: String? = nil) {
        self.message = message
    }

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

### §5.17 RuulInlineMessage

Mensaje inline para feedback en formularios.

```swift
public struct RuulInlineMessage: View {
    let text: String
    var style: Style

    public init(_ text: String, style: Style = .info) {
        self.text = text
        self.style = style
    }

    public enum Style {
        case info, success, warning, error

        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .success: "checkmark.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .info: .ruulInfo
            case .success: .ruulPositive
            case .warning: .ruulWarning
            case .error: .ruulNegative
            }
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.symbol)
                .font(.system(size: 14, weight: .medium))
            Text(text)
                .font(.ruulCaption)
        }
        .foregroundStyle(style.color)
        .padding(.horizontal, RuulSpacing.sm)
        .padding(.vertical, RuulSpacing.xs)
        .background(style.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.medium))
    }
}
```

### §5.18 GroupScopedBackground modifier

View modifier que aplica background contextual.

```swift
public extension View {
    func ruulGroupScopedBackground(_ group: Group?) -> some View {
        modifier(GroupScopedBackgroundModifier(group: group))
    }
}

struct GroupScopedBackgroundModifier: ViewModifier {
    let group: Group?

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Color.ruulBackground
                    if let group {
                        LinearGradient(
                            colors: [
                                group.category.ramp.background.opacity(0.3),
                                group.category.ramp.background.opacity(0.1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .ignoresSafeArea()
            }
    }
}
```

---

## §6 Layout patterns

### §6.1 Layout cross-grupos (Home)

```swift
public struct CrossGroupLayout<Content: View>: View {
    let content: Content
    var onNotificationsTap: () -> Void

    public init(
        onNotificationsTap: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.onNotificationsTap = onNotificationsTap
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.ruulBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("ruul")
                        .font(.ruulDisplayMedium)

                    Spacer()

                    RuulPillButton(symbol: "bell", action: onNotificationsTap)
                }
                .padding(.horizontal, RuulSpacing.screenPadding)
                .padding(.top, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.lg)

                // Content
                ScrollView {
                    VStack(spacing: RuulSpacing.sectionGap) {
                        content
                    }
                    .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
                }
            }
        }
    }
}
```

### §6.2 Layout grupo-activo (Group, History)

```swift
public struct GroupScopedLayout<Content: View>: View {
    @Bindable var session: SessionState
    let content: Content

    public init(
        session: SessionState,
        @ViewBuilder content: () -> Content
    ) {
        self._session = Bindable(session)
        self.content = content()
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Background contextual
            (session.activeGroup?.category.ramp.background ?? .clear)
                .opacity(0.3)
                .ignoresSafeArea()

            Color.ruulBackground.opacity(0.7).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header con switcher
                if let activeGroup = session.activeGroup {
                    HStack {
                        RuulGroupSwitcher(
                            activeGroup: activeGroup,
                            availableGroups: session.availableGroups
                        ) { newGroup in
                            session.setActiveGroup(newGroup)
                        }

                        Spacer()

                        RuulPillButton(symbol: "ellipsis") {
                            // group settings shortcut
                        }
                    }
                    .padding(.horizontal, RuulSpacing.screenPadding)
                    .padding(.vertical, RuulSpacing.md)
                }

                content
            }
        }
    }
}
```

### §6.3 Layout sub-tabs adaptativas

```swift
public struct AdaptiveSubTabLayout<SubTab: RuulSubTabItem, Content: View>: View {
    @Binding var selectedSubTab: SubTab
    let availableSubTabs: [SubTab]
    let activeColor: Color
    let content: (SubTab) -> Content

    public init(
        selectedSubTab: Binding<SubTab>,
        availableSubTabs: [SubTab],
        activeColor: Color = .ruulAccent,
        @ViewBuilder content: @escaping (SubTab) -> Content
    ) {
        self._selectedSubTab = selectedSubTab
        self.availableSubTabs = availableSubTabs
        self.activeColor = activeColor
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            RuulSubTabBar(
                selected: $selectedSubTab,
                tabs: availableSubTabs,
                activeColor: activeColor
            )
            .padding(.bottom, RuulSpacing.md)

            ScrollView {
                content(selectedSubTab)
                    .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
            }
        }
    }
}
```

### §6.4 Layout lista cronológica con secciones

```swift
public struct ChronologicalSectionedList<Item: Identifiable, ItemView: View>: View {
    let sections: [(date: String, items: [Item])]
    let itemView: (Item) -> ItemView

    public init(
        sections: [(date: String, items: [Item])],
        @ViewBuilder itemView: @escaping (Item) -> ItemView
    ) {
        self.sections = sections
        self.itemView = itemView
    }

    public var body: some View {
        LazyVStack(alignment: .leading, spacing: RuulSpacing.lg) {
            ForEach(sections, id: \.date) { section in
                VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                    Text(section.date.uppercased())
                        .font(.ruulMicro.weight(.semibold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, RuulSpacing.screenPadding)
                        .padding(.leading, 4)

                    LazyVStack(spacing: RuulSpacing.itemGap) {
                        ForEach(section.items) { item in
                            itemView(item)
                                .padding(.horizontal, RuulSpacing.screenPadding)
                        }
                    }
                }
            }
        }
    }
}
```

### §6.5 Sheet de creación / edición

```swift
public struct RuulFormSheet<Content: View>: View {
    let title: String
    let primaryActionLabel: String
    let primaryAction: () -> Void
    var canSubmit: Bool
    let content: Content

    @Environment(\.dismiss) private var dismiss

    public init(
        title: String,
        primaryActionLabel: String = "Guardar",
        canSubmit: Bool = true,
        primaryAction: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.primaryActionLabel = primaryActionLabel
        self.canSubmit = canSubmit
        self.primaryAction = primaryAction
        self.content = content()
    }

    public var body: some View {
        NavigationStack {
            Form {
                content
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(primaryActionLabel) {
                        primaryAction()
                        dismiss()
                    }
                    .disabled(!canSubmit)
                    .bold()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
```

---

## §7 Catálogo de pantallas

### §7.1 Onboarding flow

| Pantalla | Layout | Componentes |
|---|---|---|
| `WelcomeView` | Splash centered | RuulButton |
| `AuthView` | Form | TextField, RuulButton, RuulInlineMessage |
| `TemplateSelectorView` | Grid | TemplatePickerCard |
| `CreateGroupSheet` | RuulFormSheet | TextField, RuulInlineMessage |
| `InviteMembersSheet` | RuulFormSheet | TextField, list |
| `GroupReadyView` | Confirmation | RuulButton |

### §7.2 Main tabs

**Tab 1 — `HomeView` (cross-grupos)**:
- Layout: `CrossGroupLayout`
- Hero: item de mayor urgencia con `RuulOriginTag`
- Section: pendientes con `RuulOriginTag` en cada item
- Section: actividad reciente con `RuulOriginTag`
- Tab bar: Inicio highlighted

**Tab 2 — `GroupTabView` (grupo-activo)**:
- Layout: `GroupScopedLayout` + `AdaptiveSubTabLayout`
- Header: `RuulGroupSwitcher` + ellipsis pill
- Sub-tabs adaptativas según template
- Content por sub-tab

**Tab 3 — `HistoryView` (grupo-activo)**:
- Layout: `GroupScopedLayout`
- Header: `RuulGroupSwitcher`
- Filter pills (todo, votos, multas, reglas)
- Timeline `ChronologicalSectionedList`

**Tab 4 — `SettingsView` (dual scope)**:
- Header: solo título "Ajustes"
- Section "Tu cuenta" (global): perfil, notificaciones
- Section "Este grupo" con `RuulGroupSwitcher`: members, governance, danger zone

### §7.3 Detail views

| Vista | Acceso | Layout |
|---|---|---|
| `EventDetailView` | Tap en event | NavigationStack push |
| `FineDetailView` | Tap en fine | Sheet o push |
| `VoteDetailView` | Tap en pendiente | Sheet con body por type |
| `RuleDetailView` | Tap en rule | Sheet read-only |
| `MemberDetailView` | Tap en member | Sheet con info pública |

### §7.4 Sheets de acción

| Sheet | Trigger | Layout |
|---|---|---|
| `RSVPSheet` | "Confirmar asistencia" | RuulFormSheet |
| `AppealFineSheet` | "Apelar multa" | RuulFormSheet |
| `VoteOnAppealSheet` | "Votar apelación" | RuulFormSheet |
| `CreateGeneralProposalSheet` | "Nueva propuesta" | RuulFormSheet |
| `CreateRuleChangeSheet` | "Cambiar regla" | RuulFormSheet |
| `EditRuleSheet` | Tap en rule edit | RuulFormSheet |
| `EditMembersSheet` | Settings → Members | RuulFormSheet |
| `RuulGroupSwitcherSheet` | Tap en switcher | Bottom sheet |
| `CreateGroupSheet` | "+" en switcher | Bottom sheet |

---

## §8 Adaptación responsiva

### §8.1 iPhone (target principal V1)

- iPhone 15 (393pt) como base
- Verificar iPhone SE (375pt) y iPhone 16 Pro Max (430pt)
- Touch targets mínimos 44x44pt

### §8.2 iPad y macOS (V2+)

V1 funciona pero no se optimiza visualmente. Cuando se haga (V2+):

- iPad: split view con sidebar de grupos a la izquierda (mejor que bottom sheet en iPad)
- Mac: window resizable, sidebar persistente

### §8.3 Dynamic Type

- Toda tipografía respeta Dynamic Type automáticamente
- Verificación obligatoria en AX5
- Tab bar labels NO escalan más allá de XL
- Icons en tab bar: tamaño fijo

```swift
@Environment(\.dynamicTypeSize) var dynamicTypeSize

// Limit specific elements
.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
```

### §8.4 Light vs Dark mode

- Asset Catalog con variants automáticas
- Liquid Glass auto-adapta
- Group color ramps tienen variants explícitas

```swift
@Environment(\.colorScheme) var colorScheme

// Solo si necesitás lógica específica (raro)
let opacity = colorScheme == .dark ? 0.4 : 0.3
```

---

## §9 Iconografía

### §9.1 Sistema

**SF Symbols only**.
- Pesos: `.regular` para context, `.medium` para acciones primarias
- NO icons custom para conceptos cubiertos por SF Symbols

### §9.2 Iconos canónicos

| Concepto | SF Symbol |
|---|---|
| Inicio | `house` |
| Grupo (tab) | `person.3` |
| Historial | `clock.arrow.circlepath` |
| Ajustes | `gear` |
| Atrás | `chevron.left` |
| Más opciones | `ellipsis` |
| Buscar | `magnifyingglass` |
| Crear / Agregar | `plus` |
| Cerrar | `xmark` |
| Confirmar | `checkmark` |
| Eliminar | `trash` |
| Editar | `pencil` |
| Compartir | `square.and.arrow.up` |
| Notificación | `bell` |
| Cambiar grupo | `chevron.down` (en switcher) |
| Persona | `person.fill` |
| Grupo (concepto) | `person.3.fill` |
| Cena/evento | `fork.knife` o `calendar` |
| Multa | `exclamationmark.circle` |
| Dinero | `dollarsign.circle` |
| Voto | `checkmark.bubble` |
| Regla | `doc.text` |
| Tiempo | `clock` |
| Ubicación | `mappin.and.ellipse` |
| Anfitrión | `crown.fill` |
| Rotación | `arrow.triangle.2.circlepath` (Fase 2+) |
| Slot | `square.grid.3x1.below.line.grid.1x2` (Fase 3+) |
| Fondo | `banknote` (Fase 4+) |
| Activo | `building.columns` (Fase 3+) |
| Propuesta | `text.bubble` (Fase 5+) |

---

## §10 Accesibilidad

### §10.1 Mínimos no negociables

1. **VoiceOver completo** — toda interacción accesible
2. **Dynamic Type AX5** — sin overflow en tamaño máximo
3. **Reduce Motion** — animations conditionalizadas
4. **Contraste WCAG AA** — 4.5:1 normal, 3:1 grande
5. **Touch targets 44x44pt** — área tappable real

### §10.2 Accessibility labels para multi-group

```swift
// RuulOriginTag
.accessibilityElement(children: .combine)
.accessibilityLabel("Del grupo \(group.name)")

// RuulGroupSwitcher
.accessibilityLabel("Grupo activo: \(activeGroup.name)")
.accessibilityHint(
    canSwitch ? "Toca para cambiar a otro grupo" : ""
)
.accessibilityAddTraits(.isButton)

// Item de Home con origen
.accessibilityElement(children: .combine)
.accessibilityLabel(
    "\(group.name): \(action.title), \(action.subtitle)"
)
```

### §10.3 Reduce Motion

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

withAnimation(reduceMotion ? .none : .ruulGroupSwitch) {
    activeGroup = newGroup
}
```

### §10.4 Color como solo señal

Nunca usar SOLO color para transmitir información. Siempre acompañar con:
- Texto explícito
- Icono
- Diferencia de peso/tamaño

```swift
// ❌ Mal - solo color
RuulMoneyView(amount: -100, semantic: .negative)

// ✓ Bien - color + signo
RuulMoneyView(amount: -100, showSign: true, semantic: .negative)
// Renders: "-$100"
```

### §10.5 Testing accessibility

```swift
// En UI tests
func testHomeAccessibility() {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleAccessibilityPreferredContentSizeCategoryName", "AX5"]
    app.launch()

    // Verificar que elementos clave son alcanzables
    XCTAssertTrue(app.buttons["Confirmar asistencia"].isHittable)
}
```

---

## §11 SwiftUI best practices (iOS 26)

### §11.1 @Observable vs ObservableObject

**Siempre `@Observable`** (iOS 17+, mandatorio en iOS 26+):

```swift
// ❌ Patrón viejo (Combine)
final class HomeCoordinator: ObservableObject {
    @Published var items: [HomeItem] = []
}

struct HomeView: View {
    @StateObject var coordinator = HomeCoordinator()
}

// ✓ Patrón nuevo (iOS 17+)
@Observable
final class HomeCoordinator {
    var items: [HomeItem] = []
}

struct HomeView: View {
    @State private var coordinator = HomeCoordinator()

    // Pasar a sub-views via @Bindable
    var body: some View {
        SubView(coordinator: coordinator)
    }
}

struct SubView: View {
    @Bindable var coordinator: HomeCoordinator
}
```

**Beneficios**:
- No `@Published` necesario, todas propiedades observables por default
- Mejor performance (tracking granular)
- Menos boilerplate

### §11.2 State ownership

**Regla**: el dueño del state usa `@State`, los consumidores usan `@Bindable` (para `@Observable`) o `let` (para snapshots inmutables).

```swift
// View que CREA el state
struct GroupTabView: View {
    @State private var coordinator = GroupCoordinator()

    var body: some View {
        EventsListView(coordinator: coordinator)
    }
}

// View que CONSUME el state mutable
struct EventsListView: View {
    @Bindable var coordinator: GroupCoordinator

    var body: some View {
        // Puede leer y escribir
        Button("Refresh") { coordinator.refresh() }
    }
}

// View que solo LEE
struct EventDetailView: View {
    let event: Event  // snapshot inmutable, no necesita observabilidad

    var body: some View { ... }
}
```

### §11.3 NavigationStack (no NavigationView)

NavigationView está deprecated desde iOS 16. Usar `NavigationStack`:

```swift
// ❌ Deprecated
NavigationView {
    HomeView()
}

// ✓ Correcto
NavigationStack {
    HomeView()
        .navigationDestination(for: Event.self) { event in
            EventDetailView(event: event)
        }
}
```

### §11.4 Concurrency en views

```swift
// View con async work
struct HomeView: View {
    @State private var coordinator = HomeCoordinator()

    var body: some View {
        Group {
            if coordinator.isLoading {
                RuulLoadingState()
            } else {
                contentView
            }
        }
        .task {
            await coordinator.load()
        }
        .refreshable {
            await coordinator.refresh()
        }
    }
}

@Observable
@MainActor
final class HomeCoordinator {
    var items: [HomeItem] = []
    var isLoading = false
    var error: Error?

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            items = try await repository.fetchHomeItems()
        } catch {
            self.error = error
        }
    }

    func refresh() async {
        await load()
    }
}
```

### §11.5 Sheet presentation patterns

```swift
// Sheet con state booleano
@State private var showSheet = false

Button("Open") { showSheet = true }
    .sheet(isPresented: $showSheet) {
        SheetContent()
    }

// Sheet con item (mejor para pasar data)
@State private var selectedEvent: Event?

ForEach(events) { event in
    Button(event.title) { selectedEvent = event }
}
.sheet(item: $selectedEvent) { event in
    EventDetailView(event: event)
}

// Multiple sheets
enum ActiveSheet: Identifiable {
    case rsvp(Event)
    case appeal(Fine)

    var id: String {
        switch self {
        case .rsvp(let e): "rsvp-\(e.id)"
        case .appeal(let f): "appeal-\(f.id)"
        }
    }
}

@State private var activeSheet: ActiveSheet?

.sheet(item: $activeSheet) { sheet in
    switch sheet {
    case .rsvp(let event): RSVPSheet(event: event)
    case .appeal(let fine): AppealFineSheet(fine: fine)
    }
}
```

### §11.6 Performance: LazyVStack y AsyncImage

```swift
// ❌ VStack para listas largas
ScrollView {
    VStack {
        ForEach(events) { ... }  // Renders ALL items
    }
}

// ✓ LazyVStack para listas largas
ScrollView {
    LazyVStack {
        ForEach(events) { ... }  // Renders only visible
    }
}

// ✓ AsyncImage con cache automático
AsyncImage(url: imageURL) { phase in
    switch phase {
    case .empty: ProgressView()
    case .success(let image): image.resizable()
    case .failure: Image(systemName: "photo")
    @unknown default: EmptyView()
    }
}
```

### §11.7 Bindings derivados

```swift
// Crear binding desde @Observable property
struct EditView: View {
    @Bindable var coordinator: Coordinator

    var body: some View {
        TextField("Name", text: $coordinator.name)
    }
}

// Crear binding desde @State con transform
@State private var amount: Double = 0

var amountString: Binding<String> {
    Binding(
        get: { String(format: "%.2f", amount) },
        set: { amount = Double($0) ?? 0 }
    )
}
```

### §11.8 Preview macros

Usar nuevo `#Preview` macro (iOS 17+):

```swift
// ❌ Patrón viejo
struct MyView_Previews: PreviewProvider {
    static var previews: some View {
        MyView()
    }
}

// ✓ Patrón nuevo
#Preview("Default") {
    MyView()
}

#Preview("Dark mode") {
    MyView()
        .preferredColorScheme(.dark)
}

#Preview("AX5") {
    MyView()
        .environment(\.dynamicTypeSize, .accessibility5)
}
```

### §11.9 Environment values custom

```swift
// Define key
struct ActiveGroupKey: EnvironmentKey {
    static let defaultValue: Group? = nil
}

extension EnvironmentValues {
    var activeGroup: Group? {
        get { self[ActiveGroupKey.self] }
        set { self[ActiveGroupKey.self] = newValue }
    }
}

// Usage
struct ParentView: View {
    var body: some View {
        ChildView()
            .environment(\.activeGroup, group)
    }
}

struct ChildView: View {
    @Environment(\.activeGroup) var activeGroup

    var body: some View {
        Text(activeGroup?.name ?? "")
    }
}
```

---

## §12 Concurrencia (Swift 6)

### §12.1 Strict concurrency mandatory

```swift
// Package.swift
.target(
    name: "RuulUI",
    swiftSettings: [
        .swiftLanguageMode(.v6)
    ]
)
```

Todo el código debe pasar Swift 6 strict checking.

### §12.2 @MainActor para UI

```swift
// Coordinators que tocan UI: @MainActor
@Observable
@MainActor
final class HomeCoordinator {
    var items: [HomeItem] = []

    func load() async {
        // Esto corre en MainActor por default
        items = await fetchItems()
    }
}

// Repository que NO toca UI: nonisolated
final class GroupRepository: Sendable {
    func fetch(id: UUID) async throws -> Group {
        // Corre en background
        try await client.fetch(id: id)
    }
}

// Bridge entre actors
@MainActor
final class GroupCoordinator {
    private let repository = GroupRepository()
    var group: Group?

    func load(id: UUID) async {
        do {
            // repository.fetch corre en background
            let result = try await repository.fetch(id: id)
            // assignment a self.group corre en MainActor
            self.group = result
        } catch {
            // ...
        }
    }
}
```

### §12.3 Sendable conformance

```swift
// Todos los models deben ser Sendable
struct Group: Sendable, Identifiable, Codable {
    let id: UUID
    let name: String
    let initials: String
    let category: GroupCategory
    let createdAt: Date
}

// Tipos con clases requieren explicit Sendable
final class GroupRepository: Sendable {
    private let client: SupabaseClient  // Debe ser Sendable

    init(client: SupabaseClient) {
        self.client = client
    }
}
```

### §12.4 Typed throws

```swift
// Define error types
enum GroupError: Error, Sendable {
    case notFound
    case unauthorized
    case networkError(URLError)
}

// Usar typed throws (Swift 6)
func fetchGroup(id: UUID) async throws(GroupError) -> Group {
    do {
        return try await client.fetch(id)
    } catch is URLError {
        throw .networkError(...)
    } catch {
        throw .notFound
    }
}

// Llamar con typed catch
do {
    let group = try await fetchGroup(id: id)
} catch {
    // error es de tipo GroupError, no Error
    switch error {
    case .notFound: ...
    case .unauthorized: ...
    case .networkError(let urlError): ...
    }
}
```

### §12.5 Tasks y cancellation

```swift
@Observable
@MainActor
final class HomeCoordinator {
    private var loadTask: Task<Void, Never>?

    func load() {
        // Cancel previous task
        loadTask?.cancel()

        loadTask = Task {
            do {
                let items = try await repository.fetch()

                // Check cancellation
                try Task.checkCancellation()

                self.items = items
            } catch is CancellationError {
                // Task was cancelled, ignore
            } catch {
                self.error = error
            }
        }
    }
}
```

---

## §13 Liquid Glass (iOS 26)

### §13.1 Cuándo usar Liquid Glass

**SÍ** — UI infrastructure (chrome):
- Tab bars
- Toolbars / Navigation bars
- Sheets
- Buttons flotantes
- Switcher pills

**NO** — Contenido del usuario:
- Cards de eventos
- Avatares
- Metric cards
- Form fields

**Razón**: Liquid Glass es para indicar "esto es UI del sistema, no contenido". Cards con contenido deben sentirse sólidos.

### §13.2 APIs nativas iOS 26

iOS 26 introduce APIs nativas para Liquid Glass. Ya NO necesitamos hacks de `.background(.regularMaterial)`:

```swift
// ❌ Patrón viejo (manual)
.background(.regularMaterial)
.background(.ultraThinMaterial)

// ✓ Patrón nuevo iOS 26
.glassBackground()  // Auto-adapts a contexto
.glassBackground(.subtle)  // Variante sutil
.glassBackground(.prominent)  // Variante prominente

// Para shapes específicos
Capsule()
    .glassMaterial()  // Aplica Liquid Glass
```

### §13.3 Variantes

```swift
public enum RuulGlassStyle {
    case subtle      // Para elementos secundarios
    case regular     // Default — la mayoría
    case prominent   // Para elementos destacados (tab bar)
}
```

### §13.4 Composability con tinting

```swift
// Glass + tint del grupo
Capsule()
    .glassMaterial(.regular)
    .tint(activeGroup.category.ramp.accent.opacity(0.15))

// Tab bar con tinting
.glassBackground(.prominent)
.tint(activeGroup.category.ramp.accent)
```

### §13.5 Performance considerations

Liquid Glass tiene costo de GPU. Reglas:

- Máximo 3-4 elementos Liquid Glass visibles simultáneamente
- No anidar (glass dentro de glass)
- Usar `.subtle` cuando no se requiere prominence
- Desactivar en vistas con muchos items (preferir solid)

---

## §14 Reglas de evolución

### §14.1 Cuándo agregar componente nuevo

Cuando se cumplen TODOS:

1. Pattern aparece 3+ veces en código
2. No existe variante razonable de componente existente
3. Comportamiento es semánticamente distinto
4. No es composición trivial de componentes existentes

### §14.2 Cuándo extender componente existente

- Pattern es variación de uno existente
- Cambio se puede expresar como prop opcional con default
- No rompe usos existentes

### §14.3 Cuándo crear modifier vs componente

**Modifier** cuando:
- Aplica estilo o behavior a content arbitrario
- No tiene structure interna fija
- Ej: `.ruulGroupScopedBackground(group)`

**Componente** cuando:
- Tiene structure interna definida
- Combina varios elementos
- Tiene state propio
- Ej: `RuulGroupSwitcher`

### §14.4 Evolución por fase

**Fase 1 (V1, actual)** — shipped:
- Componentes §5 con multi-group support completo
- Layouts §6
- 4 tabs base
- Tab Grupo con sub-tabs Events, Rules, Fines
- Liquid Glass en chrome

**Fase 2 (Rotation universal)**:
- `RuulRotationView` — visualización de orden
- `RuulPositionBadge` — posición en rotación
- Sub-tab "Rotación" en GroupTabView
- Anti-pattern: "alguien saltó turno"

**Fase 3 (Slot + Asset)**:
- `RuulSlotCard` — slot asignable
- `RuulAssetView` — vista de activo
- Sub-tabs "Activos" y "Slots"
- Pattern: cascada de asignación

**Fase 4 (Fund + Contribution)**:
- `RuulFundBalanceCard` — saldo con trend
- `RuulContributionRow` — aporte
- `RuulCyclePhase` — fase de ciclo
- Sub-tab "Fondo"

**Fase 5 (Proposal + Comment + Roles)**:
- `RuulProposalCard`
- `RuulCommentThread`
- `RuulRoleBadge`
- Sub-tab "Propuestas"
- Filtros opcionales en Home (5+ grupos)

**Fase 6 (Editor + Commitment)**:
- `RuulRuleBuilder`
- `RuulConditionRow`, `RuulConsequenceCard`
- `RuulCommitmentCard`
- Sub-tab "Compromisos"

### §14.5 Versionado del DS

**Major** (X.0.0): cambios breaking en componentes core o arquitectura
**Minor** (X.Y.0): nuevos componentes, fases nuevas
**Patch** (X.Y.Z): clarificaciones, fixes

Estado actual: **DS v3.0.0** — autoritativo, supersede v1 y v2.

---

## §15 Review checklist

Pre-merge, verificar TODOS:

### §15.1 Tokens

- [ ] Spacing usa `RuulSpacing.*` (cero literales)
- [ ] Tipografía usa `Font.ruul*`
- [ ] Colores usan `Color.ruul*` o group color ramps
- [ ] Corner radius usa `RuulRadius.*`
- [ ] Animaciones usan `Animation.ruul*`
- [ ] Cero hex colors en código

### §15.2 Componentes

- [ ] Reutiliza componentes existentes
- [ ] Componentes nuevos justificados (§14.1)
- [ ] Props opcionales con defaults razonables
- [ ] Public API documentada
- [ ] Preview macro presente
- [ ] Accessibility labels presentes

### §15.3 Multi-group

- [ ] Si pantalla cross-grupos: cada item con `RuulOriginTag`
- [ ] Si pantalla grupo-activo: header con `RuulGroupSwitcher`
- [ ] Funciona con N=1 grupo (sin redundancia)
- [ ] Funciona con N=20 grupos (no se rompe)
- [ ] Background contextual aplicado en tabs grupo-activas

### §15.4 SwiftUI best practices

- [ ] `@Observable` (no ObservableObject)
- [ ] `NavigationStack` (no NavigationView)
- [ ] `LazyVStack` para listas largas
- [ ] `@State` solo en owners
- [ ] `@Bindable` en consumers
- [ ] async/await (no Combine en código nuevo)
- [ ] `@MainActor` en coordinators que tocan UI

### §15.5 Concurrencia

- [ ] Models conforman `Sendable`
- [ ] `@MainActor` apropiado
- [ ] No data races (Swift 6 strict)
- [ ] Cancellation handling en tasks

### §15.6 Patterns

- [ ] Layout sigue §6 patterns
- [ ] Empty/error/loading states explícitos
- [ ] Tap feedback (haptic donde corresponde)
- [ ] Dynamic Type funciona en AX5

### §15.7 Copy

- [ ] Tono descriptivo, no acusatorio
- [ ] Sin emojis estructurales
- [ ] Sin exclamaciones excepto confirmaciones críticas
- [ ] Concreto, no aspiracional
- [ ] Localizable.strings (no hardcoded)

### §15.8 Performance

- [ ] LazyVStack para listas
- [ ] AsyncImage con phase handling
- [ ] No re-renders innecesarios (verificar con Instruments)
- [ ] Liquid Glass usado con moderación (§13.5)

### §15.9 Accessibility

- [ ] Accessibility labels en elementos interactivos
- [ ] Accessibility hints donde useful
- [ ] Color no es la única señal
- [ ] Touch targets 44x44pt
- [ ] Funciona en VoiceOver
- [ ] Funciona en AX5
- [ ] Reduce Motion respetado

### §15.10 Testing

- [ ] Preview macros para todos los componentes nuevos
- [ ] UI test si flow crítico
- [ ] Snapshot test si componente complejo

---

## §16 Anti-patterns

**❌ Tabs separadas para Pendientes/Notificaciones/Inbox**
→ Pendientes vive en Home con badge en tab bar.

**❌ Switcher de grupo en Home**
→ Home es cross-grupos por diseño. Switcher solo en otras tabs.

**❌ Items de Home sin indicar grupo de origen (multi-group user)**
→ Cada item de Home cross-grupos debe tener `RuulOriginTag`.

**❌ Color del avatar elegido por founder**
→ Color automático según categoría de template.

**❌ Sub-tabs en tab Grupo idénticas en todos los templates**
→ Sub-tabs adaptativas según template del grupo activo.

**❌ Gradientes decorativos**
→ ruul es Wallet, no Stripe. Gradientes solo para background contextual sutil (§4.11).

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
→ `RuulTabBar` flotante con Liquid Glass.

**❌ NavigationView (deprecated)**
→ `NavigationStack`.

**❌ Combine para nuevos features**
→ async/await + @Observable.

**❌ ObservableObject**
→ @Observable.

**❌ UIKit en código nuevo**
→ SwiftUI puro estricto. Para camera/scanner usar APIs nativas SwiftUI (PhotosPicker, DocumentPicker, DataScannerViewController) con UIViewControllerRepresentable solo si no hay equivalente nativo iOS 26.

**❌ Hardcoded strings**
→ Localizable desde V1.

**❌ Hex colors en código**
→ Asset Catalog only.

**❌ Mostrar nombre del grupo como prefijo en cada texto**
→ Usar `RuulOriginTag` arriba del item.

**❌ Liquid Glass en cards de contenido**
→ Solo en chrome (tab bar, toolbars, sheets, buttons flotantes).

**❌ Animar transiciones sin respetar Reduce Motion**
→ Conditionalizar con `@Environment(\.accessibilityReduceMotion)`.

**❌ @Published en código nuevo**
→ @Observable hace todo automático.

**❌ MockData hardcoded en views**
→ Repositorio inyectable + Preview con mock repository.

**❌ View que hace fetch directo**
→ Coordinator @Observable hace fetch, view consume.

---

## §17 Testing visual

### §17.1 Preview macros

Cada componente debe tener al menos:

```swift
#Preview("Default") {
    ComponentName(...)
}

#Preview("Dark mode") {
    ComponentName(...)
        .preferredColorScheme(.dark)
}

#Preview("AX5 (large text)") {
    ComponentName(...)
        .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Reduce Motion") {
    ComponentName(...)
        .environment(\.accessibilityReduceMotion, true)
}
```

### §17.2 Snapshot testing

Para componentes complejos, agregar snapshot tests:

```swift
import SnapshotTesting
import XCTest

final class RuulButtonTests: XCTestCase {
    func testPrimaryButton() {
        let view = RuulButton("Confirmar") {}
            .frame(width: 300)

        assertSnapshot(of: view, as: .image)
    }

    func testAllStyles() {
        ForEach(RuulButton.Style.allCases) { style in
            let view = RuulButton("Test", style: style) {}
            assertSnapshot(
                of: view,
                as: .image,
                named: "style-\(style)"
            )
        }
    }
}
```

### §17.3 Accessibility audit

Antes de cada release:

1. Activar VoiceOver, navegar app completa
2. Activar AX5 Dynamic Type, verificar layouts
3. Activar Reduce Motion, verificar animaciones
4. Verificar contraste con sketch/figma plugin

### §17.4 UI tests

Para flows críticos:

```swift
final class HomeFlowTests: XCTestCase {
    func testRSVPFlow() throws {
        let app = XCUIApplication()
        app.launch()

        // Verificar hero
        XCTAssertTrue(app.staticTexts["PRÓXIMO"].exists)

        // Tap confirmar
        app.buttons["Confirmar asistencia"].tap()

        // Sheet abre
        XCTAssertTrue(app.otherElements["RSVPSheet"].exists)
    }
}
```

---

## §18 Migration v2 → v3

### §18.1 Breaking changes v2 → v3

**Paradigma de state management**:
- Migrar todos los `ObservableObject` → `@Observable`
- Migrar todos los `@StateObject` → `@State`
- Migrar todos los `@ObservedObject` → `@Bindable`

**Concurrencia**:
- Activar Swift 6 strict checking
- Agregar `@MainActor` a coordinators
- Conformar models a `Sendable`

**Liquid Glass**:
- Reemplazar `.background(.regularMaterial)` con `.glassBackground()` cuando sea iOS 26

### §18.2 No breaking en componentes públicos

Los componentes (`RuulButton`, `RuulCard`, etc) mantienen API. Las migraciones son internas.

### §18.3 Migration plan

Sprint dedicado de 1 semana:

**Día 1-2**: Migrar coordinators a @Observable
**Día 3**: Activar Swift 6 strict, fix concurrency warnings
**Día 4**: Update Liquid Glass APIs
**Día 5**: Tests + verificación visual

### §18.4 Checklist migration

- [ ] Todos los coordinators usan @Observable
- [ ] Todos los models conforman Sendable
- [ ] Swift 6 strict checking pasa
- [ ] Liquid Glass APIs actualizadas
- [ ] Tests pasan
- [ ] Visual regression no existe

---

## §19 Changelog

### v3.0.0 (2026-05-07)

**Major rewrite**:
- Estructura final post-conversación arquitectónica
- Sección §11 SwiftUI best practices iOS 26 nueva
- Sección §12 Concurrencia Swift 6 nueva
- Sección §13 Liquid Glass APIs nativas iOS 26 nueva
- Sección §17 Testing visual nueva
- Sección §18 Migration plan v2→v3

**Componentes**:
- Todos los componentes con `#Preview` macros
- Todos los componentes con accessibility labels
- Todos los models con `Sendable`

### v2.0.0 (2026-05-07)

- BREAKING: Tab structure cambió a Inicio/Grupo/Historial/Ajustes
- BREAKING: Multi-group como arquitectura estructural V1
- Componentes nuevos: RuulGroupAvatar, RuulGroupSwitcher, etc
- Patrón híbrido: Home cross-grupos, otras tabs grupo-activo

### v1.0.0 (2026-05-06)

- Release inicial al cierre de Fase 1 (F0)

---

## §20 Glosario

- **Token**: valor de design referenciado por nombre, no literal
- **Surface**: nivel de background (background → surface → surfaceElevated)
- **Chrome**: UI infrastructure (toolbars, tab bar, sheets) — Liquid Glass
- **Content**: contenido del usuario — surfaces sólidas
- **Pattern**: combinación canónica de componentes
- **Liquid Glass**: material translúcido iOS 26
- **Group active**: grupo seleccionado para tabs grupo-específicas
- **Cross-group**: tab que muestra contenido de todos los grupos
- **Origin tag**: avatar + nombre del grupo en items de Home
- **Color ramp**: 7 stops del mismo color para grupos
- **@Observable**: macro de Observation framework (iOS 17+)
- **@Bindable**: wrapper para pasar bindings de @Observable
- **Sendable**: protocol que indica safety entre actors
- **@MainActor**: actor que ejecuta en main thread
- **Typed throws**: throws con tipo específico de error (Swift 6)
- **Strict concurrency**: modo Swift 6 que detecta data races

---

## §21 Apéndice: ejemplos completos

### §21.1 HomeView (cross-grupos)

```swift
import SwiftUI
import RuulCore
import RuulUI

struct HomeView: View {
    @State private var coordinator = HomeCoordinator()
    @Environment(SessionState.self) private var session

    var body: some View {
        CrossGroupLayout(
            onNotificationsTap: coordinator.openNotifications
        ) {
            // Hero
            if let urgent = coordinator.mostUrgentItem {
                heroSection(item: urgent)
            }

            // Pendientes
            if !coordinator.pendingActions.isEmpty {
                pendingsSection
            }

            // Activity
            if !coordinator.recentActivity.isEmpty {
                activitySection
            }
        }
        .task { await coordinator.load() }
        .refreshable { await coordinator.refresh() }
    }

    @ViewBuilder
    private func heroSection(item: HomeItem) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text("PRÓXIMO")
                .font(.ruulMicro.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, RuulSpacing.screenPadding)

            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                if session.hasMultipleGroups {
                    RuulOriginTag(group: item.group)
                }

                // Item-specific content
                heroContent(for: item)
            }
            .padding(RuulSpacing.lg)
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large))
            .padding(.horizontal, RuulSpacing.screenPadding)
        }
    }

    // ... resto de implementación
}

@Observable
@MainActor
final class HomeCoordinator {
    var pendingActions: [PendingAction] = []
    var recentActivity: [ActivityItem] = []
    var mostUrgentItem: HomeItem?
    var isLoading = false
    var error: Error?

    private let repository: HomeRepository

    init(repository: HomeRepository = .live) {
        self.repository = repository
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let pendings = repository.fetchPendings()
            async let activity = repository.fetchActivity()
            async let urgent = repository.fetchMostUrgent()

            let (p, a, u) = try await (pendings, activity, urgent)
            self.pendingActions = p
            self.recentActivity = a
            self.mostUrgentItem = u
        } catch {
            self.error = error
        }
    }

    func refresh() async {
        await load()
    }

    func openNotifications() {
        // navegación...
    }
}
```

### §21.2 GroupTabView (grupo-activo)

```swift
struct GroupTabView: View {
    @Environment(SessionState.self) private var session
    @State private var coordinator = GroupTabCoordinator()
    @State private var selectedSubTab: GroupSubTab = .events

    var body: some View {
        GroupScopedLayout(session: session) {
            if let activeGroup = session.activeGroup {
                AdaptiveSubTabLayout(
                    selectedSubTab: $selectedSubTab,
                    availableSubTabs: availableSubTabs(for: activeGroup),
                    activeColor: activeGroup.category.ramp.accent
                ) { subTab in
                    contentView(for: subTab, group: activeGroup)
                }
            } else {
                RuulEmptyState(
                    symbol: "person.3",
                    title: "Sin grupos",
                    message: "Crea tu primer grupo para empezar",
                    action: .init(
                        label: "Crear grupo",
                        handler: coordinator.createGroup
                    )
                )
            }
        }
        .task {
            if let groupID = session.activeGroup?.id {
                await coordinator.load(groupID: groupID)
            }
        }
        .onChange(of: session.activeGroup) { _, newGroup in
            if let id = newGroup?.id {
                Task { await coordinator.load(groupID: id) }
            }
        }
    }

    private func availableSubTabs(for group: Group) -> [GroupSubTab] {
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

    @ViewBuilder
    private func contentView(for subTab: GroupSubTab, group: Group) -> some View {
        switch subTab {
        case .events: EventsListView(coordinator: coordinator, group: group)
        case .rotation: RotationView(group: group)
        case .slots: SlotsView(group: group)
        case .fund: FundView(group: group)
        case .proposals: ProposalsView(group: group)
        case .rules: RulesView(group: group)
        case .fines: FinesView(group: group)
        }
    }
}
```

### §21.3 SessionState (global)

```swift
import Foundation
import RuulCore

@Observable
@MainActor
final class SessionState {
    var activeGroup: Group?
    var availableGroups: [Group] = []
    var currentUser: User?

    private let groupRepository: GroupRepository
    private let userDefaults: UserDefaults

    init(
        groupRepository: GroupRepository = .live,
        userDefaults: UserDefaults = .standard
    ) {
        self.groupRepository = groupRepository
        self.userDefaults = userDefaults
    }

    var hasMultipleGroups: Bool {
        availableGroups.count > 1
    }

    func loadInitial() async {
        do {
            availableGroups = try await groupRepository.fetchUserGroups()
            restoreActiveGroup()
        } catch {
            // ...
        }
    }

    func setActiveGroup(_ group: Group) {
        activeGroup = group
        userDefaults.set(group.id.uuidString, forKey: "activeGroupID")
        RuulHaptic.groupSwitch.trigger()
    }

    func handleGroupRemoval(_ groupID: UUID) {
        availableGroups.removeAll { $0.id == groupID }
        if activeGroup?.id == groupID {
            activeGroup = availableGroups.first
        }
    }

    private func restoreActiveGroup() {
        if let storedID = userDefaults.string(forKey: "activeGroupID"),
           let uuid = UUID(uuidString: storedID),
           let group = availableGroups.first(where: { $0.id == uuid }) {
            activeGroup = group
        } else {
            activeGroup = availableGroups.first
        }
    }
}
```

### §21.4 App entry point

```swift
import SwiftUI
import RuulCore

@main
struct ruulApp: App {
    @State private var session = SessionState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task {
                    await session.loadInitial()
                }
        }
    }
}

struct RootView: View {
    @Environment(SessionState.self) private var session
    @State private var selectedTab: MainTab = .home

    var body: some View {
        ZStack {
            Group {
                switch selectedTab {
                case .home: HomeView()
                case .group: GroupTabView()
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }

            VStack {
                Spacer()
                RuulTabBar(
                    selected: $selectedTab,
                    tabs: MainTab.allCases,
                    activeTint: session.activeGroup?.category.ramp.accent ?? .ruulAccent
                )
                .padding(.horizontal, RuulSpacing.xl)
                .padding(.bottom, RuulSpacing.sm)
            }
        }
    }
}
```

---

**Fin del Design System v3.0.**

Cualquier desviación documentada y justificada actualiza este documento.
