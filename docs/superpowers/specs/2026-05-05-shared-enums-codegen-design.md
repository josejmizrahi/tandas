# Shared Enums Codegen — Design Spec

**Date:** 2026-05-05
**Roadmap reference:** Plans/Roadmap.md §3 Fase 0 item #1
**Status:** Approved (brainstorm 2026-05-05), pending implementation plan

---

## Goal

Eliminate manual sync between Swift and TypeScript for the 6 shared platform enums (`SystemEventType`, `ConditionType`, `ConsequenceType`, `ResourceType`, `GovernanceAction`, `PermissionLevel`). A hand-written Swift file is the single source; codegen produces a defensive Swift `Codable` extension plus a TypeScript union type. Pre-commit hook + CI prevent drift.

## Motivation

Three sources of truth exist today: Swift (`ios/Tandas/Platform/Models/`), TypeScript (`supabase/functions/_shared/platformTypes.ts`), and Postgres (`text` columns, no constraint). The TS file's own header comment says "Keep this file in sync with Swift" — manual convention that has already failed. Live drift example as of this spec:

- Swift `SystemEventType` has `fineReminderSent`, `voteOpened`, `voteResolved`.
- TS `SystemEventType` does not.

Rules referencing those triggers from seed data silently log "unknown" and skip in the rule engine. This is a recurring failure mode the Roadmap §1 calls out.

## Decisions

| # | Decision | Notes |
|---|---|---|
| 1 | **Swift is source.** TS is generated. | Matches existing convention in `platformTypes.ts` header comment. |
| 2 | **V1 scope: the 6 enums only.** | Structs (`SystemEvent`, `Rule`, `RuleTrigger`, etc.) stay hand-maintained. Future Fase 0.5 may extend. |
| 3 | **Postgres remains permissive.** | No `CHECK` constraint, no `CREATE TYPE`. Codegen does not touch DB. Avoids migration coupling and stays compatible with future custom-rules-per-group (Fase 5). |
| 4 | **Defensive Swift decoding via `case unknown(String)` bucket.** | Consumers must handle `.unknown` explicitly. Prevents crash when server emits a case the client predates. |
| 5 | **CI gate via pre-commit (lefthook) + verifier job.** | Local hook auto-regenerates and stages output; CI fails the PR if output is stale. Generated files are committed. |

## Architecture

```
SOURCE (hand-written)                    GENERATED (committed but not hand-edited)
─────────────────────                    ───────────────────────────────────────
ios/Tandas/Platform/Models/              ios/Tandas/Platform/Models/Generated/
  SystemEventType.swift          ─────►    SystemEventType+Codable.swift
  ConditionType.swift            ─────►    ConditionType+Codable.swift
  ConsequenceType.swift          ─────►    ConsequenceType+Codable.swift
  ResourceType.swift             ─────►    ResourceType+Codable.swift
  GovernanceAction.swift         ─────►    GovernanceAction+Codable.swift
  PermissionLevel.swift          ─────►    PermissionLevel+Codable.swift
                                         supabase/functions/_shared/types/
                                 ─────►    systemEventType.ts
                                 ─────►    conditionType.ts
                                 ─────►    consequenceType.ts
                                 ─────►    resourceType.ts
                                 ─────►    governanceAction.ts
                                 ─────►    permissionLevel.ts
                                         scripts/codegen/  (tooling, ~150–200 LOC)
```

Hand-written source files contain only case names + `case unknown(String)`. Computed properties (e.g., `isImplementedInV1`) move to `*+Extensions.swift` files; the parser ignores them.

`supabase/functions/_shared/platformTypes.ts` is rewritten to import each enum from `./types/<name>.ts`. The 7 interface/struct definitions (`SystemEvent`, `Rule`, `RuleTrigger`, `RuleCondition`, `RuleConsequence`, `RuleTarget`, `ExecutionResult`) stay in that file, hand-maintained.

## Source File Format

Required shape of a source enum file:

```swift
import Foundation

// @codegen:enum
public enum SystemEventType: Codable, Sendable, Hashable {
    case eventClosed
    case eventCreated
    // ... known cases
    case memberJoined
    case memberLeft

    case unknown(String)
}
```

Parser rules (all explicit; violation fails with line number):

- File must contain `// @codegen:enum` marker in the first 20 lines.
- The `enum { ... }` block contains only `case <name>` lines, the trailing `case unknown(String)`, blank lines, and Swift comments.
- No nested types, no associated values other than the trailing `unknown(String)`, no inline raw values, no protocol witnesses inside the enum body.
- Conformances on the declaration line (`Codable, Sendable, Hashable`) are preserved verbatim — the parser does not modify them.

Computed properties live in a sibling extension file:

```swift
// SystemEventType+Extensions.swift (hand-written, not parsed)
extension SystemEventType {
    public var isImplementedInV1: Bool {
        switch self {
        case .eventClosed, .checkInRecorded, /* ... */: return true
        case .checkInMissed, /* ... */: return false
        case .unknown: return false
        }
    }
}
```

## Generated Output

### Swift (`Generated/<Name>+Codable.swift`)

```swift
// AUTOGENERATED. Do not edit. Source: SystemEventType.swift
// Run: deno run -A scripts/codegen/gen-types.ts

import Foundation

extension SystemEventType {
    public static let knownCases: [SystemEventType] = [
        .eventClosed, .eventCreated, /* ... */
    ]

    public static let knownRawValues: Set<String> = [
        "eventClosed", "eventCreated", /* ... */
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.from(raw: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(self.rawString)
    }

    public var rawString: String {
        switch self {
        case .eventClosed: return "eventClosed"
        // ... all known cases
        case .unknown(let s): return s
        }
    }

    public static func from(raw: String) -> SystemEventType {
        switch raw {
        case "eventClosed": return .eventClosed
        // ... all known cases
        default: return .unknown(raw)
        }
    }
}
```

### TypeScript (`_shared/types/<name>.ts`)

```ts
// AUTOGENERATED. Do not edit. Source: ios/Tandas/Platform/Models/SystemEventType.swift
// Run: deno run -A scripts/codegen/gen-types.ts

export const systemEventTypeValues = [
  "eventClosed",
  "eventCreated",
  // ... all known cases
] as const;

export type SystemEventType = (typeof systemEventTypeValues)[number];

export function isSystemEventType(value: string): value is SystemEventType {
  return (systemEventTypeValues as readonly string[]).includes(value);
}
```

Notes:
- `Hashable` and `Sendable` ship from the source declaration; not regenerated.
- `CaseIterable` is not preserved (the `.unknown(_)` case violates its contract). Replacement is `knownCases`. All call sites using `.allCases` migrate to `.knownCases`.
- The TS `isSystemEventType` type guard is exposed but not enforced anywhere in V1. Future work may use it for inbound payload validation.

## Tooling

### Language: Deno

Reasons:
- Edge functions already use Deno; one runtime to install and trust.
- Single-binary install (`brew install deno`); no `package.json`, no `node_modules`.
- Native TypeScript without transpilation.
- CI install is fast and standard via `denoland/setup-deno@v1`.

### Layout

```
scripts/codegen/
├── gen-types.ts            # entry point (~50 LOC)
├── parser.ts               # Swift enum parser (~60 LOC)
├── emit-swift.ts           # +Codable.swift emitter (~40 LOC)
├── emit-ts.ts              # *.ts emitter (~30 LOC)
├── grep-orphans.ts         # SQL/TS string-literal validator (~80 LOC)
├── orphan-allowlist.txt    # benign matches (one camelCase id per line)
├── README.md               # dev-facing usage docs
└── test/
    ├── gen-types.test.ts   # parser + emitter tests
    ├── grep-orphans.test.ts# orphan detector tests
    └── fixtures/
        ├── sample-input.swift
        ├── expected-output.swift
        └── expected-output.ts
```

### Commands

```
deno run -A scripts/codegen/gen-types.ts          # regenerate all 6 enums
deno run -A scripts/codegen/gen-types.ts --check  # exit non-zero if output stale (CI mode)
deno test scripts/codegen/                        # codegen unit tests
```

### Makefile (root)

```makefile
.PHONY: gen gen-check gen-test gen-orphans

gen:
	deno run -A scripts/codegen/gen-types.ts

gen-check:
	deno run -A scripts/codegen/gen-types.ts --check

gen-orphans:
	deno run -A scripts/codegen/grep-orphans.ts

gen-test:
	deno test scripts/codegen/
```

## Pre-commit + CI

### Pre-commit hook (lefthook)

`brew install lefthook`. New file at repo root:

```yaml
# lefthook.yml
pre-commit:
  parallel: true
  commands:
    gen-types:
      glob: "ios/Tandas/Platform/Models/{SystemEventType,ConditionType,ConsequenceType,ResourceType,GovernanceAction,PermissionLevel}.swift"
      run: |
        deno run -A scripts/codegen/gen-types.ts
        git add ios/Tandas/Platform/Models/Generated supabase/functions/_shared/types
```

`lefthook install` activates per-developer. Devs without lefthook still pass CI as long as they run `make gen` before push.

### CI workflow

New file `.github/workflows/codegen.yml`:

```yaml
name: codegen

on:
  push:
    branches: [main, ios-rewrite]
  pull_request:

jobs:
  gen-types-clean:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: denoland/setup-deno@v1
        with:
          deno-version: v2.x
      - name: Run codegen tests
        run: deno test -A scripts/codegen/
      - name: Verify generated files are up to date
        run: |
          deno run -A scripts/codegen/gen-types.ts
          if ! git diff --exit-code ios/Tandas/Platform/Models/Generated supabase/functions/_shared/types; then
            echo "::error::Generated files out of date. Run 'make gen' and commit."
            exit 1
          fi
      - name: Check for orphan enum string literals
        run: deno run -A scripts/codegen/grep-orphans.ts
```

Runs in parallel with the existing `ios-ci.yml`. Expected runtime ~30s.

## Migration Plan

Per-enum, in this order (least risk first): `PermissionLevel`, `GovernanceAction`, `ResourceType`, `ConsequenceType`, `ConditionType`, `SystemEventType`. One commit per enum.

For each enum:

1. **Pre-flight check**: confirm every existing `case x = "y"` in the source file has `x == y` (case name equals raw value). All current 6 enums comply per inspection 2026-05-05, so removing the `= "..."` literals preserves wire format. If a future enum has a divergence, that's persisted state and needs a separate data-migration plan before this codegen migration.
2. **Mutate source file**: drop `: String, CaseIterable`; drop `= "rawValue"` literals; add `case unknown(String)`; add `// @codegen:enum`; move computed props to `<Name>+Extensions.swift`.
3. **Run `make gen`**: produces `Generated/<Name>+Codable.swift` and `_shared/types/<name>.ts`.
4. **Migrate Swift call sites**: `EnumType.allCases` → `EnumType.knownCases`; `EnumType(rawValue: s)` → `EnumType.from(raw: s)`; `enum.rawValue` → `enum.rawString`. Exhaustive switches gain `case .unknown(let s):` or `@unknown default`. (Per 2026-05-05 inspection: only 2 `.allCases` sites for the 6 target enums, both on `SystemEventType` in `GroupHistoryView.swift`. No explicit `(rawValue:)` for the 6 enums; Codable handles the rest.)
5. **Update `_shared/platformTypes.ts`**: replace inline union with `import { SystemEventType } from "./types/systemEventType.ts";`. Re-export if needed.
6. **Drift sweep**: the `grep-orphans.ts` CI tool now catches new orphans automatically. For this migration commit, also run it locally (`deno run -A scripts/codegen/grep-orphans.ts`) and address any pre-existing orphans surfaced (likely targets: `voteOpened`, `voteResolved` which exist in SQL but not in pre-migration TS — they will resolve themselves once `SystemEventType` is migrated).
7. **Run pre-merge audits** (per enum):
   - `PermissionLevel`: Audit A (governance jsonb round-trip).
   - `SystemEventType`: Audit C (silently-skipped rules waking up) before merge; Audit B (orphan rule triggers) after merge.
   - Other 4 enums: skip — none are persisted to jsonb columns or trigger consequences.
   See "Pre-merge audits" section for SQL.
8. **Verify tests**: `xcodebuild test`, `deno test supabase/functions/_tests/`.
9. **Commit**: one enum per commit.

After all 6 are migrated, the TS `_shared/platformTypes.ts` re-exports the 6 enum types from generated files. Drift documented in §Motivation closes (TS gains the 3 missing `SystemEventType` cases automatically).

**Risk: open PRs touching these enums during migration.** Mitigation: announce a 1–2 day migration window; coordinate; merge or block conflicting PRs.

## Testing

1. **Codegen unit tests** (`scripts/codegen/test/`):
   - Sample input fixture → expected output fixtures (both Swift and TS) match exactly.
   - Negative cases: missing marker → fails with clear error; non-`unknown` associated value → fails with line number; missing `case unknown(String)` → fails.

2. **Round-trip Swift** (`ios/TandasTests/Platform/CodableEnumsTests.swift`, one test per enum):

   ```swift
   func testSystemEventTypeRoundTrip() throws {
       for case_ in SystemEventType.knownCases {
           let data = try JSONEncoder().encode(case_)
           let decoded = try JSONDecoder().decode(SystemEventType.self, from: data)
           XCTAssertEqual(case_, decoded)
       }
       let unknownData = #""futureCase""#.data(using: .utf8)!
       let decoded = try JSONDecoder().decode(SystemEventType.self, from: unknownData)
       guard case .unknown(let s) = decoded, s == "futureCase" else {
           XCTFail("expected .unknown(\"futureCase\")")
           return
       }
   }
   ```

3. **Round-trip TS** (`supabase/functions/_tests/types.test.ts`):
   - `systemEventTypeValues` is a non-empty `readonly string[]`.
   - `isSystemEventType("eventClosed") === true`, `isSystemEventType("madeUp") === false`.

4. **Drift detection** is the CI `gen-types-clean` job itself.

## Rollout

1. Land tooling commit (codegen + Makefile + lefthook config + CI workflow). Generated dirs empty → CI green.
2. Migrate 6 enums one by one, per the migration plan above.
3. Rewrite `_shared/platformTypes.ts` to import generated.
4. Delete obsolete inline definitions from that file.
5. Sanity check on staging (Supabase staging project if exists; otherwise TestFlight build).

## Rollback

- Each enum migration is its own commit → revertible per enum.
- The tooling commit is independent of any migration → can land and idle.
- If mid-migration the pattern proves wrong for one enum, freeze: migrated enums keep their generated `+Codable.swift`, un-migrated enums stay as today.

## SQL / TS string-literal drift check (V1, in scope)

The codegen alone does not protect Postgres or non-`_shared/types/` TS files from referencing enum strings that don't exist. Today, ≥25 hardcoded enum strings live in `supabase/migrations/*.sql` (trigger functions, seed rules) and TS edge functions outside `_shared/`. If a case is renamed in Swift, those references silently break; today's drift between Swift's `voteOpened`/`voteResolved` and the missing TS counterparts is exactly this failure mode.

**Tool**: a third Deno script `scripts/codegen/grep-orphans.ts` runs in the same CI job. It:

1. Loads the catalog of known raw values from the just-generated TS files (`_shared/types/*.ts`).
2. Scans `supabase/migrations/*.sql`, `supabase/functions/**/*.ts` (excluding the generated `_shared/types/` dir), and Swift outside `Platform/Models/Generated/`.
3. Extracts string literals matching `[a-z][A-Za-z0-9]*` that look enum-shaped (camelCase, no spaces, length ≥3).
4. Reports any literal that appears in an enum-suggesting context (e.g., `event_type =`, `'eventType'`, `record_system_event(...,`) but is NOT in the catalog.
5. Allowlist file `scripts/codegen/orphan-allowlist.txt` for benign matches (e.g., shell command names, RPC names that happen to be camelCase).

False positives are expected; allowlisting is cheap. The job blocks PR if a new orphan appears that isn't allowlisted.

**Allowlist inclusion criteria** (must be in the file's header comment and enforced by review):

A string may be added to `orphan-allowlist.txt` only if **all** of the following hold:

- It is provably not an enum value of any of the 6 catalogued enums (today or in any planned future case).
- It originates from a different naming domain — e.g., a Postgres column or RPC name (`group_id`, `select_member`), a Stripe / Apple / Sentry SDK identifier (`paymentSheet`, `applePay`), a 3rd-party API field, an i18n key, or a Swift property name that happens to match `[a-z][A-Za-z0-9]*`.
- The PR adding it includes a one-line comment in the allowlist explaining the source: `paymentSheet     # Stripe SDK API name`.

Adding a string whose origin cannot be cited in one sentence is not allowed; in that case the answer is to add the value to the corresponding Swift enum source instead. PR review must reject silenced-without-explanation entries — otherwise the allowlist becomes a drift cemetery and defeats the purpose of the check.

This closes the Postgres source-of-truth gap without taking on `CHECK` constraints or `CREATE TYPE` (Decision 3 stands).

## Pre-merge audits (one-time, V1 migration only)

Two audits run during the migration, not in steady-state:

**Audit A — governance jsonb round-trip** (before merging the `PermissionLevel` migration):

Query a sample of production data:

```sql
select id, governance from groups limit 20;
```

Confirm every persisted value (`anyMember`, `founder`, `host`, `majorityVote`, etc.) appears in the post-migration `PermissionLevel.knownRawValues`. The Swift cases today use `case anyMember = "anyMember"` — codegen preserves rawString as the case name — so identity should hold. But verify before, not after. Same check applies to `GovernanceAction` if it's persisted anywhere.

**Audit B — orphan rule triggers** (after the `SystemEventType` migration):

Query `rules` for trigger event types that don't exist in the new catalog:

```sql
select id, group_id, name, trigger->'eventType' as event_type
from rules
where trigger->>'eventType' not in (
  -- list from the post-migration catalog, paste from generated TS values
);
```

Any row returned is a rule that was silently failing. Per row, decide: rename the trigger (data migration) or delete the rule.

**Audit C — silently-skipped rules waking up** (before the `SystemEventType` migration):

Adding `voteOpened`, `voteResolved`, and `fineReminderSent` to the TS catalog means the rule engine starts evaluating rules whose `trigger.eventType` matches them — rules that have been silently skipped to date. If those rules have side-effecting consequences (`fine`, `sendNotification`, `assignSlot`, `transferRight`), they begin firing prospectively the moment the migration deploys.

Run before merging the `SystemEventType` migration:

```sql
select id, group_id, name, is_active,
       trigger->>'eventType'         as trigger_event,
       jsonb_array_length(consequences) as cons_count,
       consequences
from rules
where is_active = true
  and trigger->>'eventType' in ('voteOpened', 'voteResolved', 'fineReminderSent')
order by group_id, name;
```

Per row, classify:

- **Designed-correct, was just broken** — flip the migration switch, accept that the rule starts working. Notify affected groups in advance if consequences create fines or notifications.
- **Stale / no longer wanted** — set `is_active=false` in a separate commit before the codegen migration lands.
- **Designed wrong, needs rewrite** — pause the migration on this enum until the rule is fixed.

Past `system_events` rows with these `event_type` values are already marked `processed_at IS NOT NULL` by the existing cron (which marks processed even when no rules match), so retroactive replay is not a concern. The risk is purely prospective.

All audits are documented runbooks, not code; their output gets attached to the migration PR before merge.

## Out of Scope (V1)

- Postgres `CHECK` constraints or `CREATE TYPE` (kept permissive per Decision 3).
- Codegen of structs/interfaces (`SystemEvent`, `Rule`, `RuleTrigger`, etc.) — possible Fase 0.5.
- Codegen of doc comments per case across to TS — would require parser to attribute comments to cases; not justified for V1.
- TS-side runtime enforcement of `isSystemEventType` on inbound payloads — guard is exposed but call sites are not migrated.
- Cross-repo deployment ordering safeguards (server-deploys-before-client). Defer to release-process documentation, not codegen scope.

## Success Criteria

- All 6 enums migrated and CI green.
- TS `_shared/platformTypes.ts` is free of inline enum string literals; all 6 enums imported from generated files.
- A new case added to any enum's source file requires a single `make gen` to produce both the Swift Generated and TS files; CI fails if forgotten.
- Zero decode-failure crashes from `SystemEventType` / `ConditionType` / `ConsequenceType` / `ResourceType` / `GovernanceAction` / `PermissionLevel` in TestFlight builds for two consecutive weeks after rollout.
- Roadmap §3 Fase 0 item #1 marked done.
