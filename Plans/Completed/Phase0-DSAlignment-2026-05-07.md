# Phase 0 — Design System Alignment

> Fecha: 2026-05-07
> Origen: `docs/DesignSystem.md` (v1.0.0 autoritativo)
> Objetivo: alinear código con DS doc — additive primero, breaking después.

---

## 0. Tesis

El DS doc define la verdad. El código diverge en 3 áreas:

1. **Naming de tokens**: `RuulSpacing.s4` vs spec `.md`. `Color.ruulBackgroundCanvas` vs `.ruulBackground`. Conceptos correctos, etiquetas distintas.
2. **Componentes faltantes**: `RuulPillButton`, `RuulHeaderActions`, `RuulTabBar`, `RuulSectionHeader`, `RuulMoneyView`, `RuulInlineMessage`, `RuulLoadingState`.
3. **Anti-patterns activos**: Sprint 1 introdujo `LoadingStateView` con shimmer skeleton — el DS lo prohíbe explícitamente (§13). Hay que rever.

---

## 1. Estrategia

**Additive primero**, breaking changes al final del barrido. Cada fase queda commiteable y deja el código compilando.

### Fase A — Foundations (additive)
Extender tokens existentes con aliases del DS. Construir componentes faltantes. Sin cambiar callsites.

### Fase B — Anti-pattern fix
Reemplazar shimmer `LoadingStateView` por `RuulLoadingState` (ProgressView simple). Refactor las 8 vistas de Sprint 1 al nuevo pattern.

### Fase C — Tab bar swap
Sustituir `ResourceTabBar` por `RuulTabBar` flotante con Liquid Glass en `MainTabView`.

### Fase D — Component adoption
Aplicar `RuulPillButton`/`RuulSectionHeader`/`RuulMoneyView`/`RuulBadge`/`RuulInlineMessage` en pantallas existentes.

### Fase E — Token rename sweep
Mechanical rename `RuulSpacing.s4 → RuulSpacing.md`, `Color.ruulBackgroundCanvas → ruulBackground`, etc. Eliminar aliases legacy en último commit.

---

## 2. Token aliases (Fase A)

### 2.1 RuulSpacing — agregar aliases sin tocar `s0..s12`

```swift
public enum RuulSpacing {
    // Existing s0..s12 stay.

    // DS doc names (canonical going forward):
    public static let xxs:  CGFloat = 4   // = s1
    public static let xs:   CGFloat = 8   // = s2
    public static let sm:   CGFloat = 12  // = s3
    public static let md:   CGFloat = 16  // = s4
    public static let lg:   CGFloat = 20  // = s5
    public static let xl:   CGFloat = 24  // = s6
    public static let xxl:  CGFloat = 32  // = s7
    public static let xxxl: CGFloat = 48  // = s9

    // Semantic aliases:
    public static let cardPadding: CGFloat   = md   // 16
    public static let screenPadding: CGFloat = lg   // 20
    public static let sectionGap: CGFloat    = xxl  // 32
    public static let itemGap: CGFloat       = sm   // 12
}
```

### 2.2 RuulRadius — agregar aliases

```swift
public extension RuulRadius {
    static let small: CGFloat       = sm  // 8
    static let medium: CGFloat      = md  // 12
    static let large: CGFloat       = lg  // 16
    static let extraLarge: CGFloat  = xl  // 20
    // pill ya existe
}
```

### 2.3 Color — agregar aliases sobre tokens existentes

```swift
public extension Color {
    static var ruulBackground: Color        { ruulBackgroundCanvas }
    static var ruulSurface: Color           { ruulBackgroundElevated }
    static var ruulSurfaceElevated: Color   { ruulBackgroundElevated }
    static var ruulPositive: Color          { ruulSemanticSuccess }
    static var ruulNegative: Color          { ruulSemanticError }
    static var ruulWarning: Color           { ruulSemanticWarning }
    static var ruulInfo: Color              { ruulSemanticInfo }
    static var ruulNeutral: Color           { ruulTextTertiary }
    static var ruulSeparator: Color         { ruulBorderSubtle }
    static var ruulSeparatorOpaque: Color   { ruulBorderDefault }
    static var ruulAccent: Color            { ruulAccentPrimary }
    static var ruulAccentMuted: Color       { ruulAccentSubtle }

    // Tinted backgrounds (NEW):
    static var ruulPositiveBackground: Color { ruulSemanticSuccess.opacity(0.12) }
    static var ruulNegativeBackground: Color { ruulSemanticError.opacity(0.12) }
    static var ruulWarningBackground: Color  { ruulSemanticWarning.opacity(0.12) }
    static var ruulInfoBackground: Color     { ruulSemanticInfo.opacity(0.12) }
}
```

### 2.4 Font — agregar nombres del DS doc

```swift
public extension Font {
    // Existing ruul* aliases stay.

    // DS doc additions (semantic):
    static var ruulTitleSmall: Font        { .system(.headline, design: .default, weight: .semibold) }
    static var ruulBodyEmphasis: Font      { .system(.body, design: .default, weight: .semibold) }
    static var ruulCaptionEmphasis: Font   { .system(.subheadline, design: .default, weight: .medium) }
    static var ruulCaptionSmall: Font      { .system(.footnote, design: .default, weight: .regular) }

    // Money — tabular numbers
    static var ruulMoneyLarge: Font        { .system(.title, design: .default, weight: .semibold).monospacedDigit() }
    static var ruulMoneyMedium: Font       { .system(.title3, design: .default, weight: .semibold).monospacedDigit() }
    static var ruulMoneySmall: Font        { .system(.body, design: .default, weight: .semibold).monospacedDigit() }

    // Labels
    static var ruulLabel: Font             { .system(.subheadline, design: .default, weight: .medium) }
    static var ruulLabelSmall: Font        { .system(.caption, design: .default, weight: .medium) }

    // Microcopy
    static var ruulMicro: Font             { .system(.caption2, design: .default, weight: .regular) }
}
```

### 2.5 Animation — agregar tokens del DS

```swift
public extension Animation {
    // Existing ruulSnappy/ruulSmooth/ruulBouncy/ruulMorph stay.

    static let ruulTap         = Animation.spring(response: 0.30, dampingFraction: 0.70)
    static let ruulStateChange = Animation.smooth(duration: 0.30)
    static let ruulAppear      = Animation.smooth(duration: 0.40)
    static let ruulSuccess     = Animation.spring(response: 0.40, dampingFraction: 0.60)
    static let ruulSubtle      = Animation.easeInOut(duration: 0.20)
}
```

### 2.6 Shadow — extensions

```swift
public extension View {
    func ruulShadowSubtle() -> some View {
        shadow(color: .black.opacity(0.04), radius: 8,  x: 0, y: 2)
    }
    func ruulShadowMedium() -> some View {
        shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 4)
    }
    func ruulShadowElevated() -> some View {
        shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
    }
}
```

---

## 3. Componentes nuevos (Fase A)

### 3.1 RuulPillButton

Pill button para back nav y header actions. 32/40/48 sizes.

### 3.2 RuulHeaderActions

Container que agrupa N pill buttons en una sola pill compartida (`.regularMaterial` background).

### 3.3 RuulTabBar

Tab bar flotante con Liquid Glass que reemplaza `TabView` default. Recibe `[RuulTabItem]` + binding. NO reemplaza ResourceTabBar todavía — Fase C lo hace.

### 3.4 RuulSectionHeader

`title / subtitle` con divider tipográfico opcional + trailing slot.

### 3.5 RuulMoneyView

Display de monto con tabular digits, currency formatter, `+` opcional, `accessibilityLabel` con palabra hablada.

### 3.6 RuulInlineMessage

`info/success/warning/error` style + opcional action button. Glass-tinted background.

### 3.7 RuulLoadingState

`ProgressView()` simple + mensaje opcional. **Reemplaza shimmer LoadingStateView** (Fase B). Per anti-pattern §13.

### 3.8 RuulBadge

Cápsula tinted (positive/negative/warning/info/neutral). RuulChip existente puede coexistir; RuulBadge es el canonical del DS doc.

### 3.9 RuulEmptyState (typealias o builder)

Adaptar EmptyStateView existente o exponer typealias.

### 3.10 RuulErrorState (typealias)

`typealias RuulErrorState = ErrorStateView` o builder shim.

### 3.11 RuulCard

✓ Existe, sin cambios.

### 3.12 RuulAvatarView

`typealias RuulAvatarView = RuulAvatar` o rename suave.

---

## 4. Sequencing

| Fase | Tarea | Esfuerzo | Bloquea |
|---|---|---|---|
| A | Tokens additive + new components | 1.5 sesiones | B-E |
| B | Replace shimmer LoadingStateView con RuulLoadingState (Sprint 1 fixes) | 1 sesión | C |
| C | RuulTabBar swap en MainTabView | 1.5 sesiones | D |
| D | Apply Pill/Money/Badge/InlineMessage/SectionHeader en pantallas | 2 sesiones | E |
| E | Token rename sweep + cleanup aliases legacy | 1 sesión | — |

---

## 5. Constraints

- **Cada fase compila independientemente**. No checkpoint con build roto.
- **Anti-pattern §13 wins**: shimmer salió, ProgressView entra. Sprint 1 se corrige.
- **NO localizable strings ni Asset Catalog colors** en este sprint — el DS doc lo pide pero es trabajo aparte (V1 hardcoded está OK por ahora).
- **NO custom fonts** — SF Pro stays.

---

## 6. Estado de implementación

- [ ] Fase A: Tokens additive + missing components
- [ ] Fase B: Loading state anti-pattern fix
- [ ] Fase C: RuulTabBar swap
- [ ] Fase D: Component adoption en pantallas
- [ ] Fase E: Rename sweep + alias cleanup

Build target: `** BUILD SUCCEEDED **` después de cada fase. Smoke en simulador. Device install al final de C, D y E.
