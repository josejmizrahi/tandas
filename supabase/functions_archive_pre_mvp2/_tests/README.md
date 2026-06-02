# Edge function E2E tests

End-to-end tests for the dinner_recurring V1 contract. Validates the full
chain: rule engine → fine proposed → grace period → officialized → appeal
→ vote → resolved, with `notifications_outbox` writes asserted at every
step.

## What's covered

| File | Scenarios |
|------|-----------|
| `e2e/dinnerHappyPath.test.ts` | (1) Late check-in → escalating fine → officialized. (2) Appeal → votes pass → fine cancelled. |
| `e2e/appealQuorumFailed.test.ts` | (3) 2-member group, infractor only → quorum impossible → appeal closes as `quorum_failed`, fine stays officialized. |

Each scenario asserts three levels:

1. **State** — direct SQL queries against `fines`, `votes`, `vote_casts`.
2. **Causal chain** — `system_events` rows in expected order.
3. **Notifications** — `notifications_outbox` rows for the right
   `recipient_member_id` + `notification_type`.

## Prerequisites

- Docker Desktop running.
- Local Supabase started: `supabase start` from repo root.
- Deno installed: `brew install deno` (or via the official installer).
- Migrations applied: handled automatically by `supabase start`.

## Run

```bash
cd /Users/jj/code/tandas

# Defaults to local supabase URLs + service-role key from `supabase status`.
# Source those env vars or pass them explicitly.
export SUPABASE_URL=$(supabase status -o json | jq -r .API_URL)
export SUPABASE_SERVICE_ROLE_KEY=$(supabase status -o json | jq -r .SERVICE_ROLE_KEY)
export SUPABASE_ANON_KEY=$(supabase status -o json | jq -r .ANON_KEY)
export ALLOW_CLOCK_OVERRIDE=true   # required for X-Test-Clock to work

deno test --allow-net --allow-env supabase/functions/_tests/e2e/
```

To run a single scenario:

```bash
deno test --allow-net --allow-env supabase/functions/_tests/e2e/dinnerHappyPath.test.ts
```

## Pointing at staging (manual verification)

```bash
export SUPABASE_URL=https://<staging-project>.supabase.co
export SUPABASE_SERVICE_ROLE_KEY=<staging service-role key>
export SUPABASE_ANON_KEY=<staging anon key>
export ALLOW_CLOCK_OVERRIDE=true   # MUST be set in staging too, NOT in production
deno test --allow-net --allow-env supabase/functions/_tests/e2e/
```

**Never set `ALLOW_CLOCK_OVERRIDE=true` in production env.** It is the only gate
that lets the `X-Test-Clock` header bypass real time. Without the flag the
header is silently ignored.

## Cleanup

Tests run hermetically — each scenario uses a fresh `group_id` UUID and
cleans up via `cleanupGroup(groupId)` in `afterEach`. Belt-and-suspenders:
local supabase can be reset with `supabase db reset` between full test runs
to clear any orphans from a crashed test.

## CI

Not wired yet (intentional, per Bloque 12 plan). Once these tests are
stable locally, a separate commit adds the GitHub Actions step that boots
local supabase + runs the suite.
