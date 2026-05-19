#!/usr/bin/env bash
# Human-Layer vocabulary lint — fails when forbidden ontology / engine
# jargon leaks into user-facing strings.
#
# Per Plans/Active/HumanLayerSimplification.md §D + §F Slice 3.
#
# Scope: ios/Packages/RuulFeatures/Sources/**/*.swift (the only layer
# that surfaces strings to end users — RuulCore and RuulUI may hold
# the internal vocabulary, but UI copy must read in plain Spanish).
#
# Detection: forbidden word inside a "..." string literal on a non-
# comment line. Comments (// and ///) are exempt — they're for
# engineers, not users. SwiftSyntax-based detection would catch
# more (multi-line strings, string interpolation) but the regex
# approach covers the >95% of cases that matter in practice.
#
# Opt-out: append `// allow-vocab` on the same line if a forbidden
# word legitimately must appear (e.g. a glossary view explaining
# what "Disparador" used to mean before rename).
#
# Exit codes:
#   0 — clean
#   1 — at least one violation found (prints file:line:content)
#   2 — invocation error (missing scope dir)

set -euo pipefail

SCOPE="ios/Packages/RuulFeatures/Sources"

if [ ! -d "$SCOPE" ]; then
  echo "vocab-lint: scope directory '$SCOPE' not found — invoke from repo root." >&2
  exit 2
fi

# Forbidden words. Spanish-only set (Slice 3 minimum):
#   - Pure user-facing words with zero legitimate code-identifier use.
#   - English ontology terms (capability, projection, atom...) are
#     intentionally NOT in this first pass — they collide with type
#     names that DO legitimately appear in code. A future SwiftSyntax-
#     based lint can scope to user-facing strings only.
#
# Format: pattern|human-replacement-hint
FORBIDDEN=(
  "disparador|use 'momento' (noun) or 'cuándo' (label)"
  "consecuencia|use 'acción' or 'lo que pasa'"
  "vincul|use 'relacionado' / 'conectar' / 'conecta'"
)

EXIT_CODE=0
FOUND_COUNT=0

for entry in "${FORBIDDEN[@]}"; do
  word="${entry%%|*}"
  hint="${entry##*|}"

  # grep -E: extended regex. Pattern catches the word inside a "..."
  # string literal — at least one non-quote char allowed before/after.
  # Case-insensitive via -i (lowercase / Lowercase / etc).
  matches=$(grep -rEni "\"[^\"]*${word}[^\"]*\"" "$SCOPE" \
    --include='*.swift' 2>/dev/null \
    | grep -v -E ':[[:space:]]*//' \
    | grep -v -E '// allow-vocab' \
    || true)

  if [ -n "$matches" ]; then
    if [ "$FOUND_COUNT" -eq 0 ]; then
      echo "✘ vocab-lint: forbidden user-facing vocabulary detected"
      echo "  doctrine: Plans/Active/HumanLayerSimplification.md §D"
      echo ""
    fi
    echo "  • '${word}' — ${hint}"
    # Indent each match line for readability
    echo "$matches" | sed 's/^/      /'
    echo ""
    FOUND_COUNT=$((FOUND_COUNT + 1))
    EXIT_CODE=1
  fi
done

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "  Fix the strings above, or add '// allow-vocab' if the use is"
  echo "  intentional (e.g. a glossary explaining the old word)."
fi

exit "$EXIT_CODE"
