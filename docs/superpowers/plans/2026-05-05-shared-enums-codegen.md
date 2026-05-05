# Shared Enums Codegen — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up Swift→{Swift+Codable, TS} codegen for 5 platform enums with defensive `.unknown(String)` decoding, plus a CI grep that prevents new SQL/TS string-literal drift, and migrate the 5 enums onto the codegen pattern.

**Architecture:** Hand-written Swift enum (the source) is parsed by a Deno script. The script emits a defensive Codable extension to `ios/Tandas/Platform/Models/Generated/` and a TypeScript union type to `supabase/functions/_shared/types/`. A second Deno script scans SQL + TS for camelCase string literals near enum-suggesting tokens and reports any not in the catalog (configurable allowlist). Lefthook regenerates on commit; a CI job fails the PR if generated output is stale.

**Tech Stack:** Deno 2.x (matches edge functions runtime), lefthook (Go binary, no Node infra), GitHub Actions, Swift 6 / iOS 26 (existing).

**Spec reference:** `docs/superpowers/specs/2026-05-05-shared-enums-codegen-design.md` (commits `a51b914` → `376c10e`).

**Sentry dependency note:** Spec Success Criterion #4 ("zero decode-failure crashes for two consecutive weeks") depends on Sentry, which is a separate Fase 0 item. Until Sentry is wired in iOS, treat the criterion as: "no manually-reported decode crashes from TestFlight feedback for two weeks". Sentry installation upgrades this to automated measurement.

---

## File Structure

**New files** (Phase A):
- `scripts/codegen/parser.ts` — Swift enum parser; one responsibility: parse source file → structured `EnumDecl`.
- `scripts/codegen/emit-swift.ts` — Render `EnumDecl` → Swift `+Codable.swift` content.
- `scripts/codegen/emit-ts.ts` — Render `EnumDecl` → TypeScript `*.ts` content.
- `scripts/codegen/gen-types.ts` — CLI entry: discover source files, parse, emit, optionally check for diff.
- `scripts/codegen/grep-orphans.ts` — Scan SQL + TS for orphan camelCase literals; respect allowlist.
- `scripts/codegen/orphan-contexts.txt` — Pinned list of grep contexts (the four review flags' #4).
- `scripts/codegen/orphan-allowlist.txt` — Allowlist of benign matches with documented criteria.
- `scripts/codegen/README.md` — Dev-facing usage docs.
- `scripts/codegen/test/parser.test.ts`, `emit-swift.test.ts`, `emit-ts.test.ts`, `gen-types.test.ts`, `grep-orphans.test.ts` — TDD tests.
- `scripts/codegen/test/fixtures/sample-input.swift`, `expected-output.swift`, `expected-output.ts` — Golden fixtures.
- `Makefile` (root) — `make gen`, `make gen-check`, `make gen-orphans`, `make gen-test`.
- `lefthook.yml` (root) — Pre-commit hook config.
- `.github/workflows/codegen.yml` — CI verifier job.
- `ios/Tandas/Platform/Models/Generated/.gitkeep` — Empty dir marker until first migration adds files.
- `supabase/functions/_shared/types/.gitkeep` — Same.
- `ios/Tandas/Platform/Models/<Name>+Extensions.swift` (one per enum that has computed props).
- `ios/TandasTests/Platform/CodableEnumsTests.swift` — Round-trip Swift tests (added incrementally per migration).
- `supabase/functions/_tests/types.test.ts` — Round-trip TS tests.

**Modified files** (Phase B):
- `ios/Tandas/Platform/Models/PermissionLevel.swift`
- `ios/Tandas/Platform/Models/ResourceType.swift`
- `ios/Tandas/Platform/Models/ConsequenceType.swift`
- `ios/Tandas/Platform/Models/ConditionType.swift`
- `ios/Tandas/Platform/Models/SystemEventType.swift`
- Various Swift call sites that use `.allCases` / `(rawValue:)` / `.rawValue` for the migrated enums (the only `.allCases` sites in scope are 2 in `ios/Tandas/Features/History/Views/GroupHistoryView.swift`).

**Modified files** (Phase C):
- `supabase/functions/_shared/platformTypes.ts` — Replace inline `SystemEventType`, `ConditionType`, `ConsequenceType` unions with imports from `./types/`.

**Untouched in V1:**
- `ios/Tandas/Platform/Models/GovernanceAction.swift` — Out of scope per spec amendment.

---

## Phase A — Tooling foundation (8 commits)

### Task A1: Initialize codegen skeleton

**Files:**
- Create: `scripts/codegen/deno.jsonc`
- Create: `scripts/codegen/README.md`
- Create: `Makefile`
- Create: `ios/Tandas/Platform/Models/Generated/.gitkeep`
- Create: `supabase/functions/_shared/types/.gitkeep`

- [ ] **Step 1: Verify Deno is installed**

Run: `deno --version`
Expected: prints `deno 2.x.y` or similar. If not installed: `brew install deno`.

- [ ] **Step 2: Create `scripts/codegen/deno.jsonc`**

```jsonc
{
  // Local Deno config for the codegen tooling. Keeps lints/types consistent
  // and pins task aliases used by Makefile.
  "lint": {
    "rules": {
      "tags": ["recommended"]
    }
  },
  "fmt": {
    "lineWidth": 100,
    "useTabs": false,
    "indentWidth": 2
  },
  "tasks": {
    "gen": "deno run -A gen-types.ts",
    "gen:check": "deno run -A gen-types.ts --check",
    "gen:orphans": "deno run -A grep-orphans.ts",
    "test": "deno test -A"
  }
}
```

- [ ] **Step 3: Create `scripts/codegen/README.md`**

```markdown
# Shared Enums Codegen

Generates defensive Swift `Codable` extensions and TypeScript union types for platform enums whose source of truth is Swift.

## When to run

Anytime you add or rename a case in one of the source enums under `ios/Tandas/Platform/Models/` that has the `// @codegen:enum` marker.

If you have lefthook installed (`brew install lefthook && lefthook install`), this runs automatically on commit.

## Manual usage

From the repo root:

```sh
make gen          # regenerate all generated files
make gen-check    # exit non-zero if outputs are stale (used by CI)
make gen-orphans  # scan SQL + TS for orphan enum-shaped string literals
make gen-test     # run codegen unit tests
```

## Adding a new enum to the codegen

1. Source file `ios/Tandas/Platform/Models/<Name>.swift` must have `// @codegen:enum` in the first 20 lines.
2. The enum body must contain only `case <name>` lines, blank lines, comments, and a trailing `case unknown(String)`.
3. Move computed properties to a sibling extension file `<Name>+Extensions.swift`.
4. Run `make gen` and commit the generated files.

## Adding to the orphan allowlist

Edit `orphan-allowlist.txt`. Each entry needs a one-line comment explaining the source domain (column name, SDK identifier, etc.). PR review rejects entries lacking explanation.

## Out of scope

- Codegen of structs (only enums). 
- Postgres CHECK constraints (kept permissive per spec Decision 3).
- `GovernanceAction` (spec Out of Scope).
```

- [ ] **Step 4: Create `Makefile` at repo root**

```makefile
.PHONY: gen gen-check gen-orphans gen-test

gen:
	cd scripts/codegen && deno task gen

gen-check:
	cd scripts/codegen && deno task gen:check

gen-orphans:
	cd scripts/codegen && deno task gen:orphans

gen-test:
	cd scripts/codegen && deno task test
```

- [ ] **Step 5: Create empty placeholder dirs**

Run:
```sh
mkdir -p ios/Tandas/Platform/Models/Generated
mkdir -p supabase/functions/_shared/types
touch ios/Tandas/Platform/Models/Generated/.gitkeep
touch supabase/functions/_shared/types/.gitkeep
```

- [ ] **Step 6: Commit**

```sh
git add scripts/codegen/deno.jsonc scripts/codegen/README.md Makefile \
  ios/Tandas/Platform/Models/Generated/.gitkeep \
  supabase/functions/_shared/types/.gitkeep
git commit -m "$(cat <<'EOF'
chore(codegen): scaffold scripts/codegen + placeholder generated dirs

Phase A1 of shared-enums-codegen. Empty Deno workspace + Makefile.
No source enums migrated yet.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A2: Implement parser (TDD)

**Files:**
- Create: `scripts/codegen/parser.ts`
- Create: `scripts/codegen/test/fixtures/sample-input.swift`
- Create: `scripts/codegen/test/fixtures/divergent-input.swift`
- Create: `scripts/codegen/test/parser.test.ts`

- [ ] **Step 1: Create input fixtures**

`scripts/codegen/test/fixtures/sample-input.swift`:
```swift
import Foundation

// @codegen:enum
public enum SampleType: Codable, Sendable, Hashable {
    /// Doc comment on a case — parser ignores.
    case alpha
    case beta
    case gammaRay

    case unknown(String)
}
```

`scripts/codegen/test/fixtures/divergent-input.swift`:
```swift
import Foundation

// @codegen:enum
public enum BadType: Codable {
    case a
    case b(String)  // associated value not allowed except trailing unknown
    case unknown(String)
}
```

- [ ] **Step 2: Write the failing test**

`scripts/codegen/test/parser.test.ts`:
```ts
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { parseEnumFile } from "../parser.ts";

const FIXTURES = new URL("./fixtures/", import.meta.url);

Deno.test("parser: extracts enum name and case names from sample-input.swift", async () => {
  const result = await parseEnumFile(new URL("sample-input.swift", FIXTURES).pathname);
  assertEquals(result, {
    typeName: "SampleType",
    cases: ["alpha", "beta", "gammaRay"],
    sourceRelative: "scripts/codegen/test/fixtures/sample-input.swift",
  });
});

Deno.test("parser: rejects file without @codegen:enum marker", async () => {
  const tmp = await Deno.makeTempFile({ suffix: ".swift" });
  await Deno.writeTextFile(tmp, "public enum X { case a; case unknown(String) }\n");
  await assertRejects(
    () => parseEnumFile(tmp),
    Error,
    "missing // @codegen:enum marker",
  );
});

Deno.test("parser: rejects associated values other than trailing unknown(String)", async () => {
  await assertRejects(
    () => parseEnumFile(new URL("divergent-input.swift", FIXTURES).pathname),
    Error,
    "associated value",
  );
});

Deno.test("parser: rejects file missing trailing case unknown(String)", async () => {
  const tmp = await Deno.makeTempFile({ suffix: ".swift" });
  await Deno.writeTextFile(
    tmp,
    "// @codegen:enum\npublic enum X: Codable {\n  case a\n}\n",
  );
  await assertRejects(
    () => parseEnumFile(tmp),
    Error,
    "missing 'case unknown(String)'",
  );
});
```

- [ ] **Step 3: Run test, expect fail**

Run from `scripts/codegen/`: `deno test -A test/parser.test.ts`
Expected: FAIL with `Cannot find module '../parser.ts'` or similar.

- [ ] **Step 4: Implement `parser.ts`**

`scripts/codegen/parser.ts`:
```ts
// Minimal Swift enum parser for codegen.
//
// Recognized shape:
//
//   // @codegen:enum
//   public enum <Name>: <conformances> {
//       case <name1>
//       case <name2>
//       ...
//       case unknown(String)
//   }
//
// Anything else fails with a helpful message that includes a line number
// when one is locally derivable.

import { relative } from "jsr:@std/path@1";

export interface EnumDecl {
  typeName: string;
  cases: string[];
  /** Path relative to repo root, used in generated header comments. */
  sourceRelative: string;
}

const MARKER = "// @codegen:enum";
const MARKER_WINDOW = 20; // first N lines must contain the marker
const ENUM_HEADER_RE = /^public\s+enum\s+(?<name>[A-Z][A-Za-z0-9_]*)\s*:[^{]*\{\s*$/;
const CASE_RE = /^case\s+(?<name>[a-z][A-Za-z0-9_]*)\s*$/;
const UNKNOWN_CASE_RE = /^case\s+unknown\s*\(\s*String\s*\)\s*$/;

export async function parseEnumFile(path: string): Promise<EnumDecl> {
  const text = await Deno.readTextFile(path);
  return parseEnumText(text, path);
}

export function parseEnumText(text: string, path: string): EnumDecl {
  const rawLines = text.split(/\r?\n/);

  // 1. Marker check — must appear in first 20 lines.
  const markerIdx = rawLines.slice(0, MARKER_WINDOW).findIndex((l) =>
    l.trim() === MARKER
  );
  if (markerIdx < 0) {
    throw new Error(`${path}: missing // @codegen:enum marker in first ${MARKER_WINDOW} lines`);
  }

  // 2. Find `public enum X: ... {` somewhere after the marker.
  let headerLineIdx = -1;
  let typeName = "";
  for (let i = markerIdx + 1; i < rawLines.length; i++) {
    const m = rawLines[i].match(ENUM_HEADER_RE);
    if (m && m.groups) {
      headerLineIdx = i;
      typeName = m.groups.name;
      break;
    }
  }
  if (headerLineIdx < 0) {
    throw new Error(`${path}: could not find 'public enum <Name>: ... {' after marker`);
  }

  // 3. Walk body until matching closing brace at column 0.
  const cases: string[] = [];
  let sawUnknown = false;
  let bodyEnded = false;

  for (let i = headerLineIdx + 1; i < rawLines.length; i++) {
    const trimmed = rawLines[i].trim();
    if (trimmed === "}") {
      bodyEnded = true;
      break;
    }
    if (trimmed === "" || trimmed.startsWith("//") || trimmed.startsWith("///")) {
      continue;
    }

    const unknownMatch = trimmed.match(UNKNOWN_CASE_RE);
    if (unknownMatch) {
      if (sawUnknown) {
        throw new Error(
          `${path}:${i + 1}: duplicate 'case unknown(String)'`,
        );
      }
      sawUnknown = true;
      continue;
    }

    const caseMatch = trimmed.match(CASE_RE);
    if (caseMatch && caseMatch.groups) {
      if (sawUnknown) {
        throw new Error(
          `${path}:${i + 1}: 'case unknown(String)' must be the last case`,
        );
      }
      cases.push(caseMatch.groups.name);
      continue;
    }

    // Reject everything else (raw values, associated values, nested types).
    if (trimmed.includes("(") || trimmed.includes("=")) {
      throw new Error(
        `${path}:${i + 1}: unsupported associated value or raw value in '${trimmed}'`,
      );
    }
    throw new Error(`${path}:${i + 1}: unrecognized enum body line: '${trimmed}'`);
  }

  if (!bodyEnded) {
    throw new Error(`${path}: enum body did not close with '}' on its own line`);
  }
  if (cases.length === 0) {
    throw new Error(`${path}: enum has no known cases (besides unknown)`);
  }
  if (!sawUnknown) {
    throw new Error(`${path}: enum is missing 'case unknown(String)' as last case`);
  }

  // Compute repo-relative path for the generated header comment.
  const repoRoot = findRepoRoot(path);
  const sourceRelative = relative(repoRoot, path);

  return { typeName, cases, sourceRelative };
}

function findRepoRoot(fromPath: string): string {
  // Walk up until we see a .git directory (or reach /). Falls back to cwd.
  let dir = fromPath;
  for (let i = 0; i < 20; i++) {
    dir = dir.replace(/\/[^/]+\/?$/, "");
    if (!dir) break;
    try {
      const stat = Deno.statSync(`${dir}/.git`);
      if (stat.isDirectory) return dir;
    } catch (_) {
      // keep walking
    }
  }
  return Deno.cwd();
}
```

- [ ] **Step 5: Run test, expect pass**

Run: `cd scripts/codegen && deno test -A test/parser.test.ts`
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```sh
git add scripts/codegen/parser.ts scripts/codegen/test/parser.test.ts \
  scripts/codegen/test/fixtures/sample-input.swift \
  scripts/codegen/test/fixtures/divergent-input.swift
git commit -m "$(cat <<'EOF'
feat(codegen): Swift enum parser with marker and shape validation

Phase A2 of shared-enums-codegen. Parses files with // @codegen:enum
marker, extracts type name + case list. Rejects associated values,
inline raw values, missing trailing unknown(String). 4 unit tests.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A3: Implement Swift emitter (TDD)

**Files:**
- Create: `scripts/codegen/emit-swift.ts`
- Create: `scripts/codegen/test/fixtures/expected-output.swift`
- Create: `scripts/codegen/test/emit-swift.test.ts`

- [ ] **Step 1: Create golden output fixture**

`scripts/codegen/test/fixtures/expected-output.swift`:
```swift
// AUTOGENERATED. Do not edit. Source: scripts/codegen/test/fixtures/sample-input.swift
// Run: make gen

import Foundation

extension SampleType {
    public static let knownCases: [SampleType] = [
        .alpha,
        .beta,
        .gammaRay,
    ]

    public static let knownRawValues: Set<String> = [
        "alpha",
        "beta",
        "gammaRay",
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
        case .alpha: return "alpha"
        case .beta: return "beta"
        case .gammaRay: return "gammaRay"
        case .unknown(let s): return s
        }
    }

    public static func from(raw: String) -> SampleType {
        switch raw {
        case "alpha": return .alpha
        case "beta": return .beta
        case "gammaRay": return .gammaRay
        default: return .unknown(raw)
        }
    }
}
```

- [ ] **Step 2: Write the failing test**

`scripts/codegen/test/emit-swift.test.ts`:
```ts
import { assertEquals } from "jsr:@std/assert@1";
import { emitSwift } from "../emit-swift.ts";

const FIXTURES = new URL("./fixtures/", import.meta.url);

Deno.test("emit-swift: produces expected output for SampleType", async () => {
  const expected = await Deno.readTextFile(
    new URL("expected-output.swift", FIXTURES).pathname,
  );
  const actual = emitSwift({
    typeName: "SampleType",
    cases: ["alpha", "beta", "gammaRay"],
    sourceRelative: "scripts/codegen/test/fixtures/sample-input.swift",
  });
  assertEquals(actual, expected);
});
```

- [ ] **Step 3: Run test, expect fail**

Run: `cd scripts/codegen && deno test -A test/emit-swift.test.ts`
Expected: FAIL — `emit-swift.ts` does not exist.

- [ ] **Step 4: Implement `emit-swift.ts`**

`scripts/codegen/emit-swift.ts`:
```ts
import type { EnumDecl } from "./parser.ts";

export function emitSwift(decl: EnumDecl): string {
  const { typeName, cases, sourceRelative } = decl;

  const knownCases = cases.map((c) => `        .${c},`).join("\n");
  const knownRaw = cases.map((c) => `        "${c}",`).join("\n");
  const rawStringArms = cases
    .map((c) => `        case .${c}: return "${c}"`)
    .join("\n");
  const fromRawArms = cases
    .map((c) => `        case "${c}": return .${c}`)
    .join("\n");

  return `// AUTOGENERATED. Do not edit. Source: ${sourceRelative}
// Run: make gen

import Foundation

extension ${typeName} {
    public static let knownCases: [${typeName}] = [
${knownCases}
    ]

    public static let knownRawValues: Set<String> = [
${knownRaw}
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
${rawStringArms}
        case .unknown(let s): return s
        }
    }

    public static func from(raw: String) -> ${typeName} {
        switch raw {
${fromRawArms}
        default: return .unknown(raw)
        }
    }
}
`;
}
```

- [ ] **Step 5: Run test, expect pass**

Run: `cd scripts/codegen && deno test -A test/emit-swift.test.ts`
Expected: 1 test passes.

- [ ] **Step 6: Commit**

```sh
git add scripts/codegen/emit-swift.ts scripts/codegen/test/emit-swift.test.ts \
  scripts/codegen/test/fixtures/expected-output.swift
git commit -m "$(cat <<'EOF'
feat(codegen): Swift Codable extension emitter

Phase A3 of shared-enums-codegen. Renders +Codable.swift with
defensive init(from:), encode(to:), rawString, from(raw:), knownCases,
knownRawValues. Golden file test passes byte-for-byte.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A4: Implement TS emitter (TDD)

**Files:**
- Create: `scripts/codegen/emit-ts.ts`
- Create: `scripts/codegen/test/fixtures/expected-output.ts`
- Create: `scripts/codegen/test/emit-ts.test.ts`

- [ ] **Step 1: Create golden output fixture**

`scripts/codegen/test/fixtures/expected-output.ts`:
```ts
// AUTOGENERATED. Do not edit. Source: scripts/codegen/test/fixtures/sample-input.swift
// Run: make gen

export const sampleTypeValues = [
  "alpha",
  "beta",
  "gammaRay",
] as const;

export type SampleType = (typeof sampleTypeValues)[number];

export function isSampleType(value: string): value is SampleType {
  return (sampleTypeValues as readonly string[]).includes(value);
}
```

- [ ] **Step 2: Write the failing test**

`scripts/codegen/test/emit-ts.test.ts`:
```ts
import { assertEquals } from "jsr:@std/assert@1";
import { emitTs } from "../emit-ts.ts";

const FIXTURES = new URL("./fixtures/", import.meta.url);

Deno.test("emit-ts: produces expected output for SampleType", async () => {
  const expected = await Deno.readTextFile(
    new URL("expected-output.ts", FIXTURES).pathname,
  );
  const actual = emitTs({
    typeName: "SampleType",
    cases: ["alpha", "beta", "gammaRay"],
    sourceRelative: "scripts/codegen/test/fixtures/sample-input.swift",
  });
  assertEquals(actual, expected);
});
```

- [ ] **Step 3: Run test, expect fail**

Run: `cd scripts/codegen && deno test -A test/emit-ts.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 4: Implement `emit-ts.ts`**

`scripts/codegen/emit-ts.ts`:
```ts
import type { EnumDecl } from "./parser.ts";

export function emitTs(decl: EnumDecl): string {
  const { typeName, cases, sourceRelative } = decl;
  const valuesIdent = lowerFirst(typeName) + "Values";
  const guardIdent = "is" + typeName;

  const valueLines = cases.map((c) => `  "${c}",`).join("\n");

  return `// AUTOGENERATED. Do not edit. Source: ${sourceRelative}
// Run: make gen

export const ${valuesIdent} = [
${valueLines}
] as const;

export type ${typeName} = (typeof ${valuesIdent})[number];

export function ${guardIdent}(value: string): value is ${typeName} {
  return (${valuesIdent} as readonly string[]).includes(value);
}
`;
}

function lowerFirst(s: string): string {
  return s.length === 0 ? s : s[0].toLowerCase() + s.slice(1);
}
```

- [ ] **Step 5: Run test, expect pass**

Run: `cd scripts/codegen && deno test -A test/emit-ts.test.ts`
Expected: 1 test passes.

- [ ] **Step 6: Commit**

```sh
git add scripts/codegen/emit-ts.ts scripts/codegen/test/emit-ts.test.ts \
  scripts/codegen/test/fixtures/expected-output.ts
git commit -m "$(cat <<'EOF'
feat(codegen): TypeScript union type emitter

Phase A4 of shared-enums-codegen. Renders the values-tuple + branded
union + type guard. Golden file test passes byte-for-byte.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A5: Wire `gen-types.ts` entry point + integration test

**Files:**
- Create: `scripts/codegen/gen-types.ts`
- Create: `scripts/codegen/test/gen-types.test.ts`

- [ ] **Step 1: Write the failing integration test**

`scripts/codegen/test/gen-types.test.ts`:
```ts
import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { generate } from "../gen-types.ts";

Deno.test("gen-types: discovers marked sources, writes Swift + TS", async () => {
  const tmp = await Deno.makeTempDir();
  const swiftDir = `${tmp}/ios/Tandas/Platform/Models`;
  const swiftGen = `${swiftDir}/Generated`;
  const tsDir = `${tmp}/supabase/functions/_shared/types`;
  await Deno.mkdir(swiftDir, { recursive: true });
  await Deno.mkdir(swiftGen, { recursive: true });
  await Deno.mkdir(tsDir, { recursive: true });

  await Deno.writeTextFile(
    `${swiftDir}/SampleType.swift`,
    `import Foundation\n\n// @codegen:enum\npublic enum SampleType: Codable {\n  case alpha\n  case beta\n  case unknown(String)\n}\n`,
  );
  await Deno.writeTextFile(
    `${swiftDir}/Plain.swift`,
    `import Foundation\npublic enum Plain { case x }\n`, // no marker — must skip
  );

  const result = await generate({
    repoRoot: tmp,
    sourceDir: swiftDir,
    swiftOutDir: swiftGen,
    tsOutDir: tsDir,
    mode: "write",
  });

  assertEquals(result.processed.sort(), ["SampleType"]);
  assertEquals(result.skipped.length, 1);

  const swiftOut = await Deno.readTextFile(`${swiftGen}/SampleType+Codable.swift`);
  assertStringIncludes(swiftOut, "extension SampleType");
  assertStringIncludes(swiftOut, ".alpha,");

  const tsOut = await Deno.readTextFile(`${tsDir}/sampleType.ts`);
  assertStringIncludes(tsOut, "export const sampleTypeValues");
  assertStringIncludes(tsOut, '"alpha"');
});

Deno.test("gen-types: --check returns non-zero exit code when output is stale", async () => {
  const tmp = await Deno.makeTempDir();
  const swiftDir = `${tmp}/ios/Tandas/Platform/Models`;
  const swiftGen = `${swiftDir}/Generated`;
  const tsDir = `${tmp}/supabase/functions/_shared/types`;
  await Deno.mkdir(swiftDir, { recursive: true });
  await Deno.mkdir(swiftGen, { recursive: true });
  await Deno.mkdir(tsDir, { recursive: true });

  await Deno.writeTextFile(
    `${swiftDir}/SampleType.swift`,
    `import Foundation\n\n// @codegen:enum\npublic enum SampleType: Codable {\n  case alpha\n  case unknown(String)\n}\n`,
  );

  // No generated files exist — check should report stale.
  const result = await generate({
    repoRoot: tmp,
    sourceDir: swiftDir,
    swiftOutDir: swiftGen,
    tsOutDir: tsDir,
    mode: "check",
  });

  assertEquals(result.stale.length, 2); // missing Swift + TS
});
```

- [ ] **Step 2: Run test, expect fail**

Run: `cd scripts/codegen && deno test -A test/gen-types.test.ts`
Expected: FAIL — `gen-types.ts` does not exist.

- [ ] **Step 3: Implement `gen-types.ts`**

`scripts/codegen/gen-types.ts`:
```ts
// CLI entry point for the codegen.
//
// Discovers all *.swift files under the source dir, parses those that
// have the // @codegen:enum marker, and writes the generated Swift and
// TS counterparts. Files without the marker are silently skipped (so
// the lefthook glob can be a wildcard without errors).
//
// Modes:
//   --check (default off): does not write; reports any files whose
//     re-rendered content differs from disk. Used by CI.

import { parseEnumFile, type EnumDecl } from "./parser.ts";
import { emitSwift } from "./emit-swift.ts";
import { emitTs } from "./emit-ts.ts";

const DEFAULT_REPO_ROOT = (() => {
  // Resolve to two parents of this script: scripts/codegen/ → scripts/ → repo root.
  const here = new URL(".", import.meta.url).pathname;
  return here.replace(/\/scripts\/codegen\/?$/, "");
})();

const DEFAULT_SOURCE_DIR = `${DEFAULT_REPO_ROOT}/ios/Tandas/Platform/Models`;
const DEFAULT_SWIFT_OUT = `${DEFAULT_SOURCE_DIR}/Generated`;
const DEFAULT_TS_OUT = `${DEFAULT_REPO_ROOT}/supabase/functions/_shared/types`;

export interface GenerateOpts {
  repoRoot: string;
  sourceDir: string;
  swiftOutDir: string;
  tsOutDir: string;
  mode: "write" | "check";
}

export interface GenerateResult {
  processed: string[]; // typeNames
  skipped: string[];   // file paths
  stale: string[];     // output paths that differ (check mode)
}

const MARKER = "// @codegen:enum";

export async function generate(opts: GenerateOpts): Promise<GenerateResult> {
  const result: GenerateResult = { processed: [], skipped: [], stale: [] };

  for await (const entry of Deno.readDir(opts.sourceDir)) {
    if (!entry.isFile || !entry.name.endsWith(".swift")) continue;
    if (entry.name === "Generated" || entry.name.endsWith("+Extensions.swift")) continue;

    const path = `${opts.sourceDir}/${entry.name}`;
    const text = await Deno.readTextFile(path);
    if (!text.split(/\r?\n/).slice(0, 20).some((l) => l.trim() === MARKER)) {
      result.skipped.push(path);
      continue;
    }

    let decl: EnumDecl;
    try {
      decl = await parseEnumFile(path);
    } catch (e) {
      throw new Error(`parser failed on ${path}: ${e instanceof Error ? e.message : String(e)}`);
    }

    const swiftOut = `${opts.swiftOutDir}/${decl.typeName}+Codable.swift`;
    const tsOut = `${opts.tsOutDir}/${lowerFirst(decl.typeName)}.ts`;

    const swiftContent = emitSwift(decl);
    const tsContent = emitTs(decl);

    if (opts.mode === "check") {
      if (await diffs(swiftOut, swiftContent)) result.stale.push(swiftOut);
      if (await diffs(tsOut, tsContent)) result.stale.push(tsOut);
    } else {
      await Deno.writeTextFile(swiftOut, swiftContent);
      await Deno.writeTextFile(tsOut, tsContent);
    }
    result.processed.push(decl.typeName);
  }

  return result;
}

async function diffs(path: string, expected: string): Promise<boolean> {
  try {
    const actual = await Deno.readTextFile(path);
    return actual !== expected;
  } catch (_) {
    return true; // missing file counts as stale
  }
}

function lowerFirst(s: string): string {
  return s.length === 0 ? s : s[0].toLowerCase() + s.slice(1);
}

// CLI shim
if (import.meta.main) {
  const mode = Deno.args.includes("--check") ? "check" : "write";
  const result = await generate({
    repoRoot: DEFAULT_REPO_ROOT,
    sourceDir: DEFAULT_SOURCE_DIR,
    swiftOutDir: DEFAULT_SWIFT_OUT,
    tsOutDir: DEFAULT_TS_OUT,
    mode,
  });

  if (mode === "check" && result.stale.length > 0) {
    console.error("Stale generated files:");
    for (const p of result.stale) console.error(`  ${p}`);
    console.error("Run 'make gen' and commit.");
    Deno.exit(1);
  }

  console.log(`Processed: ${result.processed.join(", ") || "(none)"}`);
  if (result.skipped.length > 0) {
    console.log(`Skipped (no marker): ${result.skipped.length} file(s)`);
  }
}
```

- [ ] **Step 4: Run test, expect pass**

Run: `cd scripts/codegen && deno test -A test/gen-types.test.ts`
Expected: 2 tests pass.

- [ ] **Step 5: Smoke-test the CLI on the real repo (no source files marked yet → no-op)**

Run from repo root: `make gen`
Expected output: `Processed: (none)` and a "Skipped (no marker): N file(s)" line. No files written. No error.

- [ ] **Step 6: Run check mode**

Run: `make gen-check`
Expected: exit 0. No stale files because there are no `@codegen:enum` markers yet.

- [ ] **Step 7: Commit**

```sh
git add scripts/codegen/gen-types.ts scripts/codegen/test/gen-types.test.ts
git commit -m "$(cat <<'EOF'
feat(codegen): gen-types.ts CLI entry with write + --check modes

Phase A5 of shared-enums-codegen. Discovers @codegen:enum-marked
files in ios/Tandas/Platform/Models, emits Generated/<Name>+Codable.swift
and _shared/types/<name>.ts. Files without marker silently skipped.
--check mode reports stale outputs and exits non-zero.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A6: Implement orphan grep + contexts + allowlist

**Files:**
- Create: `scripts/codegen/grep-orphans.ts`
- Create: `scripts/codegen/orphan-contexts.txt`
- Create: `scripts/codegen/orphan-allowlist.txt`
- Create: `scripts/codegen/test/grep-orphans.test.ts`

- [ ] **Step 1: Pin the orphan-contexts list**

`scripts/codegen/orphan-contexts.txt`:
```
# Pinned list of token-contexts the orphan grep cares about.
# A camelCase string literal triggers the orphan check only if it
# appears within ORPHAN_PROXIMITY characters of one of these tokens
# on the same logical line.
#
# Adding a context: only do it for a real new place where enum string
# literals appear; not for every camelCase-adjacent column. PR review
# rejects expansions without justification.

# SQL contexts (supabase/migrations/*.sql)
record_system_event(
event_type
'eventType'
"eventType"
condition_type
'conditionType'
consequence_type
'consequenceType'
trigger->>'eventType'

# TypeScript contexts (supabase/functions/**/*.ts, excl. _shared/types/)
event_type:
eventType:
condition_type:
conditionType:
consequence_type:
consequenceType:
emitSystemEvent(
recordEvent(
```

- [ ] **Step 2: Initialize allowlist with documented criteria**

`scripts/codegen/orphan-allowlist.txt`:
```
# Allowlist of camelCase string literals that are NOT enum values.
#
# Inclusion criteria (must hold for every entry; PR review rejects entries
# that violate any of these):
#   1. The string is provably not an enum value of any catalogued enum,
#      now or in any planned future case.
#   2. It originates from a different naming domain — Postgres column,
#      RPC name, third-party SDK identifier, i18n key, etc.
#   3. The entry includes a one-line comment naming the source domain.
#
# Format: one identifier per line, optionally followed by '#' and a comment.
# Do not silence drift by adding entries without a citable origin.

# (none yet — populated as needed during enum migrations)
```

- [ ] **Step 3: Write the failing test**

`scripts/codegen/test/grep-orphans.test.ts`:
```ts
import { assertEquals } from "jsr:@std/assert@1";
import { findOrphans } from "../grep-orphans.ts";

Deno.test("grep-orphans: flags string literal near event_type if not in catalog", async () => {
  const tmp = await Deno.makeTempDir();
  await Deno.writeTextFile(
    `${tmp}/sample.sql`,
    "INSERT INTO system_events (event_type) VALUES ('madeUpEvent');\n",
  );
  await Deno.writeTextFile(`${tmp}/contexts.txt`, "event_type\n");
  await Deno.writeTextFile(`${tmp}/allowlist.txt`, "");

  const orphans = await findOrphans({
    catalog: new Set(["eventClosed", "voteCast"]),
    targetFiles: [`${tmp}/sample.sql`],
    contextsFile: `${tmp}/contexts.txt`,
    allowlistFile: `${tmp}/allowlist.txt`,
  });

  assertEquals(orphans, [
    {
      file: `${tmp}/sample.sql`,
      line: 1,
      identifier: "madeUpEvent",
      context: "event_type",
    },
  ]);
});

Deno.test("grep-orphans: respects allowlist", async () => {
  const tmp = await Deno.makeTempDir();
  await Deno.writeTextFile(
    `${tmp}/sample.sql`,
    "INSERT INTO system_events (event_type) VALUES ('madeUpEvent');\n",
  );
  await Deno.writeTextFile(`${tmp}/contexts.txt`, "event_type\n");
  await Deno.writeTextFile(`${tmp}/allowlist.txt`, "madeUpEvent  # placeholder\n");

  const orphans = await findOrphans({
    catalog: new Set(["eventClosed"]),
    targetFiles: [`${tmp}/sample.sql`],
    contextsFile: `${tmp}/contexts.txt`,
    allowlistFile: `${tmp}/allowlist.txt`,
  });

  assertEquals(orphans, []);
});

Deno.test("grep-orphans: ignores literals not near a context token", async () => {
  const tmp = await Deno.makeTempDir();
  await Deno.writeTextFile(
    `${tmp}/sample.sql`,
    "SELECT 'someRandomCamel' FROM unrelated;\n",
  );
  await Deno.writeTextFile(`${tmp}/contexts.txt`, "event_type\n");
  await Deno.writeTextFile(`${tmp}/allowlist.txt`, "");

  const orphans = await findOrphans({
    catalog: new Set(["eventClosed"]),
    targetFiles: [`${tmp}/sample.sql`],
    contextsFile: `${tmp}/contexts.txt`,
    allowlistFile: `${tmp}/allowlist.txt`,
  });

  assertEquals(orphans, []);
});
```

- [ ] **Step 4: Run test, expect fail**

Run: `cd scripts/codegen && deno test -A test/grep-orphans.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 5: Implement `grep-orphans.ts`**

`scripts/codegen/grep-orphans.ts`:
```ts
// Orphan-string detector.
//
// Scans target files for camelCase string literals that:
//   (a) appear on the same line as one of the pinned context tokens,
//   (b) are within ORPHAN_PROXIMITY chars of the context token,
//   (c) are not in the catalog (the union of all known enum raw values),
//   (d) are not in the allowlist.
//
// Reports orphans to stdout and exits non-zero if any are found.
// Designed for CI; fast (one pass, no AST).

const ORPHAN_PROXIMITY = 80; // characters
const STRING_LITERAL_RE = /['"]([a-z][A-Za-z0-9]{2,})['"]/g;

export interface FindOrphansOpts {
  catalog: Set<string>;
  targetFiles: string[];
  contextsFile: string;
  allowlistFile: string;
}

export interface Orphan {
  file: string;
  line: number;
  identifier: string;
  context: string;
}

export async function findOrphans(opts: FindOrphansOpts): Promise<Orphan[]> {
  const contexts = await readNonEmptyLines(opts.contextsFile);
  const allowlist = new Set(
    (await readNonEmptyLines(opts.allowlistFile)).map((l) =>
      l.split("#")[0].trim()
    ).filter(Boolean),
  );

  const orphans: Orphan[] = [];

  for (const file of opts.targetFiles) {
    const text = await Deno.readTextFile(file);
    const lines = text.split(/\r?\n/);

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const ctx = contexts.find((c) => line.includes(c));
      if (!ctx) continue;
      const ctxIdx = line.indexOf(ctx);

      STRING_LITERAL_RE.lastIndex = 0;
      let m: RegExpExecArray | null;
      while ((m = STRING_LITERAL_RE.exec(line)) !== null) {
        const litIdx = m.index;
        if (Math.abs(litIdx - ctxIdx) > ORPHAN_PROXIMITY) continue;
        const ident = m[1];
        if (opts.catalog.has(ident) || allowlist.has(ident)) continue;
        orphans.push({ file, line: i + 1, identifier: ident, context: ctx });
      }
    }
  }

  return orphans;
}

async function readNonEmptyLines(path: string): Promise<string[]> {
  const text = await Deno.readTextFile(path);
  return text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith("#"));
}

// CLI shim
if (import.meta.main) {
  const repoRoot = (() => {
    const here = new URL(".", import.meta.url).pathname;
    return here.replace(/\/scripts\/codegen\/?$/, "");
  })();
  const tsTypesDir = `${repoRoot}/supabase/functions/_shared/types`;
  const targetGlobs = [
    `${repoRoot}/supabase/migrations`,
    `${repoRoot}/supabase/functions`,
  ];

  // Build catalog from generated TS files.
  const catalog = new Set<string>();
  try {
    for await (const entry of Deno.readDir(tsTypesDir)) {
      if (!entry.isFile || !entry.name.endsWith(".ts")) continue;
      const content = await Deno.readTextFile(`${tsTypesDir}/${entry.name}`);
      for (const m of content.matchAll(/"([a-z][A-Za-z0-9]+)"/g)) {
        catalog.add(m[1]);
      }
    }
  } catch (_) {
    // _shared/types/ doesn't exist or is empty — catalog stays empty.
  }

  // Walk target dirs for .sql / .ts files (exclude generated TS types).
  const targetFiles: string[] = [];
  for (const dir of targetGlobs) {
    for await (const entry of walk(dir)) {
      if (!entry.isFile) continue;
      if (entry.path.includes("/_shared/types/")) continue;
      if (entry.path.endsWith(".sql") || entry.path.endsWith(".ts")) {
        targetFiles.push(entry.path);
      }
    }
  }

  const orphans = await findOrphans({
    catalog,
    targetFiles,
    contextsFile: `${repoRoot}/scripts/codegen/orphan-contexts.txt`,
    allowlistFile: `${repoRoot}/scripts/codegen/orphan-allowlist.txt`,
  });

  if (orphans.length > 0) {
    console.error(`Found ${orphans.length} orphan enum-shaped string literals:`);
    for (const o of orphans) {
      console.error(`  ${o.file}:${o.line}: '${o.identifier}' near '${o.context}'`);
    }
    console.error("");
    console.error("Resolve by either:");
    console.error("  - adding the identifier to the matching Swift enum source, then 'make gen'; or");
    console.error("  - adding it to scripts/codegen/orphan-allowlist.txt with a one-line origin comment.");
    Deno.exit(1);
  }

  console.log(`Scanned ${targetFiles.length} files; no orphan string literals.`);
}

async function* walk(
  root: string,
): AsyncGenerator<{ path: string; isFile: boolean }> {
  try {
    for await (const entry of Deno.readDir(root)) {
      const path = `${root}/${entry.name}`;
      if (entry.isFile) {
        yield { path, isFile: true };
      } else if (entry.isDirectory) {
        yield* walk(path);
      }
    }
  } catch (_) {
    // Skip unreadable dirs silently.
  }
}
```

- [ ] **Step 6: Run test, expect pass**

Run: `cd scripts/codegen && deno test -A test/grep-orphans.test.ts`
Expected: 3 tests pass.

- [ ] **Step 7: Smoke-test on the real repo**

Run from repo root: `make gen-orphans`
Expected: at this point the catalog is empty (no generated TS types yet) — every camelCase literal near a context will report as orphan. Most output is signal: it will surface every enum string literal currently hardcoded in SQL/TS files. **Do not act on the report yet** — it will resolve itself as Phase B migrations populate the catalog.

For this step, add the noisy output to a temporary allowlist or tolerate the failure exit code. The expectation is documented.

- [ ] **Step 8: Commit**

```sh
git add scripts/codegen/grep-orphans.ts scripts/codegen/test/grep-orphans.test.ts \
  scripts/codegen/orphan-contexts.txt scripts/codegen/orphan-allowlist.txt
git commit -m "$(cat <<'EOF'
feat(codegen): orphan-string grep with pinned contexts and allowlist

Phase A6 of shared-enums-codegen. grep-orphans.ts scans SQL +
edge-function TS for camelCase string literals near pinned tokens
and reports any not in the catalog or allowlist. Allowlist has
documented inclusion criteria. Will produce signal-rich output
until enum migrations populate the catalog (Phase B).

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A7: lefthook config + install instructions

**Files:**
- Create: `lefthook.yml`
- Modify: `scripts/codegen/README.md` (append install instructions)

- [ ] **Step 1: Verify lefthook is available**

Run: `which lefthook` or `lefthook version`
If not installed: `brew install lefthook`. If you cannot install, document but skip the install step; CI will still catch drift.

- [ ] **Step 2: Create `lefthook.yml`**

```yaml
# Lefthook config — runs the codegen on commit so generated files stay
# in sync with hand-written sources. Glob is intentionally wildcard;
# the codegen filters by the @codegen:enum marker, so it's safe to
# re-run on unrelated Swift edits (a no-op).

pre-commit:
  parallel: true
  commands:
    gen-types:
      glob: "ios/Tandas/Platform/Models/*.swift"
      run: |
        deno run -A scripts/codegen/gen-types.ts
        git add ios/Tandas/Platform/Models/Generated supabase/functions/_shared/types
```

- [ ] **Step 3: Install lefthook hook**

Run from repo root: `lefthook install`
Expected: prints `sync hooks: ✔` (or similar). Creates `.git/hooks/pre-commit`.

- [ ] **Step 4: Append install docs to `scripts/codegen/README.md`**

Append to the existing file:

```markdown

## Setting up the pre-commit hook

```sh
brew install lefthook
lefthook install
```

The hook runs `make gen` automatically on Swift edits in `ios/Tandas/Platform/Models/`. If you can't install lefthook, you must run `make gen` manually before committing — CI will fail otherwise.
```

- [ ] **Step 5: Commit**

```sh
git add lefthook.yml scripts/codegen/README.md
git commit -m "$(cat <<'EOF'
chore(codegen): lefthook pre-commit hook + install docs

Phase A7 of shared-enums-codegen. Wildcard glob on
ios/Tandas/Platform/Models/*.swift; the codegen filters by marker
internally so unrelated edits are no-ops. Adding a 6th source enum
later requires no glob change.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A8: CI workflow + final tooling commit

**Files:**
- Create: `.github/workflows/codegen.yml`

- [ ] **Step 1: Create the workflow file**

`.github/workflows/codegen.yml`:
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

      - name: Run codegen unit tests
        working-directory: scripts/codegen
        run: deno test -A

      - name: Verify generated files are up to date
        run: |
          deno run -A scripts/codegen/gen-types.ts
          if ! git diff --exit-code ios/Tandas/Platform/Models/Generated supabase/functions/_shared/types; then
            echo "::error::Generated files out of date. Run 'make gen' and commit."
            exit 1
          fi

      - name: Check for orphan enum string literals
        run: deno run -A scripts/codegen/grep-orphans.ts
        # Will succeed (no orphans) once Phase B migrations populate the catalog.
        # During Phase A there are no generated types yet → catalog is empty →
        # the run does report orphans. The CI step is allow-failure-style for
        # this transitional period; flip to required after Phase B5 lands.
        continue-on-error: true
```

- [ ] **Step 2: Commit**

```sh
git add .github/workflows/codegen.yml
git commit -m "$(cat <<'EOF'
ci(codegen): codegen.yml workflow with gen-check and orphan grep

Phase A8 of shared-enums-codegen. New ubuntu-latest job:
- runs codegen unit tests
- regenerates outputs and fails on diff
- runs grep-orphans (continue-on-error during Phase A; flip to
  required after Phase B completes and the catalog is populated).

Parallel with the existing ios-ci.yml.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

- [ ] **Step 3: Push the Phase A bundle for visibility**

```sh
git push origin main
```

Expected: 8 new commits land on origin. `gen-types-clean` job in the new workflow should pass (no source files marked yet).

---

## Phase B — Per-enum migrations (5 commits)

Each migration follows the same shape. Code blocks per task are self-contained — do not refer back across tasks.

### Task B1: Migrate `PermissionLevel` (with Audit A)

**Files:**
- Modify: `ios/Tandas/Platform/Models/PermissionLevel.swift`
- Generated by codegen: `ios/Tandas/Platform/Models/Generated/PermissionLevel+Codable.swift`
- Generated by codegen: `supabase/functions/_shared/types/permissionLevel.ts`
- Create: `ios/TandasTests/Platform/CodableEnumsTests.swift`

- [ ] **Step 1: Run Audit A — governance jsonb round-trip**

Run this query against the production Supabase DB:
```sql
select id, governance from groups limit 20;
```

For each row, expand the `governance` jsonb and confirm every `whoCan*` key's value (`anyMember`, `founder`, `host`, `majorityVote`, `supermajorityVote`, `treasurer`) appears in the post-migration `PermissionLevel.knownRawValues` list. Expected list after migration: `["founder", "anyMember", "majorityVote", "supermajorityVote", "host", "treasurer"]`.

If any persisted value is not in that set, **stop**: it is data the migration would invalidate. Investigate before continuing.

If all 20 rows clear, paste the audit output into the PR description.

- [ ] **Step 2: Write the failing round-trip test**

Create `ios/TandasTests/Platform/CodableEnumsTests.swift`:
```swift
import Foundation
import XCTest
@testable import Tandas

final class CodableEnumsTests: XCTestCase {
    func testPermissionLevelRoundTrip() throws {
        for value in PermissionLevel.knownCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(PermissionLevel.self, from: data)
            XCTAssertEqual(value, decoded)
        }

        let unknownData = #""futureLevel""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PermissionLevel.self, from: unknownData)
        guard case .unknown(let s) = decoded, s == "futureLevel" else {
            XCTFail("expected .unknown(\"futureLevel\"), got \(decoded)")
            return
        }
    }
}
```

- [ ] **Step 3: Run test, expect compile failure**

Run: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' -only-testing:TandasTests/CodableEnumsTests 2>&1 | tail -20`
Expected: compile failure — `PermissionLevel.knownCases` does not exist; `case .unknown(let s)` doesn't match a `String` raw enum.

- [ ] **Step 4: Mutate `ios/Tandas/Platform/Models/PermissionLevel.swift`**

Replace the file's contents with:
```swift
import Foundation

// @codegen:enum
public enum PermissionLevel: Codable, Sendable, Hashable {
    /// Only the founder of the group can perform the action.
    case founder

    /// Any active member of the group can perform the action.
    case anyMember

    /// A successful majority vote (>= 50% threshold by default) is required.
    case majorityVote

    /// A successful supermajority vote (>= 66% threshold by default) is required.
    case supermajorityVote

    /// Only the host of the contextual event can perform the action.
    case host

    /// Only the treasurer (V2 role) can perform the action.
    case treasurer

    case unknown(String)
}
```

Note: `: String, CaseIterable` removed; `Codable, Sendable, Hashable` retained. `PermissionLevel` has no computed properties to move, so no `+Extensions.swift` is needed.

- [ ] **Step 5: Run codegen**

Run from repo root: `make gen`
Expected: `Processed: PermissionLevel`. Two files created:
- `ios/Tandas/Platform/Models/Generated/PermissionLevel+Codable.swift`
- `supabase/functions/_shared/types/permissionLevel.ts`

- [ ] **Step 6: Add the new generated file to the Xcode project**

Run from repo root: `cd ios && xcodegen`
Expected: project regenerated; the new `Generated/PermissionLevel+Codable.swift` is now part of the Tandas target. Verify in the project navigator if running locally.

- [ ] **Step 7: Update Swift call sites**

`PermissionLevel` has zero `.allCases` and zero `(rawValue:)` references in the codebase per inspection 2026-05-05. The only adjustment is in `ios/Tandas/Platform/Models/GovernanceRules.swift` lines 54–59, where `c.decode(PermissionLevel.self, ...)` is already correct (Codable conformance preserved). No call site changes needed.

Verify with: `grep -rn "PermissionLevel\." ios/Tandas --include="*.swift" | grep -E "allCases|rawValue|\(rawValue:" | head`
Expected: no output.

- [ ] **Step 8: Run iOS tests**

Run: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' -only-testing:TandasTests/CodableEnumsTests 2>&1 | tail -10`
Expected: `testPermissionLevelRoundTrip` passes.

Then run the full suite:
Run: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' 2>&1 | tail -20`
Expected: all tests pass. `governance` decoding still works (the cases serialize identically because `case anyMember` produces `"anyMember"` — same as before).

- [ ] **Step 9: Commit**

```sh
git add ios/Tandas/Platform/Models/PermissionLevel.swift \
  ios/Tandas/Platform/Models/Generated/PermissionLevel+Codable.swift \
  supabase/functions/_shared/types/permissionLevel.ts \
  ios/TandasTests/Platform/CodableEnumsTests.swift \
  ios/Tandas.xcodeproj
git commit -m "$(cat <<'EOF'
feat(platform): migrate PermissionLevel to codegen pattern

Phase B1 of shared-enums-codegen. Source file now uses bare cases +
case unknown(String). Codegen produces +Codable.swift extension and
TS forward-compat union. Audit A (governance jsonb round-trip) cleared
on 20 sample rows pre-migration.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task B2: Migrate `ResourceType`

**Files:**
- Modify: `ios/Tandas/Platform/Models/ResourceType.swift`
- Generated: `ios/Tandas/Platform/Models/Generated/ResourceType+Codable.swift`
- Generated: `supabase/functions/_shared/types/resourceType.ts`
- Modify: `ios/TandasTests/Platform/CodableEnumsTests.swift`

- [ ] **Step 1: Inspect the current `ResourceType.swift` for computed props**

Run: `cat ios/Tandas/Platform/Models/ResourceType.swift`

If there are computed properties (`var isXxx: Bool`, etc.) outside the cases, they must be moved to a sibling extension file before mutating. If only doc comments and cases, proceed directly.

- [ ] **Step 2: Append the round-trip test for `ResourceType`**

Add to `ios/TandasTests/Platform/CodableEnumsTests.swift`:
```swift
    func testResourceTypeRoundTrip() throws {
        for value in ResourceType.knownCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ResourceType.self, from: data)
            XCTAssertEqual(value, decoded)
        }

        let unknownData = #""futureResource""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ResourceType.self, from: unknownData)
        guard case .unknown(let s) = decoded, s == "futureResource" else {
            XCTFail("expected .unknown(\"futureResource\"), got \(decoded)")
            return
        }
    }
```

- [ ] **Step 3: Run test, expect compile failure**

Run: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' -only-testing:TandasTests/CodableEnumsTests/testResourceTypeRoundTrip 2>&1 | tail -10`
Expected: compile failure on `ResourceType.knownCases`.

- [ ] **Step 4: Mutate `ResourceType.swift`**

Open `ios/Tandas/Platform/Models/ResourceType.swift`. Apply these structural changes:

1. Add `// @codegen:enum` immediately above `public enum ResourceType`.
2. Change the declaration from `public enum ResourceType: String, Codable, Sendable, Hashable, CaseIterable {` to `public enum ResourceType: Codable, Sendable, Hashable {`.
3. Remove any `= "rawValue"` literal from each case.
4. Add `case unknown(String)` as the last case (with a blank line above).
5. If computed properties (`var x: T { ... }` or `func y(...)`) live inside the enum body or extensions in the same file, move them to a new file `ios/Tandas/Platform/Models/ResourceType+Extensions.swift` with the `extension ResourceType { ... }` wrapper. Add a `case .unknown:` arm to every exhaustive switch in those props.

- [ ] **Step 5: Run codegen**

Run: `make gen`
Expected: `Processed: PermissionLevel, ResourceType`. Two new files created.

- [ ] **Step 6: Refresh Xcode project**

Run: `cd ios && xcodegen`

- [ ] **Step 7: Find and update Swift call sites**

Run: `grep -rn "ResourceType\." ios/Tandas --include="*.swift" | grep -E "allCases|\(rawValue:|\.rawValue"`

For each match, apply:
- `.allCases` → `.knownCases`
- `(rawValue: someString)` → `.from(raw: someString)` (note: now returns non-optional)
- `.rawValue` → `.rawString`

Exhaustive switches on `ResourceType` need a `case .unknown(let s):` arm or `@unknown default:`. Pick the explicit arm where the meaning is clear (typically: log + treat as a no-op).

- [ ] **Step 8: Run iOS tests**

Run: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' 2>&1 | tail -20`
Expected: all tests pass including `testResourceTypeRoundTrip`.

- [ ] **Step 9: Commit**

```sh
git add ios/Tandas/Platform/Models/ResourceType.swift \
  ios/Tandas/Platform/Models/ResourceType+Extensions.swift 2>/dev/null \
  ios/Tandas/Platform/Models/Generated/ResourceType+Codable.swift \
  supabase/functions/_shared/types/resourceType.ts \
  ios/TandasTests/Platform/CodableEnumsTests.swift \
  ios/Tandas.xcodeproj
# Add updated call site files if step 7 produced changes (run `git status` to list)

git commit -m "$(cat <<'EOF'
feat(platform): migrate ResourceType to codegen pattern

Phase B2 of shared-enums-codegen. TS counterpart generated for
forward-compat (no consumer today). Computed props (if any) moved
to ResourceType+Extensions.swift.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task B3: Migrate `ConsequenceType`

**Files:**
- Modify: `ios/Tandas/Platform/Models/ConsequenceType.swift`
- Generated: `ios/Tandas/Platform/Models/Generated/ConsequenceType+Codable.swift`
- Generated: `supabase/functions/_shared/types/consequenceType.ts`
- Modify: `ios/TandasTests/Platform/CodableEnumsTests.swift`

- [ ] **Step 1: Append the round-trip test for `ConsequenceType`**

Add to `ios/TandasTests/Platform/CodableEnumsTests.swift`:
```swift
    func testConsequenceTypeRoundTrip() throws {
        for value in ConsequenceType.knownCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ConsequenceType.self, from: data)
            XCTAssertEqual(value, decoded)
        }

        let unknownData = #""futureConsequence""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConsequenceType.self, from: unknownData)
        guard case .unknown(let s) = decoded, s == "futureConsequence" else {
            XCTFail("expected .unknown(\"futureConsequence\"), got \(decoded)")
            return
        }
    }
```

- [ ] **Step 2: Run test, expect compile failure**

Run: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' -only-testing:TandasTests/CodableEnumsTests/testConsequenceTypeRoundTrip 2>&1 | tail -10`
Expected: compile failure on `ConsequenceType.knownCases`.

- [ ] **Step 3: Mutate `ConsequenceType.swift`**

Open the file. Apply the four structural changes (marker, drop `: String, CaseIterable`, drop raw-value literals, add `case unknown(String)`). Move any computed properties to `ConsequenceType+Extensions.swift`.

- [ ] **Step 4: Run codegen**

Run: `make gen`
Expected: `Processed: ConsequenceType, PermissionLevel, ResourceType`.

- [ ] **Step 5: Refresh Xcode project**

Run: `cd ios && xcodegen`

- [ ] **Step 6: Update Swift call sites**

Run: `grep -rn "ConsequenceType\." ios/Tandas --include="*.swift" | grep -E "allCases|\(rawValue:|\.rawValue"`

Apply per match:
- `.allCases` → `.knownCases`
- `(rawValue: x)` → `.from(raw: x)` (non-optional return)
- `.rawValue` → `.rawString`
- Exhaustive switches: add `case .unknown(let s):` arm.

- [ ] **Step 7: Replace TS inline definition in `_shared/platformTypes.ts`**

Open `supabase/functions/_shared/platformTypes.ts`. The current inline `ConsequenceType` definition starts at line 72:
```ts
export type ConsequenceType =
  | "fine"
  | "loseTurn"
  | ...
  | "callWebhook";
```

Replace those lines with:
```ts
import { type ConsequenceType } from "./types/consequenceType.ts";
export type { ConsequenceType };
```

- [ ] **Step 8: Run iOS tests + edge function tests**

Run: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' 2>&1 | tail -20`
Expected: all pass.

Run: `cd supabase/functions/_tests && deno test -A 2>&1 | tail -20`
Expected: all pass; rule engine tests still build (the import shim preserves the type identity).

- [ ] **Step 9: Commit**

```sh
git add ios/Tandas/Platform/Models/ConsequenceType.swift \
  ios/Tandas/Platform/Models/ConsequenceType+Extensions.swift 2>/dev/null \
  ios/Tandas/Platform/Models/Generated/ConsequenceType+Codable.swift \
  supabase/functions/_shared/types/consequenceType.ts \
  supabase/functions/_shared/platformTypes.ts \
  ios/TandasTests/Platform/CodableEnumsTests.swift \
  ios/Tandas.xcodeproj
# plus any call site files modified in step 6/7 (run `git status` to list)

git commit -m "$(cat <<'EOF'
feat(platform): migrate ConsequenceType to codegen pattern

Phase B3 of shared-enums-codegen. Inline ConsequenceType union in
_shared/platformTypes.ts replaced with import from generated file.
Rule engine and consequence executors continue to type-check.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task B4: Migrate `ConditionType`

**Files:**
- Modify: `ios/Tandas/Platform/Models/ConditionType.swift`
- Generated: `ios/Tandas/Platform/Models/Generated/ConditionType+Codable.swift`
- Generated: `supabase/functions/_shared/types/conditionType.ts`
- Modify: `supabase/functions/_shared/platformTypes.ts`
- Modify: `ios/TandasTests/Platform/CodableEnumsTests.swift`

- [ ] **Step 1: Append the round-trip test for `ConditionType`**

Add to `ios/TandasTests/Platform/CodableEnumsTests.swift`:
```swift
    func testConditionTypeRoundTrip() throws {
        for value in ConditionType.knownCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ConditionType.self, from: data)
            XCTAssertEqual(value, decoded)
        }

        let unknownData = #""futureCondition""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConditionType.self, from: unknownData)
        guard case .unknown(let s) = decoded, s == "futureCondition" else {
            XCTFail("expected .unknown(\"futureCondition\"), got \(decoded)")
            return
        }
    }
```

- [ ] **Step 2: Run test, expect compile failure**

Run: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' -only-testing:TandasTests/CodableEnumsTests/testConditionTypeRoundTrip 2>&1 | tail -10`
Expected: compile failure on `ConditionType.knownCases`.

- [ ] **Step 3: Mutate `ConditionType.swift`**

Apply the four structural changes (marker, drop conformance suffix, drop raw-value literals, add unknown). The current file has the `isImplementedInV1` computed property on lines 55–63 — move it to `ConditionType+Extensions.swift`:

`ios/Tandas/Platform/Models/ConditionType+Extensions.swift`:
```swift
import Foundation

extension ConditionType {
    public var isImplementedInV1: Bool {
        switch self {
        case .alwaysTrue, .responseStatusIs, .checkInExists,
             .checkInMinutesLate, .eventDescriptionMissing:
            return true
        case .minutesAfterScheduled, .hoursBeforeEvent,
             .memberHasMultipleFines, .memberFinesAbove,
             .memberMissedConsecutive, .eventDayOfWeek,
             .eventTimeWindow, .fundBalanceAbove,
             .fundBalanceBelow, .rotationPositionEquals:
            return false
        case .unknown:
            return false
        }
    }
}
```

The exhaustive switch was previously a `default: return false` — making it explicit removes the silent-future-cases hazard while keeping behavior identical for current cases.

- [ ] **Step 4: Run codegen**

Run: `make gen`
Expected: `Processed: ConditionType, ConsequenceType, PermissionLevel, ResourceType`.

- [ ] **Step 5: Refresh Xcode project**

Run: `cd ios && xcodegen`

- [ ] **Step 6: Update Swift call sites**

Run: `grep -rn "ConditionType\." ios/Tandas --include="*.swift" | grep -E "allCases|\(rawValue:|\.rawValue"`

Apply per match:
- `.allCases` → `.knownCases`
- `(rawValue: x)` → `.from(raw: x)`
- `.rawValue` → `.rawString`
- Exhaustive switches: `case .unknown(let s):` arm.

- [ ] **Step 7: Replace TS inline definition**

In `supabase/functions/_shared/platformTypes.ts`, find the `ConditionType` union (currently lines 55–70):
```ts
export type ConditionType =
  | "alwaysTrue"
  | ...
  | "rotationPositionEquals";
```

Replace with:
```ts
import { type ConditionType } from "./types/conditionType.ts";
export type { ConditionType };
```

- [ ] **Step 8: Run iOS + edge tests**

Run iOS tests: `cd ios && xcodebuild test ... 2>&1 | tail -20`
Run edge tests: `cd supabase/functions/_tests && deno test -A 2>&1 | tail -20`
Expected: both pass.

- [ ] **Step 9: Commit**

```sh
git add ios/Tandas/Platform/Models/ConditionType.swift \
  ios/Tandas/Platform/Models/ConditionType+Extensions.swift \
  ios/Tandas/Platform/Models/Generated/ConditionType+Codable.swift \
  supabase/functions/_shared/types/conditionType.ts \
  supabase/functions/_shared/platformTypes.ts \
  ios/TandasTests/Platform/CodableEnumsTests.swift \
  ios/Tandas.xcodeproj
# plus call site files

git commit -m "$(cat <<'EOF'
feat(platform): migrate ConditionType to codegen pattern

Phase B4 of shared-enums-codegen. isImplementedInV1 computed property
moved to ConditionType+Extensions.swift with explicit .unknown arm.
TS counterpart now imported from generated file.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task B5: Migrate `SystemEventType` (with Audit C pre + Audit B post)

**Files:**
- Modify: `ios/Tandas/Platform/Models/SystemEventType.swift`
- Create: `ios/Tandas/Platform/Models/SystemEventType+Extensions.swift`
- Generated: `ios/Tandas/Platform/Models/Generated/SystemEventType+Codable.swift`
- Generated: `supabase/functions/_shared/types/systemEventType.ts`
- Modify: `supabase/functions/_shared/platformTypes.ts`
- Modify: `ios/Tandas/Features/History/Views/GroupHistoryView.swift`
- Modify: `ios/TandasTests/Platform/CodableEnumsTests.swift`

This is the largest enum and the one whose migration awakens previously-skipped rules. Three of the cases (`fineReminderSent`, `voteOpened`, `voteResolved`) exist in Swift today but not in TS, so once the TS file is generated, the rule engine begins evaluating rules with those triggers.

- [ ] **Step 1: Run Audit C — silently-skipped rules waking up**

Run this query against the production Supabase DB:
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

Classify each returned row into exactly one bucket and document the decision in the PR description:

- **Designed-correct, was just broken**: keep `is_active=true`, accept the rule starts firing on the next `system_events` row of that type after the deploy. If consequences include `fine` or `sendNotification`, also do the comms step below.
- **Stale / no longer wanted**: in a separate commit BEFORE this task's commit, set `is_active=false` for those rules.
- **Designed wrong, needs rewrite**: pause this task. Fix the rule definition first.

**Comms step (only if any "designed-correct" row has fine or sendNotification consequences):**

Owner: Jose. Channel: WhatsApp group of each affected `group_id`. Timing: at least 24 hours before the migration commit deploys to production. Message template (Spanish, send-as-is):

> Hola — un aviso. Vamos a desplegar un fix técnico mañana que vuelve a activar una regla del grupo (`<rule.name>`) que estaba detenida por un bug. A partir del despliegue, esta regla volverá a aplicarse cuando ocurra `<trigger_event>`. Si esto te parece incorrecto o quieres revisar la regla antes, responde aquí en las próximas 24h.

If the affected groups are tests/internal, skip the comms step but document why in the PR.

- [ ] **Step 2: Append the round-trip test for `SystemEventType`**

Add to `ios/TandasTests/Platform/CodableEnumsTests.swift`:
```swift
    func testSystemEventTypeRoundTrip() throws {
        for value in SystemEventType.knownCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(SystemEventType.self, from: data)
            XCTAssertEqual(value, decoded)
        }

        let unknownData = #""futureSystemEvent""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SystemEventType.self, from: unknownData)
        guard case .unknown(let s) = decoded, s == "futureSystemEvent" else {
            XCTFail("expected .unknown(\"futureSystemEvent\"), got \(decoded)")
            return
        }
    }
```

- [ ] **Step 3: Run test, expect compile failure**

Run: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' -only-testing:TandasTests/CodableEnumsTests/testSystemEventTypeRoundTrip 2>&1 | tail -10`
Expected: compile failure on `SystemEventType.knownCases`.

- [ ] **Step 4: Mutate `SystemEventType.swift`**

Replace the file's contents with:
```swift
import Foundation

// @codegen:enum
public enum SystemEventType: Codable, Sendable, Hashable {

    // MARK: - Event resource lifecycle
    case eventClosed
    case eventCreated
    case rsvpDeadlinePassed
    case hoursBeforeEvent

    // MARK: - RSVP / attendance
    case rsvpSubmitted
    case rsvpChangedSameDay
    case checkInRecorded
    case checkInMissed
    case eventDescriptionMissing

    // MARK: - Slot resource (Fase 2)
    case slotAssigned
    case slotDeclined
    case slotExpired

    // MARK: - Fines + appeals
    case fineOfficialized
    case finePaid
    case fineReminderSent
    case appealCreated
    case appealResolved
    case voteOpened
    case voteCast
    case voteResolved

    // MARK: - Fund (Fase posterior)
    case fundDeposit
    case fundThresholdReached

    // MARK: - Rotation / membership
    case positionChanged
    case memberJoined
    case memberLeft

    case unknown(String)
}
```

- [ ] **Step 5: Move `isImplementedInV1` to extension**

Create `ios/Tandas/Platform/Models/SystemEventType+Extensions.swift`:
```swift
import Foundation

extension SystemEventType {
    /// True if Sprint 1a / V1 has a TriggerEvaluator implementation.
    public var isImplementedInV1: Bool {
        switch self {
        case .eventClosed, .checkInRecorded, .rsvpChangedSameDay,
             .hoursBeforeEvent, .rsvpSubmitted, .rsvpDeadlinePassed,
             .eventDescriptionMissing,
             .appealCreated, .appealResolved,
             .voteOpened, .voteCast, .voteResolved,
             .fineOfficialized, .finePaid, .fineReminderSent,
             .eventCreated, .memberJoined, .memberLeft:
            return true
        case .checkInMissed,
             .slotAssigned, .slotDeclined, .slotExpired,
             .fundDeposit, .fundThresholdReached,
             .positionChanged:
            return false
        case .unknown:
            return false
        }
    }
}
```

- [ ] **Step 6: Run codegen**

Run: `make gen`
Expected: `Processed: ConditionType, ConsequenceType, PermissionLevel, ResourceType, SystemEventType`.

- [ ] **Step 7: Refresh Xcode project**

Run: `cd ios && xcodegen`

- [ ] **Step 8: Update Swift call sites**

Edit `ios/Tandas/Features/History/Views/GroupHistoryView.swift`:

Line 163: replace `SystemEventType.allCases` with `SystemEventType.knownCases`. The line currently reads:
```swift
private static let typeOptions: [SystemEventType?] = [nil] + SystemEventType.allCases
```
Change to:
```swift
private static let typeOptions: [SystemEventType?] = [nil] + SystemEventType.knownCases
```

Line 196: replace `SystemEventType.allCases` with `SystemEventType.knownCases`. Currently:
```swift
ForEach(SystemEventType.allCases, id: \.self) { t in
```
Change to:
```swift
ForEach(SystemEventType.knownCases, id: \.self) { t in
```

The `HistoryItemPresentation.swift` file uses `SystemEventType` in switch statements. Find any exhaustive switches and add a `case .unknown(let s):` arm. Run:
```sh
grep -rn "switch.*SystemEventType\|case \." ios/Tandas/Features/History --include="*.swift" | head
```

Inspect each exhaustive switch on `SystemEventType` (most likely in `HistoryItemPresentation.swift` line 79 and surrounding). Add a `.unknown` arm that returns a fallback presentation (e.g., generic icon + "Activity" label).

- [ ] **Step 9: Replace TS inline definition**

In `supabase/functions/_shared/platformTypes.ts`, find the `SystemEventType` union (currently lines 16–38). Replace those lines with:
```ts
import { type SystemEventType } from "./types/systemEventType.ts";
export type { SystemEventType };
```

- [ ] **Step 10: Run iOS + edge tests**

Run iOS: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' 2>&1 | tail -20`
Expected: all tests pass.

Run edge: `cd supabase/functions/_tests && deno test -A 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 11: Run Audit B — orphan rule triggers**

Run this query against production Supabase:
```sql
select id, group_id, name, trigger->'eventType' as event_type
from rules
where trigger->>'eventType' not in (
  -- paste the post-migration catalog here, one quoted string per line:
  'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
  'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
  'eventDescriptionMissing', 'slotAssigned', 'slotDeclined', 'slotExpired',
  'fineOfficialized', 'finePaid', 'fineReminderSent', 'appealCreated',
  'appealResolved', 'voteOpened', 'voteCast', 'voteResolved', 'fundDeposit',
  'fundThresholdReached', 'positionChanged', 'memberJoined', 'memberLeft'
);
```

Any returned row is an orphan: a rule whose `trigger.eventType` is a string the catalog does not know. Per row, decide:

- **Typo or rename**: data-migration to fix the value.
- **Old / deprecated trigger**: delete the row or set `is_active=false`.

Document the audit output (and any follow-up commits) in the PR description.

- [ ] **Step 12: Run grep-orphans, address findings**

Run: `make gen-orphans`
Expected: drastically fewer orphans than during Phase A — the catalog is now populated. Any remaining orphans are real drift in SQL/TS files (e.g., a hardcoded string in a migration that's not in any source enum).

For each genuine orphan:
- If the literal SHOULD be an enum case: add it to the matching Swift source, run `make gen` again, re-run grep-orphans.
- If the literal is benign (column name, RPC, SDK identifier): add to `scripts/codegen/orphan-allowlist.txt` with a one-line origin comment.

- [ ] **Step 13: Flip the CI orphan check from continue-on-error to required**

Edit `.github/workflows/codegen.yml`. Remove the `continue-on-error: true` line and the surrounding comment block from the orphan-check step. The block now reads:

```yaml
      - name: Check for orphan enum string literals
        run: deno run -A scripts/codegen/grep-orphans.ts
```

- [ ] **Step 14: Commit**

```sh
git add ios/Tandas/Platform/Models/SystemEventType.swift \
  ios/Tandas/Platform/Models/SystemEventType+Extensions.swift \
  ios/Tandas/Platform/Models/Generated/SystemEventType+Codable.swift \
  supabase/functions/_shared/types/systemEventType.ts \
  supabase/functions/_shared/platformTypes.ts \
  ios/Tandas/Features/History/Views/GroupHistoryView.swift \
  ios/Tandas/Features/History/Views/HistoryItemPresentation.swift \
  ios/TandasTests/Platform/CodableEnumsTests.swift \
  scripts/codegen/orphan-allowlist.txt \
  .github/workflows/codegen.yml \
  ios/Tandas.xcodeproj

git commit -m "$(cat <<'EOF'
feat(platform): migrate SystemEventType to codegen pattern

Phase B5 of shared-enums-codegen. Closes the documented Swift↔TS
drift: fineReminderSent, voteOpened, voteResolved are now in the
TS catalog and rule engine evaluates rules with those triggers.

Audit C run pre-merge: <N> active rules in those buckets, classified
in PR description; comms sent where required.
Audit B run post-merge: <N> orphan rules cleaned.

CI orphan-check flipped to required.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase C — Cleanup (1 commit)

### Task C1: Sweep `_shared/platformTypes.ts` for residue + verify

**Files:**
- Modify: `supabase/functions/_shared/platformTypes.ts`

- [ ] **Step 1: Inspect the current state of platformTypes.ts**

Run: `cat supabase/functions/_shared/platformTypes.ts`

After Phase B, the file should contain three `import { type X } from "./types/x.ts"; export type { X };` shims and the 7 hand-maintained struct/interface definitions (`SystemEvent`, `Rule`, `RuleTrigger`, `RuleCondition`, `RuleConsequence`, `RuleTarget`, `ExecutionResult`).

- [ ] **Step 2: Update the file header comment**

Replace the existing header comment (lines 1–7, currently saying "Keep this file in sync with `ios/Tandas/Platform/Models/`...") with:
```ts
// Platform types for the rule engine and edge functions.
//
// Enums (SystemEventType, ConditionType, ConsequenceType) are codegen-
// produced from `ios/Tandas/Platform/Models/<Name>.swift` — see
// `scripts/codegen/README.md`. Do not edit them inline here.
//
// The structs/interfaces below (SystemEvent, Rule, RuleTrigger, etc.)
// are still hand-maintained mirrors of the Swift Platform/Models structs.
// A future Fase 0.5 may add codegen for those too; until then, keep them
// in sync manually when the Swift side changes.
```

- [ ] **Step 3: Verify all three import shims are present and correct**

Run: `grep -E "import \{ type (SystemEventType|ConditionType|ConsequenceType) \} from" supabase/functions/_shared/platformTypes.ts`
Expected: 3 lines, one per enum, all importing from `./types/<name>.ts`.

If any are missing, the corresponding Phase B task didn't apply step 7 / step 9 — fix here.

- [ ] **Step 4: Add TS round-trip test**

Create `supabase/functions/_tests/types.test.ts`:
```ts
import { assertEquals } from "jsr:@std/assert@1";
import {
  isSystemEventType,
  systemEventTypeValues,
} from "../_shared/types/systemEventType.ts";
import {
  conditionTypeValues,
  isConditionType,
} from "../_shared/types/conditionType.ts";
import {
  consequenceTypeValues,
  isConsequenceType,
} from "../_shared/types/consequenceType.ts";
import {
  isResourceType,
  resourceTypeValues,
} from "../_shared/types/resourceType.ts";
import {
  isPermissionLevel,
  permissionLevelValues,
} from "../_shared/types/permissionLevel.ts";

Deno.test("generated TS catalogs are non-empty and well-formed", () => {
  for (
    const [name, values] of [
      ["SystemEventType", systemEventTypeValues],
      ["ConditionType", conditionTypeValues],
      ["ConsequenceType", consequenceTypeValues],
      ["ResourceType", resourceTypeValues],
      ["PermissionLevel", permissionLevelValues],
    ] as const
  ) {
    if (values.length === 0) {
      throw new Error(`${name} catalog is empty`);
    }
    for (const v of values) {
      if (typeof v !== "string" || v.length === 0) {
        throw new Error(`${name} contains non-string or empty entry: ${v}`);
      }
      if (!/^[a-z][A-Za-z0-9]*$/.test(v)) {
        throw new Error(`${name} entry violates camelCase shape: ${v}`);
      }
    }
  }
});

Deno.test("type guards accept known values, reject unknown", () => {
  assertEquals(isSystemEventType("eventClosed"), true);
  assertEquals(isSystemEventType("madeUp"), false);

  assertEquals(isConditionType("alwaysTrue"), true);
  assertEquals(isConditionType("madeUp"), false);

  assertEquals(isConsequenceType("fine"), true);
  assertEquals(isConsequenceType("madeUp"), false);

  assertEquals(isResourceType(resourceTypeValues[0]), true);
  assertEquals(isResourceType("madeUp"), false);

  assertEquals(isPermissionLevel("founder"), true);
  assertEquals(isPermissionLevel("madeUp"), false);
});
```

- [ ] **Step 5: Run TS round-trip test**

Run: `cd supabase/functions/_tests && deno test -A types.test.ts`
Expected: 2 tests pass.

- [ ] **Step 6: Run final verification**

Run: `make gen-check`
Expected: exit 0. No stale outputs.

Run: `make gen-orphans`
Expected: exit 0. Zero orphans (assuming Phase B5 step 12 was thorough).

Run: `cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' 2>&1 | tail -10`
Expected: all tests pass.

Run: `cd supabase/functions/_tests && deno test -A 2>&1 | tail -10`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```sh
git add supabase/functions/_shared/platformTypes.ts \
  supabase/functions/_tests/types.test.ts
git commit -m "$(cat <<'EOF'
chore(platform): platformTypes.ts header + TS round-trip test

Phase C1 of shared-enums-codegen. Header comment now states that the
3 enum types come from the codegen and the 7 structs/interfaces remain
hand-maintained. Adds types.test.ts with shape + type-guard checks
against all 5 generated catalogs. Closes the migration.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

- [ ] **Step 8: Push the full sequence**

```sh
git push origin main
```

Expected: Phase B + C commits on origin. CI runs `gen-types-clean` (now without `continue-on-error`) and passes — generated outputs match, zero orphans.

---

## Final verification (no commit)

- [ ] Spec Success Criterion #1 — All 5 enums migrated, CI green: confirmed by Phase B + C completion.
- [ ] Spec Success Criterion #2 — `_shared/platformTypes.ts` is free of inline enum string literals for the 3 dual-source enums: confirmed by Task C1 step 3.
- [ ] Spec Success Criterion #3 — Adding a case to any source enum produces both Swift Generated and TS files via `make gen`; CI fails if forgotten. Smoke-test by adding a fake case temporarily, running `make gen`, observing both files updated, then reverting.
- [ ] Spec Success Criterion #4 — Decode-failure crash count: depends on Sentry (separate Fase 0 item). Until Sentry lands, verify by polling TestFlight crash reports for two weeks post-rollout.
- [ ] Spec Success Criterion #5 — Roadmap §3 Fase 0 item #1 marked done: edit `Plans/Roadmap.md` to strike-through "Codegen de tipos compartidos" once verification passes (separate housekeeping commit, optional).
