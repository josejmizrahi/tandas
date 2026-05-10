# SPM 3-Package Split — DS v3 Sprint 2

> Fecha: 2026-05-07
> Origen: `docs/DesignSystem.md` v3.0.0 §2 + `Plans/Active/Phase0-DSv3-Migration-2026-05-07.md` §1 Sprint 2.
> Estado: PLAN — análisis hecho, ejecución multi-sesión.

---

## 0. Goal

Split del project mono-target `Tandas` en 3 SPM packages + app shell:

```
ios/
├── Packages/
│   ├── RuulCore/          # Models, Repositories, Services, Utilities (Foundation/SwiftData/Supabase)
│   ├── RuulUI/            # Tokens, Modifiers, Primitives, Patterns, Templates (SwiftUI; depends on RuulCore para domain-coupled components)
│   └── RuulFeatures/      # Features/, Templates/ (depends on RuulCore + RuulUI)
└── Tandas/                # App target ultra-thin (TandasApp.swift + Shell/AuthGate.swift + Resources/)
```

**Beneficios**: build incremental más rápido, separation of concerns explícito (compiler-enforced), reusabilidad (RuulUI puede servir otros apps), test isolation por package.

**Razón v3**: DS doc §2.1 — "Cada package compila como módulo independiente. Cuando agregás un primitive nuevo, solo el package RuulUI recompila."

---

## 1. Análisis de deps (verificado 2026-05-07)

### 1.1 File counts

| Package candidato | Origen actual | Files |
|---|---|---|
| **RuulCore** | `Models/` + `Platform/Models/` + `Platform/Repositories/` + `Supabase/` + `Services/` + `Platform/Services/` + `Platform/Coordinators/` + `Utilities/` | **98** |
| **RuulUI** | `DesignSystem/Tokens/` + `Modifiers/` + `Primitives/` + `Patterns/` + `Templates/` + `Components/` + `Theme/` | **80** |
| **RuulFeatures** | `Features/` + `Templates/` | **113** |
| **App** | `Shell/` + `TandasApp.swift` + `Resources/` | **3** + Resources |

### 1.2 Dep graph (verificado por `grep -rln`)

```
TandasApp / Shell
    └── RuulFeatures
            ├── RuulUI
            │     └── RuulCore  (Group/Profile/Event refs en RuulGroupSwitcher, RuulGroupAvatar, RSVPStateView, EventCardStub, ErrorStateView+CoordinatorError, etc.)
            └── RuulCore
RuulUI ─────────────────┐
RuulCore  (no upward deps; Models import solo Foundation + SwiftData)
```

**Cero ciclos detectados:**
- `Platform/` no importa `Features/` ✓
- `Models/` no importa `Platform/Repositories/` ni `Features/` ✓
- `DesignSystem/` no importa `Features/` ni `Platform/` ✓
- `DesignSystem/Tokens/` importa solo Foundation/SwiftUI/CoreGraphics/UIKit ✓

### 1.3 DS↔Domain coupling (componentes que requerirán `RuulUI → RuulCore`)

Verificado por grep de tipos `Group|Profile|MemberWithProfile|Event|Fine|Rule|Vote`:

| File | Tipo coupling |
|---|---|
| `Primitives/RuulGroupSwitcher.swift` | usa `Group` |
| `Primitives/RuulGroupComponents+Group.swift` | usa `Group` |
| `Primitives/RuulGroupAvatar.swift` | usa `Group` |
| `Patterns/RSVPStateView.swift` | usa `Event`, `RSVPStatus` |
| `Patterns/EventCardStub.swift` | usa `Event` |
| `Patterns/ErrorStateView+CoordinatorError.swift` | usa `CoordinatorError` |
| `Tokens/GroupColorRamp.swift` | usa `GroupCategory` |

→ **RuulUI debe declarar `dependencies: [.product(name: "RuulCore", ...)]`** en su Package.swift.

### 1.4 External deps por package

| Package | External deps |
|---|---|
| RuulCore | `Supabase`, `Sentry` (algunos servicios) |
| RuulUI | (ninguna externa — solo system frameworks) |
| RuulFeatures | hereda `Supabase`, `Sentry` vía RuulCore |

---

## 2. Estrategia de migración: leaf-first incremental

**Principio**: cada step deja el árbol verde (build + tests). Si algo se rompe, rollback es 1 step atrás.

**Anti-principio**: NO big-bang. Big bang implica decenas de errores simultáneos de access-control + imports faltantes que no se pueden debuggear linealmente.

### 2.1 Order: leaves primero (cero deps internas)

1. **RuulCore** primero — está abajo en el grafo, no depende de nada interno.
2. **RuulUI** después — depende de RuulCore (que ya existe como package).
3. **RuulFeatures** al final — depende de RuulCore + RuulUI.

Dentro de cada package, sub-orden interno:
- `Models/` → `Repositories/` → `Services/` → `Coordinators/` (RuulCore)
- `Tokens/` → `Modifiers/` → `Primitives/` → `Patterns/` → `Templates/` (RuulUI)

### 2.2 Per-step protocol

Cada step:

```
1. Crear/extender Package.swift target.
2. Mover N files físicamente (`git mv`).
3. Convertir `internal` → `public` en APIs que cruzan el boundary (ojo: solo lo que use el código de afuera).
4. Agregar `import RuulCore` / `import RuulUI` a los consumers.
5. Update `ios/project.yml` para que el app target dependa del nuevo package.
6. `xcodegen` para regenerar `.xcodeproj`.
7. `make build` + `xcodebuild test -only-testing:TandasTests/PrimitiveSnapshotTests` (snapshot net protege).
8. Commit con mensaje `refactor(spm): RuulCore phase N — moved <X>`.
9. Si rompe: `git reset --hard HEAD~1` y rethink.
```

---

## 3. Sprint 2.1 — RuulCore (3 sesiones estimadas)

### Sesión 2.1a — Crear package + mover Models (~1h)

**Goal**: Package.swift declarado, `Models/` movido, app target consume RuulCore.

**Pasos:**

1. Crear `ios/Packages/RuulCore/Package.swift`:
   ```swift
   // swift-tools-version: 6.0
   import PackageDescription

   let package = Package(
       name: "RuulCore",
       platforms: [.iOS(.v26)],
       products: [.library(name: "RuulCore", targets: ["RuulCore"])],
       dependencies: [
           .package(url: "https://github.com/supabase/supabase-swift", from: "2.20.0")
       ],
       targets: [
           .target(
               name: "RuulCore",
               dependencies: [.product(name: "Supabase", package: "supabase-swift")],
               path: "Sources/RuulCore",
               swiftSettings: [.swiftLanguageMode(.v6)]
           ),
           .testTarget(name: "RuulCoreTests", dependencies: ["RuulCore"], path: "Tests/RuulCoreTests")
       ]
   )
   ```

2. `git mv ios/Tandas/Models ios/Packages/RuulCore/Sources/RuulCore/Models`
3. `git mv ios/Tandas/Platform/Models ios/Packages/RuulCore/Sources/RuulCore/PlatformModels`
4. Audit access: `Models/*.swift` y `Platform/Models/*.swift` → todo `struct` → `public struct` + `public init` + `public var`. Lista canónica de tipos (~58 + 30 files):
   - `Group`, `Member`, `Profile`, `MemberWithProfile`, `Event`, `Rule`, `Vote`, `Fine`, etc.
   - Cada `Codable` conformance ya hace los `let` Decodable; el `public` es el cambio crítico.
5. Update `ios/project.yml`:
   ```yaml
   packages:
     RuulCore:
       path: Packages/RuulCore
   targets:
     Tandas:
       dependencies:
         - package: RuulCore
   ```
6. `xcodegen`
7. Add `import RuulCore` a TODOS los consumers de `Group`, `Member`, `Event`, etc. Approx 200+ files. Helper:
   ```bash
   grep -rln "Group\b\|Profile\b\|Member\b\|Event\b\|Rule\b\|Vote\b\|Fine\b" ios/Tandas/ | xargs -I{} sh -c 'grep -L "import RuulCore" {} && head -3 {}'
   ```
   Alternativa: en cada file que use estos tipos, insertar `import RuulCore` después del último `import` existente.
8. `make build` — esperar errores de visibility, fix uno por uno (cada `public` faltante).
9. `xcodebuild test -only-testing:TandasTests/PrimitiveSnapshotTests` debe quedar verde.
10. Commit: `refactor(spm): create RuulCore package, move Models`

**Riesgo alto**: SwiftData `@Model` classes que crucen el boundary. Si `Group` o cualquier otro modelo es `@Model`, requiere `public final class` y todos sus stored props también. Verificar antes.

### Sesión 2.1b — Mover Repositories + Supabase (~1.5h)

1. `git mv ios/Tandas/Platform/Repositories ios/Packages/RuulCore/Sources/RuulCore/Repositories`
2. `git mv ios/Tandas/Supabase ios/Packages/RuulCore/Sources/RuulCore/Supabase`
3. Public-ify:
   - Protocols: `public protocol GroupsRepository: Sendable { ... }`
   - Concrete impls: `public final class SupabaseGroupsRepository: GroupsRepository`
   - Methods que use el app: `public func ...`
4. `make build` + tests
5. Commit: `refactor(spm): move Repositories + Supabase to RuulCore`

### Sesión 2.1c — Mover Services + Utilities + Coordinators (~1.5h)

1. `git mv ios/Tandas/Services ios/Packages/RuulCore/Sources/RuulCore/Services`
2. `git mv ios/Tandas/Platform/Services ios/Packages/RuulCore/Sources/RuulCore/PlatformServices`
3. `git mv ios/Tandas/Utilities ios/Packages/RuulCore/Sources/RuulCore/Utilities`
4. `git mv ios/Tandas/Platform/Coordinators ios/Packages/RuulCore/Sources/RuulCore/Coordinators`
5. Public-ify
6. `make build` + tests
7. Commit: `refactor(spm): move Services + Utilities + Coordinators to RuulCore`

**Salida Sprint 2.1**: `ios/Tandas/Platform/` queda vacío (puede borrarse), todos los Models/Services/Repos viven en RuulCore. App + Features importan `RuulCore`.

---

## 4. Sprint 2.2 — RuulUI (2-3 sesiones estimadas)

### Sesión 2.2a — Crear package + mover Tokens (~45min)

1. Crear `ios/Packages/RuulUI/Package.swift` con `dependencies: [.package(path: "../RuulCore")]` + target dependency.
2. `git mv ios/Tandas/DesignSystem/Tokens ios/Packages/RuulUI/Sources/RuulUI/Tokens`
3. Audit: `RuulSpacing`, `RuulColors`, `RuulRadius`, `RuulMotion`, `Font.ruul*`, `Color.ruul*`, `RuulHaptic`, `GlassMaterial`, etc. — todo a `public`.
4. `GroupColorRamp.swift` requiere `import RuulCore` (usa `GroupCategory`).
5. Update `project.yml`:
   ```yaml
   packages:
     RuulUI:
       path: Packages/RuulUI
   targets:
     Tandas:
       dependencies:
         - package: RuulCore
         - package: RuulUI
   ```
6. xcodegen + build + test
7. Commit: `refactor(spm): create RuulUI package, move Tokens`

### Sesión 2.2b — Mover Modifiers + Primitives + Patterns + Templates (~2h)

1. `git mv` los 4 directorios (`Modifiers/`, `Primitives/`, `Patterns/`, `Templates/`, `Components/`, `Theme/`).
2. Public-ify cada `struct/View`: `public struct RuulButton: View`, `public init`, `public var body`.
3. Wire `import RuulCore` en components con domain coupling (RuulGroupSwitcher, RuulGroupAvatar, RSVPStateView, EventCardStub, ErrorStateView+CoordinatorError).
4. Update consumers en Features para `import RuulUI`.
5. Build + tests (snapshot tests deben pasar idénticos pixel-by-pixel — si fallan, alguna API rompió).
6. Commit: `refactor(spm): move DesignSystem to RuulUI`

**Salida Sprint 2.2**: `ios/Tandas/DesignSystem/` queda vacío excepto `Showcase/` (para preview matrix; puede irse a app target o RuulUI test target).

---

## 5. Sprint 2.3 — RuulFeatures (2 sesiones estimadas)

### Sesión 2.3a — Crear package + mover Features (~2h)

1. Crear `ios/Packages/RuulFeatures/Package.swift` con deps en RuulCore + RuulUI.
2. `git mv ios/Tandas/Features ios/Packages/RuulFeatures/Sources/RuulFeatures/Features`
3. Public-ify cada View que sea entry point para el app shell:
   - `MainTabView`, `OnboardingRootView`, `SignInView`, etc.
   - Inicializadores y dependencies inject points.
4. Update App target `Shell/AuthGate.swift` para `import RuulFeatures`.
5. Build + tests (incluyendo snapshot suite).
6. Commit: `refactor(spm): move Features to RuulFeatures`

### Sesión 2.3b — Polishing y cleanup (~1h)

1. `git mv ios/Tandas/Templates ios/Packages/RuulFeatures/Sources/RuulFeatures/Templates`
2. Borrar directorios vacíos en `ios/Tandas/`.
3. Verificar app target tiene solo: `TandasApp.swift`, `Shell/`, `Resources/`, `Supabase/Repos/` (si queda algo).
4. Update `docs/DesignSystem.md` §2 para describir la estructura final.
5. Commit: `refactor(spm): cleanup and docs update for SPM split`

---

## 6. Riesgos y mitigaciones

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| Access-control fanout (cientos de `public` faltantes) | ALTA | Build incremental por step, fix lineal. Usar `swift -typecheck` para listar errores. |
| `@Model` SwiftData no public-able | MEDIA | Verificar antes de Sesión 2.1a. Si conflict, fork: dejar SwiftData entities en app target. |
| `@testable import` rompe en cross-package | MEDIA | Tests internos del package usan `@testable`; tests del app reescribir a public APIs. |
| Showcase target depende de DS | BAJA | `Showcase/` se queda en app target o se mueve a un target separado de previews. |
| Strict concurrency `Sendable` warnings nuevos | MEDIA | Models ya conforman Sendable (Sprint 1 audit). Si aparecen warnings, resolver caso por caso. |
| `import Tandas` en tests rompe (módulo cambia) | BAJA | Tests reorganizan imports → `import RuulCore`/`RuulUI`/`RuulFeatures` según sea apropiado. |
| Rollback complejo si fail en step N+M | MEDIA | Cada step es un commit. `git reset --hard HEAD~1` siempre disponible. Snapshot tests detectan regresiones visuales. |

---

## 7. Definition of Done

- [ ] `ios/Packages/RuulCore/Package.swift` con Models + Repositories + Services + Utilities + Coordinators
- [ ] `ios/Packages/RuulUI/Package.swift` con Tokens + Modifiers + Primitives + Patterns + Templates + Components + Theme
- [ ] `ios/Packages/RuulFeatures/Package.swift` con Features + Templates
- [ ] App target `Tandas` solo contiene `TandasApp.swift`, `Shell/`, `Resources/`
- [ ] `make build` verde
- [ ] `make test` verde (incluyendo snapshot suite — pixel idéntico)
- [ ] Build incremental: cambio en `Tokens/` solo recompila RuulUI (verificar con timing)
- [ ] `docs/DesignSystem.md` §2 actualizado
- [ ] Commit history limpio (un commit por step para facilitar bisect futuro)

---

## 8. Estado de implementación

- [x] Sprint 2.1a — RuulCore + Models (2026-05-07, commit `aa99ac7`)
- [x] Sprint 2.1b — RuulCore + Repositories + Supabase + Templates (2026-05-07, commit `0614145`)
- [x] Sprint 2.1c — RuulCore + Services + Utilities + Platform (2026-05-08, commit `4c8a257`)
- [x] Sprint 2.2a — RuulUI + Tokens (2026-05-07, commit `971f8da`)
- [x] Sprint 2.2b — RuulUI + Modifiers + Primitives (35) + Patterns (8) + Templates + Theme (2026-05-07, commits `9168192` + `447b905`)
- [x] Sprint 2.2c — Move 11 deferred domain-coupled DS files into RuulUI (2026-05-07, commit `3791377`)
- [x] Sprint 2.3 — RuulFeatures + Features + AppState/OnboardingProgress extraction (2026-05-08, commit `7c71deb`)
- [ ] Sprint 2.4 — Final cleanup: docs/DesignSystem.md §2 update, incremental build verification

**Estimado total**: 7 commits, 8-10 horas de trabajo focused. Mejor hacer 1 step por día para evitar fatigue + permitir review.

**Deviación del orden original (2026-05-07)**: Empecé con RuulUI en lugar de RuulCore porque Tokens/Modifiers/most-Primitives son leaf-pure (cero domain refs) y validaban la mecánica del split sin tocar el alto-fanout `Group`/`Profile`/`Member`. RuulCore ahora es lo siguiente.

**Files que quedan en `ios/Tandas/DesignSystem/` (11 domain-coupled, esperan RuulCore):**
- `Components/`: ResourceCard.swift, ResourceActionsSection.swift (usan `ResourceProtocol`, `RSVPStatus`, `ResourceAction`)
- `Patterns/`: ErrorStateView+CoordinatorError.swift, EventCardStub.swift, RSVPStateView.swift
- `Primitives/`: RuulDatePicker.swift, RuulGroupAvatar.swift, RuulGroupComponents+Group.swift, RuulGroupSwitcher.swift, RuulGroupSwitcherSheet.swift, RuulOriginTag.swift
- `Showcase/` (el catálogo de previews — ya importa RuulUI; puede irse a app target o a un test target dedicado)

**Próximo paso (Sprint 2.1a) — fanout estimado:**
- 88 files de Models a mover (`Models/*.swift` 8 + `Models/Events/*` 1 + `Platform/Models/*` 30, dejando `Models/Onboarding/` en app target porque tiene `@Model OnboardingProgress`)
- ~63 files referencian `Group` solo, plus `Profile`, `Member`, etc. Probablemente >100 files necesitan `import RuulCore`.
- Public-ifying: ~80 types (struct/enum) + sus inits + sus stored properties.
- Riesgo medio-alto. Recomendado: una sesión focused, preferir muchos commits pequeños (uno por type group) sobre un big-bang.
