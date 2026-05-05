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
