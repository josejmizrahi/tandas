#!/usr/bin/env bash
#
# check_migration_drift.sh — fail-loud guard for Supabase migration drift.
#
# Compares supabase_migrations.schema_migrations in a live/linked Postgres
# DB against the files in supabase/migrations/. Was added after R.3A and
# R.2V.4 shipped to the live DB without leaving SQL artifacts on disk —
# `edge-tests.yml` replay was silently producing a partial schema.
#
# Failure modes detected:
#   1. name in live but not on disk     → hard fail
#   2. name on disk but not in live     → hard fail
#   3. name matches but version differs → warn (or fail with --strict)
#
# Optional: --check-sha verifies SHA256 of each on-disk file matches the
# statements[1] stored in live (catches manual edits to disk files).
#
# Env:
#   SUPABASE_DB_URL  required. If unset, the script exits 0 with a warning
#                    (so PRs from forks without secrets don't fail).
#
# Exit codes:
#   0 — no drift (or skipped)
#   1 — drift detected
#   2 — setup error (missing tool, bad query)

set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--strict] [--check-sha] [--help]

  --strict     Fail (exit 1) on version mismatches in addition to missing
               or extra names. Default behavior is to warn.
  --check-sha  Verify SHA256 of each disk file matches live statements[1].
               Slower (one query per migration). Requires SUPABASE_DB_URL.
  --help       Show this message and exit.

Env: SUPABASE_DB_URL must point at a Postgres connection with read access
     to supabase_migrations.schema_migrations.

The check filters out migrations applied BEFORE the MVP2 reset
(\`mvp2_000_reset_and_foundation\`, version 20260602054851). Pre-reset
migrations exist in live's history but their effects were wiped by the
reset, so they are intentionally absent from supabase/migrations/.
USAGE
}

STRICT=0
CHECK_SHA=0
for arg in "$@"; do
  case "$arg" in
    --strict)    STRICT=1 ;;
    --check-sha) CHECK_SHA=1 ;;
    --help|-h)   usage; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
# mvp2_000_reset_and_foundation — anything before this was wiped by the reset
RESET_VERSION="20260602054851"

if [[ ! -d "$MIGRATIONS_DIR" ]]; then
  echo "✗ migrations dir not found: $MIGRATIONS_DIR" >&2
  exit 2
fi

if [[ -z "${SUPABASE_DB_URL:-}" ]]; then
  echo "⚠  SUPABASE_DB_URL not set — skipping migration drift check."
  echo "   Set it as a CI secret to enable. Example for local use:"
  echo "     export SUPABASE_DB_URL='postgresql://postgres.PROJECT:PASSWORD@aws-0-REGION.pooler.supabase.com:6543/postgres'"
  exit 0
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "✗ psql not found in PATH — required when SUPABASE_DB_URL is set." >&2
  exit 2
fi

# ─── live ─────────────────────────────────────────────────────────────────
echo "→ Querying live migrations (version >= $RESET_VERSION)…"
LIVE_TSV="$(psql "$SUPABASE_DB_URL" -tAX -F $'\t' -v ON_ERROR_STOP=1 -c \
  "SELECT version, name FROM supabase_migrations.schema_migrations \
   WHERE version >= '$RESET_VERSION' ORDER BY name" 2>&1)" || {
  echo "✗ psql query failed:" >&2
  echo "$LIVE_TSV" >&2
  exit 2
}
if [[ -z "$LIVE_TSV" ]]; then
  echo "✗ live query returned 0 rows — wrong DB? schema_migrations missing?" >&2
  exit 2
fi
LIVE_COUNT=$(printf '%s\n' "$LIVE_TSV" | wc -l | tr -d ' ')
echo "  found $LIVE_COUNT live migrations post-reset."

# ─── disk ─────────────────────────────────────────────────────────────────
echo "→ Collecting disk migrations from supabase/migrations/…"
DISK_TSV="$(find "$MIGRATIONS_DIR" -maxdepth 1 -name '[0-9]*_*.sql' -type f \
  | sort \
  | while read -r f; do
      base=$(basename "$f" .sql)
      ver=${base%%_*}
      name=${base#*_}
      printf '%s\t%s\n' "$ver" "$name"
    done)"
if [[ -z "$DISK_TSV" ]]; then
  echo "✗ no migrations found on disk" >&2
  exit 2
fi
DISK_COUNT=$(printf '%s\n' "$DISK_TSV" | wc -l | tr -d ' ')
echo "  found $DISK_COUNT disk migrations."

# ─── diff by name ─────────────────────────────────────────────────────────
LIVE_NAMES=$(printf '%s\n' "$LIVE_TSV" | cut -f2 | sort -u)
DISK_NAMES=$(printf '%s\n' "$DISK_TSV" | cut -f2 | sort -u)

MISSING_FROM_DISK=$(comm -23 <(printf '%s\n' "$LIVE_NAMES") <(printf '%s\n' "$DISK_NAMES") || true)
EXTRA_ON_DISK=$(comm -13 <(printf '%s\n' "$LIVE_NAMES") <(printf '%s\n' "$DISK_NAMES") || true)

FAIL=0

if [[ -n "$MISSING_FROM_DISK" ]]; then
  echo
  echo "✗ MIGRATIONS PRESENT IN LIVE BUT MISSING FROM DISK:" >&2
  printf '%s\n' "$MISSING_FROM_DISK" | sed 's/^/    - /' >&2
  echo >&2
  echo "  Restore them via scripts/restore_live_migration.sh <name>, or query:" >&2
  echo "    SELECT version, name, statements[1] FROM supabase_migrations.schema_migrations" >&2
  echo "     WHERE name = '<name>';" >&2
  FAIL=1
fi

if [[ -n "$EXTRA_ON_DISK" ]]; then
  echo
  echo "✗ MIGRATIONS PRESENT ON DISK BUT NOT IN LIVE:" >&2
  printf '%s\n' "$EXTRA_ON_DISK" | sed 's/^/    - /' >&2
  echo >&2
  echo "  Either apply them to live (supabase db push) or delete from disk." >&2
  FAIL=1
fi

# ─── version mismatches (warn or strict-fail) ─────────────────────────────
# Build maps name→version for both, then compare.
LIVE_MAP=$(printf '%s\n' "$LIVE_TSV" | awk -F'\t' '{print $2"\t"$1}' | sort)
DISK_MAP=$(printf '%s\n' "$DISK_TSV" | awk -F'\t' '{print $2"\t"$1}' | sort)
VERSION_MISMATCH=$(join -t $'\t' -1 1 -2 1 <(printf '%s\n' "$LIVE_MAP") <(printf '%s\n' "$DISK_MAP") \
  | awk -F'\t' '$2 != $3 {print $1"\t"$3"\t"$2}')

if [[ -n "$VERSION_MISMATCH" ]]; then
  COUNT=$(printf '%s\n' "$VERSION_MISMATCH" | wc -l | tr -d ' ')
  if (( STRICT )); then
    echo
    echo "✗ VERSION MISMATCHES (strict mode): $COUNT migrations" >&2
    printf '%-60s  %-16s  %-16s\n' "NAME" "DISK_VERSION" "LIVE_VERSION" >&2
    printf '%s\n' "$VERSION_MISMATCH" | awk -F'\t' '{printf "%-60s  %-16s  %-16s\n", $1, $2, $3}' >&2
    FAIL=1
  else
    echo
    echo "⚠  $COUNT version mismatches (same name, different timestamp prefix)."
    echo "   Run with --strict to fail on these. Examples:"
    printf '%s\n' "$VERSION_MISMATCH" | head -5 | awk -F'\t' '{printf "     %s: disk=%s  live=%s\n", $1, $2, $3}'
    if (( COUNT > 5 )); then
      echo "     … ($((COUNT - 5)) more)"
    fi
  fi
fi

# ─── optional SHA256 verification ─────────────────────────────────────────
if (( CHECK_SHA )) && (( FAIL == 0 )); then
  echo
  echo "→ Verifying SHA256 of each disk file against live statements[1]…"
  SHA_FAIL=0
  while IFS=$'\t' read -r disk_ver disk_name; do
    [[ -z "$disk_name" ]] && continue
    disk_file="$MIGRATIONS_DIR/${disk_ver}_${disk_name}.sql"
    [[ -f "$disk_file" ]] || continue
    disk_sha=$(shasum -a 256 < "$disk_file" | awk '{print $1}')
    live_sha=$(psql "$SUPABASE_DB_URL" -tAX -v ON_ERROR_STOP=1 -c \
      "SELECT encode(digest(statements[1], 'sha256'), 'hex') \
       FROM supabase_migrations.schema_migrations WHERE name = '$disk_name'" 2>/dev/null || true)
    if [[ -z "$live_sha" ]]; then
      echo "  ⚠  $disk_name: no live row to compare" >&2
      continue
    fi
    if [[ "$disk_sha" != "$live_sha" ]]; then
      echo "  ✗ SHA mismatch: $disk_name" >&2
      echo "      disk=$disk_sha" >&2
      echo "      live=$live_sha" >&2
      SHA_FAIL=$((SHA_FAIL + 1))
    fi
  done <<<"$DISK_TSV"
  if (( SHA_FAIL > 0 )); then
    echo
    echo "✗ $SHA_FAIL SHA mismatches — disk content drifted from live." >&2
    FAIL=1
  else
    echo "  $DISK_COUNT files verified."
  fi
fi

# ─── done ─────────────────────────────────────────────────────────────────
if (( FAIL )); then
  echo
  echo "✗ migration drift detected." >&2
  exit 1
fi

echo
echo "✓ no drift: $LIVE_COUNT live == $DISK_COUNT disk (by name)."
exit 0
