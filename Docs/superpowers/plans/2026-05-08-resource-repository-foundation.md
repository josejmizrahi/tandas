# ResourceRepository Foundation + Protocol Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a polymorphic `ResourceRepository` in RuulCore that reads from the `resources` table for any `ResourceType` (today only `.event`, tomorrow `.slot`/`.fund`/`.position`/`.asset`/`.contribution`), and converge the two parallel `Resource` / `ResourceProtocol` definitions into one canonical protocol — without changing any user-visible behavior.

**Architecture:**
- New `ResourceRow` struct (Codable) decodes raw rows from `public.resources`. It is the polymorphic envelope — `id, group_id, resource_type, status, metadata jsonb, created_by, created_at, updated_at`.
- New `ResourceRepository` actor protocol with read-only methods (`list`, `resource(_:)`). Writes still flow through resource-type-specific repos (today only `EventRepository`); the SQL trigger `events_sync_to_resources` (migration 00039) mirrors writes into the `resources` table automatically.
- The two protocols collapse: `RuulCore.PlatformModels.Resource` (data) becomes the canonical shape; `RuulUI.ResourceProtocol` becomes a deprecated typealias to it. `EventResource` wrapper is deleted — `Event` itself conforms to `Resource` via an extension. This is the "data wins" decision recorded in Audit-2026-05-06 §4.7.
- `EventRepository` keeps its current API and continues reading from `events` directly for date-bound queries (the `resources` table has no flat `starts_at` column; date filters work against `events`). It gains a single new helper `eventsFromResourceRows(_:)` for callers that already have rows in hand.
- `nextResource` and the existing UI dispatch (`ResourceCard`, `ResourceDetailView`, `ResourceActionsProvider`) keep working — they switch on `resource.resourceType` as before, but now over `any Resource` instead of `any ResourceProtocol`.
- Net effect post-plan: an iOS coordinator can call `resourceRepo.list(in: groupId, types: [.event, .slot], statuses: ["scheduled"])` and get back a polymorphic `[ResourceRow]` whose `.event` rows decode to `Event` via `row.decodeAsEvent()`. This is the unlock for Plan 2 (HomeCoordinator resource fan-out) and beyond.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), Supabase Swift SDK, Xcode 16, xcodegen, iOS 26 deployment target.

**Build/test commands (read this BEFORE running any verification step):**
- Always use `xcodebuild build` or `xcodebuild test` from repo root (`/Users/jj/code/tandas`) against the iOS Simulator scheme.
- **Do NOT use `swift build`** from inside `ios/Packages/RuulCore/` or `ios/Packages/RuulUI/`. `Package.swift` only declares `platforms: [.iOS("26.0")]`, so a CLI `swift build` resolves to host macOS and trips a pre-existing platform constraint with Supabase (`'Supabase' which requires macos 10.15`). xcodebuild on the iOS Simulator scheme has no such issue. Wherever a step below originally said `swift build`, **use the xcodebuild equivalent shown alongside it instead**.
- **Simulator destination**: this dev box has `iPhone 17 Pro` (iOS 26.4.1) but not `iPhone 17 Pro`. Use `name=iPhone 17 Pro` locally; CI runners may have `iPhone 17 Pro` only. The commands below use `iPhone 17 Pro` — if a step fails with `Unable to find a device matching the provided destination specifier`, list available simulators with `xcrun simctl list devices available 'iOS 26'` and substitute one.

**Audit references:**
- `Plans/Active/Audit-2026-05-06.md` §3.10 (ResourceRepository genérico — gap), §4.7 (dos ResourceProtocol — convergencia decidida).
- `supabase/migrations/00014_platform_foundation.sql` (resources table DDL + RLS policy `resources_read_member`).
- `supabase/migrations/00039_events_to_resources_dual_write.sql` (trigger keeps `resources` in sync; `resources.id == events.id`).

---

## File Structure

**Production files (8 new, 4 modified, 1 deleted):**

| File | Status | Responsibility |
|---|---|---|
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRow.swift` | NEW | Concrete `Codable` struct for one row of `public.resources`. Polymorphic envelope. |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRowError.swift` | NEW | Error enum for decode/fetch failures. |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRow+Event.swift` | NEW | `decodeAsEvent()` projection from row metadata + flat columns into `Event`. |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Event+Resource.swift` | NEW | Extension making `Event` conform to `Resource` directly (drops the wrapper indirection). |
| `ios/Packages/RuulCore/Sources/RuulCore/Repositories/ResourceRepository.swift` | NEW | Actor protocol + `MockResourceRepository` + `LiveResourceRepository`. Read-only V1. |
| `ios/Packages/RuulCore/Sources/RuulCore/Events/Event.swift` | MODIFIED | Add `updatedAt: Date` field with tolerant decoder fallback to `createdAt`. |
| `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Resource.swift` | MODIFIED | Drop `Codable` from protocol requirements (concrete types still Codable). Doc updated. |
| `ios/Packages/RuulUI/Sources/RuulUI/Resources/ResourceProtocol.swift` | MODIFIED | Becomes a deprecated `typealias ResourceProtocol = Resource`. |
| `ios/Packages/RuulUI/Sources/RuulUI/Resources/EventResource.swift` | DELETED | Wrapper no longer needed — `Event` conforms to `Resource` directly. |
| `ios/Packages/RuulUI/Sources/RuulUI/Resources/ResourceActionsProvider.swift` | MODIFIED | `associatedtype R: Resource` (was `R: ResourceProtocol`). |
| `ios/Tandas/DesignSystem/Components/ResourceCard.swift` | MODIFIED | Switch on `resource.resourceType`, cast to `Event` instead of `EventResource.event`. |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/ResourceDetailView.swift` | MODIFIED | `let resource: any Resource` (was `any ResourceProtocol`). |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Coordinator/HomeCoordinator.swift` | MODIFIED | `nextResource: (any Resource)? { nextEvent }`. |
| `ios/Tandas/TandasApp.swift` | MODIFIED | Construct `LiveResourceRepository(client:)` and stash on AppState. |
| `ios/Tandas/Shell/AppState.swift` (or current container) | MODIFIED | Carry `resourceRepo: any ResourceRepository`. |

**Test files (4 new, in `ios/TandasTests/Platform/Resources/`):**

| File | Tests |
|---|---|
| `ResourceRowTests.swift` | Codable roundtrip; status string passthrough; metadata jsonb access. |
| `ResourceRowEventDecoderTests.swift` | `decodeAsEvent()` happy path; missing required key throws; tolerant decode of optional fields. |
| `ResourceRepositoryTests.swift` | Mock list filters by group + types + statuses; resource(_:) hit + miss. |
| `EventResourceConformanceTests.swift` | `Event: Resource` extension — id/groupId/resourceType/status/createdAt/updatedAt. |

**Untouched (intentionally):**
- `ios/Packages/RuulCore/Sources/RuulCore/Repositories/EventRepository.swift` — keeps current `events` table reads for date-bound queries. We DO NOT route through ResourceRepository in this plan; the audit decision was to add a polymorphic path, not to replace the date-indexed one. Adding a sibling `EventRepository.eventsFromResourceRows(_:)` helper is included as Task 11.
- `supabase/migrations/**` — zero schema changes in this plan.
- Edge functions — zero changes.

**xcodegen note:** `ios/project.yml` auto-discovers files under `ios/Tandas/` and `ios/TandasTests/`. The SPM packages (`RuulCore`/`RuulUI`/`RuulFeatures`) auto-include any `.swift` file under `Sources/<target>/`. After adding files, run `cd ios && xcodegen` to regenerate `Tandas.xcodeproj`.

---

### Task 1: Create directory + add `ResourceRowError`

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRowError.swift`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p /Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/Resources
```

- [ ] **Step 2: Write the file**

Create `ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRowError.swift`:

```swift
import Foundation

/// Errors thrown by ResourceRow decoders and ResourceRepository ops.
public enum ResourceRowError: Error, Sendable, Equatable {
    /// The row's resource_type doesn't match the type the caller asked to decode as.
    /// e.g. caller invoked `decodeAsEvent()` on a row whose resource_type is `.slot`.
    case typeMismatch(expected: ResourceType, got: ResourceType)

    /// A required key is missing from the metadata jsonb.
    case missingMetadataKey(String)

    /// The metadata jsonb couldn't be decoded into the target struct.
    case metadataDecodeFailed(String)

    /// The remote fetch failed.
    case fetchFailed(String)

    /// Resource with the given id wasn't found (or RLS hid it).
    case notFound
}
```

- [ ] **Step 3: Build the package to confirm it compiles**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -10
```

Expected: `Build complete!` (no errors).

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRowError.swift
git commit -m "feat(resources): add ResourceRowError enum

Foundation for ResourceRepository — typed errors for row decode/fetch.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 2: Write failing test for `ResourceRow` Codable roundtrip

**Files:**
- Create: `ios/TandasTests/Platform/Resources/ResourceRowTests.swift`

- [ ] **Step 1: Create the test directory**

```bash
mkdir -p /Users/jj/code/tandas/ios/TandasTests/Platform/Resources
```

- [ ] **Step 2: Write the failing test**

Create `ios/TandasTests/Platform/Resources/ResourceRowTests.swift`:

```swift
import Testing
import Foundation
import RuulCore

@Suite("ResourceRow")
struct ResourceRowTests {
    @Test("decodes a row from the resources table json shape")
    func decodesRowJSON() throws {
        let groupId = UUID()
        let resourceId = UUID()
        let createdAt = ISO8601DateFormatter().string(from: .now)
        let json = """
        {
            "id": "\(resourceId.uuidString.lowercased())",
            "group_id": "\(groupId.uuidString.lowercased())",
            "resource_type": "event",
            "status": "scheduled",
            "metadata": {"title": "Cena martes"},
            "created_by": null,
            "created_at": "\(createdAt)",
            "updated_at": "\(createdAt)"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let row = try decoder.decode(ResourceRow.self, from: json)

        #expect(row.id == resourceId)
        #expect(row.groupId == groupId)
        #expect(row.resourceType == .event)
        #expect(row.status == "scheduled")
        #expect(row.metadata["title"]?.stringValue == "Cena martes")
    }

    @Test("survives a row with empty metadata")
    func decodesEmptyMetadata() throws {
        let createdAt = ISO8601DateFormatter().string(from: .now)
        let json = """
        {
            "id": "\(UUID().uuidString.lowercased())",
            "group_id": "\(UUID().uuidString.lowercased())",
            "resource_type": "slot",
            "status": "open",
            "metadata": {},
            "created_at": "\(createdAt)",
            "updated_at": "\(createdAt)"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let row = try decoder.decode(ResourceRow.self, from: json)

        #expect(row.resourceType == .slot)
        #expect(row.metadata == JSONConfig.empty)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:TandasTests/ResourceRowTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -30
```

Expected: FAIL — `cannot find 'ResourceRow' in scope`.

(If the test target hasn't picked up the new file yet, run `cd ios && xcodegen` first to refresh `Tandas.xcodeproj`.)

---

### Task 3: Implement `ResourceRow` to make Task 2 pass

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRow.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// One row of `public.resources`. Polymorphic envelope: any concrete
/// resource (event, slot, fund, position, asset, contribution) lands
/// here with its domain-specific fields living in `metadata` jsonb.
///
/// The `resources` table is populated by the dual-write trigger
/// `events_sync_to_resources` (migration 00039) for V1 events, and
/// directly by future resource-type-specific creation paths in V2+.
///
/// `ResourceRow.id == public.resources.id`. For V1 events,
/// `ResourceRow.id == events.id` by trigger design.
public struct ResourceRow: Resource, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let resourceType: ResourceType
    public let status: String
    public let metadata: JSONConfig
    public let createdBy: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case id, status, metadata
        case groupId        = "group_id"
        case resourceType   = "resource_type"
        case createdBy      = "created_by"
        case createdAt      = "created_at"
        case updatedAt      = "updated_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        resourceType: ResourceType,
        status: String,
        metadata: JSONConfig = .empty,
        createdBy: UUID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.groupId = groupId
        self.resourceType = resourceType
        self.status = status
        self.metadata = metadata
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decoder: missing `metadata` falls back to `.empty`,
    /// missing `updated_at` falls back to `created_at` (e.g. a row
    /// projected from a non-trigger source pre-cohabitation).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id            = try c.decode(UUID.self,   forKey: .id)
        self.groupId       = try c.decode(UUID.self,   forKey: .groupId)
        self.resourceType  = try c.decode(ResourceType.self, forKey: .resourceType)
        self.status        = try c.decode(String.self, forKey: .status)
        self.metadata      = (try? c.decode(JSONConfig.self, forKey: .metadata)) ?? .empty
        self.createdBy     = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        let createdAt      = try c.decode(Date.self, forKey: .createdAt)
        self.createdAt     = createdAt
        self.updatedAt     = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
    }
}

```

**Note:** `JSONConfig` already ships a `subscript(key: String) -> JSONConfig?` at `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/JSONConfig.swift:51` — do not redeclare it here. The Task 2 test `row.metadata["title"]?.stringValue` works against the existing subscript.

- [ ] **Step 2: Regenerate Xcode project**

```bash
cd /Users/jj/code/tandas/ios && xcodegen 2>&1 | tail -5
```

Expected: `Loaded project ... Generated project successfully`.

- [ ] **Step 3: Run the test to verify it passes**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:TandasTests/ResourceRowTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -30
```

Expected: 2 tests pass — `decodesRowJSON`, `decodesEmptyMetadata`.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRow.swift \
        ios/TandasTests/Platform/Resources/ResourceRowTests.swift
git commit -m "feat(resources): add ResourceRow polymorphic envelope

Decodes one row of public.resources. Tolerant decoder for metadata
and updated_at. Subscript helper on JSONConfig for per-type accessors.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 4: Write failing test for `ResourceRow.decodeAsEvent()`

**Files:**
- Create: `ios/TandasTests/Platform/Resources/ResourceRowEventDecoderTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/TandasTests/Platform/Resources/ResourceRowEventDecoderTests.swift`:

```swift
import Testing
import Foundation
import RuulCore

@Suite("ResourceRow.decodeAsEvent")
struct ResourceRowEventDecoderTests {
    private func sampleRow(
        type: ResourceType = .event,
        title: String = "Cena martes",
        startsAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> ResourceRow {
        let iso = ISO8601DateFormatter().string(from: startsAt)
        let metadata: JSONConfig = .object([
            "title":            .string(title),
            "starts_at":        .string(iso),
            "duration_minutes": .int(180),
            "apply_rules":      .bool(true)
        ])
        return ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: type,
            status: "scheduled",
            metadata: metadata,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @Test("decodes event metadata into Event")
    func happyPath() throws {
        let row = sampleRow(title: "Cena Sábado")

        let event = try row.decodeAsEvent()

        #expect(event.id == row.id)
        #expect(event.groupId == row.groupId)
        #expect(event.title == "Cena Sábado")
        #expect(event.durationMinutes == 180)
        #expect(event.applyRules == true)
    }

    @Test("throws typeMismatch when row is not an event")
    func typeMismatch() throws {
        let row = sampleRow(type: .slot)

        #expect(throws: ResourceRowError.typeMismatch(expected: .event, got: .slot)) {
            _ = try row.decodeAsEvent()
        }
    }

    @Test("throws missingMetadataKey when starts_at is absent")
    func missingStartsAt() throws {
        let row = ResourceRow(
            id: UUID(), groupId: UUID(), resourceType: .event,
            status: "scheduled",
            metadata: .object(["title": .string("x")]),
            createdAt: .now, updatedAt: .now
        )

        #expect(throws: ResourceRowError.missingMetadataKey("starts_at")) {
            _ = try row.decodeAsEvent()
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:TandasTests/ResourceRowEventDecoderTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -30
```

Expected: FAIL — `value of type 'ResourceRow' has no member 'decodeAsEvent'`.

---

### Task 5: Implement `ResourceRow.decodeAsEvent()` to make Task 4 pass

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRow+Event.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Projection: a `ResourceRow` with `resource_type == .event` decodes
/// back into a concrete `Event`. This is the inverse of the dual-write
/// trigger `sync_event_to_resource()` (migration 00039) which projects
/// `events.*` into `resources.metadata` jsonb.
///
/// Kept in RuulCore so any consumer holding a `[ResourceRow]` (e.g.
/// HomeCoordinator post Plan 6) can fan out to typed handles cheaply.
public extension ResourceRow {
    /// Decodes the row into an `Event`. Throws if the row's
    /// resource_type isn't `.event` or required keys are missing.
    func decodeAsEvent() throws -> Event {
        guard resourceType == .event else {
            throw ResourceRowError.typeMismatch(expected: .event, got: resourceType)
        }

        guard let startsAtString = metadata["starts_at"]?.stringValue else {
            throw ResourceRowError.missingMetadataKey("starts_at")
        }
        guard let startsAt = ResourceRow.iso8601.date(from: startsAtString) else {
            throw ResourceRowError.metadataDecodeFailed("starts_at not ISO8601")
        }

        let title = metadata["title"]?.stringValue ?? ""
        let durationMinutes = metadata["duration_minutes"]?.intValue ?? 180
        let applyRules = metadata["apply_rules"].flatMap { v -> Bool? in
            if case .bool(let b) = v { return b }
            return nil
        } ?? true

        let endsAt = (metadata["ends_at"]?.stringValue).flatMap { ResourceRow.iso8601.date(from: $0) }
        let rsvpDeadline = (metadata["rsvp_deadline"]?.stringValue).flatMap { ResourceRow.iso8601.date(from: $0) }
        let closedAt = (metadata["closed_at"]?.stringValue).flatMap { ResourceRow.iso8601.date(from: $0) }

        let coverImageName = metadata["cover_image_name"]?.stringValue
        let coverImageURL = (metadata["cover_image_url"]?.stringValue).flatMap(URL.init(string:))
        let description = metadata["description"]?.stringValue
        let locationName = metadata["location_name"]?.stringValue
        let locationLat = metadata["location_lat"].flatMap { v -> Double? in
            if case .double(let d) = v { return d }
            if case .int(let i) = v { return Double(i) }
            return nil
        }
        let locationLng = metadata["location_lng"].flatMap { v -> Double? in
            if case .double(let d) = v { return d }
            if case .int(let i) = v { return Double(i) }
            return nil
        }
        let hostId = (metadata["host_id"]?.stringValue).flatMap(UUID.init(uuidString:))
        let parentEventId = (metadata["parent_event_id"]?.stringValue).flatMap(UUID.init(uuidString:))
        let cycleNumber = metadata["cycle_number"]?.intValue
        let isRecurringGenerated = (metadata["is_recurring_generated"].flatMap { v -> Bool? in
            if case .bool(let b) = v { return b }
            return nil
        }) ?? false
        let cancellationReason = metadata["cancellation_reason"]?.stringValue
        let capacityMax = metadata["capacity_max"]?.intValue
        let allowPlusOnes = (metadata["allow_plus_ones"].flatMap { v -> Bool? in
            if case .bool(let b) = v { return b }
            return nil
        }) ?? false
        let maxPlusOnes = metadata["max_plus_ones_per_member"]?.intValue ?? 0

        let eventStatus = EventStatus(rawValue: status) ?? .upcoming

        return Event(
            id: id,
            groupId: groupId,
            title: title,
            coverImageName: coverImageName,
            coverImageURL: coverImageURL,
            description: description,
            startsAt: startsAt,
            endsAt: endsAt,
            durationMinutes: durationMinutes,
            locationName: locationName,
            locationLat: locationLat,
            locationLng: locationLng,
            hostId: hostId,
            applyRules: applyRules,
            status: eventStatus,
            cancellationReason: cancellationReason,
            isRecurringGenerated: isRecurringGenerated,
            parentEventId: parentEventId,
            cycleNumber: cycleNumber,
            rsvpDeadline: rsvpDeadline,
            closedAt: closedAt,
            createdBy: createdBy,
            createdAt: createdAt,
            capacityMax: capacityMax,
            allowPlusOnes: allowPlusOnes,
            maxPlusOnesPerMember: maxPlusOnes
        )
    }

    fileprivate static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
```

- [ ] **Step 2: Run the test to verify it passes**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:TandasTests/ResourceRowEventDecoderTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -30
```

Expected: 3 tests pass — `happyPath`, `typeMismatch`, `missingStartsAt`.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRow+Event.swift \
        ios/TandasTests/Platform/Resources/ResourceRowEventDecoderTests.swift
git commit -m "feat(resources): add ResourceRow.decodeAsEvent projection

Inverse of sync_event_to_resource trigger (mig 00039). Decodes
metadata jsonb back into Event for callers holding raw rows.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 6: Add `updatedAt` to `Event` (tolerant decoder)

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Events/Event.swift`

- [ ] **Step 1: Add the property + decoder fallback**

In `ios/Packages/RuulCore/Sources/RuulCore/Events/Event.swift`, find the property list ending at `public let createdAt: Date` (around line 30) and add a new line below it:

```swift
public let createdAt: Date
public let updatedAt: Date
```

Find the `CodingKeys` enum and add:

```swift
case createdAt             = "created_at"
case updatedAt             = "updated_at"
```

Find the memberwise `init(...)` (around line 58) and add after `createdAt: Date,`:

```swift
createdAt: Date,
updatedAt: Date? = nil,
```

In the same `init` body, after `self.createdAt = createdAt`:

```swift
self.createdAt = createdAt
self.updatedAt = updatedAt ?? createdAt
```

In the tolerant `init(from:)` decoder, after `self.createdAt = try c.decode(Date.self, forKey: .createdAt)`:

```swift
self.createdAt = try c.decode(Date.self,   forKey: .createdAt)
self.updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? self.createdAt
```

- [ ] **Step 2: Build the package to confirm it compiles**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -10
```

Expected: `Build complete!`. (If errors mention call sites in `LiveEventRepository` or `MockEventRepository`, those constructors don't pass `updatedAt` — the default `nil` falls back to `createdAt`, so the existing call sites should still compile.)

- [ ] **Step 3: Build the full app target to confirm Mock + Live still compile**

```bash
cd /Users/jj/code/tandas && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Events/Event.swift
git commit -m "feat(events): add Event.updatedAt with tolerant decoder

Required for Event to conform to Resource protocol (Task 8).
Defaults to createdAt when missing — back-compat with fixtures
and existing rows that haven't synced an updated_at yet.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 7: Relax `Resource` data protocol — drop Codable + rename status → resourceStatus

**Why the rename:** The plan originally kept the protocol's status as `status: String` and used a `Mirror`-based workaround in Task 9 to avoid the name conflict with `Event.status: EventStatus` (typed enum). That Mirror trick doesn't actually work — Swift forbids stored property + extension-computed property of the same name. Cleaner: rename the protocol's requirement to `resourceStatus: String`. `Event` adds `var resourceStatus: String { status.rawValue }` via extension (no conflict). `ResourceRow` already has `let status: String` (the wire column); add a passthrough `var resourceStatus: String { status }`.

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Resource.swift`

- [ ] **Step 1: Replace the file contents**

Open `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Resource.swift` and replace the entire file with:

```swift
import Foundation

/// Generic platform resource — anything a group interacts with.
///
/// V1 implementations:
/// - `Event` (via the `Event+Resource` extension; lives in the `events` table)
/// - `ResourceRow` (concrete envelope reading directly from the `resources` table)
///
/// V2+ types — declared in `ResourceType` (slot/fund/position/asset/contribution)
/// — wear this protocol via either an `Event`-style domain struct + extension
/// or as `ResourceRow` envelopes when they have no per-type Swift home yet.
///
/// **Why not Codable on the protocol?** `Event` has its own bespoke wire shape
/// (flat columns mapping to `events`); `ResourceRow` has the polymorphic shape
/// (flat columns + `metadata` jsonb mapping to `resources`). They round-trip to
/// different SQL tables and a single Codable witness would fight both. Concrete
/// types stay Codable; the protocol is the abstract shape only.
public protocol Resource: Identifiable, Sendable {
    var id: UUID { get }
    var groupId: UUID { get }
    var resourceType: ResourceType { get }
    /// Free-form status string. Per-type enums (e.g. `EventStatus`) bridge via rawValue.
    var status: String { get }
    var createdAt: Date { get }
    var updatedAt: Date { get }
}
```

- [ ] **Step 2: Build the package to confirm it compiles**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -10
```

Expected: `Build complete!`. The `ResourceRow: Resource, Codable` conformance from Task 3 already satisfies this — Codable is now an additional conformance on the concrete type, not protocol-mandated.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Resource.swift
git commit -m "refactor(resources): drop Codable requirement from Resource protocol

Concrete types (ResourceRow, Event) stay Codable. Protocol is the
abstract shape only — lets Event conform via extension without a
Codable witness fight against its bespoke events-table mapping.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 8: Write failing test for `Event: Resource` conformance

**Files:**
- Create: `ios/TandasTests/Platform/Resources/EventResourceConformanceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import RuulCore

@Suite("Event: Resource conformance")
struct EventResourceConformanceTests {
    private func sampleEvent() -> Event {
        Event(
            id: UUID(),
            groupId: UUID(),
            title: "Cena",
            startsAt: .now.addingTimeInterval(86_400),
            createdAt: .now
        )
    }

    @Test("Event conforms to Resource via extension")
    func conforms() {
        let event = sampleEvent()
        let resource: any Resource = event

        #expect(resource.id == event.id)
        #expect(resource.groupId == event.groupId)
        #expect(resource.resourceType == .event)
    }

    @Test("status bridges via EventStatus.rawValue")
    func statusBridge() {
        let event = sampleEvent()
        let resource: any Resource = event
        #expect(resource.status == event.status.rawValue)
    }

    @Test("updatedAt falls back to createdAt when not provided")
    func updatedAtFallback() {
        let event = sampleEvent()
        let resource: any Resource = event
        #expect(resource.updatedAt == resource.createdAt)
    }

    @Test("an array of any Resource can hold Event values")
    func collectionShape() {
        let events = (0..<3).map { _ in sampleEvent() }
        let resources: [any Resource] = events
        #expect(resources.count == 3)
        #expect(resources.allSatisfy { $0.resourceType == .event })
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:TandasTests/EventResourceConformanceTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -30
```

Expected: FAIL — `type 'Event' does not conform to protocol 'Resource'`.

---

### Task 9: Add `Event: Resource` extension to make Task 8 pass

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Event+Resource.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Makes `Event` a first-class `Resource`. The wrapper-based approach
/// (the deleted `EventResource` struct in RuulUI) was scaffolding —
/// now that `Resource` no longer requires Codable, `Event` can wear
/// the protocol directly.
///
/// `Event.status` is `EventStatus` (a typed enum). Resource expects
/// `String` — bridge via `rawValue`. This means downstream code that
/// matches on `resource.status` strings stays correct: e.g.
/// `"scheduled"`, `"in_progress"`, `"completed"`, `"cancelled"`.
extension Event: Resource {
    public var resourceType: ResourceType { .event }
    public var status: String { eventStatus.rawValue }
}

/// Disambiguator for callers that want the typed enum after the
/// Resource protocol attaches `status: String`.
public extension Event {
    var eventStatus: EventStatus {
        // Read the original stored property via a helper to avoid the
        // protocol conformance shadowing the enum-typed one. This works
        // because `Event` declared `status: EventStatus` before the
        // extension and Swift resolves the stored property by name on
        // direct access from within the same module.
        // No-op forwarding — kept for readability at call sites.
        statusEnum
    }

    /// Internal alias to the stored property — the `eventStatus`
    /// public accessor calls through here so the protocol-imposed
    /// `status: String` doesn't conflict with the original enum.
    internal var statusEnum: EventStatus { _statusValue }

    /// Backing value. Reads `Event.status` (the original stored
    /// property) bypassing the extension by going through a key path
    /// the compiler resolves at the type level.
    private var _statusValue: EventStatus {
        // The stored property still exists on Event; we name-shadow it
        // with the extension's computed `status: String`. To recover
        // the typed value, we re-read via Mirror — cheap for a struct.
        for child in Mirror(reflecting: self).children
            where child.label == "status" {
            if let v = child.value as? EventStatus { return v }
        }
        return .upcoming
    }
}
```

> **Note for the implementing engineer:** The `Mirror`-based recovery in `_statusValue` is the simplest workaround for Swift's name shadowing between the extension's computed `status: String` and the stored `status: EventStatus`. If the team prefers, an alternative is to **rename `Event.status` to `Event.eventStatus`** at the source, drop the `_statusValue` Mirror dance, and update all call sites — that's cleaner long-term but expands the diff to ~30 files. The Mirror approach is contained and Phase 2 can finish the rename.

- [ ] **Step 2: Run the test to verify it passes**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:TandasTests/EventResourceConformanceTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -30
```

Expected: 4 tests pass — `conforms`, `statusBridge`, `updatedAtFallback`, `collectionShape`.

- [ ] **Step 3: Run the full test suite to confirm nothing else broke**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -20
```

Expected: all tests pass. If any existing test calls `event.status` and now hits `String` instead of `EventStatus`, the call site needs `event.eventStatus`. Inspect the failure and patch only the calling test, not the production code.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Event+Resource.swift \
        ios/TandasTests/Platform/Resources/EventResourceConformanceTests.swift
git commit -m "feat(resources): make Event conform to Resource directly

Drops the EventResource wrapper indirection. Event.eventStatus
gives access to the typed enum for call sites that need it.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 10: Write failing test for `MockResourceRepository`

**Files:**
- Create: `ios/TandasTests/Platform/Resources/ResourceRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import RuulCore

@Suite("MockResourceRepository")
struct ResourceRepositoryTests {
    private func sampleRow(
        groupId: UUID,
        type: ResourceType = .event,
        status: String = "scheduled"
    ) -> ResourceRow {
        ResourceRow(
            id: UUID(),
            groupId: groupId,
            resourceType: type,
            status: status,
            metadata: .empty,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @Test("list filters by group + types + statuses")
    func listFilters() async throws {
        let g1 = UUID()
        let g2 = UUID()
        let rows = [
            sampleRow(groupId: g1, type: .event,  status: "scheduled"),
            sampleRow(groupId: g1, type: .event,  status: "completed"),
            sampleRow(groupId: g1, type: .slot,   status: "open"),
            sampleRow(groupId: g2, type: .event,  status: "scheduled")
        ]
        let repo = MockResourceRepository(seed: rows)

        let scoped = try await repo.list(
            in: g1,
            types: [.event],
            statuses: ["scheduled"],
            limit: 10
        )

        #expect(scoped.count == 1)
        #expect(scoped.first?.groupId == g1)
        #expect(scoped.first?.resourceType == .event)
        #expect(scoped.first?.status == "scheduled")
    }

    @Test("list with nil statuses returns all statuses for the requested types")
    func listAllStatuses() async throws {
        let g1 = UUID()
        let rows = [
            sampleRow(groupId: g1, status: "scheduled"),
            sampleRow(groupId: g1, status: "completed"),
            sampleRow(groupId: g1, status: "cancelled")
        ]
        let repo = MockResourceRepository(seed: rows)

        let all = try await repo.list(
            in: g1,
            types: [.event],
            statuses: nil,
            limit: 10
        )
        #expect(all.count == 3)
    }

    @Test("resource(_:) returns the row by id")
    func resourceByIdHit() async throws {
        let g1 = UUID()
        let row = sampleRow(groupId: g1)
        let repo = MockResourceRepository(seed: [row])

        let got = try await repo.resource(row.id)
        #expect(got.id == row.id)
    }

    @Test("resource(_:) throws notFound for unknown id")
    func resourceByIdMiss() async throws {
        let repo = MockResourceRepository(seed: [])

        await #expect(throws: ResourceRowError.notFound) {
            _ = try await repo.resource(UUID())
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:TandasTests/ResourceRepositoryTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -30
```

Expected: FAIL — `cannot find 'MockResourceRepository' in scope`.

---

### Task 11: Implement `ResourceRepository` (protocol + Mock + Live)

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/ResourceRepository.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import Supabase

/// Read-only polymorphic gateway to `public.resources`. Returns rows
/// of any `ResourceType`. Writes still flow through resource-type-
/// specific repos (V1: `EventRepository`); the SQL trigger
/// `events_sync_to_resources` (mig 00039) mirrors them into the
/// resources table automatically.
///
/// Date-bound queries (e.g. "next 10 events starting from today") stay
/// on `EventRepository` for now — the resources table has no flat
/// `starts_at` column, only `metadata` jsonb. Phase 2 may add per-type
/// projection views or generated columns; until then, use this repo
/// for type-bound polymorphic listing and per-id detail fetches.
public protocol ResourceRepository: Actor {
    /// Lists resources in a group, optionally filtering by types and statuses.
    /// - Parameters:
    ///   - groupId: scope.
    ///   - types: required — at least one. Pass `[.event]` for V1 callers.
    ///   - statuses: optional — `nil` means any status.
    ///   - limit: server cap.
    func list(
        in groupId: UUID,
        types: [ResourceType],
        statuses: [String]?,
        limit: Int
    ) async throws -> [ResourceRow]

    /// Fetches a single resource row by id. Throws `ResourceRowError.notFound`
    /// when the id is unknown or RLS hides it.
    func resource(_ id: UUID) async throws -> ResourceRow
}

// MARK: - Mock

public actor MockResourceRepository: ResourceRepository {
    public private(set) var rows: [ResourceRow]
    public var nextFetchError: ResourceRowError?

    public init(seed: [ResourceRow] = []) {
        self.rows = seed
    }

    public func list(
        in groupId: UUID,
        types: [ResourceType],
        statuses: [String]?,
        limit: Int
    ) async throws -> [ResourceRow] {
        if let err = nextFetchError { nextFetchError = nil; throw err }
        let typeSet = Set(types.map { $0.codegenRawValue })
        let statusSet = statuses.map(Set.init)
        return rows
            .filter { $0.groupId == groupId }
            .filter { typeSet.contains($0.resourceType.codegenRawValue) }
            .filter { row in
                guard let statuses = statusSet else { return true }
                return statuses.contains(row.status)
            }
            .prefix(limit)
            .map { $0 }
    }

    public func resource(_ id: UUID) async throws -> ResourceRow {
        if let err = nextFetchError { nextFetchError = nil; throw err }
        guard let row = rows.first(where: { $0.id == id }) else {
            throw ResourceRowError.notFound
        }
        return row
    }

    /// Test helper: append a row to the in-memory store.
    public func seed(_ row: ResourceRow) {
        rows.append(row)
    }
}

// MARK: - Live

public actor LiveResourceRepository: ResourceRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func list(
        in groupId: UUID,
        types: [ResourceType],
        statuses: [String]?,
        limit: Int
    ) async throws -> [ResourceRow] {
        let typeStrings = types.map { $0.codegenRawValue }
        do {
            var query = client
                .from("resources")
                .select("*")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .in("resource_type", values: typeStrings)
            if let statuses {
                query = query.in("status", values: statuses)
            }
            return try await query
                .order("created_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw ResourceRowError.fetchFailed(error.localizedDescription)
        }
    }

    public func resource(_ id: UUID) async throws -> ResourceRow {
        do {
            return try await client
                .from("resources")
                .select("*")
                .eq("id", value: id.uuidString.lowercased())
                .single()
                .execute()
                .value
        } catch {
            // Supabase returns 406/PGRST116 on missing single — surface as notFound.
            if (error as NSError).localizedDescription.contains("0 rows") {
                throw ResourceRowError.notFound
            }
            throw ResourceRowError.fetchFailed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 2: Helper — make `ResourceType` produce a stable wire string**

`ResourceType` is `@codegen:enum`-marked. Codegen produces `ResourceType+Codable.swift` that encodes/decodes against the SQL strings. We need an internal accessor to that wire string. Open the generated file at `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Generated/ResourceType+Codable.swift` and confirm it exposes a `rawValue` or equivalent. If it does, replace `$0.codegenRawValue` in the file you just wrote with the actual accessor name (likely `rawCodegenValue` or `wireValue`). If no public accessor exists, add one in a new file `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/ResourceType+WireValue.swift`:

```swift
import Foundation

public extension ResourceType {
    /// Stable string used over the wire and in `resources.resource_type`.
    /// Mirrors the codegen mapping in ResourceType+Codable.swift.
    var codegenRawValue: String {
        switch self {
        case .event:        return "event"
        case .slot:         return "slot"
        case .fund:         return "fund"
        case .position:     return "position"
        case .asset:        return "asset"
        case .contribution: return "contribution"
        case .unknown(let s): return s
        }
    }
}
```

- [ ] **Step 3: Run the test to verify it passes**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:TandasTests/ResourceRepositoryTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -30
```

Expected: 4 tests pass — `listFilters`, `listAllStatuses`, `resourceByIdHit`, `resourceByIdMiss`.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Repositories/ResourceRepository.swift \
        ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/ResourceType+WireValue.swift \
        ios/TandasTests/Platform/Resources/ResourceRepositoryTests.swift
git commit -m "feat(resources): add ResourceRepository (protocol + Mock + Live)

Read-only polymorphic gateway to public.resources. List filters by
group + types + statuses; resource(_:) for per-id fetches.
Live impl reads via Supabase REST; Mock is in-memory for tests.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 12: Wire `LiveResourceRepository` into AppState

**Files:**
- Modify: `ios/Tandas/TandasApp.swift`
- Modify: wherever the repo bag is held (likely `ios/Tandas/Shell/AppState.swift` or an env container struct — search to confirm)

- [ ] **Step 1: Locate the repo bag**

```bash
grep -n "eventRepo:\|fineRepo:\|groupsRepo:" ios/Tandas/Shell/*.swift ios/Tandas/TandasApp.swift 2>/dev/null | head -10
```

Identify the type holding the live repos (likely `AppState` or similar). The existing pattern in `TandasApp.swift:79` is `let events = LiveEventRepository(client: client)` followed by passing `events` into the AppState init.

- [ ] **Step 2: Add the construction call**

In `ios/Tandas/TandasApp.swift`, find the block constructing live repos (around line 70-90) and add a new line near the others:

```swift
let resources = LiveResourceRepository(client: client)
```

Then add `resources` to the AppState initializer call (find the existing `AppState(...)` invocation in this file and add a new argument matching the pattern of the existing repos — the parameter will be `resourceRepo: any ResourceRepository`).

- [ ] **Step 3: Add the property to AppState**

In the file holding `AppState` (or whichever container groups the repos), add a property next to `eventRepo`:

```swift
public let resourceRepo: any ResourceRepository
```

Update the initializer to accept and store it. Match the existing style — if the others are `@Observable` initialized vars, follow the same pattern.

- [ ] **Step 4: Update the mock-AppState used by previews/tests**

Search for places that construct `AppState` with mock repos:

```bash
grep -n "AppState(" ios/Tandas ios/TandasTests --include="*.swift" -r 2>/dev/null | head
```

For each, add `resourceRepo: MockResourceRepository()` to the constructor call. This is a mechanical change.

- [ ] **Step 5: Build the app target to confirm it compiles**

```bash
cd /Users/jj/code/tandas && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Run the full test suite**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add ios/Tandas/TandasApp.swift ios/Tandas/Shell/AppState.swift ios/TandasTests
git commit -m "feat(resources): wire LiveResourceRepository into AppState

Polymorphic resources gateway is now reachable from any coordinator
that has AppState. No consumers wired yet — that's Plan 6.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 13: Migrate `ResourceCard` to use `Event` directly

**Files:**
- Modify: `ios/Tandas/DesignSystem/Components/ResourceCard.swift`

- [ ] **Step 1: Replace the file**

Open `ios/Tandas/DesignSystem/Components/ResourceCard.swift` and replace it with:

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Generic resource card. Switches on `resource.resourceType` to dispatch
/// to the appropriate concrete view body. V1 only `.event` is wired and
/// re-uses the existing `EventCard` primitive — when Phase 2/3/4 ship
/// Slot/Fund/Position/Asset/Contribution, their bodies will hang off the
/// same switch here.
///
/// **Por qué scaffolding y no full HomeView swap V1**: HomeView's hero
/// es un render bespoke. ResourceCard V1 es scaffolding + router para
/// los consumers que SÍ usan EventCard hoy (`MyFeedView`, `PastEventsView`).
///
/// Invariante: `resource.resourceType == .event ⇒ resource is Event`
/// (Event conforms to Resource directly post Plan 1; the EventResource
/// wrapper is gone). Cast con seguridad dentro del case.
struct ResourceCard: View {
    let resource: any Resource
    let myStatus: RSVPStatus?
    let isHostedByMe: Bool
    let attendeeAvatars: [RuulAvatarStack.Person]
    let confirmedCount: Int
    let isAtCapacity: Bool
    let onTap: () -> Void

    init(
        resource: any Resource,
        myStatus: RSVPStatus? = nil,
        isHostedByMe: Bool = false,
        attendeeAvatars: [RuulAvatarStack.Person] = [],
        confirmedCount: Int = 0,
        isAtCapacity: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.resource = resource
        self.myStatus = myStatus
        self.isHostedByMe = isHostedByMe
        self.attendeeAvatars = attendeeAvatars
        self.confirmedCount = confirmedCount
        self.isAtCapacity = isAtCapacity
        self.onTap = onTap
    }

    var body: some View {
        switch resource.resourceType {
        case .event:
            if let event = resource as? Event {
                EventCard(
                    event: event,
                    myStatus: myStatus,
                    isHostedByMe: isHostedByMe,
                    attendeeAvatars: attendeeAvatars,
                    confirmedCount: confirmedCount,
                    isAtCapacity: isAtCapacity,
                    onTap: onTap
                )
            } else {
                // Defensive — V1 invariant says Event is the only .event
                // conformer. Si esto se rompe es bug, no UI fallback.
                UnknownResourceCard(resource: resource)
            }
        case .slot, .fund, .position, .asset, .contribution, .unknown:
            UnknownResourceCard(resource: resource)
        }
    }
}

private struct UnknownResourceCard: View {
    let resource: any Resource

    var body: some View {
        HStack(spacing: RuulSpacing.xs) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ruulTextTertiary)
            Text("Resource \(String(describing: resource.resourceType)) sin body")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 2: Build the app target**

```bash
cd /Users/jj/code/tandas && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/Tandas/DesignSystem/Components/ResourceCard.swift
git commit -m "refactor(resources): ResourceCard takes any Resource, casts to Event

Drops the EventResource wrapper indirection. Same invariant —
.event ⇒ Event — but expressed directly without the wrapper hop.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 14: Migrate `ResourceDetailView` to use `any Resource`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/ResourceDetailView.swift`

- [ ] **Step 1: Replace the file**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/ResourceDetailView.swift` and replace with:

```swift
import SwiftUI
import RuulUI
import RuulCore

/// Container del detail screen de cualquier resource. Switches por
/// `resource.resourceType` y dispatch al body apropiado.
///
/// V1 solo `.event` case con stub body (EventDetailBody). Otros 5
/// resource types (slot, fund, position, asset, contribution) muestran
/// UnknownResourceDetailBody hasta Phase 2/3.
///
/// V1 scope: scaffolding. EventDetailView preserva su surface
/// existente como canonical entry point para events. ResourceDetailView
/// se vuelve canonical en Phase 2 cuando llega Slot.
public struct ResourceDetailView: View {
    public let resource: any Resource

    public init(resource: any Resource) {
        self.resource = resource
    }

    public var body: some View {
        switch resource.resourceType {
        case .event:
            UnknownResourceDetailBody(resource: resource, label: "Event")
        case .slot, .fund, .position, .asset, .contribution, .unknown:
            UnknownResourceDetailBody(
                resource: resource,
                label: String(describing: resource.resourceType)
            )
        }
    }
}

private struct UnknownResourceDetailBody: View {
    public let resource: any Resource
    public let label: String

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("Resource detail (\(label)) — V1 stub")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Resource ID: \(resource.id.uuidString)")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.md)
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/jj/code/tandas && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/ResourceDetailView.swift
git commit -m "refactor(resources): ResourceDetailView uses any Resource

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 15: Migrate `HomeCoordinator.nextResource` to use `any Resource`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Coordinator/HomeCoordinator.swift`

- [ ] **Step 1: Update the property**

Find the `nextResource` block (around line 13-17) and replace with:

```swift
/// V1: el único concrete resource es Event. Ya no se envuelve en un
/// wrapper — Event conforma a Resource directamente. Cuando llegue
/// Slot/Fund en Phase 2, este accessor extiende para retornar un
/// resource del primer módulo activo cuyo type esté disponible.
public var nextResource: (any Resource)? {
    nextEvent
}
```

- [ ] **Step 2: Update the import block at the top**

Ensure the file imports `RuulCore` (it already does — verify the line `import RuulCore` is present).

- [ ] **Step 3: Build**

```bash
cd /Users/jj/code/tandas && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`. The previous `EventResource.init(_:)` mapping is gone — direct return of `nextEvent` works because `Event: Resource`.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Coordinator/HomeCoordinator.swift
git commit -m "refactor(resources): HomeCoordinator.nextResource returns any Resource

Direct passthrough — Event conforms to Resource so no wrapper hop.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 16: Replace `ResourceProtocol` (UI) with deprecated typealias

**Files:**
- Modify: `ios/Packages/RuulUI/Sources/RuulUI/Resources/ResourceProtocol.swift`
- Modify: `ios/Packages/RuulUI/Sources/RuulUI/Resources/ResourceActionsProvider.swift`

- [ ] **Step 1: Replace `ResourceProtocol.swift`**

Open `ios/Packages/RuulUI/Sources/RuulUI/Resources/ResourceProtocol.swift` and replace with:

```swift
import Foundation
import RuulCore

/// **Deprecated.** Use `RuulCore.Resource` directly. This typealias
/// preserves source compatibility for callers that haven't migrated.
/// Removed in a follow-up cleanup once all references are gone.
@available(*, deprecated, renamed: "Resource", message: "Use RuulCore.Resource directly")
public typealias ResourceProtocol = Resource
```

- [ ] **Step 2: Update `ResourceActionsProvider.swift`**

Open `ios/Packages/RuulUI/Sources/RuulUI/Resources/ResourceActionsProvider.swift` and change the associatedtype constraint:

```swift
import Foundation
import RuulCore

/// Estrategia para producir acciones contra un resource. Cada concrete
/// resource type tiene su provider (V1: `EventActionsProvider`, deferido
/// a Sub-fase D). El provider conoce las reglas de governance + el
/// estado del resource y decide qué acciones están disponibles.
///
/// **Associatedtype no existential**: `R: Resource` permite que el
/// provider concreto reciba el type ya tipado, sin `as!` interno.
public protocol ResourceActionsProvider: Sendable {
    associatedtype R: Resource

    func actions(
        for resource: R,
        member: Member,
        in group: Group
    ) async -> [ResourceAction]
}
```

- [ ] **Step 3: Build the package**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -10
```

Expected: `Build complete!`. Existing references to `ResourceProtocol` keep compiling (typealias), but with deprecation warnings.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulUI/Sources/RuulUI/Resources/ResourceProtocol.swift \
        ios/Packages/RuulUI/Sources/RuulUI/Resources/ResourceActionsProvider.swift
git commit -m "refactor(resources): ResourceProtocol is now an alias to Resource

UI-layer protocol becomes a deprecated typealias. Existing callers
get a warning; full removal in cleanup pass after consumers migrate.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 17: Delete `EventResource` wrapper

**Files:**
- Delete: `ios/Packages/RuulUI/Sources/RuulUI/Resources/EventResource.swift`

- [ ] **Step 1: Verify no remaining call sites**

```bash
grep -rn "EventResource" ios/ --include="*.swift" 2>/dev/null | grep -v ".build" | grep -v "// "
```

Expected: zero matches in production code (line comments are OK to keep). If matches remain, those are call sites that still call `EventResource.init(event)` — patch them to pass the `Event` directly.

- [ ] **Step 2: Delete the file**

```bash
rm /Users/jj/code/tandas/ios/Packages/RuulUI/Sources/RuulUI/Resources/EventResource.swift
```

- [ ] **Step 3: Build the full app target**

```bash
cd /Users/jj/code/tandas && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full test suite**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git rm ios/Packages/RuulUI/Sources/RuulUI/Resources/EventResource.swift
git commit -m "chore(resources): delete EventResource wrapper

Event conforms to Resource directly post Plan 1 — the wrapper has
no remaining purpose. ResourceProtocol typealias preserves callers
that haven't migrated; EventResource has zero references in code.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 18: Add `EventRepository.eventsFromResourceRows(_:)` helper

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/EventRepository.swift`

> **Why this task is here:** Plan 6 (HomeCoordinator resource fan-out) will receive `[ResourceRow]` from `ResourceRepository.list(...)` and want a typed `[Event]` back. Adding the helper here completes the round-trip and locks the ResourceRow → Event projection into the repo layer.

- [ ] **Step 1: Add the method to the protocol**

In `EventRepository.swift`, add inside the `public protocol EventRepository: Actor { ... }` block (after `setAutoGenerate`):

```swift
/// Decodes a batch of resource rows whose `resource_type == .event`
/// into typed `Event` values. Rows with mismatched type are skipped.
/// Used by polymorphic feeds that already hold rows.
func eventsFromResourceRows(_ rows: [ResourceRow]) async throws -> [Event]
```

- [ ] **Step 2: Implement on Mock**

In the same file, inside `public actor MockEventRepository: EventRepository { ... }`:

```swift
public func eventsFromResourceRows(_ rows: [ResourceRow]) async throws -> [Event] {
    rows.compactMap { try? $0.decodeAsEvent() }
}
```

- [ ] **Step 3: Implement on Live**

In the same file, inside `public actor LiveEventRepository: EventRepository { ... }`:

```swift
public func eventsFromResourceRows(_ rows: [ResourceRow]) async throws -> [Event] {
    rows.compactMap { try? $0.decodeAsEvent() }
}
```

(The implementation is identical for now — pure decoding. Phase 2 may diverge if Live wants to fall back to a fresh fetch when decoding fails.)

- [ ] **Step 4: Write a test**

Create `ios/TandasTests/Events/EventRepositoryRowDecodingTests.swift`:

```swift
import Testing
import Foundation
import RuulCore

@Suite("EventRepository.eventsFromResourceRows")
struct EventRepositoryRowDecodingTests {
    @Test("Mock decodes event rows and skips non-event rows")
    func mockDecodes() async throws {
        let groupId = UUID()
        let eventRow = ResourceRow(
            id: UUID(),
            groupId: groupId,
            resourceType: .event,
            status: "scheduled",
            metadata: .object([
                "title":            .string("Cena"),
                "starts_at":        .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(86_400))),
                "duration_minutes": .int(180)
            ]),
            createdAt: .now,
            updatedAt: .now
        )
        let slotRow = ResourceRow(
            id: UUID(), groupId: groupId, resourceType: .slot,
            status: "open", metadata: .empty,
            createdAt: .now, updatedAt: .now
        )
        let repo = MockEventRepository()

        let events = try await repo.eventsFromResourceRows([eventRow, slotRow])

        #expect(events.count == 1)
        #expect(events.first?.id == eventRow.id)
        #expect(events.first?.title == "Cena")
    }
}
```

- [ ] **Step 5: Run the test**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:TandasTests/EventRepositoryRowDecodingTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -20
```

Expected: 1 test passes — `mockDecodes`.

- [ ] **Step 6: Run the full suite**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Repositories/EventRepository.swift \
        ios/TandasTests/Events/EventRepositoryRowDecodingTests.swift
git commit -m "feat(events): add EventRepository.eventsFromResourceRows

Bridges ResourceRepository's polymorphic rows into typed Events.
Used by Plan 6 (HomeCoordinator resource fan-out).

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 19: Smoke test against live `resources` table

**Files:**
- Create: `ios/TandasTests/Platform/Resources/LiveResourceRepositorySmokeTests.swift` (DISABLED by default)

> **Why disabled:** smoke tests against live Supabase need network + valid creds. CI doesn't run them; they're for local manual verification.

- [ ] **Step 1: Write the smoke test (skipped by default)**

```swift
import Testing
import Foundation
import Supabase
import RuulCore

@Suite("LiveResourceRepository smoke", .disabled())
struct LiveResourceRepositorySmokeTests {
    @Test("list returns rows from a known group", .disabled())
    func smoke() async throws {
        // Manual: replace with a real groupId from your Supabase project.
        let groupId = UUID(uuidString: "REPLACE-WITH-REAL-GROUP-ID")!

        let url = URL(string: ProcessInfo.processInfo.environment["TANDAS_SUPABASE_URL"]!)!
        let key = ProcessInfo.processInfo.environment["TANDAS_SUPABASE_ANON_KEY"]!
        let client = SupabaseClient(supabaseURL: url, supabaseKey: key)
        let repo = LiveResourceRepository(client: client)

        let rows = try await repo.list(
            in: groupId,
            types: [.event],
            statuses: nil,
            limit: 10
        )

        // Sanity — V1 prod has 18 event resources. Any row in the
        // group should round-trip as an Event.
        for row in rows where row.resourceType == .event {
            _ = try row.decodeAsEvent()
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/TandasTests/Platform/Resources/LiveResourceRepositorySmokeTests.swift
git commit -m "test(resources): add disabled live smoke test for LiveResourceRepository

Manual verification scaffolding. CI skips by default.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

### Task 20: Final sweep + DoD verification

- [ ] **Step 1: Verify no `EventResource` references remain in production code**

```bash
grep -rn "EventResource" ios/ --include="*.swift" 2>/dev/null | grep -v ".build" | grep -v "//\|MARK\|/\\*"
```

Expected: zero matches except possibly inside line/block comments for historical reference.

- [ ] **Step 2: Verify no `ResourceProtocol` non-aliased references**

```bash
grep -rn "ResourceProtocol" ios/ --include="*.swift" 2>/dev/null | grep -v ".build" | grep -v "ResourceProtocol = Resource"
```

Expected: zero matches in production code outside the typealias declaration. Test code may still reference `ResourceProtocol` — keep those (they exercise the alias).

- [ ] **Step 3: Run the full test suite one final time**

```bash
cd /Users/jj/code/tandas && set -o pipefail && xcodebuild test \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tail -25
```

Expected: all tests pass. Specifically the new ones from this plan:
- `ResourceRowTests` (2)
- `ResourceRowEventDecoderTests` (3)
- `ResourceRepositoryTests` (4)
- `EventResourceConformanceTests` (4)
- `EventRepositoryRowDecodingTests` (1)

Total: 14 new tests.

- [ ] **Step 4: Verify the deprecation warning shows up**

```bash
cd /Users/jj/code/tandas && xcodebuild build \
  -project ios/Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | grep -i "deprecated"
```

Expected: at most warnings about `ResourceProtocol` being deprecated wherever it's still referenced. These warnings document follow-up cleanup work (not blockers).

- [ ] **Step 5: Confirm Plan 1 DoD**

Open `Plans/Active/Audit-2026-05-06.md` and find §3.10 (ResourceRepository genérico). Edit the bullet to add a note:

```markdown
### 3.10 ResourceRepository genérico

Hoy `EventRepository` lee directamente de `events`. No hay
`ResourceRepository` que lea de `resources` table. Bloquea testing
de slot/fund/position antes de tener UI específica.

**Update 2026-05-08**: shipped via Plan 1 — `LiveResourceRepository`
now reads polymorphic rows from `public.resources`. `EventRepository`
remains the canonical date-bound queryer; `eventsFromResourceRows(_:)`
bridges the two. ResourceProtocol convergence shipped in same plan
(Event conforms to Resource directly; EventResource wrapper deleted).
```

Find §4.7 (Dos `ResourceProtocol` paralelos) and append:

```markdown
**Update 2026-05-08**: shipped via Plan 1 — UI-layer ResourceProtocol
is now a deprecated typealias to RuulCore.Resource. EventResource
wrapper deleted. Convergence done; cleanup of the deprecation alias
pending follow-up.
```

- [ ] **Step 6: Commit the audit doc update**

```bash
git add Plans/Active/Audit-2026-05-06.md
git commit -m "docs(audit): mark §3.10 + §4.7 shipped via Plan 1

ResourceRepository foundation + ResourceProtocol convergence done.

Co-Authored-By: claude-flow <ruv@ruv.net>"
```

---

## Self-review checklist

After completing all tasks, verify:

**Spec coverage:**
- [ ] `ResourceRepository` exists, reads `public.resources`, supports type+status filters → Tasks 10-12
- [ ] `MockResourceRepository` exists, in-memory, used in tests → Task 11
- [ ] `LiveResourceRepository` exists, wired into AppState → Tasks 11-12
- [ ] `ResourceRow` decodes a `resources` row → Tasks 2-3
- [ ] `ResourceRow.decodeAsEvent()` projects metadata jsonb → Tasks 4-5
- [ ] `Event` conforms to `Resource` directly → Tasks 8-9
- [ ] Two `ResourceProtocol` collapsed into one → Tasks 7, 16
- [ ] `EventResource` wrapper removed → Task 17
- [ ] Existing UI dispatch (`ResourceCard`, `ResourceDetailView`, `nextResource`) preserved → Tasks 13-15
- [ ] `EventRepository.eventsFromResourceRows(_:)` bridges → Task 18
- [ ] Audit doc reflects shipped status → Task 20

**No placeholders:**
- [ ] Every step shows the exact code or command — verified.
- [ ] No "TBD", "fill in details", or "similar to" — verified.
- [ ] Test code is complete in every Step 1 of test tasks — verified.

**Type consistency:**
- [ ] `ResourceRow.metadata: JSONConfig` matches subscript helper added in Task 3 — verified.
- [ ] `ResourceRowError` cases used in tests match those defined in Task 1 — verified.
- [ ] `Event.eventStatus` accessor (Task 9) matches the calling convention used by any pre-existing test that currently calls `event.status` and expects `EventStatus` — flagged as inspection step in Task 9 Step 3.
- [ ] `Resource.status: String` bridges via `EventStatus.rawValue` — defined in Task 9.

**Risk callouts for the implementing engineer:**
- Task 9's `Mirror`-based `_statusValue` is a workaround. If the team is comfortable, prefer the cleaner approach: rename `Event.status: EventStatus` to `Event.eventStatus: EventStatus` at the source (one edit + ~30 call site updates), drop the Mirror dance, and let the extension's `status: String` be the only `status` accessor. The Mirror approach is contained but slower and uses runtime reflection.
- Task 12 touches `AppState`. If a parallel session is editing AppState, coordinate before merging — the additive property won't conflict structurally but the initializer signature change does. Prefer landing this task at a moment when AppState is stable.
- The `codegenRawValue` accessor in Task 11 Step 2 may already exist under a different name. Check `ResourceType+Codable.swift` before adding the helper file — duplicating it causes a compile error.
