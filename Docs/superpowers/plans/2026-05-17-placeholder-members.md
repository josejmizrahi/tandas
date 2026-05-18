# Placeholder Members Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permitir que un admin agregue miembros (nombre + teléfono) que ya participan en rotación/RSVP/fines/votos antes de que la persona se registre, con fusión automática de identidad al primer login por cualquier provider (phone, Apple, Google, email).

**Architecture:** Placeholder member = `auth.users` row con `is_anonymous=true`, phone sólo en `profiles` (no en auth.users → no choca con phone OTP del real). Magic-link via WhatsApp como camino primario + auto-detect post-login por phone match. Identity merge: reasigna `group_members.user_id` y profile metadata; atoms membership-based (system_events, ledger_entries) heredan automáticamente porque apuntan a `group_members.id`; atoms user-id-based (vote_casts, user_actions) se resuelven via `identity_resolver` view.

**Tech Stack:** Postgres 15 + Supabase, Deno edge functions, SwiftUI iOS 26+, supabase-swift SDK, Deno test runner para tests DB (patrón `supabase/functions/_tests/db/*.test.ts` con `seedGroup` fixture).

**Spec source:** `Docs/superpowers/specs/2026-05-17-placeholder-members-design.md`

---

## Pre-implementation context

### Freeze status

La spec declara `status: blocked-by-freeze`. El usuario (founder) autorizó implementación explícitamente con "implementa" tras revisar el spec — interpretación: exemption del freeze 2026-05-17 para esta feature concreta. **Si el founder revoca la exemption durante implementación, las migraciones aún no merged-a-main son reversibles via DROP.** Tasks marcan checkpoints donde revisar antes de mergear.

### Schema descubrimientos clave (versus spec)

La spec fue escrita antes de leer 100% del schema. Ajustes:

- **`group_members.joined_via` valores reales:** `'founder_seed'|'invite_code'|'admin_add'|'unknown'`. Agregar `'placeholder'`.
- **`record_system_event(p_group_id, p_event_type, p_resource_id, p_member_id, p_payload)`** — usa `p_member_id` (group_members.id), no actor uid. Whitelist via `is_known_system_event_type()`.
- **Atoms membership-based** (`system_events.member_id`, `ledger_entries.from_member_id/to_member_id`): heredan auto al reasignar `group_members.user_id`. **No requieren reasignación en atoms.**
- **Atoms user-id-based** (`vote_casts.user_id`, `user_actions.user_id`): permanecen apuntando al placeholder uid; projections que los lean deben usar `identity_resolver`.
- **Test fixture:** `supabase/functions/_tests/e2e/_fixtures/seedGroup.ts` provee `seedGroup({memberSpecs: [...]})`.

### File structure (overview)

**Migrations (new):**
- `supabase/migrations/00300_profiles_placeholder_columns.sql`
- `supabase/migrations/00301_invites_placeholder_columns.sql`
- `supabase/migrations/00302_group_members_joined_via_placeholder.sql`
- `supabase/migrations/00303_identity_resolver_view.sql`
- `supabase/migrations/00304_system_event_types_member_lifecycle.sql`
- `supabase/migrations/00305_finalize_placeholder_member_rpc.sql`
- `supabase/migrations/00306_merge_placeholder_rpcs.sql`
- `supabase/migrations/00307_claim_placeholder_rpcs.sql`
- `supabase/migrations/00308_discover_and_summary_rpcs.sql`
- `supabase/migrations/00309_profiles_rls_placeholder.sql`

Rollbacks under `supabase/migrations/_rollbacks/00300_rollback.sql` … `00309_rollback.sql`.

**Edge functions:**
- `supabase/functions/create-placeholder-member/index.ts` (new)
- `supabase/functions/send-whatsapp-invite/index.ts` (modify — accept `claim_token`)

**iOS core:**
- `ios/Packages/RuulCore/Sources/RuulCore/Invite.swift` (modify — add `placeholderUserId`, `claimTokenHash`)
- `ios/Packages/RuulCore/Sources/RuulCore/Profile.swift` (modify — add `isPlaceholder`, `claimedAt`)
- `ios/Packages/RuulCore/Sources/RuulCore/Repositories/PlaceholderMemberRepository.swift` (new)
- `ios/Packages/RuulCore/Sources/RuulCore/Repositories/ClaimRepository.swift` (new)

**iOS UI:**
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/AddPlaceholderSheet.swift` (new)
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/MembersListView.swift` (modify — badge)
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Claims/PendingClaimsView.swift` (new)
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Claims/ClaimReviewView.swift` (new)
- `ios/Tandas/Shell/DeepLinkRouter.swift` (modify — `/claim/<token>`)

**Tests:**
- `supabase/functions/_tests/db/placeholder_member_creation.test.ts`
- `supabase/functions/_tests/db/placeholder_merge_engine.test.ts`
- `supabase/functions/_tests/db/placeholder_claim_flow.test.ts`
- `supabase/functions/_tests/db/placeholder_decline_flow.test.ts`
- `supabase/functions/_tests/db/placeholder_invariants.test.ts`
- `supabase/functions/_tests/db/identity_resolver.test.ts`

---

## Phase 1 — Schema foundation

### Task 1: `profiles` placeholder columns

**Files:**
- Create: `supabase/migrations/00300_profiles_placeholder_columns.sql`
- Create: `supabase/migrations/_rollbacks/00300_rollback.sql`

- [ ] **Step 1: Verify profiles current shape**

Run: `grep -A 20 "create table.*public.profiles" supabase/migrations/00001*.sql`
Expected: confirm columns `id`, `display_name`, `phone` exist; no `is_placeholder`, no `claimed_at`.

- [ ] **Step 2: Write migration**

Create `supabase/migrations/00300_profiles_placeholder_columns.sql`:

```sql
-- Mig 00300: profiles columns for placeholder identity lifecycle.
--
-- A "placeholder" profile is an auth.users(is_anonymous=true) created by an
-- admin to represent a person who hasn't registered yet but already
-- participates in a group (rotation/RSVP/fines/votes). When the real person
-- authenticates by ANY provider (phone OTP, Apple, Google, email), the merge
-- engine (mig 00306) reassigns the placeholder's group_members.user_id to
-- the real user and the placeholders profile is deleted; the auth.users row
-- stays with raw_user_meta_data.merged_into = canonical_uid so the
-- identity_resolver view (mig 00303) can map historical user-id-based atoms.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §8, §15.1

begin;

alter table public.profiles
  add column if not exists is_placeholder boolean not null default false,
  add column if not exists claimed_at timestamptz,
  add column if not exists claimed_by_user_id uuid
    references auth.users(id) on delete set null,
  add column if not exists disputed_at timestamptz,
  add column if not exists disputed_by_user_id uuid
    references auth.users(id) on delete set null;

comment on column public.profiles.is_placeholder is
  'True when this profile represents an admin-created stand-in for someone who has not yet registered. Cleared (false) post-claim only because the profile row is deleted during merge; the auth.users row carries merged_into in raw_user_meta_data.';
comment on column public.profiles.claimed_at is
  'Set during decline flow to mark the placeholder as reviewed-but-rejected by the rightful owner. NOT set on accept (profile row is deleted instead).';
comment on column public.profiles.claimed_by_user_id is
  'Audit pointer to the auth.uid() who acted on this placeholder during decline.';

-- Prevent two unclaimed placeholders with the same phone — admin gets
-- 409 from create-placeholder-member edge function when this fires.
create unique index if not exists profiles_placeholder_phone_uq
  on public.profiles (phone)
  where is_placeholder = true and claimed_at is null and phone is not null;

commit;
```

Create `supabase/migrations/_rollbacks/00300_rollback.sql`:

```sql
begin;
drop index if exists public.profiles_placeholder_phone_uq;
alter table public.profiles
  drop column if exists disputed_by_user_id,
  drop column if exists disputed_at,
  drop column if exists claimed_by_user_id,
  drop column if exists claimed_at,
  drop column if exists is_placeholder;
commit;
```

- [ ] **Step 3: Apply migration locally and verify**

Run: `supabase db reset --local` (or `mcp__supabase__apply_migration` if remote-only).
Then:

```bash
psql "$LOCAL_DB_URL" -c "\d public.profiles" | grep -E "is_placeholder|claimed_at|disputed_at"
```

Expected: 5 new columns present.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/00300_profiles_placeholder_columns.sql \
        supabase/migrations/_rollbacks/00300_rollback.sql
git commit -m "feat(schema): profiles columns for placeholder identity lifecycle (mig 00300)"
```

---

### Task 2: `invites` placeholder columns

**Files:**
- Create: `supabase/migrations/00301_invites_placeholder_columns.sql`
- Create: `supabase/migrations/_rollbacks/00301_rollback.sql`

- [ ] **Step 1: Write migration**

Create `supabase/migrations/00301_invites_placeholder_columns.sql`:

```sql
-- Mig 00301: invites columns for placeholder claim tokens.
--
-- claim_token_hash = sha256(raw_token); raw token is returned ONCE to the
-- edge function which embeds it in the WhatsApp magic link. The link is the
-- primary claim path; phone match is secondary.
--
-- placeholder_user_id ties this invite to the auth.users row we created for
-- the placeholder. On accept, we reassign group_members.user_id and delete
-- profiles[placeholder]. On decline, we deactivate group_members and stamp
-- disputed_at on the profile.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §15.2

begin;

alter table public.invites
  add column if not exists placeholder_user_id uuid
    references auth.users(id) on delete cascade,
  add column if not exists claim_token_hash text;

create unique index if not exists invites_claim_token_hash_uq
  on public.invites (claim_token_hash)
  where claim_token_hash is not null;

create index if not exists invites_placeholder_uid_idx
  on public.invites (placeholder_user_id)
  where placeholder_user_id is not null and used_at is null;

comment on column public.invites.placeholder_user_id is
  'When set, this invite is tied to a placeholder auth.users row created by the admin. Claim/decline RPCs use this pointer to find the merge target.';
comment on column public.invites.claim_token_hash is
  'sha256 of the raw claim token (never stored plaintext). The raw token lives only in the WhatsApp magic link sent to the invitee.';

commit;
```

Create `supabase/migrations/_rollbacks/00301_rollback.sql`:

```sql
begin;
drop index if exists public.invites_placeholder_uid_idx;
drop index if exists public.invites_claim_token_hash_uq;
alter table public.invites
  drop column if exists claim_token_hash,
  drop column if exists placeholder_user_id;
commit;
```

- [ ] **Step 2: Apply and verify**

```bash
supabase db reset --local
psql "$LOCAL_DB_URL" -c "\d public.invites" | grep -E "placeholder_user_id|claim_token_hash"
```

Expected: 2 new columns present.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/00301_invites_placeholder_columns.sql \
        supabase/migrations/_rollbacks/00301_rollback.sql
git commit -m "feat(schema): invites claim_token_hash + placeholder_user_id (mig 00301)"
```

---

### Task 3: `group_members.joined_via` accept `'placeholder'`

**Files:**
- Create: `supabase/migrations/00302_group_members_joined_via_placeholder.sql`
- Create: `supabase/migrations/_rollbacks/00302_rollback.sql`

- [ ] **Step 1: Verify current constraint values**

Run: `grep -A 2 "joined_via in" supabase/migrations/00180*.sql`
Expected output: `check (joined_via in ('founder_seed', 'invite_code', 'admin_add', 'unknown'))`

If the constraint was modified by a later migration, find the latest one with:
`grep -rn "joined_via in" supabase/migrations/*.sql | tail -3`
Use that as the basis. The migration below assumes mig 00180 still controls it.

- [ ] **Step 2: Write migration**

Create `supabase/migrations/00302_group_members_joined_via_placeholder.sql`:

```sql
-- Mig 00302: extend group_members.joined_via to accept 'placeholder'.
--
-- Created by admin via create-placeholder-member edge function. Independent
-- of self/invite_code paths — never gets stamped by triggers because the
-- RPC inserts the row directly with joined_via='placeholder'.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §15.3

begin;

alter table public.group_members
  drop constraint if exists group_members_joined_via_check;

alter table public.group_members
  add constraint group_members_joined_via_check
  check (joined_via in (
    'founder_seed', 'invite_code', 'admin_add', 'unknown', 'placeholder'
  ));

commit;
```

Create `supabase/migrations/_rollbacks/00302_rollback.sql`:

```sql
begin;
-- Caller must clean placeholder rows BEFORE rolling back, or this fails.
alter table public.group_members
  drop constraint if exists group_members_joined_via_check;
alter table public.group_members
  add constraint group_members_joined_via_check
  check (joined_via in (
    'founder_seed', 'invite_code', 'admin_add', 'unknown'
  ));
commit;
```

- [ ] **Step 3: Apply and verify**

```bash
supabase db reset --local
psql "$LOCAL_DB_URL" -c "\d+ public.group_members" | grep joined_via_check
```

Expected: constraint includes `placeholder` in its allowed list.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/00302_group_members_joined_via_placeholder.sql \
        supabase/migrations/_rollbacks/00302_rollback.sql
git commit -m "feat(schema): group_members.joined_via accepts 'placeholder' (mig 00302)"
```

---

### Task 4: `identity_resolver` view

**Files:**
- Create: `supabase/migrations/00303_identity_resolver_view.sql`
- Create: `supabase/migrations/_rollbacks/00303_rollback.sql`
- Test: `supabase/functions/_tests/db/identity_resolver.test.ts`

- [ ] **Step 1: Write migration**

Create `supabase/migrations/00303_identity_resolver_view.sql`:

```sql
-- Mig 00303: identity_resolver view — maps raw_id → canonical_id.
--
-- After a placeholder is merged into a real user, the auth.users row for the
-- placeholder remains (we don't delete it because user-id-based atoms like
-- vote_casts and user_actions still point at its id). The merge stamps
-- raw_user_meta_data.merged_into = canonical_uid. This view follows that
-- pointer (depth-limited) so projections that aggregate by user_id can
-- collapse historical placeholder uids into the canonical owner.
--
-- Membership-based atoms (system_events, ledger_entries) point at
-- group_members.id which is reassigned atomically during merge — they don't
-- need this view.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §8.4

begin;

create or replace view public.identity_resolver as
with recursive resolver as (
  select
    u.id as raw_id,
    u.id as current_id,
    coalesce((u.raw_user_meta_data->>'merged_into')::uuid, u.id) as next_id,
    0 as depth
  from auth.users u
  union all
  select
    r.raw_id,
    r.next_id as current_id,
    coalesce((u.raw_user_meta_data->>'merged_into')::uuid, u.id) as next_id,
    r.depth + 1
  from resolver r
  join auth.users u on u.id = r.next_id
  where r.depth < 10
    and r.current_id <> r.next_id
)
select distinct on (raw_id)
  raw_id,
  next_id as canonical_id
from resolver
order by raw_id, depth desc;

comment on view public.identity_resolver is
  'Maps each auth.users.id to its canonical owner by following raw_user_meta_data.merged_into chains (depth-limited to 10). For non-merged users canonical_id = raw_id.';

grant select on public.identity_resolver to authenticated, anon;

commit;
```

Create `supabase/migrations/_rollbacks/00303_rollback.sql`:

```sql
begin;
drop view if exists public.identity_resolver;
commit;
```

- [ ] **Step 2: Apply migration**

```bash
supabase db reset --local
```

- [ ] **Step 3: Write test**

Create `supabase/functions/_tests/db/identity_resolver.test.ts`:

```typescript
// Tests identity_resolver view: maps raw user id to canonical owner by
// following raw_user_meta_data.merged_into chains.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient, createTestUser } from "../e2e/_fixtures/supabaseClients.ts";

const admin = adminClient();

Deno.test("identity_resolver: unmerged user maps to itself", async () => {
  const user = await createTestUser({ email: `iresolve-self-${crypto.randomUUID()}@test.local` });
  try {
    const { data } = await admin
      .from("identity_resolver")
      .select("raw_id, canonical_id")
      .eq("raw_id", user.userId)
      .single();
    assertEquals(data?.raw_id, user.userId);
    assertEquals(data?.canonical_id, user.userId);
  } finally {
    await admin.auth.admin.deleteUser(user.userId);
  }
});

Deno.test("identity_resolver: merged user maps to target", async () => {
  const placeholder = await createTestUser({ email: `iresolve-placeholder-${crypto.randomUUID()}@test.local` });
  const target = await createTestUser({ email: `iresolve-target-${crypto.randomUUID()}@test.local` });
  try {
    await admin.auth.admin.updateUserById(placeholder.userId, {
      user_metadata: { merged_into: target.userId },
    });

    const { data } = await admin
      .from("identity_resolver")
      .select("canonical_id")
      .eq("raw_id", placeholder.userId)
      .single();
    assertEquals(data?.canonical_id, target.userId);
  } finally {
    await admin.auth.admin.deleteUser(placeholder.userId);
    await admin.auth.admin.deleteUser(target.userId);
  }
});

Deno.test("identity_resolver: 2-hop chain follows transitively", async () => {
  const a = await createTestUser({ email: `iresolve-a-${crypto.randomUUID()}@test.local` });
  const b = await createTestUser({ email: `iresolve-b-${crypto.randomUUID()}@test.local` });
  const c = await createTestUser({ email: `iresolve-c-${crypto.randomUUID()}@test.local` });
  try {
    await admin.auth.admin.updateUserById(a.userId, { user_metadata: { merged_into: b.userId } });
    await admin.auth.admin.updateUserById(b.userId, { user_metadata: { merged_into: c.userId } });

    const { data } = await admin
      .from("identity_resolver")
      .select("canonical_id")
      .eq("raw_id", a.userId)
      .single();
    assertEquals(data?.canonical_id, c.userId);
  } finally {
    await admin.auth.admin.deleteUser(a.userId);
    await admin.auth.admin.deleteUser(b.userId);
    await admin.auth.admin.deleteUser(c.userId);
  }
});
```

- [ ] **Step 4: Run test**

```bash
cd supabase/functions && \
  deno test --allow-all _tests/db/identity_resolver.test.ts
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/00303_identity_resolver_view.sql \
        supabase/migrations/_rollbacks/00303_rollback.sql \
        supabase/functions/_tests/db/identity_resolver.test.ts
git commit -m "feat(schema): identity_resolver view + tests (mig 00303)"
```

---

### Task 5: Whitelist new system_event types

**Files:**
- Create: `supabase/migrations/00304_system_event_types_member_lifecycle.sql`
- Create: `supabase/migrations/_rollbacks/00304_rollback.sql`

- [ ] **Step 1: Find the current `is_known_system_event_type` definition**

Run: `grep -rn "is_known_system_event_type\|known_system_event_types" supabase/migrations/*.sql | head -10`

The first occurrence defines the function. Later migrations may extend it. Read the most recent one that contains the whitelist array — that's the one to extend with our new types.

- [ ] **Step 2: Write migration**

Create `supabase/migrations/00304_system_event_types_member_lifecycle.sql`:

```sql
-- Mig 00304: whitelist new member lifecycle event types for placeholder
-- flow. The whitelist guards record_system_event from inserting unknown
-- event_types (mig 00094 group_membership_guard).
--
-- New types:
--   member.placeholder_created — emitted by finalize_placeholder_member
--   member.claimed             — emitted by accept_placeholder_claim
--   member.merge_declined      — emitted by decline_placeholder_claim
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §5.5, §15.6

begin;

-- IMPORTANT: copy the latest `is_known_system_event_type` body from the most
-- recent migration that defines it, then append the three new types to the
-- whitelist array. Do NOT just CREATE OR REPLACE with a stub — the function
-- carries domain-specific lists that must be preserved verbatim.
--
-- Template (replace ARRAY[...] with current contents + new types):
--
-- create or replace function public.is_known_system_event_type(p_type text)
-- returns boolean
-- language sql immutable as $$
--   select p_type = any (array[
--     -- ... existing types from latest definition ...
--     'member.placeholder_created',
--     'member.claimed',
--     'member.merge_declined'
--   ]);
-- $$;

-- The executing engineer must:
--   1. Read the latest is_known_system_event_type body from
--      `grep -rn "is_known_system_event_type" supabase/migrations/*.sql | tail -2`
--   2. Paste it here with the three new types appended.
--   3. Replace this comment block with the actual CREATE OR REPLACE.

commit;
```

> **Note for executor:** the function body must be copied verbatim because the whitelist grows over time. Don't risk overwriting existing types with stale ones.

- [ ] **Step 3: Replace the placeholder block with the actual function definition**

After copying the latest body, the migration should look like:

```sql
begin;

create or replace function public.is_known_system_event_type(p_type text)
returns boolean
language sql immutable as $$
  select p_type = any (array[
    -- ... all existing types verbatim from latest mig ...
    'member.placeholder_created',
    'member.claimed',
    'member.merge_declined'
  ]);
$$;

commit;
```

Create `supabase/migrations/_rollbacks/00304_rollback.sql` — restore the previous body verbatim (without the 3 new types) by copying the prior migration's definition.

- [ ] **Step 4: Apply and verify**

```bash
supabase db reset --local
psql "$LOCAL_DB_URL" -c "select public.is_known_system_event_type('member.claimed');"
```

Expected: `t` (true).

```bash
psql "$LOCAL_DB_URL" -c "select public.is_known_system_event_type('eventClosed');"
```

Expected: `t` — regression check that existing types still pass.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/00304_system_event_types_member_lifecycle.sql \
        supabase/migrations/_rollbacks/00304_rollback.sql
git commit -m "feat(schema): whitelist member.{placeholder_created,claimed,merge_declined} system event types (mig 00304)"
```

---

### Task 6: Verify schema baseline end-to-end

- [ ] **Step 1: Reset and apply all migrations cleanly**

```bash
supabase db reset --local
```

Expected: zero errors. All migrations 00001-00304 apply.

- [ ] **Step 2: Run existing test suite to verify no regression**

```bash
cd supabase/functions && deno test --allow-all _tests/db/ 2>&1 | tail -20
```

Expected: all previously-passing tests still pass. New `identity_resolver.test.ts` is the only addition.

- [ ] **Step 3: Commit checkpoint (optional)** — only if you made fixes for unexpected breakage.

---

## Phase 2 — RPCs

### Task 7: `finalize_placeholder_member` RPC

**Files:**
- Create: `supabase/migrations/00305_finalize_placeholder_member_rpc.sql`
- Create: `supabase/migrations/_rollbacks/00305_rollback.sql`
- Test: `supabase/functions/_tests/db/placeholder_member_creation.test.ts`

- [ ] **Step 1: Verify `has_permission` signature**

Run: `grep -A 5 "create.*function public.has_permission" supabase/migrations/00063*.sql`

Note the exact parameter names. The body below assumes `(p_group_id uuid, p_user_id uuid, p_permission text)`. Adjust if the codebase uses different names.

- [ ] **Step 2: Write migration**

Create `supabase/migrations/00305_finalize_placeholder_member_rpc.sql`:

```sql
-- Mig 00305: finalize_placeholder_member RPC.
--
-- Called by the create-placeholder-member edge function AFTER it has used
-- the Supabase Admin API to create the placeholder auth.users row. This RPC
-- runs the rest atomically in Postgres:
--   1. Insert profiles (is_placeholder=true, phone, display_name).
--   2. Insert group_members (joined_via='placeholder', active=true, next turn_order).
--   3. Insert invites with claim_token_hash + placeholder_user_id.
--   4. record_system_event(member.placeholder_created).
--   5. Return the raw claim_token (returned to edge function — never stored plaintext).
--
-- SECURITY: SECURITY DEFINER. Re-checks permission p_actor has
-- 'members.invite' on p_group_id as defense in depth — the edge function
-- already checked but RPC must be independently safe.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §9.2

begin;

create or replace function public.finalize_placeholder_member(
  p_placeholder_user_id uuid,
  p_group_id uuid,
  p_display_name text,
  p_phone_e164 text,
  p_actor_user_id uuid
) returns jsonb
language plpgsql security definer set search_path = public, pg_catalog
as $$
declare
  v_claim_token text := encode(gen_random_bytes(32), 'hex');
  v_claim_token_hash text := encode(
    digest(v_claim_token::bytea, 'sha256'), 'hex'
  );
  v_invite_id uuid;
  v_member_id uuid;
  v_turn int;
begin
  if p_placeholder_user_id is null
     or p_group_id is null
     or p_display_name is null or length(trim(p_display_name)) = 0
     or p_phone_e164 is null or length(trim(p_phone_e164)) = 0
     or p_actor_user_id is null then
    raise exception 'finalize_placeholder_member: all args required';
  end if;

  -- Defense-in-depth permission check.
  if not public.has_permission(p_group_id, p_actor_user_id, 'members.invite') then
    raise exception 'finalize_placeholder_member: actor % lacks members.invite on %', p_actor_user_id, p_group_id;
  end if;

  -- Reject if a real (non-placeholder) profile already owns this phone.
  if exists (
    select 1 from public.profiles
    where phone = p_phone_e164
      and (is_placeholder = false or claimed_at is not null)
  ) then
    raise exception 'finalize_placeholder_member: phone % belongs to a real user', p_phone_e164;
  end if;

  -- Profile.
  insert into public.profiles
    (id, display_name, phone, is_placeholder, claimed_at)
  values
    (p_placeholder_user_id, p_display_name, p_phone_e164, true, null);

  -- group_members at the end of the rotation.
  select coalesce(max(turn_order), 0) + 1 into v_turn
  from public.group_members where group_id = p_group_id;

  insert into public.group_members
    (group_id, user_id, role, turn_order, joined_via, active)
  values
    (p_group_id, p_placeholder_user_id, 'member', v_turn, 'placeholder', true)
  returning id into v_member_id;

  -- Invite with claim token.
  insert into public.invites
    (group_id, invited_by, phone_e164, claim_token_hash,
     placeholder_user_id, expires_at)
  values
    (p_group_id, p_actor_user_id, p_phone_e164, v_claim_token_hash,
     p_placeholder_user_id, now() + interval '30 days')
  returning id into v_invite_id;

  -- Atom.
  perform public.record_system_event(
    p_group_id    := p_group_id,
    p_event_type  := 'member.placeholder_created',
    p_resource_id := null,
    p_member_id   := v_member_id,
    p_payload     := jsonb_build_object(
      'placeholder_user_id', p_placeholder_user_id,
      'invite_id',           v_invite_id,
      'phone_e164',          p_phone_e164,
      'display_name',        p_display_name,
      'actor_user_id',       p_actor_user_id
    )
  );

  return jsonb_build_object(
    'claim_token', v_claim_token,
    'invite_id',   v_invite_id,
    'member_id',   v_member_id,
    'placeholder_user_id', p_placeholder_user_id,
    'turn_order',  v_turn
  );
end$$;

revoke all on function public.finalize_placeholder_member(uuid, uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.finalize_placeholder_member(uuid, uuid, text, text, uuid) to service_role;

commit;
```

Create `supabase/migrations/_rollbacks/00305_rollback.sql`:

```sql
begin;
drop function if exists public.finalize_placeholder_member(uuid, uuid, text, text, uuid);
commit;
```

- [ ] **Step 3: Write test**

Create `supabase/functions/_tests/db/placeholder_member_creation.test.ts`:

```typescript
// Tests finalize_placeholder_member RPC happy path + guards.

import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup } from "../e2e/_fixtures/seedGroup.ts";

const admin = adminClient();

Deno.test("finalize_placeholder_member: happy path inserts profile + membership + invite + atom", async () => {
  const g = await seedGroup({ memberSpecs: [{ handle: "founder" }], seedDinnerRules: false });
  const phone = `+5215555${Math.floor(1000000 + Math.random() * 8999999)}`;

  const { data: phUser } = await admin.auth.admin.createUser({
    user_metadata: { placeholder: true, display_name: "Juan Test" },
  });
  const placeholderUid = phUser!.user!.id;

  try {
    const { data, error } = await admin.rpc("finalize_placeholder_member", {
      p_placeholder_user_id: placeholderUid,
      p_group_id: g.groupId,
      p_display_name: "Juan Test",
      p_phone_e164: phone,
      p_actor_user_id: g.founder.userId,
    });
    assert(!error, `RPC failed: ${error?.message}`);
    assert(data?.claim_token && typeof data.claim_token === "string");

    // Profile.
    const { data: profile } = await admin.from("profiles").select("*").eq("id", placeholderUid).single();
    assertEquals(profile?.is_placeholder, true);
    assertEquals(profile?.phone, phone);

    // Membership.
    const { data: gm } = await admin.from("group_members")
      .select("user_id, joined_via, active")
      .eq("group_id", g.groupId).eq("user_id", placeholderUid).single();
    assertEquals(gm?.joined_via, "placeholder");
    assertEquals(gm?.active, true);

    // Invite with hashed token.
    const { data: invite } = await admin.from("invites")
      .select("placeholder_user_id, claim_token_hash")
      .eq("id", data.invite_id).single();
    assertEquals(invite?.placeholder_user_id, placeholderUid);
    assert(invite?.claim_token_hash, "claim_token_hash must be set");

    // Atom emitted.
    const { data: events } = await admin.from("system_events")
      .select("event_type, payload")
      .eq("group_id", g.groupId)
      .eq("event_type", "member.placeholder_created");
    assert((events ?? []).length === 1);
    assertEquals((events![0].payload as { placeholder_user_id: string }).placeholder_user_id, placeholderUid);
  } finally {
    await admin.from("group_members").delete().eq("user_id", placeholderUid);
    await admin.from("profiles").delete().eq("id", placeholderUid);
    await admin.auth.admin.deleteUser(placeholderUid);
    // seedGroup cleanup handled by fixture or test teardown convention.
  }
});

Deno.test("finalize_placeholder_member: rejects duplicate phone of real user", async () => {
  const g = await seedGroup({ memberSpecs: [{ handle: "founder" }], seedDinnerRules: false });
  const phone = `+5215555${Math.floor(1000000 + Math.random() * 8999999)}`;

  // Real profile already owns this phone.
  await admin.from("profiles").update({ phone }).eq("id", g.founder.userId);

  const { data: phUser } = await admin.auth.admin.createUser({});
  const placeholderUid = phUser!.user!.id;

  try {
    await assertRejects(async () => {
      const { error } = await admin.rpc("finalize_placeholder_member", {
        p_placeholder_user_id: placeholderUid,
        p_group_id: g.groupId,
        p_display_name: "Dup",
        p_phone_e164: phone,
        p_actor_user_id: g.founder.userId,
      });
      if (error) throw new Error(error.message);
    });
  } finally {
    await admin.auth.admin.deleteUser(placeholderUid);
  }
});
```

- [ ] **Step 4: Run test**

```bash
cd supabase/functions && \
  deno test --allow-all _tests/db/placeholder_member_creation.test.ts
```

Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/00305_finalize_placeholder_member_rpc.sql \
        supabase/migrations/_rollbacks/00305_rollback.sql \
        supabase/functions/_tests/db/placeholder_member_creation.test.ts
git commit -m "feat(rpc): finalize_placeholder_member + tests (mig 00305)"
```

---

### Task 8: `_merge_group_members` helper

**Files:**
- Create: `supabase/migrations/00306_merge_placeholder_rpcs.sql` (will accumulate Tasks 8 + 9 in same migration)

- [ ] **Step 1: Open the merge migration file (will be created in this task and extended in Task 9)**

Create `supabase/migrations/00306_merge_placeholder_rpcs.sql`:

```sql
-- Mig 00306: merge_placeholder_into_user + _merge_group_members helper.
--
-- See Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §12.
--
-- Append-only contract:
--   - DOES reassign mutable projections: group_members, profiles,
--     notification_tokens, notification_preferences.
--   - DOES NOT touch atoms: system_events, ledger_entries (auto-inherit via
--     group_members.id reassignment), vote_casts, user_actions (resolved
--     via identity_resolver view).
--   - DOES NOT delete the placeholder's auth.users row — atoms still
--     reference its id. The row is marked with
--     raw_user_meta_data.merged_into = canonical_uid.

begin;

create or replace function public._merge_group_members(
  p_placeholder uuid,
  p_target uuid
) returns void
language plpgsql security definer set search_path = public, pg_catalog
as $$
declare
  r record;
begin
  for r in
    select gm_p.*
    from public.group_members gm_p
    where gm_p.user_id = p_placeholder
  loop
    if exists (
      select 1 from public.group_members
      where group_id = r.group_id and user_id = p_target
    ) then
      -- Target already a member: merge metadata into target row, drop placeholder.
      update public.group_members tgt
        set
          turn_order = coalesce(tgt.turn_order, r.turn_order),
          roles = coalesce(tgt.roles, '[]'::jsonb)
                  || coalesce(r.roles, '[]'::jsonb),
          active = tgt.active or r.active
        where tgt.group_id = r.group_id and tgt.user_id = p_target;

      delete from public.group_members
        where group_id = r.group_id and user_id = p_placeholder;
    else
      -- Simple reassign.
      update public.group_members
        set user_id = p_target
        where group_id = r.group_id and user_id = p_placeholder;
    end if;
  end loop;
end$$;

revoke all on function public._merge_group_members(uuid, uuid) from public, anon, authenticated;

commit;
```

- [ ] **Step 2: Apply and verify the helper exists**

```bash
supabase db reset --local
psql "$LOCAL_DB_URL" -c "\df public._merge_group_members"
```

Expected: 1 row, function exists.

- [ ] **Step 3: Commit (Task 8 and Task 9 land together in this migration; commit after Task 9 step 4)**

No commit here — Task 9 finalizes the migration in the same file.

---

### Task 9: `merge_placeholder_into_user` RPC + test

**Files:**
- Modify: `supabase/migrations/00306_merge_placeholder_rpcs.sql`
- Create: `supabase/migrations/_rollbacks/00306_rollback.sql`
- Test: `supabase/functions/_tests/db/placeholder_merge_engine.test.ts`

- [ ] **Step 1: Append `merge_placeholder_into_user` to the migration**

Edit `supabase/migrations/00306_merge_placeholder_rpcs.sql` and add **before** the closing `commit;`:

```sql
create or replace function public.merge_placeholder_into_user(
  p_placeholder uuid,
  p_target uuid
) returns void
language plpgsql security definer set search_path = public, pg_catalog
as $$
declare
  v_meta jsonb;
begin
  if p_placeholder = p_target then return; end if;

  if not exists (
    select 1 from public.profiles
    where id = p_placeholder and is_placeholder = true and claimed_at is null
  ) then
    raise exception 'merge_placeholder_into_user: % is not an unclaimed placeholder', p_placeholder;
  end if;

  if exists (
    select 1 from auth.users
    where id = p_target and coalesce(is_anonymous, false) = true
  ) then
    raise exception 'merge_placeholder_into_user: target % is anonymous', p_target;
  end if;

  -- Stamp merged_into on placeholder auth.users (identity_resolver follows this).
  select raw_user_meta_data into v_meta from auth.users where id = p_placeholder;
  update auth.users
    set raw_user_meta_data = coalesce(v_meta, '{}'::jsonb)
      || jsonb_build_object('merged_into', p_target::text)
    where id = p_placeholder;

  -- Reassign mutable projections.
  perform public._merge_group_members(p_placeholder, p_target);

  -- notification_tokens: avoid duplicate (user_id, token) by deleting placeholder rows
  -- whose tokens already exist for the target, then UPDATEing the rest.
  delete from public.notification_tokens
    where user_id = p_placeholder
      and exists (
        select 1 from public.notification_tokens t2
        where t2.user_id = p_target and t2.token = notification_tokens.token
      );
  update public.notification_tokens
    set user_id = p_target
    where user_id = p_placeholder;

  -- notification_preferences: target keeps its own; drop placeholder's row.
  delete from public.notification_preferences
    where user_id = p_placeholder;

  -- Delete placeholder profile (canonical = target's profile).
  delete from public.profiles where id = p_placeholder;

  -- Atoms (system_events, vote_casts, user_actions, ledger_entries) intentionally untouched.
end$$;

revoke all on function public.merge_placeholder_into_user(uuid, uuid) from public, anon, authenticated;
grant execute on function public.merge_placeholder_into_user(uuid, uuid) to service_role;
```

Create `supabase/migrations/_rollbacks/00306_rollback.sql`:

```sql
begin;
drop function if exists public.merge_placeholder_into_user(uuid, uuid);
drop function if exists public._merge_group_members(uuid, uuid);
commit;
```

- [ ] **Step 2: Apply migration**

```bash
supabase db reset --local
```

- [ ] **Step 3: Write test**

Create `supabase/functions/_tests/db/placeholder_merge_engine.test.ts`:

```typescript
// Tests merge_placeholder_into_user: reassigns mutable projections,
// marks merged_into in auth.users meta, deletes placeholder profile,
// leaves atoms intact.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup } from "../e2e/_fixtures/seedGroup.ts";

const admin = adminClient();

Deno.test("merge_placeholder_into_user: reassigns group_members, stamps merged_into, deletes profile", async () => {
  const g = await seedGroup({ memberSpecs: [{ handle: "founder" }, { handle: "real" }], seedDinnerRules: false });
  const phone = `+5215555${Math.floor(1000000 + Math.random() * 8999999)}`;

  // Create placeholder via finalize_placeholder_member.
  const { data: phUser } = await admin.auth.admin.createUser({});
  const placeholderUid = phUser!.user!.id;

  await admin.rpc("finalize_placeholder_member", {
    p_placeholder_user_id: placeholderUid,
    p_group_id: g.groupId,
    p_display_name: "Juan",
    p_phone_e164: phone,
    p_actor_user_id: g.founder.userId,
  });

  // Sanity: placeholder is a member.
  const { count: beforeCount } = await admin.from("group_members")
    .select("*", { count: "exact", head: true })
    .eq("group_id", g.groupId).eq("user_id", placeholderUid);
  assertEquals(beforeCount, 1);

  // Merge into the 2nd seeded member.
  const target = g.members[1];
  const { error } = await admin.rpc("merge_placeholder_into_user", {
    p_placeholder: placeholderUid,
    p_target: target.userId,
  });
  assert(!error, `merge failed: ${error?.message}`);

  // Placeholder no longer in group_members.
  const { count: afterPlaceholder } = await admin.from("group_members")
    .select("*", { count: "exact", head: true })
    .eq("group_id", g.groupId).eq("user_id", placeholderUid);
  assertEquals(afterPlaceholder, 0);

  // Target still in group_members.
  const { count: afterTarget } = await admin.from("group_members")
    .select("*", { count: "exact", head: true })
    .eq("group_id", g.groupId).eq("user_id", target.userId);
  assertEquals(afterTarget, 1);

  // Placeholder profile deleted.
  const { data: profile } = await admin.from("profiles").select("id").eq("id", placeholderUid).maybeSingle();
  assertEquals(profile, null);

  // auth.users[placeholder] has merged_into set.
  const { data: phAuth } = await admin.auth.admin.getUserById(placeholderUid);
  assertEquals(phAuth.user?.user_metadata?.merged_into, target.userId);

  // identity_resolver resolves placeholder → target.
  const { data: resolved } = await admin.from("identity_resolver")
    .select("canonical_id").eq("raw_id", placeholderUid).single();
  assertEquals(resolved?.canonical_id, target.userId);

  // The member.placeholder_created atom still exists (atoms intact).
  const { data: atoms } = await admin.from("system_events")
    .select("id").eq("group_id", g.groupId).eq("event_type", "member.placeholder_created");
  assert((atoms ?? []).length === 1);
});

Deno.test("merge_placeholder_into_user: rejects when placeholder is not actually a placeholder", async () => {
  const g = await seedGroup({ memberSpecs: [{ handle: "founder" }, { handle: "other" }], seedDinnerRules: false });
  const { error } = await admin.rpc("merge_placeholder_into_user", {
    p_placeholder: g.founder.userId,
    p_target: g.members[1].userId,
  });
  assert(error != null, "should reject non-placeholder");
});
```

- [ ] **Step 4: Run test**

```bash
cd supabase/functions && \
  deno test --allow-all _tests/db/placeholder_merge_engine.test.ts
```

Expected: 2 passed.

- [ ] **Step 5: Commit (Tasks 8 + 9 together)**

```bash
git add supabase/migrations/00306_merge_placeholder_rpcs.sql \
        supabase/migrations/_rollbacks/00306_rollback.sql \
        supabase/functions/_tests/db/placeholder_merge_engine.test.ts
git commit -m "feat(rpc): merge_placeholder_into_user + _merge_group_members + tests (mig 00306)"
```

---

### Task 10: `accept_placeholder_claim` RPC + test

**Files:**
- Create: `supabase/migrations/00307_claim_placeholder_rpcs.sql` (will accumulate Tasks 10 + 11 RPCs)
- Test: `supabase/functions/_tests/db/placeholder_claim_flow.test.ts`

- [ ] **Step 1: Write migration (accept only — decline added in Task 11)**

Create `supabase/migrations/00307_claim_placeholder_rpcs.sql`:

```sql
-- Mig 00307: accept_placeholder_claim + decline_placeholder_claim RPCs.
--
-- Two claim paths, one RPC:
--   - Camino A (magic link): caller passes p_claim_token (raw, from URL).
--   - Camino B (phone match): caller passes p_placeholder_uid; SQL verifies
--     auth.uid()'s phone matches profiles[placeholder].phone.
--
-- Both paths end in merge_placeholder_into_user(placeholder, auth.uid())
-- inside a pg_advisory_xact_lock so concurrent taps serialize cleanly.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §11.4

begin;

create or replace function public.accept_placeholder_claim(
  p_claim_token text default null,
  p_placeholder_uid uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_catalog
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_phone text;
  v_placeholder uuid;
  v_invite record;
  v_invite_id uuid;
  v_group_id uuid;
  v_target_member_id uuid;
begin
  if v_actor is null then raise exception 'accept_placeholder_claim: not authenticated'; end if;

  if p_claim_token is not null then
    select * into v_invite
    from public.invites
    where claim_token_hash = encode(digest(p_claim_token::bytea, 'sha256'), 'hex')
      and used_at is null
      and expires_at > now()
      and placeholder_user_id is not null
    for update;
    if v_invite.id is null then raise exception 'accept_placeholder_claim: invalid_or_expired_token'; end if;
    v_placeholder := v_invite.placeholder_user_id;
    v_group_id := v_invite.group_id;
    v_invite_id := v_invite.id;

  elsif p_placeholder_uid is not null then
    select phone into v_actor_phone from auth.users where id = v_actor;
    if v_actor_phone is null then
      raise exception 'accept_placeholder_claim: no_verified_phone_for_caller';
    end if;

    if not exists (
      select 1 from public.profiles
      where id = p_placeholder_uid
        and is_placeholder = true
        and claimed_at is null
        and phone = v_actor_phone
    ) then raise exception 'accept_placeholder_claim: phone_mismatch_or_not_placeholder'; end if;

    v_placeholder := p_placeholder_uid;

    -- Look up the open invite tied to this placeholder.
    select * into v_invite
    from public.invites
    where placeholder_user_id = v_placeholder
      and used_at is null
    order by created_at desc
    limit 1
    for update;
    if v_invite.id is not null then
      v_group_id := v_invite.group_id;
      v_invite_id := v_invite.id;
    else
      -- No open invite; recover group_id from group_members.
      select group_id into v_group_id
      from public.group_members where user_id = v_placeholder
      order by joined_at asc limit 1;
      if v_group_id is null then
        raise exception 'accept_placeholder_claim: placeholder_has_no_group';
      end if;
    end if;

  else
    raise exception 'accept_placeholder_claim: token_or_uid_required';
  end if;

  -- Serialize concurrent taps on same placeholder.
  perform pg_advisory_xact_lock(hashtext(v_placeholder::text));

  -- Do the merge.
  perform public.merge_placeholder_into_user(v_placeholder, v_actor);

  -- Mark invite consumed.
  if v_invite_id is not null then
    update public.invites
      set used_at = now(), used_by_user_id = v_actor
      where id = v_invite_id;
  end if;

  -- Resolve target's group_member id for the atom.
  select id into v_target_member_id
  from public.group_members where group_id = v_group_id and user_id = v_actor;

  perform public.record_system_event(
    p_group_id    := v_group_id,
    p_event_type  := 'member.claimed',
    p_resource_id := null,
    p_member_id   := v_target_member_id,
    p_payload     := jsonb_build_object(
      'placeholder_user_id', v_placeholder,
      'canonical_user_id',   v_actor,
      'invite_id',           v_invite_id,
      'path',                case when p_claim_token is not null then 'magic_link' else 'phone_match' end
    )
  );

  return jsonb_build_object(
    'canonical_user_id', v_actor,
    'group_id',          v_group_id,
    'member_id',         v_target_member_id
  );
end$$;

revoke all on function public.accept_placeholder_claim(text, uuid) from public, anon;
grant execute on function public.accept_placeholder_claim(text, uuid) to authenticated;

commit;
```

- [ ] **Step 2: Apply migration**

```bash
supabase db reset --local
```

- [ ] **Step 3: Write test**

Create `supabase/functions/_tests/db/placeholder_claim_flow.test.ts`:

```typescript
// Tests accept_placeholder_claim end-to-end via magic-link token path.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient, createTestUser } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup } from "../e2e/_fixtures/seedGroup.ts";

const admin = adminClient();

Deno.test("accept_placeholder_claim: token path merges placeholder into real user, emits member.claimed", async () => {
  const g = await seedGroup({ memberSpecs: [{ handle: "founder" }], seedDinnerRules: false });
  const phone = `+5215555${Math.floor(1000000 + Math.random() * 8999999)}`;

  // Create placeholder via finalize.
  const { data: phUser } = await admin.auth.admin.createUser({});
  const placeholderUid = phUser!.user!.id;

  const { data: finalizeRes } = await admin.rpc("finalize_placeholder_member", {
    p_placeholder_user_id: placeholderUid,
    p_group_id: g.groupId,
    p_display_name: "Juan",
    p_phone_e164: phone,
    p_actor_user_id: g.founder.userId,
  });
  const claimToken: string = finalizeRes!.claim_token;

  // Real user signs up.
  const real = await createTestUser({ email: `real-${crypto.randomUUID()}@test.local` });

  // Real calls accept with the magic-link token, using their user-bound client.
  const { data: acceptRes, error } = await real.client.rpc("accept_placeholder_claim", {
    p_claim_token: claimToken,
  });
  assert(!error, `accept failed: ${error?.message}`);
  assertEquals(acceptRes?.canonical_user_id, real.userId);
  assertEquals(acceptRes?.group_id, g.groupId);

  // Real is now a member with the placeholder's row reassigned.
  const { data: gmRows } = await admin.from("group_members")
    .select("user_id").eq("group_id", g.groupId);
  assert((gmRows ?? []).some(r => r.user_id === real.userId));
  assert(!(gmRows ?? []).some(r => r.user_id === placeholderUid));

  // Invite marked used.
  const { data: invite } = await admin.from("invites")
    .select("used_at, used_by_user_id").eq("id", finalizeRes!.invite_id).single();
  assert(invite?.used_at != null);
  assertEquals(invite?.used_by_user_id, real.userId);

  // member.claimed atom emitted.
  const { data: events } = await admin.from("system_events")
    .select("event_type, payload").eq("group_id", g.groupId).eq("event_type", "member.claimed");
  assertEquals((events ?? []).length, 1);

  await admin.auth.admin.deleteUser(real.userId);
});

Deno.test("accept_placeholder_claim: rejects invalid token", async () => {
  const real = await createTestUser({ email: `real2-${crypto.randomUUID()}@test.local` });
  const { error } = await real.client.rpc("accept_placeholder_claim", {
    p_claim_token: "not-a-real-token-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  });
  assert(error != null, "expected rejection");
  await admin.auth.admin.deleteUser(real.userId);
});
```

> **Note:** `createTestUser` should return `{ userId, client, accessToken, email }` based on the seedGroup fixture pattern (line ~47 of supabaseClients.ts). If the fixture doesn't expose a per-user client, adjust the test to bind a fresh `createClient(URL, ANON_KEY, { global: { headers: { Authorization: 'Bearer ' + accessToken }}})`.

- [ ] **Step 4: Run test**

```bash
cd supabase/functions && \
  deno test --allow-all _tests/db/placeholder_claim_flow.test.ts
```

Expected: 2 passed.

- [ ] **Step 5: Hold commit until Task 11 (decline RPC ships in same migration)**

---

### Task 11: `decline_placeholder_claim` RPC + test

**Files:**
- Modify: `supabase/migrations/00307_claim_placeholder_rpcs.sql`
- Create: `supabase/migrations/_rollbacks/00307_rollback.sql`
- Test: `supabase/functions/_tests/db/placeholder_decline_flow.test.ts`

- [ ] **Step 1: Verify `notifications_outbox` shape**

Run: `grep -A 15 "create table.*notifications_outbox" supabase/migrations/*.sql | head -25`

Note the exact column names. The body below assumes `(id, recipient_user_id, kind, payload, ...)`. Adjust if the actual schema differs.

- [ ] **Step 2: Append decline RPC**

Edit `supabase/migrations/00307_claim_placeholder_rpcs.sql` and add **before** the closing `commit;`:

```sql
create or replace function public.decline_placeholder_claim(
  p_claim_token text
) returns jsonb
language plpgsql security definer set search_path = public, pg_catalog
as $$
declare
  v_actor uuid := auth.uid();
  v_invite record;
  v_placeholder_member_id uuid;
begin
  if v_actor is null then raise exception 'decline_placeholder_claim: not_authenticated'; end if;
  if p_claim_token is null then raise exception 'decline_placeholder_claim: token_required'; end if;

  select * into v_invite
  from public.invites
  where claim_token_hash = encode(digest(p_claim_token::bytea, 'sha256'), 'hex')
    and used_at is null
    and expires_at > now()
    and placeholder_user_id is not null
  for update;
  if v_invite.id is null then raise exception 'decline_placeholder_claim: invalid_or_expired_token'; end if;

  -- Stamp dispute metadata on the placeholder profile (we do not delete).
  update public.profiles
    set disputed_at = now(),
        disputed_by_user_id = v_actor
    where id = v_invite.placeholder_user_id;

  -- Deactivate placeholder membership (preserve history rows).
  update public.group_members
    set active = false
    where user_id = v_invite.placeholder_user_id
      and group_id = v_invite.group_id
    returning id into v_placeholder_member_id;

  -- Burn the invite.
  update public.invites
    set used_at = now(), used_by_user_id = v_actor
    where id = v_invite.id;

  perform public.record_system_event(
    p_group_id    := v_invite.group_id,
    p_event_type  := 'member.merge_declined',
    p_resource_id := null,
    p_member_id   := v_placeholder_member_id,
    p_payload     := jsonb_build_object(
      'placeholder_user_id', v_invite.placeholder_user_id,
      'declined_by_user_id', v_actor,
      'invite_id',           v_invite.id,
      'reason',              'declined_by_real_owner'
    )
  );

  -- Best-effort notify admin via notifications_outbox.
  -- If the table's shape differs, the executing engineer must adjust the
  -- INSERT or skip it (decline still succeeds without the notification).
  begin
    insert into public.notifications_outbox
      (recipient_user_id, kind, payload)
    values (
      v_invite.invited_by,
      'placeholder_disputed',
      jsonb_build_object(
        'placeholder_user_id', v_invite.placeholder_user_id,
        'group_id',            v_invite.group_id,
        'disputed_by',         v_actor
      )
    );
  exception when others then
    raise notice 'decline_placeholder_claim: notification skipped (%)', sqlerrm;
  end;

  return jsonb_build_object(
    'declined', true,
    'placeholder_user_id', v_invite.placeholder_user_id,
    'group_id', v_invite.group_id
  );
end$$;

revoke all on function public.decline_placeholder_claim(text) from public, anon;
grant execute on function public.decline_placeholder_claim(text) to authenticated;
```

Create `supabase/migrations/_rollbacks/00307_rollback.sql`:

```sql
begin;
drop function if exists public.decline_placeholder_claim(text);
drop function if exists public.accept_placeholder_claim(text, uuid);
commit;
```

- [ ] **Step 3: Apply**

```bash
supabase db reset --local
```

- [ ] **Step 4: Write test**

Create `supabase/functions/_tests/db/placeholder_decline_flow.test.ts`:

```typescript
// Tests decline_placeholder_claim: stamps disputed, deactivates membership, burns invite, emits atom.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient, createTestUser } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup } from "../e2e/_fixtures/seedGroup.ts";

const admin = adminClient();

Deno.test("decline_placeholder_claim: stamps disputed, deactivates membership, emits atom", async () => {
  const g = await seedGroup({ memberSpecs: [{ handle: "founder" }], seedDinnerRules: false });
  const phone = `+5215555${Math.floor(1000000 + Math.random() * 8999999)}`;

  const { data: phUser } = await admin.auth.admin.createUser({});
  const placeholderUid = phUser!.user!.id;

  const { data: finalizeRes } = await admin.rpc("finalize_placeholder_member", {
    p_placeholder_user_id: placeholderUid,
    p_group_id: g.groupId,
    p_display_name: "Juan",
    p_phone_e164: phone,
    p_actor_user_id: g.founder.userId,
  });
  const claimToken: string = finalizeRes!.claim_token;

  const real = await createTestUser({ email: `decline-${crypto.randomUUID()}@test.local` });

  const { data: declineRes, error } = await real.client.rpc("decline_placeholder_claim", {
    p_claim_token: claimToken,
  });
  assert(!error, `decline failed: ${error?.message}`);
  assertEquals(declineRes?.declined, true);

  // Placeholder profile has disputed_at set, still exists, still placeholder.
  const { data: profile } = await admin.from("profiles")
    .select("disputed_at, disputed_by_user_id, is_placeholder, claimed_at")
    .eq("id", placeholderUid).single();
  assert(profile?.disputed_at != null);
  assertEquals(profile?.disputed_by_user_id, real.userId);
  assertEquals(profile?.is_placeholder, true);
  assertEquals(profile?.claimed_at, null);

  // group_members row exists but inactive.
  const { data: gm } = await admin.from("group_members")
    .select("active").eq("group_id", g.groupId).eq("user_id", placeholderUid).single();
  assertEquals(gm?.active, false);

  // Atom emitted.
  const { data: events } = await admin.from("system_events")
    .select("event_type").eq("group_id", g.groupId).eq("event_type", "member.merge_declined");
  assertEquals((events ?? []).length, 1);

  await admin.auth.admin.deleteUser(real.userId);
});
```

- [ ] **Step 5: Run tests**

```bash
cd supabase/functions && \
  deno test --allow-all _tests/db/placeholder_decline_flow.test.ts _tests/db/placeholder_claim_flow.test.ts
```

Expected: 3 passed (2 from Task 10 + 1 from this task).

- [ ] **Step 6: Commit Tasks 10 + 11 together**

```bash
git add supabase/migrations/00307_claim_placeholder_rpcs.sql \
        supabase/migrations/_rollbacks/00307_rollback.sql \
        supabase/functions/_tests/db/placeholder_claim_flow.test.ts \
        supabase/functions/_tests/db/placeholder_decline_flow.test.ts
git commit -m "feat(rpc): accept/decline_placeholder_claim + tests (mig 00307)"
```

---

### Task 12: `discover_pending_placeholders` + `get_placeholder_history_summary` + tests

**Files:**
- Create: `supabase/migrations/00308_discover_and_summary_rpcs.sql`
- Create: `supabase/migrations/_rollbacks/00308_rollback.sql`
- Test extend: `supabase/functions/_tests/db/placeholder_claim_flow.test.ts`

- [ ] **Step 1: Write migration**

Create `supabase/migrations/00308_discover_and_summary_rpcs.sql`:

```sql
-- Mig 00308: discover_pending_placeholders + get_placeholder_history_summary.
--
-- discover: post-login the iOS client calls this to find placeholders whose
-- phone matches the caller's auth.users.phone (Camino B in the spec).
--
-- summary: shown to user in ClaimReviewView before they accept/decline.
-- Returns counts of fines/votes/RSVPs/turns/contribs attributed to the
-- placeholder so they can make an informed decision.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §11.2, §11.3

begin;

create or replace function public.discover_pending_placeholders()
returns table (
  placeholder_uid uuid,
  group_id uuid,
  group_name text,
  display_name text,
  invite_id uuid
)
language sql security definer set search_path = public, pg_catalog
as $$
  select
    p.id as placeholder_uid,
    g.id as group_id,
    g.name as group_name,
    p.display_name,
    i.id as invite_id
  from auth.users me
  join public.profiles p
    on p.phone = (select phone from auth.users where id = auth.uid())
    and p.is_placeholder = true
    and p.claimed_at is null
  join public.invites i
    on i.placeholder_user_id = p.id
    and i.used_at is null
    and i.expires_at > now()
  join public.groups g on g.id = i.group_id
  where me.id = auth.uid()
    and me.phone is not null;
$$;

revoke all on function public.discover_pending_placeholders() from public, anon;
grant execute on function public.discover_pending_placeholders() to authenticated;

create or replace function public.get_placeholder_history_summary(
  p_placeholder_uid uuid
) returns jsonb
language plpgsql security definer set search_path = public, pg_catalog
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_phone text;
  v_placeholder_phone text;
  v_member_id uuid;
  v_group_id uuid;
  v_fine_count int;
  v_vote_count int;
  v_event_count int;
begin
  if v_actor is null then raise exception 'get_placeholder_history_summary: not_authenticated'; end if;

  -- Authorization: caller must either hold the magic link (we can't verify
  -- here cheaply) OR have the matching phone. We choose the latter as the
  -- minimum — magic-link callers should use the same RPC after auth.
  select phone into v_actor_phone from auth.users where id = v_actor;
  select phone into v_placeholder_phone from public.profiles
    where id = p_placeholder_uid and is_placeholder = true and claimed_at is null;
  if v_placeholder_phone is null then
    raise exception 'get_placeholder_history_summary: not_a_placeholder';
  end if;
  if v_actor_phone is null or v_actor_phone <> v_placeholder_phone then
    raise exception 'get_placeholder_history_summary: phone_mismatch';
  end if;

  select id, group_id into v_member_id, v_group_id
  from public.group_members where user_id = p_placeholder_uid limit 1;

  select count(*) into v_fine_count from public.fines
    where user_id = p_placeholder_uid;
  select count(*) into v_vote_count from public.vote_casts
    where user_id = p_placeholder_uid;
  select count(*) into v_event_count from public.system_events
    where member_id = v_member_id;

  return jsonb_build_object(
    'group_id',     v_group_id,
    'member_id',    v_member_id,
    'fine_count',   coalesce(v_fine_count, 0),
    'vote_count',   coalesce(v_vote_count, 0),
    'event_count',  coalesce(v_event_count, 0)
  );
end$$;

revoke all on function public.get_placeholder_history_summary(uuid) from public, anon;
grant execute on function public.get_placeholder_history_summary(uuid) to authenticated;

commit;
```

> **Note for executor:** column names `fines.user_id`, `vote_casts.user_id` are assumed. Verify by running `\d public.fines public.vote_casts` and adjust the COUNT queries if column names differ (e.g. `fines.subject_user_id`).

Create `supabase/migrations/_rollbacks/00308_rollback.sql`:

```sql
begin;
drop function if exists public.get_placeholder_history_summary(uuid);
drop function if exists public.discover_pending_placeholders();
commit;
```

- [ ] **Step 2: Apply**

```bash
supabase db reset --local
```

- [ ] **Step 3: Append tests to existing claim test file**

Append to `supabase/functions/_tests/db/placeholder_claim_flow.test.ts`:

```typescript
Deno.test("discover_pending_placeholders: finds placeholder by matching phone", async () => {
  const g = await seedGroup({ memberSpecs: [{ handle: "founder" }], seedDinnerRules: false });
  const phone = `+5215555${Math.floor(1000000 + Math.random() * 8999999)}`;

  const { data: phUser } = await admin.auth.admin.createUser({});
  const placeholderUid = phUser!.user!.id;
  await admin.rpc("finalize_placeholder_member", {
    p_placeholder_user_id: placeholderUid,
    p_group_id: g.groupId,
    p_display_name: "Juan",
    p_phone_e164: phone,
    p_actor_user_id: g.founder.userId,
  });

  // Real signs up with the matching phone.
  const real = await createTestUser({ email: `discover-${crypto.randomUUID()}@test.local`, phone });

  const { data: pending } = await real.client.rpc("discover_pending_placeholders");
  assert(Array.isArray(pending));
  assertEquals(pending!.length, 1);
  assertEquals((pending as Array<{placeholder_uid:string}>)[0].placeholder_uid, placeholderUid);

  await admin.auth.admin.deleteUser(real.userId);
});

Deno.test("get_placeholder_history_summary: returns counts for phone-matched caller", async () => {
  const g = await seedGroup({ memberSpecs: [{ handle: "founder" }], seedDinnerRules: false });
  const phone = `+5215555${Math.floor(1000000 + Math.random() * 8999999)}`;

  const { data: phUser } = await admin.auth.admin.createUser({});
  const placeholderUid = phUser!.user!.id;
  await admin.rpc("finalize_placeholder_member", {
    p_placeholder_user_id: placeholderUid,
    p_group_id: g.groupId,
    p_display_name: "Juan",
    p_phone_e164: phone,
    p_actor_user_id: g.founder.userId,
  });

  const real = await createTestUser({ email: `summary-${crypto.randomUUID()}@test.local`, phone });

  const { data: summary, error } = await real.client.rpc("get_placeholder_history_summary", {
    p_placeholder_uid: placeholderUid,
  });
  assert(!error, error?.message);
  assertEquals(summary?.group_id, g.groupId);
  assertEquals(summary?.fine_count, 0);
  assertEquals(summary?.vote_count, 0);
  assert((summary?.event_count ?? 0) >= 1, "should count member.placeholder_created event");

  await admin.auth.admin.deleteUser(real.userId);
});
```

> **Note:** `createTestUser` accepting `phone` parameter — verify the fixture signature. If it doesn't accept `phone`, use `admin.auth.admin.createUser({email, phone, phone_confirm: true})` directly and bind a client manually.

- [ ] **Step 4: Run all claim tests**

```bash
cd supabase/functions && \
  deno test --allow-all _tests/db/placeholder_claim_flow.test.ts
```

Expected: 4 passed total.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/00308_discover_and_summary_rpcs.sql \
        supabase/migrations/_rollbacks/00308_rollback.sql \
        supabase/functions/_tests/db/placeholder_claim_flow.test.ts
git commit -m "feat(rpc): discover_pending_placeholders + get_placeholder_history_summary + tests (mig 00308)"
```

---

### Task 13: Invariant CI test + profiles RLS

**Files:**
- Create: `supabase/migrations/00309_profiles_rls_placeholder.sql`
- Create: `supabase/migrations/_rollbacks/00309_rollback.sql`
- Test: `supabase/functions/_tests/db/placeholder_invariants.test.ts`

- [ ] **Step 1: Verify existing profiles RLS**

Run: `grep -A 5 "policy.*on public.profiles" supabase/migrations/*.sql | head -30`

Identify the SELECT policy. The migration below ADDS a new policy that gates placeholder visibility; if a more restrictive policy already covers it, the new policy is harmless additive (PostgreSQL OR's policies).

- [ ] **Step 2: Write RLS migration**

Create `supabase/migrations/00309_profiles_rls_placeholder.sql`:

```sql
-- Mig 00309: limit visibility of placeholder profiles to group admins.
--
-- Reason: placeholder.phone is sensitive (admin-entered, not opt-in). Other
-- members of the group should NOT be able to read the phone column. Two
-- options were considered:
--   (a) Column-level RLS — verbose, brittle.
--   (b) Row-level: only admins of the placeholder's group can SELECT the
--       placeholder profile row (and the profile owner — i.e., the auth.uid
--       which is the placeholder uid; no one ever logs in as it).
-- We pick (b).
--
-- Pre-existing policies remain (PostgreSQL OR's row visibility). Members of
-- the group will see the placeholder via the group_members table + a
-- redacted display_name path; we add a sibling view in a later migration if
-- the UI demands a wider read.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §15.7

begin;

drop policy if exists profiles_select_placeholder_admin_only on public.profiles;
create policy profiles_select_placeholder_admin_only on public.profiles
  for select using (
    is_placeholder = false
    or claimed_at is not null
    or exists (
      select 1 from public.group_members gm
      where gm.user_id = profiles.id
        and public.is_group_admin(gm.group_id, auth.uid())
    )
  );

commit;
```

Create `supabase/migrations/_rollbacks/00309_rollback.sql`:

```sql
begin;
drop policy if exists profiles_select_placeholder_admin_only on public.profiles;
commit;
```

- [ ] **Step 3: Apply**

```bash
supabase db reset --local
```

- [ ] **Step 4: Write invariant test**

Create `supabase/functions/_tests/db/placeholder_invariants.test.ts`:

```typescript
// Post-merge invariants: no merged placeholder must retain FKs in mutable tables.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient, createTestUser } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup } from "../e2e/_fixtures/seedGroup.ts";

const admin = adminClient();

Deno.test("post-merge invariant: no orphan rows in mutable tables for merged placeholders", async () => {
  const g = await seedGroup({ memberSpecs: [{ handle: "founder" }], seedDinnerRules: false });
  const phone = `+5215555${Math.floor(1000000 + Math.random() * 8999999)}`;

  const { data: phUser } = await admin.auth.admin.createUser({});
  const placeholderUid = phUser!.user!.id;
  const { data: finalize } = await admin.rpc("finalize_placeholder_member", {
    p_placeholder_user_id: placeholderUid,
    p_group_id: g.groupId,
    p_display_name: "Juan",
    p_phone_e164: phone,
    p_actor_user_id: g.founder.userId,
  });

  const real = await createTestUser({ email: `inv-${crypto.randomUUID()}@test.local` });
  await real.client.rpc("accept_placeholder_claim", { p_claim_token: finalize!.claim_token });

  // Query each mutable whitelisted table for the placeholder uid.
  const checks: Array<[string, () => Promise<number>]> = [
    ["group_members", async () => {
      const { count } = await admin.from("group_members")
        .select("*", { count: "exact", head: true }).eq("user_id", placeholderUid);
      return count ?? 0;
    }],
    ["profiles", async () => {
      const { count } = await admin.from("profiles")
        .select("*", { count: "exact", head: true }).eq("id", placeholderUid);
      return count ?? 0;
    }],
    ["notification_tokens", async () => {
      const { count } = await admin.from("notification_tokens")
        .select("*", { count: "exact", head: true }).eq("user_id", placeholderUid);
      return count ?? 0;
    }],
  ];

  for (const [name, fn] of checks) {
    const n = await fn();
    assertEquals(n, 0, `${name} should have 0 rows for merged placeholder; found ${n}`);
  }

  await admin.auth.admin.deleteUser(real.userId);
});
```

- [ ] **Step 5: Run all placeholder tests**

```bash
cd supabase/functions && \
  deno test --allow-all _tests/db/placeholder_*.test.ts _tests/db/identity_resolver.test.ts
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/00309_profiles_rls_placeholder.sql \
        supabase/migrations/_rollbacks/00309_rollback.sql \
        supabase/functions/_tests/db/placeholder_invariants.test.ts
git commit -m "feat(rls): admin-only visibility for unclaimed placeholders + invariant test (mig 00309)"
```

---

## Phase 3 — Edge function

### Task 14: `create-placeholder-member` edge function

**Files:**
- Create: `supabase/functions/create-placeholder-member/index.ts`

- [ ] **Step 1: Write edge function**

Create `supabase/functions/create-placeholder-member/index.ts`:

```typescript
// create-placeholder-member: admin creates a stand-in member that already
// counts for rotation/RSVP/fines/votes before the real person registers.
//
// Request: { group_id: uuid, display_name: string, phone_e164: string }
// Responses:
//   200 { kind: "created", member_id, invite_id, placeholder_user_id }
//        WhatsApp magic link sent best-effort (not awaited for success).
//   409 { kind: "existing_user", user_id, display_name? }
//        Phone already belongs to a real user; client should offer
//        add_existing_member instead.
//   409 { kind: "duplicate_placeholder", user_id }
//        Another unclaimed placeholder already owns this phone.
//   403, 400, 500 as appropriate.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { corsHeaders } from "../_shared/cors.ts";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

serve(withSentry(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "missing auth" }, 401);

  // User-bound client for actor identity + permission check.
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "invalid auth" }, 401);

  let group_id: string, display_name: string, phone_e164: string;
  try {
    const body = await req.json();
    group_id = body.group_id;
    display_name = (body.display_name ?? "").trim();
    phone_e164 = (body.phone_e164 ?? "").trim();
    if (!group_id || !display_name || !phone_e164) {
      return json({ error: "group_id, display_name, phone_e164 required" }, 400);
    }
    if (!/^\+\d{8,15}$/.test(phone_e164)) {
      return json({ error: "phone_e164 must be E.164 (e.g. +5215555551234)" }, 400);
    }
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  // Permission check via user-bound RPC (RLS-safe).
  const { data: canInvite, error: permErr } = await userClient.rpc("has_permission", {
    p_group_id: group_id,
    p_user_id: user.id,
    p_permission: "members.invite",
  });
  if (permErr) return json({ error: `permission check failed: ${permErr.message}` }, 500);
  if (!canInvite) return json({ error: "forbidden" }, 403);

  // Service-role client for admin API + RPC bypass.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // 1. Real-user phone lookup.
  const { data: existingByPhone } = await admin.auth.admin.listUsers({
    filter: `phone.eq.${phone_e164}` as never,  // listUsers filter is loosely typed
    perPage: 1,
  } as never);
  if (existingByPhone?.users?.length) {
    const u = existingByPhone.users[0];
    return json({
      kind: "existing_user",
      user_id: u.id,
      display_name: (u.user_metadata as { display_name?: string } | null)?.display_name,
    }, 409);
  }

  // 2. Unclaimed-placeholder phone lookup (the unique partial index also enforces this).
  const { data: dupPlaceholder } = await admin
    .from("profiles")
    .select("id")
    .eq("phone", phone_e164)
    .eq("is_placeholder", true)
    .is("claimed_at", null)
    .maybeSingle();
  if (dupPlaceholder) {
    return json({ kind: "duplicate_placeholder", user_id: dupPlaceholder.id }, 409);
  }

  // 3. Create the anonymous placeholder auth.users row.
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    user_metadata: {
      placeholder: true,
      display_name,
      created_by: user.id,
    },
  });
  if (createErr || !created?.user) {
    return json({ error: `createUser failed: ${createErr?.message}` }, 500);
  }
  const placeholderUid = created.user.id;

  // 4. Atomic finalize RPC.
  const { data: finalize, error: rpcErr } = await admin.rpc("finalize_placeholder_member", {
    p_placeholder_user_id: placeholderUid,
    p_group_id: group_id,
    p_display_name: display_name,
    p_phone_e164: phone_e164,
    p_actor_user_id: user.id,
  });
  if (rpcErr) {
    // Rollback orphan auth user.
    await admin.auth.admin.deleteUser(placeholderUid);
    return json({ error: `finalize failed: ${rpcErr.message}` }, 500);
  }

  const claimToken: string = finalize!.claim_token;
  const inviteId: string = finalize!.invite_id;
  const memberId: string = finalize!.member_id;

  // 5. Fire WhatsApp (best-effort, not awaited synchronously).
  const { data: groupRow } = await admin.from("groups")
    .select("name, invite_code").eq("id", group_id).single();
  if (groupRow) {
    fetch(`${SUPABASE_URL}/functions/v1/send-whatsapp-invite`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        invite_id: inviteId,
        phone: phone_e164,
        group_name: groupRow.name,
        invite_code: groupRow.invite_code,
        claim_token: claimToken,
      }),
    }).catch((err) => console.warn("whatsapp send fire-and-forget failed", err));
  }

  return json({
    kind: "created",
    member_id: memberId,
    invite_id: inviteId,
    placeholder_user_id: placeholderUid,
  });
}, { functionName: "create-placeholder-member" }));

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
```

- [ ] **Step 2: Lint/format**

```bash
deno fmt supabase/functions/create-placeholder-member/index.ts
deno check supabase/functions/create-placeholder-member/index.ts
```

Expected: no errors.

- [ ] **Step 3: Manual smoke (defer until iOS UI in Phase 5)**

The function is invoked from iOS only. No standalone test in this task; coverage comes via `placeholder_member_creation.test.ts` (already exercises the underlying RPC) and Phase 5 manual smoke.

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/create-placeholder-member/index.ts
git commit -m "feat(edge): create-placeholder-member edge function"
```

---

### Task 15: Extend `send-whatsapp-invite` for `claim_token`

**Files:**
- Modify: `supabase/functions/send-whatsapp-invite/index.ts`

- [ ] **Step 1: Apply diff**

Modify `supabase/functions/send-whatsapp-invite/index.ts`. The current state is in lines 37-64. Replace lines 37-65 with:

```typescript
  let invite_id: string, phone: string, group_name: string, invite_code: string, message: string | undefined;
  let claim_token: string | undefined;
  try {
    const body = await req.json();
    invite_id = body.invite_id;
    phone = body.phone;
    group_name = body.group_name;
    invite_code = body.invite_code;
    message = body.message;
    claim_token = body.claim_token;  // optional — placeholder claim flow
    if (!invite_id || !phone || !group_name || !invite_code) {
      return jsonError(400, "invite_id, phone, group_name, invite_code required");
    }
  } catch {
    return jsonError(400, "invalid JSON body");
  }

  // Verify the caller can see this invite (RLS will reject if they're not
  // a member of the group, except when called with service role).
  const { data: invite, error: selErr } = await supabase
    .from("invites")
    .select("id, group_id, used_at")
    .eq("id", invite_id)
    .single();
  if (selErr || !invite) return jsonError(404, "invite not found or no access");

  const finalMessage =
    message ??
    (claim_token
      ? `Hola! Te agregaron al grupo *${group_name}* en ruul. Tu lugar ya está reservado. Activa tu cuenta: https://ruul.app/claim/${claim_token}`
      : `Te invito a ${group_name} en ruul. Aquí coordinamos todo: turnos, RSVP, reglas. Únete: https://ruul.app/invite/${invite_code}`);
```

- [ ] **Step 2: Verify**

```bash
deno check supabase/functions/send-whatsapp-invite/index.ts
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/send-whatsapp-invite/index.ts
git commit -m "feat(edge): send-whatsapp-invite accepts claim_token for placeholder flow"
```

---

## Phase 4 — iOS Core models + repos

### Task 16: Extend `Invite` and `Profile` models

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Invite.swift`
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Profile.swift` (if exists; otherwise locate the profile model)

- [ ] **Step 1: Locate Profile model**

Run: `find ios/Packages/RuulCore/Sources -name "Profile*.swift" | head -5`

If found at e.g. `Profile.swift`, modify it. If profile is part of `RuulCore.swift` or another file, modify there.

- [ ] **Step 2: Extend `Invite`**

Edit `ios/Packages/RuulCore/Sources/RuulCore/Invite.swift`. Replace the `Invite` struct (lines 3-34) with:

```swift
public struct Invite: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let invitedBy: UUID
    public let phoneE164: String?
    public let usedAt: Date?
    public let usedByUserId: UUID?
    public let expiresAt: Date
    public let createdAt: Date
    public let placeholderUserId: UUID?

    public init(id: UUID, groupId: UUID, invitedBy: UUID, phoneE164: String?, usedAt: Date?, usedByUserId: UUID?, expiresAt: Date, createdAt: Date, placeholderUserId: UUID? = nil) {
        self.id = id
        self.groupId = groupId
        self.invitedBy = invitedBy
        self.phoneE164 = phoneE164
        self.usedAt = usedAt
        self.usedByUserId = usedByUserId
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.placeholderUserId = placeholderUserId
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId           = "group_id"
        case invitedBy         = "invited_by"
        case phoneE164         = "phone_e164"
        case usedAt            = "used_at"
        case usedByUserId      = "used_by_user_id"
        case expiresAt         = "expires_at"
        case createdAt         = "created_at"
        case placeholderUserId = "placeholder_user_id"
    }
}
```

> **Note:** `claim_token_hash` is intentionally not exposed to the iOS model — the raw token only ever lives in the magic-link URL.

- [ ] **Step 3: Extend `Profile`**

In the located Profile model file, add two optional fields:

```swift
public let isPlaceholder: Bool
public let claimedAt: Date?
```

Update the `init`, the `CodingKeys` (`is_placeholder`, `claimed_at`), and any persistence/decoder helpers. Defaults: `isPlaceholder = false`, `claimedAt = nil`.

- [ ] **Step 4: Build**

```bash
cd ios && xcodebuild -workspace Tandas.xcworkspace -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
  build 2>&1 | tail -20
```

If xcodebuild not configured, use `swift build` in `ios/Packages/RuulCore`:

```bash
cd ios/Packages/RuulCore && swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Invite.swift \
        ios/Packages/RuulCore/Sources/RuulCore/Profile.swift  # adjust path if Profile lives elsewhere
git commit -m "feat(model): Invite.placeholderUserId + Profile.isPlaceholder/claimedAt"
```

---

### Task 17: `PlaceholderMemberRepository`

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/PlaceholderMemberRepository.swift`

- [ ] **Step 1: Write the repo**

Create `ios/Packages/RuulCore/Sources/RuulCore/Repositories/PlaceholderMemberRepository.swift`:

```swift
import Foundation
import OSLog
import Supabase

public enum PlaceholderMemberCreateResult: Sendable {
    case created(memberId: UUID, inviteId: UUID, placeholderUserId: UUID)
    case existingUser(userId: UUID, displayName: String?)
    case duplicatePlaceholder(userId: UUID)
    case failed(String)
}

public protocol PlaceholderMemberRepository: Actor {
    /// Calls the create-placeholder-member edge function. Returns one of three
    /// shapes representing the server's decision: created / existing real
    /// user (caller should offer add-existing) / duplicate unclaimed
    /// placeholder.
    func create(groupId: UUID, displayName: String, phoneE164: String) async throws -> PlaceholderMemberCreateResult
}

// MARK: - Live

public actor LivePlaceholderMemberRepository: PlaceholderMemberRepository {
    private let client: SupabaseClient
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "placeholderMembers")
    public init(client: SupabaseClient) { self.client = client }

    public func create(groupId: UUID, displayName: String, phoneE164: String) async throws -> PlaceholderMemberCreateResult {
        struct Body: Encodable {
            let group_id: String
            let display_name: String
            let phone_e164: String
        }
        struct Created: Decodable {
            let kind: String
            let member_id: String?
            let invite_id: String?
            let placeholder_user_id: String?
            let user_id: String?
            let display_name: String?
        }
        do {
            let response: Created = try await client.functions.invoke(
                "create-placeholder-member",
                options: FunctionInvokeOptions(body: Body(
                    group_id: groupId.uuidString.lowercased(),
                    display_name: displayName,
                    phone_e164: phoneE164
                ))
            )
            switch response.kind {
            case "created":
                guard let mid = response.member_id.flatMap(UUID.init(uuidString:)),
                      let iid = response.invite_id.flatMap(UUID.init(uuidString:)),
                      let pid = response.placeholder_user_id.flatMap(UUID.init(uuidString:)) else {
                    return .failed("malformed_created_response")
                }
                return .created(memberId: mid, inviteId: iid, placeholderUserId: pid)
            case "existing_user":
                guard let uid = response.user_id.flatMap(UUID.init(uuidString:)) else {
                    return .failed("malformed_existing_user_response")
                }
                return .existingUser(userId: uid, displayName: response.display_name)
            case "duplicate_placeholder":
                guard let uid = response.user_id.flatMap(UUID.init(uuidString:)) else {
                    return .failed("malformed_duplicate_response")
                }
                return .duplicatePlaceholder(userId: uid)
            default:
                return .failed("unknown_kind_\(response.kind)")
            }
        } catch {
            log.error("create-placeholder-member failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Mock

public actor MockPlaceholderMemberRepository: PlaceholderMemberRepository {
    public var nextResult: PlaceholderMemberCreateResult?
    public init(nextResult: PlaceholderMemberCreateResult? = nil) {
        self.nextResult = nextResult
    }
    public func create(groupId: UUID, displayName: String, phoneE164: String) async throws -> PlaceholderMemberCreateResult {
        if let r = nextResult { return r }
        return .created(memberId: UUID(), inviteId: UUID(), placeholderUserId: UUID())
    }
}
```

- [ ] **Step 2: Build**

```bash
cd ios/Packages/RuulCore && swift build 2>&1 | tail -10
```

Expected: success.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Repositories/PlaceholderMemberRepository.swift
git commit -m "feat(repo): PlaceholderMemberRepository + Mock"
```

---

### Task 18: `ClaimRepository`

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/ClaimRepository.swift`

- [ ] **Step 1: Write the repo**

Create `ios/Packages/RuulCore/Sources/RuulCore/Repositories/ClaimRepository.swift`:

```swift
import Foundation
import OSLog
import Supabase

public struct PendingPlaceholderClaim: Identifiable, Codable, Sendable, Hashable {
    public let placeholderUid: UUID
    public let groupId: UUID
    public let groupName: String
    public let displayName: String
    public let inviteId: UUID
    public var id: UUID { placeholderUid }

    public enum CodingKeys: String, CodingKey {
        case placeholderUid = "placeholder_uid"
        case groupId        = "group_id"
        case groupName      = "group_name"
        case displayName    = "display_name"
        case inviteId       = "invite_id"
    }
}

public struct PlaceholderHistorySummary: Codable, Sendable, Hashable {
    public let groupId: UUID
    public let memberId: UUID?
    public let fineCount: Int
    public let voteCount: Int
    public let eventCount: Int

    public enum CodingKeys: String, CodingKey {
        case groupId    = "group_id"
        case memberId   = "member_id"
        case fineCount  = "fine_count"
        case voteCount  = "vote_count"
        case eventCount = "event_count"
    }
}

public struct ClaimAcceptResult: Codable, Sendable, Hashable {
    public let canonicalUserId: UUID
    public let groupId: UUID
    public let memberId: UUID?

    public enum CodingKeys: String, CodingKey {
        case canonicalUserId = "canonical_user_id"
        case groupId         = "group_id"
        case memberId        = "member_id"
    }
}

public protocol ClaimRepository: Actor {
    /// Post-login Camino B: find placeholders whose phone matches mine.
    func discoverPending() async throws -> [PendingPlaceholderClaim]

    /// Pre-decision summary for ClaimReviewView.
    func summary(placeholderUid: UUID) async throws -> PlaceholderHistorySummary

    /// Accept via magic-link token (Camino A).
    func acceptByToken(_ token: String) async throws -> ClaimAcceptResult

    /// Accept via phone match (Camino B) — placeholder uid discovered post-login.
    func acceptByUid(_ placeholderUid: UUID) async throws -> ClaimAcceptResult

    /// Reject the merge; the placeholder is stamped disputed and admin is notified.
    func decline(token: String) async throws
}

// MARK: - Live

public actor LiveClaimRepository: ClaimRepository {
    private let client: SupabaseClient
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "claims")
    public init(client: SupabaseClient) { self.client = client }

    public func discoverPending() async throws -> [PendingPlaceholderClaim] {
        try await client.rpc("discover_pending_placeholders").execute().value
    }

    public func summary(placeholderUid: UUID) async throws -> PlaceholderHistorySummary {
        struct Params: Encodable { let p_placeholder_uid: String }
        return try await client.rpc("get_placeholder_history_summary", params: Params(
            p_placeholder_uid: placeholderUid.uuidString.lowercased()
        )).execute().value
    }

    public func acceptByToken(_ token: String) async throws -> ClaimAcceptResult {
        struct Params: Encodable { let p_claim_token: String }
        return try await client.rpc("accept_placeholder_claim", params: Params(
            p_claim_token: token
        )).execute().value
    }

    public func acceptByUid(_ placeholderUid: UUID) async throws -> ClaimAcceptResult {
        struct Params: Encodable { let p_placeholder_uid: String }
        return try await client.rpc("accept_placeholder_claim", params: Params(
            p_placeholder_uid: placeholderUid.uuidString.lowercased()
        )).execute().value
    }

    public func decline(token: String) async throws {
        struct Params: Encodable { let p_claim_token: String }
        _ = try await client.rpc("decline_placeholder_claim", params: Params(
            p_claim_token: token
        )).execute()
    }
}

// MARK: - Mock

public actor MockClaimRepository: ClaimRepository {
    public var pending: [PendingPlaceholderClaim] = []
    public var nextSummary: PlaceholderHistorySummary?
    public var nextAccept: ClaimAcceptResult?
    public var declineCalls: [String] = []
    public init() {}

    public func discoverPending() async throws -> [PendingPlaceholderClaim] { pending }
    public func summary(placeholderUid: UUID) async throws -> PlaceholderHistorySummary {
        nextSummary ?? PlaceholderHistorySummary(groupId: UUID(), memberId: nil, fineCount: 0, voteCount: 0, eventCount: 0)
    }
    public func acceptByToken(_ token: String) async throws -> ClaimAcceptResult {
        nextAccept ?? ClaimAcceptResult(canonicalUserId: UUID(), groupId: UUID(), memberId: nil)
    }
    public func acceptByUid(_ uid: UUID) async throws -> ClaimAcceptResult {
        nextAccept ?? ClaimAcceptResult(canonicalUserId: UUID(), groupId: UUID(), memberId: nil)
    }
    public func decline(token: String) async throws { declineCalls.append(token) }
}
```

- [ ] **Step 2: Build**

```bash
cd ios/Packages/RuulCore && swift build 2>&1 | tail -10
```

Expected: success.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Repositories/ClaimRepository.swift
git commit -m "feat(repo): ClaimRepository + Mock for placeholder claim flow"
```

---

## Phase 5 — iOS UI minimum viable

### Task 19: `AddPlaceholderSheet` UI

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/AddPlaceholderSheet.swift`
- Locate: existing AppState wiring to add `placeholderMemberRepo` and `claimRepo`. Run `grep -rn "inviteRepo:" ios/Packages/RuulFeatures/Sources/RuulFeatures/AppState/ 2>/dev/null | head -5` to find the file.

- [ ] **Step 1: Wire repos into AppState**

Find the AppState (or equivalent DI container) where `inviteRepo` is constructed. Add fields for `placeholderMemberRepo: any PlaceholderMemberRepository` and `claimRepo: any ClaimRepository`. Initialize with `LivePlaceholderMemberRepository(client: ...)` and `LiveClaimRepository(client: ...)` in the live wiring and corresponding Mocks for preview/test.

- [ ] **Step 2: Write the sheet**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/AddPlaceholderSheet.swift`:

```swift
import SwiftUI
import RuulCore

@MainActor
public struct AddPlaceholderSheet: View {
    public let groupId: UUID
    public let onCreated: (UUID) -> Void  // member_id

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    @State private var displayName = ""
    @State private var phone = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var existingUser: (UUID, String?)?
    @State private var duplicatePlaceholder: UUID?

    public init(groupId: UUID, onCreated: @escaping (UUID) -> Void) {
        self.groupId = groupId
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Nuevo miembro") {
                    TextField("Nombre", text: $displayName)
                        .textContentType(.name)
                    TextField("Teléfono (+52...)", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                }
                if let existingUser {
                    Section {
                        Text("Este número ya pertenece a un usuario de Ruul"
                             + (existingUser.1.map { " (\($0))" } ?? "")
                             + ". Agrégalo directamente desde 'Invitar miembros'.")
                            .foregroundStyle(.secondary)
                    }
                }
                if duplicatePlaceholder != nil {
                    Section {
                        Text("Ya hay un miembro pendiente con ese número en algún grupo.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Agregar miembro")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isWorking { ProgressView() } else { Text("Agregar") }
                    }
                    .disabled(!canSubmit || isWorking)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        && phone.starts(with: "+")
        && phone.dropFirst().allSatisfy(\.isWholeNumber)
        && phone.count >= 9
    }

    private func submit() {
        isWorking = true
        existingUser = nil
        duplicatePlaceholder = nil
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let result = try await app.placeholderMemberRepo.create(
                    groupId: groupId,
                    displayName: displayName.trimmingCharacters(in: .whitespaces),
                    phoneE164: phone
                )
                switch result {
                case .created(let memberId, _, _):
                    onCreated(memberId)
                    dismiss()
                case .existingUser(let uid, let name):
                    existingUser = (uid, name)
                case .duplicatePlaceholder(let uid):
                    duplicatePlaceholder = uid
                case .failed(let msg):
                    errorMessage = msg
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 3: Wire entry point**

Find the existing "Agregar miembro" entry in members UI (likely `InviteMembersFromGroupView.swift` line ~132 or a Group settings screen). Add a sibling button or sheet trigger that presents `AddPlaceholderSheet(groupId: group.id) { _ in await reload() }`.

- [ ] **Step 4: Build**

```bash
cd ios && xcodebuild -workspace Tandas.xcworkspace -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
  build 2>&1 | tail -20
```

Expected: success.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/AddPlaceholderSheet.swift
# also commit the AppState wiring file if you modified one
git commit -m "feat(ios): AddPlaceholderSheet + AppState wiring for placeholder repo"
```

---

### Task 20: Member list badge

**Files:**
- Locate: member list view via `grep -rn "group_members\|MembersList\|MemberRow" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/ | head -10`
- Modify: the located file(s)

- [ ] **Step 1: Find member row view**

```bash
grep -rln "joined_via\|MemberRow\|memberCell" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/ | head -5
```

- [ ] **Step 2: Locate the type used to render each member row**

Identify the field that carries `joined_via` (likely on a `GroupMember` or `MemberView` model). If `joined_via` isn't already projected, add it to the Codable model and SQL select string.

- [ ] **Step 3: Render badge when `joinedVia == "placeholder"`**

In the row view, append a chip / badge:

```swift
if member.joinedVia == "placeholder" {
    Text("Pendiente")
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.yellow.opacity(0.25), in: Capsule())
        .foregroundStyle(.secondary)
}
```

Adjust to match the design-system primitives in `RuulUI` (look for `Badge`, `Chip`, `Tag` style in `ios/Packages/RuulUI/Sources/RuulUI/`).

- [ ] **Step 4: Build**

```bash
cd ios && swift build 2>&1 | tail -10
```

Expected: success.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/
git commit -m "feat(ios): badge 'Pendiente' for placeholder members in member list"
```

---

### Task 21: `PendingClaimsView` post-login

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Claims/PendingClaimsView.swift`
- Modify: post-login bootstrap (locate via `grep -rn "AuthService\|onAuthChange\|sessionLoaded" ios/Packages/RuulFeatures/Sources/RuulFeatures/AppState/`).

- [ ] **Step 1: Write the view**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Claims/PendingClaimsView.swift`:

```swift
import SwiftUI
import RuulCore

@MainActor
public struct PendingClaimsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    @State private var pending: [PendingPlaceholderClaim] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var workingUid: UUID?

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if pending.isEmpty {
                    ContentUnavailableView("Nada pendiente", systemImage: "checkmark.circle")
                } else {
                    List(pending) { claim in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(claim.groupName).font(.headline)
                            Text("Te agregaron como \(claim.displayName)")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Aceptar") { accept(claim) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(workingUid == claim.placeholderUid)
                                Spacer()
                                Button("Revisar primero") {
                                    // Push ClaimReviewView for this claim — see Task 22
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Invitaciones pendientes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            pending = try await app.claimRepo.discoverPending()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func accept(_ claim: PendingPlaceholderClaim) {
        workingUid = claim.placeholderUid
        Task {
            defer { workingUid = nil }
            do {
                _ = try await app.claimRepo.acceptByUid(claim.placeholderUid)
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 2: Trigger from post-login bootstrap**

In the AppState's `refreshSession()` (or equivalent), after the session is established, call:

```swift
let pending = (try? await claimRepo.discoverPending()) ?? []
if !pending.isEmpty {
    self.pendingClaimsCount = pending.count
    // surface a banner / sheet — wire into your existing onboarding overlay
}
```

Surface `PendingClaimsView()` as a sheet when `pendingClaimsCount > 0` from the main shell.

- [ ] **Step 3: Build**

```bash
cd ios && swift build 2>&1 | tail -10
```

Expected: success.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Claims/PendingClaimsView.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/AppState/  # the file you modified
git commit -m "feat(ios): PendingClaimsView + post-login bootstrap discover"
```

---

### Task 22: `ClaimReviewView` (deep-link landing)

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Claims/ClaimReviewView.swift`

- [ ] **Step 1: Write the view**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Claims/ClaimReviewView.swift`:

```swift
import SwiftUI
import RuulCore

@MainActor
public struct ClaimReviewView: View {
    public let token: String
    public let placeholderUid: UUID?  // nil when arriving via magic link (summary will resolve after accept)

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    @State private var summary: PlaceholderHistorySummary?
    @State private var isWorking = false
    @State private var errorMessage: String?

    public init(token: String, placeholderUid: UUID? = nil) {
        self.token = token
        self.placeholderUid = placeholderUid
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Te agregaron a un grupo en Ruul").font(.title2.bold())

                if let summary {
                    GroupBox("Tu historial pendiente") {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("\(summary.fineCount) fines", systemImage: "exclamationmark.circle")
                            Label("\(summary.voteCount) votos emitidos", systemImage: "checkmark.seal")
                            Label("\(summary.eventCount) eventos registrados", systemImage: "calendar")
                        }
                    }
                } else if errorMessage == nil {
                    ProgressView()
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button("No soy yo", role: .destructive) { reject() }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
                    Button("Aceptar y entrar") { accept() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                }
            }
            .padding()
            .navigationTitle("Reclamar lugar")
            .task { await loadSummary() }
        }
    }

    private func loadSummary() async {
        guard let uid = placeholderUid else { return }
        do {
            summary = try await app.claimRepo.summary(placeholderUid: uid)
        } catch {
            errorMessage = "No pudimos cargar el resumen: \(error.localizedDescription)"
        }
    }

    private func accept() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await app.claimRepo.acceptByToken(token)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reject() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await app.claimRepo.decline(token: token)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd ios && swift build 2>&1 | tail -10
```

Expected: success.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Claims/ClaimReviewView.swift
git commit -m "feat(ios): ClaimReviewView for magic-link landing"
```

---

### Task 23: Deep-link routing `/claim/<token>`

**Files:**
- Modify: `ios/Tandas/Shell/DeepLinkRouter.swift` (or wherever universal-link routing lives — locate via `grep -rn "ruul.app\|onOpenURL\|universalLink" ios/Tandas/ | head -10`)

- [ ] **Step 1: Locate the router**

```bash
grep -rln "onOpenURL\|continueUserActivity\|UniversalLink" ios/Tandas/ ios/Packages/ 2>/dev/null | head -5
```

- [ ] **Step 2: Add `/claim/<token>` handler**

In the router file, add a case for `/claim/<token>`:

```swift
// After existing /invite/<code> case:
if url.path.hasPrefix("/claim/") {
    let token = String(url.path.dropFirst("/claim/".count))
    guard !token.isEmpty else { return }
    if app.isAuthenticated {
        presentSheet(.claimReview(token: token, placeholderUid: nil))
    } else {
        pendingPostLogin = .claimReview(token: token)
        presentAuthPicker()
    }
}
```

Implement `pendingPostLogin` handling so the sheet presents after auth completes. If your router uses a different navigation pattern (e.g., `NavigationPath` + deep-link state), adapt accordingly.

- [ ] **Step 3: Verify Apple Universal Links plist**

Run: `grep -l "applinks:ruul" ios/Tandas/ 2>/dev/null`

If apple-app-site-association is not yet served from `ruul.app/.well-known/`, the deep link will fall back to a Safari open. Document this as a follow-up if not present; tests can use `xcrun simctl openurl` with `ruul://claim/<token>` if the app declares a custom URL scheme.

- [ ] **Step 4: Build**

```bash
cd ios && xcodebuild -workspace Tandas.xcworkspace -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
  build 2>&1 | tail -20
```

Expected: success.

- [ ] **Step 5: Commit**

```bash
git add ios/Tandas/Shell/   # adjust path
git commit -m "feat(ios): deep-link route /claim/<token> → ClaimReviewView"
```

---

## Phase 6 — Smoke & wrap

### Task 24: End-to-end smoke

**Files:** none modified

- [ ] **Step 1: Run full DB suite**

```bash
cd supabase/functions && deno test --allow-all _tests/db/ 2>&1 | tail -30
```

Expected: all green.

- [ ] **Step 2: Apply migrations to staging Supabase**

If `SUPABASE_DB_URL` for staging is configured:

```bash
supabase db push --linked --include-roles
```

Otherwise apply via MCP one-by-one (00300 → 00309).

- [ ] **Step 3: Simulator smoke flow**

Boot iOS app in simulator. Two-account scenario:

1. **Admin device** (account A, logged in as group admin):
   - Open a group → tap "Agregar miembro" (placeholder).
   - Enter "Juan Test" + your second phone number.
   - Verify: appears in member list with "Pendiente" badge.
   - Verify: WhatsApp message arrives (if Wassenger configured) with `/claim/...` link.
2. **Real device** (account B, fresh):
   - Sign up by phone OTP with the same number, OR by Apple.
   - Tap the magic link from WhatsApp (or, post-login, see `PendingClaimsView`).
   - Tap "Aceptar y entrar".
   - Verify: now a member of the group; placeholder badge gone; previous turn_order preserved.

- [ ] **Step 4: Verify atoms emitted**

In Supabase dashboard or psql:

```sql
select event_type, count(*) from public.system_events
where event_type like 'member.%'
group by 1;
```

Expected: at least one `member.placeholder_created` and one `member.claimed`.

- [ ] **Step 5: Final commit & PR**

```bash
git status   # verify all expected files
git log --oneline -20
git push -u origin <your-branch-name>
gh pr create --title "feat: placeholder members (admin-added pending users)" \
  --body "$(cat <<'EOF'
## Summary
- Admins can add a member with (name, phone) that already counts for rotation/RSVP/fines/votes before they register.
- Real person signs up by ANY provider (phone OTP, Apple, Google, email) → magic link or phone-match auto-detect → merge into canonical identity.
- Append-only respected: atoms untouched; `identity_resolver` view resolves user-id-based atoms; membership-based atoms inherit auto via `group_members.user_id` reassignment.
- Privacy: real can decline the merge; placeholder is stamped disputed.

Spec: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md
Plan: Docs/superpowers/plans/2026-05-17-placeholder-members.md

## Migrations
- 00300 profiles.is_placeholder/claimed_at/disputed_*
- 00301 invites.placeholder_user_id/claim_token_hash
- 00302 group_members.joined_via 'placeholder'
- 00303 identity_resolver view
- 00304 system_event whitelist (3 new types)
- 00305 finalize_placeholder_member RPC
- 00306 merge_placeholder_into_user + _merge_group_members
- 00307 accept/decline_placeholder_claim RPCs
- 00308 discover_pending_placeholders + get_placeholder_history_summary
- 00309 profiles RLS (admin-only visibility for unclaimed placeholders)

## Edge functions
- create-placeholder-member (new)
- send-whatsapp-invite (claim_token param)

## iOS
- AddPlaceholderSheet, MembersList badge, PendingClaimsView, ClaimReviewView, /claim/<token> universal link routing.

## Test plan
- [x] All DB tests in supabase/functions/_tests/db/placeholder_*.test.ts pass
- [x] identity_resolver.test.ts passes (3 cases)
- [x] placeholder_invariants.test.ts post-merge orphan check passes
- [ ] iOS simulator smoke: admin adds placeholder, second account claims via phone OTP — turn_order preserved, badge gone
- [ ] iOS simulator smoke: claim via Apple Sign-In (no phone) using magic link → ClaimReviewView accept
- [ ] iOS simulator smoke: decline path → admin gets notification, placeholder shows disputed

## Freeze impact
This feature was authorized by the founder via explicit "implementa" after reviewing the spec, which flagged blocked-by-freeze. Treated as an exemption to the Consistency Audit freeze 2026-05-17. If revoked, revert via the per-migration rollback files under supabase/migrations/_rollbacks/.

🤖 Generated with [claude-flow](https://github.com/ruvnet/claude-flow)
EOF
)"
```

---

## Self-review checklist (done by plan author)

- **Spec coverage:**
  - §5 doctrinal classification ✅ (per migration: M1=Task 1, M2=Task 2, M3=Task 3, M4=Task 4, M5=Tasks 7-12, M6=Task 5, M7=Task 13)
  - §8 identity model ✅ (Task 4 + 7 + 9)
  - §9 creation flow ✅ (Task 14 + 7)
  - §10 magic link ✅ (Task 15)
  - §11 claim flows A + B ✅ (Tasks 10, 12, 22, 23)
  - §12 merge engine ✅ (Tasks 8 + 9)
  - §13 UX ✅ (Tasks 19, 20, 21, 22, 23)
  - §14 decline ✅ (Task 11)
  - §15 data model migrations ✅ (Tasks 1-5, 13)
  - §16 invariants ✅ (Task 13)
  - §17 risks: R1/R2 mitigated by §14 decline + atom emit; R3 by xact_lock in Task 10; R5 by Task 13 invariant; R6 doc-only — not blocking
  - §18 rollout: this plan covers Phase 1 (DB + edge) + Phase 3 minimal (iOS). Phase 4 (P0 projection migrations using identity_resolver) is **explicitly out of scope** for this PR and tracked separately — projections continue to work because membership reassignment preserves member-id chains; only deep audit queries via vote_casts.user_id need the resolver, which is non-Beta-blocking.
- **Placeholder scan:** Tasks 5 and 11 contain "executor must verify" markers — these are explicit because they require reading current code state, not "TBD". OK.
- **Type consistency:** `placeholder_uid` / `placeholder_user_id` used consistently. `member_id` is `group_members.id`, `user_id` is `auth.users.id` — distinction maintained throughout.

---

_End of plan._
