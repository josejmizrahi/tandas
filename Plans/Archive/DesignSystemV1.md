# ruul — Design System V1

**Branch**: `claude/design-system-liquid-glass-d4x9M`
**Status**: PLAN — awaiting review before implementation

---

## 0. Resumen ejecutivo

Reemplazar el design-system parcial existente (`ios/Tandas/DesignSystem/`,
~10 archivos, paleta violeta-oscura dark-only) por un DS estructurado en
4 capas (Tokens → Primitives → Patterns → Templates) que soporte
light + dark + high contrast, con paleta nueva "neutros fríos modernos"
y rebrand visual a `ruul`.

**Lo que NO se hace en V1**:
- Renombrar el target Xcode `Tandas` → `Ruul` (queda para otro PR; alto
  blast radius porque toca xcodegen, bundle id, entitlements, signing).
- Tocar features de producto. Las vistas existentes (`LoginView`,
  `OnboardingView`, `WelcomeView`, `GroupsListView`, etc.) quedan como
  están. La migración de esas vistas al nuevo DS es trabajo del prompt 2
  (Onboarding) y siguientes.
- Implementar push notifs, eventos, multas, votos.

**Estrategia de coexistencia**: durante V1 el DS viejo y el nuevo viven
en paralelo. Cuando una feature se migra al DS nuevo, se borra su uso
del viejo. Cuando el último consumer migra, borramos el DS viejo
completo. Esto evita un PR gigante que rompa todas las features a la vez.

---

## 1. Respuestas a las 8 preguntas previas

### 1.1 ¿Hay design system parcial existente?
**Sí.** En `ios/Tandas/DesignSystem/`:
- `Tokens.swift` — `Brand` enum con `accent` (violeta #9C7BF4), `accent2/3`,
  `meshColors` (paleta oscura), `groupPalette` (12 colores), `Status`,
  `Radius`, `Spacing`. **Sin** colors estructurados ni soporte light.
- `Typography.swift` — 5 tokens (`tandaHero`, `tandaTitle`, `tandaBody`,
  `tandaCaption`, `tandaAmount`), todos `Font.system(... design: .rounded)`.
- `AdaptiveGlass.swift` — modifier `.adaptiveGlass(shape, tint, interactive)`
  que envuelve `glassEffect(_:in:)` con fallback a
  `accessibilityReduceTransparency`. **Reutilizable** — lo movemos a la
  capa nueva intacto.
- `MeshBackground.swift` — UNA sola variante (violeta oscuro), animación
  phase. Reemplazado por `RuulMeshBackground` con 3 variantes.
- Components: `Field`, `GlassCapsuleButton`, `GlassCard`, `OTPInput`,
  `TypologyCard`, `WalletGroupCard`, `WelcomeStepCard`.

**Qué reusar**:
- La lógica de `AdaptiveGlass.swift` (con un rename a `RuulGlass`).
- El patrón de `OTPInput` con `TextField` invisible + `oneTimeCode` content type.
- La lógica de animación phase en `MeshBackground`.

**Qué NO reusar**:
- `TypologyCard` y `WalletGroupCard` importan `GroupType` y `Group`
  (modelos de producto). El prompt explícitamente prohíbe que el DS
  conozca el modelo. Estos quedan en `Features/Groups/` (no son parte
  del DS) y se reemplazan por `EventCardStub` / `WalletCardStub` con
  datos genéricos.
- La paleta violeta-oscura completa. La nueva paleta es "neutros fríos".

### 1.2 ¿Hay assets aprovechables?
- `Assets.xcassets/AccentColor.colorset` tiene un color violeta
  (#9C7BF4). **Lo cambiamos** a `#5B6CFF` (accent.primary nuevo) con
  variantes light/dark/highContrast.
- `AppIcon.appiconset` no está poblado todavía — se ignora.
- **No hay imágenes ni símbolos custom** — todo el iconography usa
  SF Symbols, lo cual es coherente con la nueva dirección.

### 1.3 ¿Hay estilo visual existente que rompa con la dirección nueva?
**Sí, dos cosas críticas**:

1. **Dark-only hardcoded**: `TandasApp.swift:28` fuerza
   `.preferredColorScheme(.dark)`. La V1 lo elimina y respeta
   `@Environment(\.colorScheme)` (sistema decide light/dark).
2. **Branding "Ruul" mayúscula con `Font.system(... design: .rounded)`**:
   `LoginView.swift:43-45` muestra "Ruul" como wordmark. El brief pide
   `ruul` minúsculas. Cambiamos el wordmark cuando migremos LoginView
   en un prompt futuro; **NO en este PR**, para evitar tocar features
   de producto.

### 1.4 ¿Swift Package Manager o folder dentro del target principal?
**Folder dentro del target principal** (`ios/Tandas/DesignSystem/`).
Razones:
- El proyecto se genera con `xcodegen` desde `project.yml`. Modularizar
  en un sub-package SPM requiere mover folders, declarar `Package.swift`
  embebido, y reconfigurar `project.yml` para depender del sub-package.
  Riesgo medio, beneficio bajo en V1.
- En V1 el DS no se distribuye fuera del app, así que la modularización
  no aporta nada hoy.
- **Cuando** convenga (target de Showcase compartido, app companion,
  etc.) extraemos a SPM. Eso es trivial cuando los archivos ya están
  bien organizados.

**Convención obligatoria que sí se aplica**: ningún archivo en
`Features/`, `Models/`, `Supabase/`, `Shell/` puede importar nada de
`DesignSystem/Theme/` u otros internos del DS — solo la API pública
(tokens, primitivos, patterns, templates). Esto se hace por convención
+ revisión de PR (no hay enforcement de compilador hasta que sea SPM).

### 1.5 Display font final
**SF Pro como placeholder.** El brief explícitamente dice que la fuente
final viene después. `DesignSystem/Tokens/Typography.swift` se diseña
para que cambiar a una fuente custom (Söhne, Inter, etc.) sea **un solo
archivo** y ~10 líneas. Comentarios `// TODO: replace with chosen
display font` claros en cada punto de extensión.

### 1.6 Showcase: target separado vs debug menu
**Debug menu dentro del app principal** (no target separado).
Razones:
- Crear target separado en xcodegen requiere otro `Tandas` clone con
  Info.plist, entitlements, signing. Incrementa la superficie de CI y
  release.
- Un debug menu accesible vía gesto secreto (5 taps en el logo en
  splash, o `#if DEBUG` shake gesture) es estándar y suficiente.
- `#if DEBUG` garantiza que el showcase no se compila en release —
  igual de seguro que un target separado.

**Implementación**: `DesignSystem/Showcase/` con `ShowcaseRootView` y
sub-vistas, gateado por `#if DEBUG`. Activador: gesto shake desde
cualquier pantalla durante debug, abre `.fullScreenCover` con el
showcase. Si más adelante quieres target dedicado, migrar es trivial.

### 1.7 ¿Tests existentes que pueda romper?
- Tests existentes (`MockAuthServiceTests`, `MockGroupsRepositoryTests`,
  `MockProfileRepositoryTests`, `ModelsTests`) no tocan UI ni DS, no
  los rompemos.
- `HappyPathTests` (UI test) presiona botones por accessibility
  identifier. Solo se rompería si renombramos los botones existentes
  en `LoginView`/`OnboardingView`. **No los tocamos en V1**, así que safe.
- `SnapshotTesting` ya está declarado como dependencia en `project.yml`
  pero **nunca se ha usado**. No hay snapshots existentes que rompan.

### 1.8 Deployment target
**iOS 26.0** confirmado (`project.yml:5`). Liquid Glass via
`glassEffect(_:in:)` requiere iOS 26+ — sin fallback a iOS 18, lo cual
nos permite usar la API directamente.

---

## 2. Estructura de archivos final

```
ios/Tandas/DesignSystem/
├── Tokens/
│   ├── RuulColors.swift          # ColorScheme-aware via Color(.dynamic)
│   ├── RuulTypography.swift      # Font extension, fácil swap
│   ├── RuulSpacing.swift         # 4pt grid (space.0..space.12)
│   ├── RuulRadius.swift          # sm/md/lg/xl/pill/circle
│   ├── RuulElevation.swift       # ViewModifier por nivel
│   ├── RuulMotion.swift          # Animation extensions (snappy/smooth/...)
│   ├── RuulGlass.swift           # GlassMaterial + GlassContext enums
│   └── RuulHaptics.swift         # SensoryFeedback wrappers
├── Theme/
│   ├── RuulTheme.swift           # @MainActor environment provider
│   ├── ColorScheme+Ruul.swift    # accessibilityContrast helpers
│   └── EnvironmentValues+Ruul.swift  # @Environment(\.ruulTheme) etc.
├── Modifiers/
│   ├── GlassEffect+Ruul.swift    # rename de AdaptiveGlass.swift, mismo flujo
│   └── PressFeedback.swift       # scale 0.97 + opacity 0.9 en pressed
├── Primitives/
│   ├── RuulButton.swift
│   ├── RuulTextField.swift
│   ├── RuulOTPInput.swift
│   ├── RuulChip.swift
│   ├── RuulCard.swift
│   ├── RuulAvatar.swift
│   ├── RuulAvatarStack.swift
│   ├── RuulProgressBar.swift
│   ├── RuulSegmentedControl.swift
│   ├── RuulToggle.swift
│   ├── RuulPicker.swift
│   ├── RuulDatePicker.swift
│   ├── RuulSheet.swift
│   ├── RuulFullScreenCover.swift
│   ├── RuulToast.swift
│   ├── RuulMeshBackground.swift  # 3 variantes: cool/violet/aqua
│   └── RuulIconBadge.swift
├── Patterns/
│   ├── OnboardingStepContainer.swift
│   ├── EmptyStateView.swift
│   ├── LoadingStateView.swift
│   ├── ErrorStateView.swift
│   ├── MemberRowStub.swift
│   ├── EventCardStub.swift
│   ├── RSVPStateView.swift
│   ├── RuleCardStub.swift
│   └── FineCardStub.swift
├── Templates/
│   ├── OnboardingScreenTemplate.swift
│   ├── MainAppScreenTemplate.swift
│   ├── DetailScreenTemplate.swift
│   └── ModalSheetTemplate.swift
├── Showcase/                      # #if DEBUG only
│   ├── ShowcaseRootView.swift
│   ├── Sections/
│   │   ├── TokensShowcaseView.swift
│   │   ├── PrimitivesShowcaseView.swift
│   │   ├── PatternsShowcaseView.swift
│   │   └── TemplatesShowcaseView.swift
│   └── Components/
│       ├── ShowcaseSection.swift
│       ├── ShowcaseRow.swift
│       └── CodeSnippetView.swift
└── _Legacy/                       # marca temporal — borrar al migrar todo
    ├── Tokens.swift               # Brand enum (legacy, en uso por Features/)
    ├── Typography.swift           # tandaHero etc. (legacy)
    ├── AdaptiveGlass.swift        # MOVED a Modifiers/GlassEffect+Ruul.swift
    ├── MeshBackground.swift       # legacy, en uso por Features/
    └── Components/                # FIeld, GlassCard, etc. — legacy
```

**Nota sobre `_Legacy/`**: subfolder explícito para señalizar que ESOS
archivos no son parte del DS V1. Las features siguen importándolos
hasta su migración. Cuando todas las features se migren, borramos
`_Legacy/` en un PR limpio.

```
ios/TandasTests/
├── ... (tests existentes intactos)
└── DesignSystem/
    ├── TokenAccessibilityTests.swift   # contraste WCAG AA en light/dark/HC
    ├── ColorSchemeTests.swift          # paleta resuelve correctamente
    ├── Primitives/
    │   ├── RuulButtonSnapshotTests.swift
    │   ├── RuulTextFieldSnapshotTests.swift
    │   └── ... (uno por primitivo)
    └── __Snapshots__/
        ├── RuulButtonSnapshotTests/
        │   ├── primary_light.png
        │   ├── primary_dark.png
        │   ├── primary_highContrast.png
        │   └── ...
        └── ...
```

```
Plans/
└── DesignSystemV1.md              # este archivo
```

---

## 3. Capas — orden de implementación y dependencias

### Capa 1 — Tokens (sin dependencias entre sí, salvo Glass usa Colors)

Orden:
1. `RuulColors.swift` — primero porque todo lo demás lo consume.
2. `RuulTypography.swift`
3. `RuulSpacing.swift`
4. `RuulRadius.swift`
5. `RuulMotion.swift`
6. `RuulHaptics.swift`
7. `RuulElevation.swift` — usa Colors (shadows tienen tint).
8. `RuulGlass.swift` — usa Colors.
9. `Theme/` — el environment + helpers, depende de todos los tokens.
10. `Modifiers/` — `GlassEffect+Ruul` (mover de `AdaptiveGlass.swift`),
    `PressFeedback`.

**Tests de capa 1**:
- `TokenAccessibilityTests`: contraste mínimo WCAG AA (4.5:1 body,
  3:1 large text) entre `text.primary`/`text.secondary` y los 3 fondos
  (canvas/elevated/recessed) en light, dark, highContrast.
- `ColorSchemeTests`: cada token semántico resuelve a algo no-nil en los
  3 modos.

### Capa 2 — Primitivos

**MVP estricto** (necesarios para próximo prompt de Onboarding):
1. `RuulButton`
2. `RuulTextField`
3. `RuulOTPInput`
4. `RuulCard`
5. `RuulProgressBar`
6. `RuulMeshBackground`
7. `RuulIconBadge`
8. `RuulToast`
9. `RuulSheet`

**Diferibles** (no bloquean V1, pero el prompt los pide — los
implementamos para cumplir el contrato):
10. `RuulAvatar` + `RuulAvatarStack`
11. `RuulChip`
12. `RuulSegmentedControl`
13. `RuulToggle`
14. `RuulPicker`
15. `RuulDatePicker`
16. `RuulFullScreenCover`

**Tests por primitivo**: snapshot por variante × (light, dark,
highContrast). Estimado: ~80-120 snapshots totales.

### Capa 3 — Patterns

Solo los necesarios para que el showcase tenga algo que mostrar y
para validar que los primitivos componen bien:
1. `EmptyStateView` — usa Card + IconBadge + Button.
2. `LoadingStateView` — skeleton shimmer.
3. `ErrorStateView` — Card + IconBadge + Button.
4. `OnboardingStepContainer` — el más usado por el siguiente prompt.
5. `MemberRowStub` — valida Avatar + tipografía + spacing.
6. `EventCardStub` — valida Card + AvatarStack + Chip.
7. `RSVPStateView` — valida estados + transición glass-morph.
8. `RuleCardStub` — valida Card + Toggle + TextField.
9. `FineCardStub` — valida Card + estado + acción.

**Cada pattern** recibe un `*Data` struct genérico (e.g.
`MemberRowData { name, subtitle, avatarURL, metaText }`). NO importa
modelos de producto.

**Tests de patterns**: snapshot de cada uno con datos mock realistas en
light/dark/HC.

### Capa 4 — Templates

Los 4 que pide el brief. Cada template es un `View` que recibe
`@ViewBuilder content:` y opciones (e.g.
`OnboardingScreenTemplate(progress, ctaTitle, onContinue, content)`).

**Tests de templates**: snapshot con un placeholder content
(`Color.gray`) para verificar layout/spacing solamente.

---

## 4. Showcase app — contenido por sección

`#if DEBUG`, accesible vía shake gesture global cuando el debug build
está corriendo.

### TokensShowcaseView
- **Colors**: grid con un swatch por token (canvas, elevated, recessed,
  glass.thin/regular/thick, accent, semantic.success/warning/error,
  text.primary/secondary/tertiary, borders, shadows). Tap → copia el
  nombre del token al clipboard.
- **Typography**: cada token renderizado con "The quick brown fox"
  + nombre + tamaño/peso/letterSpacing.
- **Spacing**: barras horizontales de cada espacio numerado.
- **Radius**: cards con cada radio aplicado.
- **Elevation**: 4 cards lado a lado mostrando none/sm/md/lg/glass.
- **Motion**: botón "tap to preview" que dispara cada spring/duration.
- **Haptics**: lista con cada tipo, tap los dispara.
- Toggle floating: Light / Dark / High Contrast (sobreescribe
  `colorScheme` y `accessibilityContrast` en el preview).

### PrimitivesShowcaseView
Un row por primitivo, cada row muestra todas las variantes/estados
horizontales o en grid. Cada row tiene botón "copy code" con
ejemplo de uso.

### PatternsShowcaseView
Cada pattern instanciado con 2-3 sets de mock data.

### TemplatesShowcaseView
Cada template con placeholder content (gris) y un overlay que muestra
la zona de safe area.

---

## 5. Tipo de tests por capa

| Capa | Tipo | Herramienta | Cantidad estimada |
|------|------|-------------|-------------------|
| Tokens | Lógica + accessibility | swift-testing | ~10 tests |
| Primitives | Snapshot | SnapshotTesting | ~80-120 snapshots |
| Patterns | Snapshot | SnapshotTesting | ~30 snapshots |
| Templates | Snapshot (layout) | SnapshotTesting | ~12 snapshots |
| Theme/Modifiers | Lógica | swift-testing | ~5 tests |

**Snapshot strategy**:
- Renderizar a `.image(layout: .device(config: .iPhone17Pro))`.
- Cada componente: 1 snapshot por variante × por modo (light/dark/HC).
- Si una variante depende de tamaño dinámico de texto, snapshot a
  default + xxxLarge.
- **NO** snapshot screens completas hasta que migremos features.

---

## 6. Hooks de extensión — cómo el resto del app consume el DS

### Theming
`TandasApp.swift` envuelve `WindowGroup` con `RuulTheme`:
```swift
WindowGroup {
    AuthGate()
        .environment(appState)
        .ruulTheme()                           // <- nuevo
}
```
Eliminamos `.preferredColorScheme(.dark)` (sistema decide).

### Tokens
Cualquier vista accede vía:
```swift
@Environment(\.ruulColors) var colors
Text("Hola").foregroundStyle(colors.text.primary)
```
o vía extension estática en color/font:
```swift
Text("Hola")
    .font(.ruulBodyLarge)
    .foregroundStyle(.ruulTextPrimary)
```
Las extensions estáticas resuelven internamente al colorScheme del env.

### Primitivos
```swift
RuulButton("Continuar", style: .primary, size: .large) { submit() }
RuulCard(.glass) { Text("Hola") }
```

### Migración de features (NO en este PR, aquí para referencia)
Cuando migremos `LoginView`, reemplazamos:
```swift
GlassCapsuleButton("Enviar") { ... }            // viejo
RuulButton("Enviar", style: .primary) { ... }   // nuevo
```
Y luego, cuando el último consumer sale de `_Legacy/`, borramos toda la
carpeta en un PR de cleanup.

---

## 7. Riesgos y decisiones a confirmar

### 7.1 Cambio de `.preferredColorScheme(.dark)` global
**Riesgo**: La app actual fue diseñada solo para dark. Si las vistas
existentes no lucen bien en light (cosa probable), light mode se ve
roto hasta que se migren.

**Mitigación opciones**:
- (A) **Recomendada**: Mantener `.preferredColorScheme(.dark)` en
  `TandasApp.swift` durante V1. El DS soporta los 3 modos
  internamente, pero el app sigue forzando dark hasta que TODAS las
  features estén migradas. El showcase desactiva el override para
  poder probar light.
- (B) Quitar el override y aceptar que features no migradas se vean
  feas en light por unos días.

→ **Voy con (A)** salvo que digas lo contrario.

### 7.2 Paleta nueva vs. mesh actual
La paleta nueva tiene un accent `#5B6CFF` (azul-violeta). El mesh
actual es violeta-rosa muy distinto. Las features actuales asumen
`Brand.accent = #9C7BF4` para tints en glass effects.

**Decisión**: el `Brand.accent` viejo se queda en `_Legacy/Tokens.swift`
para no romper features existentes. El nuevo `RuulColors.accent.primary`
es independiente. Cuando la feature migre, cambia el color.

### 7.3 Rebrand "Tandas" → "ruul" en código
- Bundle id ya es `com.josejmizrahi.ruul` — ✅ hecho.
- Target Xcode aún se llama `Tandas` — **NO** lo tocamos en V1
  (alto blast radius en xcodegen, signing, CI).
- Tokens nuevos usan prefix `Ruul*` (no `Tanda*`).
- Wordmark visible en `LoginView` aún dice "Ruul" mayúscula — se
  cambia cuando migremos esa view.

### 7.4 `GlassEffectContainer` para perf
El brief dice "Wrap múltiples glass surfaces en GlassEffectContainer".
El código actual no lo hace. Lo agregamos en patterns que muestran
varios glass juntos (ej. `RuulAvatarStack`, `RSVPStateView`).

### 7.5 SnapshotTesting determinismo
Snapshot testing puede ser flaky entre máquinas (renderizado de
texto, anti-aliasing). Mitigación:
- Usar `.iPhone17Pro` config fijo.
- Generar snapshots desde simulador en CI (no localmente).
- Fallar tests si el simulador no es el esperado.
- Tolerancia de pixel diff: 0% inicial; si genera fricción, subir a
  ~0.5% con justificación.

---

## 8. Plan de ejecución (commits sugeridos)

Si apruebas, lo hago en commits chicos para que sea revisable:

1. **`ds: setup folder structure + move legacy to _Legacy/`**
   Mover `Tokens.swift`, `Typography.swift`, `AdaptiveGlass.swift`,
   `MeshBackground.swift`, `Components/*` a `DesignSystem/_Legacy/`.
   Actualizar imports en features. Tests siguen pasando.

2. **`ds: tokens (colors, typography, spacing, radius)`**
   Agregar los 4 token files básicos + tests de accessibility.

3. **`ds: tokens (motion, haptics, elevation, glass) + theme`**
   Resto de tokens + `RuulTheme` environment.

4. **`ds: modifiers (GlassEffect, PressFeedback)`**
   Mover `AdaptiveGlass` a `Modifiers/GlassEffect+Ruul.swift` con
   API nueva. Legacy file se mantiene como shim para features.

5. **`ds: primitives MVP (Button, TextField, OTPInput, Card, ProgressBar)`**
   + snapshots.

6. **`ds: primitives MVP cont. (MeshBackground, IconBadge, Toast, Sheet)`**
   + snapshots.

7. **`ds: primitives diferibles (Avatar, AvatarStack, Chip, ...)`**
   + snapshots.

8. **`ds: patterns (Empty, Loading, Error, OnboardingStepContainer)`**
   + snapshots.

9. **`ds: patterns (MemberRowStub, EventCardStub, RSVPStateView, RuleCardStub, FineCardStub)`**
   + snapshots.

10. **`ds: templates (4 templates) + snapshots`**

11. **`ds: showcase view (debug-only) + shake gesture`**

12. **`ds: integrate RuulTheme in TandasApp + smoke test build`**
    Conectar el theme. Verificar que la app sigue corriendo en
    simulador. Sin cambios visuales (legacy sigue forzando dark).

Total: ~12 commits, cada uno verde (compila + tests pasan).

Después del último commit, push a la rama y stop. El siguiente prompt
(Onboarding) tomará el DS y lo usará.

---

## 9. Checklist DoD del PR final

- [ ] `make -C ios test` pasa en simulador iPhone 17 Pro / iOS 26.
- [ ] `make -C ios build` sin warnings nuevos.
- [ ] Strict concurrency: 0 warnings (Swift 6 mode).
- [ ] Cada primitivo tiene `#Preview` que muestra todas las variantes.
- [ ] Cada primitivo tiene snapshot tests (light + dark + HC).
- [ ] Showcase abre en debug build, no compila en release.
- [ ] Ningún archivo en `DesignSystem/` (excepto `_Legacy/`) importa
      tipos de `Models/` o `Supabase/`.
- [ ] `TandasApp.swift` aplica `.ruulTheme()` (mantiene `.dark` global
      por ahora).
- [ ] Plan está commiteado en `Plans/DesignSystemV1.md`.

---

## 10. Lo que viene después de este PR (para tu referencia)

Prompts futuros que consumen este DS:
- **Prompt 2 — Onboarding**: migrar `LoginView`, `OTPInputView`,
  `OnboardingView` al DS nuevo. Wordmark "ruul" minúscula. Quitar el
  `.preferredColorScheme(.dark)` global.
- **Prompt 3 — Welcome + Groups list**: migrar `WelcomeView`,
  `GroupsListView`, `WalletGroupCard` (eliminar y reemplazar por
  pattern compuesto del DS).
- **Prompt 4 — Group summary + create group wizard**: migrar
  `NewGroupWizard`, `GroupSummaryView`.
- **Prompt 5 — Cleanup**: borrar `_Legacy/` cuando todas las features
  estén migradas. Borrar `Brand`, `tandaHero`, etc.

---

**Espero tu review antes de implementar.** Si algo del plan no cuadra,
dime qué cambiar y vuelvo con plan v2.
