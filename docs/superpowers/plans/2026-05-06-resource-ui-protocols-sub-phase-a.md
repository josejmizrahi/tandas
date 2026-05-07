# Resource UI Protocols (Sub-fase A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introducir las primitivas Swift que habilitan dispatch genérico de resources en UI (`ResourceProtocol` + `EventResource` wrapper + `ResourceAction` data struct + `ResourceActionsProvider` protocol skeleton + 7 tests), sin tocar nada existente.

**Architecture:** UI-layer protocol distinta de la data-layer existente (`Platform/Models/Resource.swift`). EventResource wrappea Event, expone `event` público, conforma a `ResourceProtocol` con 3 miembros mínimos. Sub-fase A es 100% aditiva: cero cambios en `Features/`, `Models/`, `Coordinators/`, backend, edge functions, RPCs, schema.

**Tech Stack:** Swift 6, SwiftUI, XCTest, xcodegen, Xcode 16+, iOS 26 deployment target.

**Spec:** [`docs/superpowers/specs/2026-05-06-resource-ui-protocols-design.md`](../specs/2026-05-06-resource-ui-protocols-design.md)

---

## File Structure

**Production files (4 new, all in `Platform/Resources/`):**

| File | Responsibility |
|---|---|
| `ios/Tandas/Platform/Resources/ResourceProtocol.swift` | UI-layer protocol con `id, groupId, resourceType` (Identifiable + Sendable). |
| `ios/Tandas/Platform/Resources/EventResource.swift` | Struct wrapper sobre Event que conforma a `ResourceProtocol`. Único concrete resource V1. |
| `ios/Tandas/Platform/Resources/ResourceAction.swift` | Struct con `id, icon, title, subtitle, isDestructive, governanceAction, onTap`. Producida por providers, consumida por `ResourceActionsSection` (Sub-fase D). |
| `ios/Tandas/Platform/Resources/ResourceActionsProvider.swift` | Protocol skeleton con `associatedtype R: ResourceProtocol`, función `actions(for:member:in:) async -> [ResourceAction]`. Sin implementación concreta en Sub-fase A. |

**Test files (2 new, in `TandasTests/Platform/Resources/`):**

| File | Tests |
|---|---|
| `ios/TandasTests/Platform/Resources/EventResourceTests.swift` | 4 tests: identity preservation, resourceType invariant, `event` property, Identifiable in collections. |
| `ios/TandasTests/Platform/Resources/ResourceActionTests.swift` | 3 tests: init defaults, id stability, `onTap` execution. |

**Project file:**
- `ios/project.yml` — sin cambios. xcodegen autodiscovers nuevos directorios bajo `Tandas/` y `TandasTests/`. Solo correr `xcodegen generate` para regenerar `.xcodeproj`.

**Cero modificaciones a:**
- `Features/Events/**`, `Features/Fines/**`, ningún feature module
- `Platform/Models/**`, `Platform/Repositories/**`, `Platform/Services/**`
- `Coordinators/**`
- `supabase/migrations/**`, edge functions, RPCs

---

### Task 1: Setup directory + ResourceProtocol

**Files:**
- Create: `ios/Tandas/Platform/Resources/ResourceProtocol.swift`

- [ ] **Step 1: Create the new directory + protocol file**

```bash
mkdir -p /Users/jj/code/tandas/ios/Tandas/Platform/Resources
```

Create `ios/Tandas/Platform/Resources/ResourceProtocol.swift` with this content:

```swift
import Foundation

/// UI-layer protocol — habilita dispatch genérico de resources en views,
/// containers y providers. Distinta de `Platform/Models/Resource.swift`
/// (data-layer protocol con Codable + status + timestamps).
///
/// Mantener minimal: si tu vista necesita un campo type-specific, accedé
/// al concrete type via cast en el branch correspondiente del switch.
/// El invariante es: `resource.resourceType == .event ⇒ resource is EventResource`.
public protocol ResourceProtocol: Identifiable, Sendable {
    var id: UUID { get }
    var groupId: UUID { get }
    var resourceType: ResourceType { get }
}
```

- [ ] **Step 2: Regenerate Xcode project**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate
```

Expected: regenerates `Tandas.xcodeproj` without errors. New `Platform/Resources/` directory is auto-included via the `Tandas` source path in `project.yml`.

- [ ] **Step 3: Verify build green**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Expected: `** BUILD SUCCEEDED **` on the last line. No `error:` lines for `ResourceProtocol.swift`.

- [ ] **Step 4: Commit**

```bash
cd /Users/jj/code/tandas && git add ios/Tandas/Platform/Resources/ResourceProtocol.swift
git commit -m "$(cat <<'EOF'
feat(resources): add ResourceProtocol UI-layer skeleton (Sub-fase A 1/5)

Minimal protocol (id, groupId, resourceType) for generic resource
dispatch in UI. Distinct from data-layer Platform/Models/Resource.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 2: EventResource (TDD)

**Files:**
- Create: `ios/TandasTests/Platform/Resources/EventResourceTests.swift`
- Create: `ios/Tandas/Platform/Resources/EventResource.swift`

- [ ] **Step 1: Write the failing tests**

```bash
mkdir -p /Users/jj/code/tandas/ios/TandasTests/Platform/Resources
```

Create `ios/TandasTests/Platform/Resources/EventResourceTests.swift`:

```swift
import XCTest
@testable import Tandas

final class EventResourceTests: XCTestCase {

    // MARK: - Fixture

    private func makeEvent(
        id: UUID = UUID(),
        groupId: UUID = UUID()
    ) -> Event {
        Event(
            id: id,
            groupId: groupId,
            title: "Test event",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Tests

    func testInitPreservesEventIdentity() {
        let id = UUID()
        let groupId = UUID()
        let event = makeEvent(id: id, groupId: groupId)
        let resource = EventResource(event)

        XCTAssertEqual(resource.id, id)
        XCTAssertEqual(resource.groupId, groupId)
    }

    func testResourceTypeAlwaysEvent() {
        let resource = EventResource(makeEvent())
        XCTAssertEqual(resource.resourceType, .event)
    }

    func testEventPropertyReturnsOriginal() {
        let event = makeEvent()
        let resource = EventResource(event)
        XCTAssertEqual(resource.event, event)
    }

    func testIdentifiableInCollections() {
        let resources = (0..<3).map { _ in EventResource(makeEvent()) }
        let ids = Set(resources.map(\.id))
        XCTAssertEqual(ids.count, 3, "three distinct resources should have three distinct ids")
    }
}
```

- [ ] **Step 2: Regenerate Xcode project (new test directory)**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=26.0' \
  -only-testing:TandasTests/EventResourceTests 2>&1 \
  | grep -E "(error:|FAILED|cannot find)" | head -10
```

Expected: build fails with `cannot find 'EventResource' in scope` or similar. This is the failing-test gate for TDD.

- [ ] **Step 4: Write minimal implementation**

Create `ios/Tandas/Platform/Resources/EventResource.swift`:

```swift
import Foundation

/// Wrapper de `Event` que conforma a `ResourceProtocol` (UI dispatch).
/// V1: el único concrete resource shippeado. Cuando llegue Slot/Fund,
/// vivirán como hermanos en este directorio.
///
/// Por qué wrapper y no extension: `Event` no debería conocer la capa
/// de UI. El wrapper es la traducción explícita — si mañana cambia el
/// shape de `ResourceProtocol`, solo este archivo se actualiza.
///
/// Invariante: `EventResource` es el único conformer de `ResourceProtocol`
/// con `resourceType == .event` en V1. Bodies concretos pueden hacer
/// `(resource as! EventResource)` con seguridad dentro del case `.event`.
public struct EventResource: ResourceProtocol {
    public let event: Event

    public init(_ event: Event) { self.event = event }

    public var id: UUID { event.id }
    public var groupId: UUID { event.groupId }
    public var resourceType: ResourceType { .event }
}
```

- [ ] **Step 5: Regenerate Xcode project (new source file)**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=26.0' \
  -only-testing:TandasTests/EventResourceTests 2>&1 \
  | grep -E "(Test Suite|PASSED|FAILED|error:)" | tail -10
```

Expected: `Test Suite 'EventResourceTests' passed.` with 4 tests executed, 0 failed.

- [ ] **Step 7: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Platform/Resources/EventResource.swift \
  ios/TandasTests/Platform/Resources/EventResourceTests.swift
git commit -m "$(cat <<'EOF'
feat(resources): add EventResource wrapper + 4 tests (Sub-fase A 2/5)

Wraps Event, conforms to ResourceProtocol with id/groupId/resourceType.
Exposes underlying event publicly so concrete bodies can cast and
project type-specific fields. V1 invariant: only conformer of .event.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 3: ResourceAction (TDD)

**Files:**
- Create: `ios/TandasTests/Platform/Resources/ResourceActionTests.swift`
- Create: `ios/Tandas/Platform/Resources/ResourceAction.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/TandasTests/Platform/Resources/ResourceActionTests.swift`:

```swift
import XCTest
@testable import Tandas

final class ResourceActionTests: XCTestCase {

    // MARK: - Fixture

    private func makeAction(
        id: String = "test-action",
        subtitle: String? = nil,
        isDestructive: Bool = false,
        onTap: @escaping @Sendable () async -> Void = {}
    ) -> ResourceAction {
        ResourceAction(
            id: id,
            icon: "xmark.circle",
            title: "Test action",
            subtitle: subtitle,
            isDestructive: isDestructive,
            governanceAction: .closeEvents,
            onTap: onTap
        )
    }

    // MARK: - Tests

    func testInitWithDefaults() {
        // Use the call-site that omits subtitle and isDestructive to
        // exercise the default-arg path on the public init.
        let action = ResourceAction(
            id: "id1",
            icon: "xmark.circle",
            title: "Title",
            governanceAction: .closeEvents,
            onTap: {}
        )

        XCTAssertEqual(action.id, "id1")
        XCTAssertEqual(action.icon, "xmark.circle")
        XCTAssertEqual(action.title, "Title")
        XCTAssertNil(action.subtitle)
        XCTAssertFalse(action.isDestructive)
        XCTAssertEqual(action.governanceAction, .closeEvents)
    }

    func testIdIsStableAcrossClosures() {
        // Same id, different closures — id is the stable diff key for
        // SwiftUI ForEach. Closures cannot be compared structurally.
        let a1 = makeAction(id: "stable", onTap: {})
        let a2 = makeAction(id: "stable", onTap: { /* different body */ })
        XCTAssertEqual(a1.id, a2.id)
    }

    func testOnTapExecutesClosure() async {
        actor Counter {
            var value: Int = 0
            func increment() { value += 1 }
            func current() -> Int { value }
        }
        let counter = Counter()
        let action = makeAction(id: "tap") {
            await counter.increment()
        }

        await action.onTap()

        let observed = await counter.current()
        XCTAssertEqual(observed, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=26.0' \
  -only-testing:TandasTests/ResourceActionTests 2>&1 \
  | grep -E "(error:|FAILED|cannot find)" | head -10
```

Expected: build fails with `cannot find 'ResourceAction' in scope` or similar.

- [ ] **Step 3: Write minimal implementation**

Create `ios/Tandas/Platform/Resources/ResourceAction.swift`:

```swift
import Foundation

/// Acción que un host puede ejecutar contra un resource. Producida por
/// un `ResourceActionsProvider`, consumida por `ResourceActionsSection`
/// (Sub-fase D). Diseñada como data + closure: el provider arma la lista,
/// la view la renderiza.
///
/// **Retain cycle warning**: `onTap` captura coordinator/services
/// lexicalmente. Cuando el provider construye la action, el closure
/// debe ser `[weak coordinator] in await coordinator?.foo()` — el
/// coordinator es @Observable (reference type) y guardarlo strong
/// dentro del closure crea ciclo. Patrón obligado en Sub-fase D.
///
/// **`governanceAction` role en V1**: metadata only. El provider ya
/// filtró las actions disponibles según governance antes de emitirlas;
/// este field documenta a qué permission key corresponde la action
/// (útil para analytics, logs y futuro re-check). V1 NO re-chequea
/// en `onTap`. Sub-fase D puede expandir a defense-in-depth con UI
/// fallback ("La gobernanza cambió, refrescá") si decide.
public struct ResourceAction: Identifiable, Sendable {
    public let id: String
    public let icon: String
    public let title: String
    public let subtitle: String?
    public let isDestructive: Bool
    public let governanceAction: GovernanceAction
    public let onTap: @Sendable () async -> Void

    public init(
        id: String,
        icon: String,
        title: String,
        subtitle: String? = nil,
        isDestructive: Bool = false,
        governanceAction: GovernanceAction,
        onTap: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isDestructive = isDestructive
        self.governanceAction = governanceAction
        self.onTap = onTap
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=26.0' \
  -only-testing:TandasTests/ResourceActionTests 2>&1 \
  | grep -E "(Test Suite|PASSED|FAILED|error:)" | tail -10
```

Expected: `Test Suite 'ResourceActionTests' passed.` with 3 tests executed, 0 failed.

- [ ] **Step 5: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Platform/Resources/ResourceAction.swift \
  ios/TandasTests/Platform/Resources/ResourceActionTests.swift
git commit -m "$(cat <<'EOF'
feat(resources): add ResourceAction struct + 3 tests (Sub-fase A 3/5)

Data + closure container for host actions. Doc-comments cover
retain-cycle warning (Sub-fase D must use [weak coordinator]) and
governanceAction-as-metadata role for V1.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 4: ResourceActionsProvider skeleton

**Files:**
- Create: `ios/Tandas/Platform/Resources/ResourceActionsProvider.swift`

This is a pure protocol declaration with `associatedtype` — no concrete implementation in Sub-fase A. No new tests (no implementation to test against). The build itself is the gate: the protocol must compile and the `Member` / `Group` / `ResourceAction` symbols must be in scope.

- [ ] **Step 1: Write the protocol**

Create `ios/Tandas/Platform/Resources/ResourceActionsProvider.swift`:

```swift
import Foundation

/// Estrategia para producir acciones contra un resource. Cada concrete
/// resource type tiene su provider (V1: `EventActionsProvider`, deferido
/// a Sub-fase D). El provider conoce las reglas de governance + el
/// estado del resource y decide qué acciones están disponibles.
///
/// **Associatedtype no existential**: `R: ResourceProtocol` permite que
/// el provider concreto reciba el type ya tipado, sin `as!` interno.
/// Trade-off: consumers no pueden tener `[any ResourceActionsProvider]`.
/// V1 no lo necesita — cada resource type tiene su provider concreto
/// inyectado donde corresponde, accedido por switch en `resource.resourceType`.
public protocol ResourceActionsProvider: Sendable {
    associatedtype R: ResourceProtocol

    func actions(
        for resource: R,
        member: Member,
        in group: Group
    ) async -> [ResourceAction]
}
```

- [ ] **Step 2: Regenerate Xcode project**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate
```

- [ ] **Step 3: Verify build green**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Expected: `** BUILD SUCCEEDED **`. If `Member` or `Group` are not in scope, fix imports — they live in `Tandas/Models/`. The protocol file should not need explicit imports beyond `Foundation` since both types are part of the same module.

- [ ] **Step 4: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Platform/Resources/ResourceActionsProvider.swift
git commit -m "$(cat <<'EOF'
feat(resources): add ResourceActionsProvider protocol skeleton (Sub-fase A 4/5)

Associatedtype-based provider contract. No concrete implementation
yet — EventActionsProvider lands in Sub-fase D once ResourceCard
and ResourceDetailView containers exist to consume the actions.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 5: Final gates (codegen + full build + full test) + DoD verify

**Files:** none modified.

- [ ] **Step 1: Codegen no-op gate**

Sub-fase A no toca enums (ResourceType, GovernanceAction, SystemEventType ya tienen los cases necesarios). Confirmar que el codegen no produce diff.

```bash
cd /Users/jj/code/tandas && make gen 2>&1 | tail -5 \
  && git status --short ios/Tandas/Platform/Models/Generated/
```

Expected: `make gen` runs clean, `git status` for `Generated/` shows no changes (codegen produced no diff).

If diff appears, abort and inspect — Sub-fase A should not modify any enum that codegen tracks.

- [ ] **Step 2: Full build gate**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Full test suite gate**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=26.0' 2>&1 \
  | grep -E "(Test Suite 'All tests'|Executed [0-9]+ tests|FAILED|error:)" | tail -10
```

Expected: `Test Suite 'All tests' passed.` and the executed-tests line shows 0 failures. The 7 new tests (4 EventResource + 3 ResourceAction) increase the totals; existing test counts must not regress.

- [ ] **Step 4: DoD verification**

Read each item from the spec DoD and confirm:

```bash
ls -la /Users/jj/code/tandas/ios/Tandas/Platform/Resources/
ls -la /Users/jj/code/tandas/ios/TandasTests/Platform/Resources/
```

Expected output: 4 files in `Tandas/Platform/Resources/` (ResourceProtocol, EventResource, ResourceAction, ResourceActionsProvider) + 2 files in `TandasTests/Platform/Resources/` (EventResourceTests, ResourceActionTests).

Verify each DoD checkbox from the spec passes:

- `Platform/Resources/ResourceProtocol.swift` exists, conforms to `Identifiable + Sendable`, exposes 3 members
- `Platform/Resources/EventResource.swift` exists, struct, conforms to `ResourceProtocol`, exposes `event: Event` public
- `Platform/Resources/ResourceAction.swift` exists, struct with doc-comments
- `Platform/Resources/ResourceActionsProvider.swift` exists, protocol skeleton with `associatedtype R: ResourceProtocol`
- `TandasTests/Platform/Resources/EventResourceTests.swift` 4 tests passing
- `TandasTests/Platform/Resources/ResourceActionTests.swift` 3 tests passing
- `xcodebuild build` green
- `xcodebuild test` green
- Codegen no-op
- Cero cambios en `Features/`, `Models/`, `Coordinators/`
- Naming alignment: `resourceType` consistente entre data y UI protocols
- xcodegen actualiza project sin necesidad de editar `project.yml`

Confirm with:

```bash
cd /Users/jj/code/tandas && git log --oneline -5 \
  && git diff --stat HEAD~4..HEAD -- ios/Tandas/Features ios/Tandas/Models ios/Tandas/Coordinators 2>/dev/null
```

Expected: 4 commits from this sub-phase ("feat(resources): … Sub-fase A 1-4/5"). The `git diff --stat` should produce zero lines (no changes outside `Platform/Resources/`).

- [ ] **Step 5: Update Roadmap (mark Sub-fase A done)**

Edit `Plans/Phase0.5-UIResourceGeneralization.md` §3 Sub-fase A heading to add `✅ shipped 2026-05-06`.

```bash
cd /Users/jj/code/tandas && grep -n "Sub-fase A — Resource UI protocols" Plans/Phase0.5-UIResourceGeneralization.md
```

Use Edit to change:

```
### Sub-fase A — Resource UI protocols + EventResource wrapper
```

to:

```
### Sub-fase A — Resource UI protocols + EventResource wrapper ✅ shipped 2026-05-06
```

- [ ] **Step 6: Final commit**

```bash
cd /Users/jj/code/tandas && git add Plans/Phase0.5-UIResourceGeneralization.md
git commit -m "$(cat <<'EOF'
docs(phase-0.5): mark Sub-fase A shipped (Sub-fase A 5/5)

7 tests green (4 EventResource + 3 ResourceAction). 4 production
files added. Zero changes outside Platform/Resources/ + tests.
Sub-fase B (HomeView refactor) unblocked.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Self-Review

**Spec coverage check** — every DoD item from the spec maps to a task:

| Spec DoD item | Plan task |
|---|---|
| `ResourceProtocol.swift` created | Task 1 |
| `EventResource.swift` created | Task 2 |
| `ResourceAction.swift` created | Task 3 |
| `ResourceActionsProvider.swift` created | Task 4 |
| `EventResourceTests.swift` 4 tests verdes | Task 2 step 6 |
| `ResourceActionTests.swift` 3 tests verdes | Task 3 step 4 |
| `xcodebuild build` green | Task 5 step 2 |
| `xcodebuild test` green | Task 5 step 3 |
| Codegen no-op | Task 5 step 1 |
| Cero cambios fuera de Platform/Resources/ + tests | Task 5 step 4 verification |
| Naming alignment verified | Encapsulado en Tasks 1-2 (un solo getter satisface ambos protocols) |
| xcodegen project.yml | Tasks 1-4 (regenerate after each new file) |

**Placeholder scan**: clean. No TBD/TODO/"implement later". Every code step has the actual code.

**Type consistency**:
- `ResourceProtocol` requires `id: UUID`, `groupId: UUID`, `resourceType: ResourceType` → Task 2 implements all three on `EventResource`.
- `ResourceAction.governanceAction: GovernanceAction` → Task 3 tests use `.closeEvents` (verified to exist in `Platform/Models/GovernanceAction.swift:10`).
- `ResourceActionsProvider.actions(for:member:in:)` → uses `Member` and `Group` (existing types in `Tandas/Models/`).
- `Event` init in test fixture uses `id, groupId, title, startsAt, createdAt` (required fields per `Models/Events/Event.swift:58-85`); other fields use struct defaults.
- `XCTAssertEqual(resource.event, event)` — `Event` is `Hashable` (per `Event.swift:3`), so Equatable is automatic.

All consistent.
