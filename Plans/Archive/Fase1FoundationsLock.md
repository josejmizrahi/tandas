# FASE 1 — Foundations Lock (PR-01)

Estado: **ACTIVO** desde 2026-05-24.
Doctrina superior: `FASE 1 native refactor doctrine` (memoria),
`feedback_dont_touch_ruului_base` (memoria), `Fase1NativeAudit.md`.

## Qué congela este documento

Una sola fuente de verdad para los tokens base. Cero hex hardcoded en
feature layer. Cero familias de fuente custom. Cero código muerto en
RuulUI/Tokens.

Después de este PR, **agregar un nuevo token al feature layer está
prohibido sin pasar antes por aquí**. Si una pantalla "necesita" un
color nuevo, casi siempre es señal de que se está usando el sitio
equivocado del HIG (ej. usando un border en vez de un Section
separator).

## Lo que cambió en PR-01

### `RuulColors.swift` — recortado 432 → ~140 líneas

**Borrado (código muerto, 0 call-sites fuera del archivo):**
- `public struct RuulColors` env-injected (33 props)
- `RuulColors.default`
- `private enum Hex` (108 líneas de constantes light/dark/HC light + 3
  arrays meshCool/meshViolet/meshAqua)
- `Color.ruulDynamic(...)` y `Color.ruulDynamicAlpha(...)`
- `private extension UIColor { init(rgb:alpha:) }`
- `Color.init(hex: UInt32, alpha: Double)` (0 call-sites)

**Reescrito (los 4 que aún apuntaban a `RuulColors.default`):**
- `ruulTextPrimary`   → `Color(.label)`
- `ruulTextSecondary` → `Color(.secondaryLabel)`
- `ruulTextTertiary`  → `Color(.tertiaryLabel)`
- `ruulSemanticSuccess/Warning/Error/Info` → `Color(.systemGreen/.systemOrange/.systemRed/.systemBlue)`

**Mantenido (407 call-sites — ya bridgeados a system):**
- Backgrounds, surface-glass tints, accent, borders, overlay, on-image,
  fill-glass — todos siguen con su firma pública.
- `Color.init(hex: UInt32)` (lo usan `RuulCoverCatalog` + `GroupColorRamp`).

### `RuulSpacing.swift` — deprecation de `s0…s12`

Las 13 constantes numéricas (`s1 = 4`, `s2 = 8`, …) ahora tienen
`@available(*, deprecated, message: "Use semantic alias…")`. Generan
warning pero no rompen el build. Wave 1 PR #4 las migra a aliases
semánticos (`xs/sm/md/lg/xl/xxl/xxxl`).

`s0_5`, `micro` y `minTouchTarget` se mantienen sin deprecation (usos
puntuales no migrables a la escala 4-pt).

### Lefthook — guard `no-hex-colors`

Pre-commit verifica que ningún archivo en `Packages/RuulFeatures/**/*.swift`
introduzca:
- `Color(red: …, green: …, blue: …)`
- `Color(hex: …)`
- `UIColor(red: …, green: …, blue: …)`
- Literales `0x[0-9A-Fa-f]{6}` (hex en código)

Permitido en `Packages/RuulUI/**` y `Packages/RuulCore/**/GroupColorRamp.swift`.

## Reglas de uso para feature layer

### Colores

| Quieres… | Usa esto | NO uses |
|---|---|---|
| Page background | `Color(.systemBackground)` | hex, `.white`, `Color.ruulBackgroundCanvas` (legacy ok pero no preferred) |
| Row fill en List | `Color(.secondarySystemBackground)` | hex |
| Backdrop de List agrupada | `Color(.systemGroupedBackground)` | hex |
| Texto primario | `.primary` | `Color.black`, hex |
| Texto secundario | `.secondary` | `Color.gray`, hex |
| Texto terciario | `Color(.tertiaryLabel)` | hex |
| Tint de affordance primaria | `.accentColor` (o `.tint(.accentColor)` en root) | hex, `.blue`, brand-specific |
| Separator | `Color(.separator)` | hex, custom border |
| Success/Warning/Error/Info | `Color(.systemGreen/Orange/Red/Blue)` | hex |
| Texto sobre imagen | `Color.ruulOnImage` (white) / `Color.ruulOnImageSecondary` | hex |
| Glass material | `.glassEffect()` | hex con opacity |

### Tipografía

| Quieres… | Usa esto | NO uses |
|---|---|---|
| Cualquier texto | `Font.system(...)` o atajos (`.headline`, `.body`, `.caption`) | `Font.custom("Inter…", …)` |
| Peso | `.fontWeight(.semibold)` | `Font.custom("Inter-SemiBold", …)` |
| Monospaced digits (números) | `.monospacedDigit()` | font custom |

PR-02 limpia los call-sites a Inter.

### Spacing

| Quieres… | Usa esto | NO uses |
|---|---|---|
| Pad interno de card / row | `RuulSpacing.md` (16) | `RuulSpacing.s4` (deprecated) |
| Margen horizontal de screen | `RuulSpacing.screenPadding` (20) | `.padding(.horizontal, 20)` literal |
| Gap entre items en list | `RuulSpacing.itemGap` (12) | literal 12 |
| Gap entre secciones | `RuulSpacing.sectionGap` (32) | literal |
| Literal 4-pt | `RuulSpacing.xxs` | literal 4 |

PR-04 migra los 103 sites de `s\d+` a aliases semánticos.

### Radius

Sin cambios. `RuulRadius.{sm,md,lg,xl,pill,circle}` ya es semántico.

### Haptic

Sin cambios. `RuulHaptic.*` ya es semántico y mapea a `SensoryFeedback`
nativo via `.sensoryFeedback(_:trigger:)`.

### Glass

`.glassEffect()` directamente. `GlassMaterial` y `GlassContext` enums
existen para tunear cuando se necesite. No usar más glass como "card
chrome universal" — ver `Fase1AntiPatternAudit.md`.

## Lo que NO toca PR-01

- **Inter → SF migration**: PR-02 (mecánico, ~1,200 sites). Inter sigue
  registrado en `project.yml` / `Info.plist` hasta PR-02 termine.
- **`RuulSpacing.s\d+` migration**: warnings ya, migración en PR-04.
- **Borrar `RuulCard`, `RuulSheet`, etc.**: Wave 2 (PRs #6-12).
- **Mesh gradients**: las constantes (meshCool/Violet/Aqua) ya cayeron
  con la struct muerta. Si alguna pantalla todavía las necesita
  (`RuulMeshBackground`), agregar el array hex inline ahí mismo o
  migrar a `.glassEffect()` / fondo plano según
  `Fase1AntiPatternAudit.md`.

## Verificación post-merge

1. `BuildProject` verde (todos los call-sites siguen compilando).
2. `RuulSpacing.s\d+` genera warnings — esperado, los limpia PR-04.
3. Lefthook bloquea un PR de prueba con `Color(hex: 0xFF0000)` en
   feature layer.
4. Dark mode + High Contrast pasan visual smoke en simulator.

## Próximos pasos (orden)

- **PR-02** Inter → SF migration. Mecánico.
- **PR-03** Reemplazar literales de color sobrevivientes (si los hay)
  con `Color.ruul*` o system. Catch-all.
- **PR-04** `RuulSpacing.s\d+` → semantic aliases (103 sites).
- **PR-05** "Primitives Canon" doc (planning, no código).
- **PR-06+** Wave 2 deletions (RuulCard, RuulSheet, RuulTabBar, RuulToast…).
