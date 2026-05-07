# DS v3.0 Migration Plan

> Fecha: 2026-05-07
> Origen: `docs/DesignSystem.md` v3.0.0 (autoritativo)
> Estado: PROPUESTA — partido en lo additive (Sprint 1) vs arquitectónico (Sprints 2-N)

---

## 0. Diff v2 → v3

v3 mantiene la misma arquitectura multi-group de v2. Lo que agrega:

1. **§2 Arquitectura SPM 3 packages**: `RuulCore` / `RuulUI` / `RuulFeatures`. Hoy es un único Xcode project con folders. Refactor mayor.
2. **§11 SwiftUI best practices iOS 26**: `@Observable` (✓ tenemos), `@Bindable`, `@State`-vs-`ObservableObject`, `#Preview` macros, env values custom.
3. **§12 Swift 6 strict concurrency**: `@MainActor` en coordinators (✓ tenemos), `Sendable` en models, typed throws.
4. **§13 Liquid Glass APIs nativas iOS 26**: `.glassBackground()` / `.glassMaterial()` en lugar de `.background(.regularMaterial)`.
5. **§17 Testing visual**: snapshots, accessibility audits, light/dark/AX5.
6. **§18 Migration plan**: 5 días para migrar coordinators ObservableObject → @Observable, activar strict concurrency, update Liquid Glass APIs.
7. **Token cambio**: `RuulSpacing.tabBarBottomSafeArea` 80 → 100.
8. **Token nuevo**: `Font.ruulGroupLabel` (caption medium) — ya estaba en v2.

Arquitectura **multi-group sigue igual que v2** (Inicio/Grupo/Historial/Ajustes). Eso queda como migration mayor separada.

---

## 1. Sprints

### Sprint 1 — v3 additive low-risk (HOY)
**Objetivo**: aplicar lo que NO requiere arquitectura, sin breaking.

- Bump `RuulSpacing.tabBarBottomSafeArea` 80 → 100
- Auditar componentes y agregar `#Preview` macros donde falten
- Auditar models y conformar a `Sendable` donde falte
- Verificar Liquid Glass: si SwiftUI iOS 26 expone `.glassBackground()` nativamente, hacer el swap selectivo en chrome surfaces (tab bar, sheets, switcher). Si no existe, mantener `.regularMaterial` con TODO.
- Validar coordinators: todos usan `@Observable + @MainActor`. Sí lo hacen post-Fase E (verificable con grep).

**Salida**: build verde, app idéntica funcionalmente, sutiles mejoras visuales si glass APIs nativas existen.

### Sprint 2 — v3 SPM packages (FUTURO, GRANDE)
**Objetivo**: split del proyecto en `RuulCore` / `RuulUI` / `RuulFeatures` packages.

- Crear `Packages/RuulCore` (Models, Repositories, Services, Extensions)
- Crear `Packages/RuulUI` (Tokens, Components, Modifiers — cero deps externas)
- Crear `Packages/RuulFeatures` (Home, Group, History, Settings)
- App target consume los 3 packages
- Mover archivos respetando boundaries
- Activar Package.resolved
- xcodegen update para reflejar la estructura

**Esfuerzo**: 1-2 sesiones cada package = 3-6 sesiones total.
**Riesgo**: alto si hay deps cíclicas. Requiere análisis previo.

### Sprint 3 — v3 multi-group arquitectura (FUTURO, ENORME)
**Objetivo**: aplicar arquitectura v2/v3 (Inicio cross-grupos / Grupo / Historial / Ajustes).

Igual al plan delineado para v2 (Plans/Phase0-DSv2-Migration sería este). Ya escrito conceptualmente. Multi-week.

### Sprint 4 — v3 testing visual (FUTURO)
**Objetivo**: snapshots, audit AX5, light/dark testing.

- Setup snapshot testing framework
- Snapshots de componentes core
- Accessibility audit con Xcode Accessibility Inspector
- Visual regression pipeline

---

## 2. Lo que YA está alineado con v3

Verificable en el código actual (post Fases A-E):

- ✅ `@Observable @MainActor` en todos los coordinators (Sprint 2 anterior)
- ✅ `RuulSpacing.xxs..xxxl` + semantic aliases (Fase A)
- ✅ `Font.ruul*` con money tabular digits (Fase A)
- ✅ `Color.ruulBackground/Surface/Positive/Negative/...` canonical (Fase E)
- ✅ `RuulRadius.small/medium/large/extraLarge` (Fase E)
- ✅ `Animation.ruulSnappy/ruulSmooth/ruulTap/ruulStateChange/...` (Fase A)
- ✅ `RuulHaptic` con `.light/.medium/.success/.warning/.error/.selection` (legacy)
- ✅ `RuulCard / RuulButton / RuulPillButton / RuulHeaderActions / RuulSectionHeader / RuulMoneyView / RuulInlineMessage / RuulLoadingState / RuulBadge` (Fase A)
- ✅ `EmptyStateView / ErrorStateView / RuulLoadingState` patterns (Fases A/B)
- ✅ Swift 6 strict concurrency activado en proyecto

## 3. Lo que falta para v3 fully-aligned

- ✅ `tabBarBottomSafeArea` 80 → 100 (Sprint 1, 2026-05-07)
- ⏳ `RuulHaptic.groupSwitch` semantic case (parte de v2 architecture)
- ⏳ `Animation.ruulGroupSwitch` (parte de v2 architecture)
- ⏳ `GroupCategory` + `GroupColorRamp` (parte de v2 architecture, requires backend migration)
- ⏳ `RuulGroupAvatar / RuulGroupSwitcher / RuulGroupSwitcherSheet / RuulSubTabBar / RuulOriginTag` (parte de v2 architecture)
- ⏳ `RuulPersonAvatar` rename de `RuulAvatar` (parte de v2 architecture)
- ✅ Liquid Glass APIs nativas (Sprint 3 Fase 5 fix 2026-05-07: `.glassEffect()` SÍ existe en iOS 26 SDK; wrapper `.ruulGlass(shape:)` ya estaba en DesignSystem/Modifiers/GlassEffect+Ruul.swift. Aplicado en RuulPillButton, RuulHeaderActions, RuulGroupSwitcher chrome surfaces. Audit inicial Sprint 1 fue erróneo — buscó nombres viejos `glassBackground`/`glassMaterial` que no existen, en lugar de `glassEffect` que sí.)
- ⏳ Tab restructure Inicio/Grupo/Historial/Ajustes (Sprint 3)
- ⏳ SPM 3 packages split (Sprint 2)
- ⏳ Snapshot testing (Sprint 4)
- ⏳ `#Preview` macros completos en componentes (Sprint 1 audit: solo falta en `RuulStatePatterns+Aliases.swift` — file de aliases puros, no necesita preview. Resto de DS Primitives/Patterns conformes.)
- ✅ `Sendable` en models (Sprint 1 audit 2026-05-07: 100% de structs en `Models/` y `Platform/Models/` ya conforman `Sendable`. Sin acción necesaria.)
- ✅ `@Observable @MainActor` coordinators (Sprint 1 audit 2026-05-07: cero usos de `ObservableObject`/`@Published` en `Features/`. Migración completa.)

---

## 4. Sequencing recomendado

```
Sprint 1 (additive, hoy)
  ↓
[validar en device]
  ↓
Sprint 3 (multi-group arch — most user-visible)
  ↓
Sprint 2 (SPM packages — refactor invisible)
  ↓
Sprint 4 (testing visual — quality net)
```

Sprint 2 (SPM split) puede hacerse paralelo a Sprint 3 pero introduce riesgo de merge conflicts. Mejor secuencial.

---

## 5. Sprint 1 — alcance concreto HOY

### 5.1 `tabBarBottomSafeArea` 80 → 100

```swift
// RuulSpacing+DSAliases.swift
public static let tabBarBottomSafeArea: CGFloat = 100
```

Buscar callsites con `.padding(.bottom, RuulSpacing.tabBarBottomSafeArea)` para confirmar que el cambio aplica. Si nadie lo usa todavía, agregar a HomeView/MyFinesView footer padding.

### 5.2 Liquid Glass APIs check

Verificar si SwiftUI iOS 26 expone `.glassBackground()` y `.glassMaterial()` como modifiers nativos. Si sí, swap en:
- `RuulPillButton` — `.background(Circle().fill(.regularMaterial))` → `.background(Circle().fill(...))` con glass
- `RuulHeaderActions` — `.background(Capsule().fill(.regularMaterial))` → glass capsule
- `RuulTabBar` (no usado actualmente, pero el código existe)
- `GroupContextHeader` — `.fill(.regularMaterial)` → glass

Si los modifiers NO existen, dejar `.regularMaterial` con comentario `// TODO v3 §13: usar .glassBackground() cuando SwiftUI lo exponga`.

### 5.3 `Sendable` audit

```bash
grep -rn "struct.*: Codable\|public struct" ios/Tandas/Platform/Models/ | head
```

Verificar models. Si una struct no conforma a `Sendable`, agregarlo (debería ser automático para structs de value types, pero hay que confirmar).

### 5.4 `#Preview` audit

```bash
grep -L "#Preview" ios/Tandas/DesignSystem/Primitives/Ruul*.swift
```

Listar componentes sin `#Preview`. Agregar previews mínimos para cada uno.

### 5.5 Migration plan doc

(Este archivo)

---

## 6. Definition of Done — Sprint 1

- [ ] `tabBarBottomSafeArea` actualizado
- [ ] Liquid Glass APIs natives evaluadas (swap si existen, TODO si no)
- [ ] Models sin `Sendable` identificados (lista)
- [ ] Componentes sin `#Preview` identificados (lista)
- [ ] Build limpio
- [ ] Smoke en simulador
- [ ] Commit

---

## 7. Estado de implementación

- [ ] Sprint 1: v3 additive low-risk
- [ ] Sprint 2: SPM packages split
- [ ] Sprint 3: Multi-group arquitectura (Inicio/Grupo/Historial/Ajustes)
- [ ] Sprint 4: Testing visual
