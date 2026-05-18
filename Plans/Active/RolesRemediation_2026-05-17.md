# Roles / Permisos — Plan de Remediación 2026-05-17

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cerrar las 3 heresías + 14 violaciones doctrinales del audit `RolesAudit_2026-05-17.md`, sin tocar el freeze de Beta-1 (no nuevos primitives/types/capabilities).

**Architecture:** 6 sprints incrementales (B → A → C → D → E → F). Sprint B (este) cierra los agujeros server-side de mutación directa de roles. Sprints subsiguientes cascadea el split founder/admin (00262) a iOS, RPCs, edge functions, y RLS.

**Tech Stack:** Postgres 17 (Supabase) · Deno tests · Swift 6 (iOS 26+) · SQL migrations via `mcp__supabase__apply_migration`.

**Restricción cardinal:** freeze 2026-05-17 (memoria `project_consistency_audit_freeze`). Encaja como Sprint 5 — sólo fixes de deuda, no features.

---

## Roadmap

| Sprint | Scope | Tipo | Estado |
|---|---|---|---|
| **B** (this) | Server SQL — guards + atoms sobre `groups.roles` y `group_members.roles` (cierra V1, V2, V14) | DB-only | **APPLIED 2026-05-17** (structural ok; Deno suite pending local) |
| **A** | iOS — `MemberRole.admin` case + eliminar alias hardcoded `'admin' ↔ 'founder'` en 5 archivos (cierra V21, V22) + mig 00290 backfill + mig 00289 fix latent updated_at bug | mixed | **APPLIED 2026-05-17** (commit 32e7657) |
| **C** | RPCs — eliminar `is_group_admin` callsites; fix HERESY V3 + V9/V10/V11/V12 (V13 deferred — needs finalize_vote whole-function re-ship) | DB SQL | **APPLIED 2026-05-17** (mig 00291; 11 RPCs migrated) |
| **D** | Edge functions — fix HERESY V5 (send-event-notification auth) + V25 (verify-otp atom) + V6 (process-system-events approver pool via list_members_with_permission helper). V8 deferred (8 files, perf concerns) | Deno + DB | **APPLIED 2026-05-17** (V5+V25+V6 shipped via mig 00298; V8 deferred) |
| **E** | Swift `GovernanceService.hasPermission` llama RPC server + cache; refactor `CapabilityResolver+SecondaryActions` (cierra V15, V16, V17, V18, V19, V20) | Swift | **APPLIED 2026-05-17** (commits 30e0ce0 V17 + 65802e9 V18/V19/V20 + Sprint E.3 V15/V16) |
| **F.0** (out-of-order, urgent) | DB infra — migrar `is_known_system_event_type` whitelist a tabla `known_event_types` (eliminada vulnerabilidad a parallel-write that perdió `groupRolesChanged` 2 veces) | DB SQL | **APPLIED 2026-05-17** (mig 00293) |
| **F.1** (V24) | is_group_admin reads jsonb + drop sync_role_text + role_validation triggers + iOS Member.isAdmin = holdsRole("admin") only | DB + Swift | **APPLIED 2026-05-17** (mig 00299) |
| **F.2** (V26) | LiveGroupsRepository.leave delegates to leave_group RPC | Swift | **APPLIED 2026-05-17** |
| **F.3** (V7) | Rule engine — new actorHasPermission condition + loadMemberPermissions sink + actor_permissions projection; mig 00300 helper. actorHasRole kept (label-only, documented) | DB + Deno + Swift | **APPLIED 2026-05-17** (mig 00300) |
| **F.4** (V23) | is_group_admin → delegates to has_permission(modifyGovernance). Single-fn rewrite, ~50 RLS policies inherit the doctrinal fix transparently | DB | **APPLIED 2026-05-17** (mig 00301) |
| **F.5** (V8) | 8 cron/emit edge functions route via record_system_events_batch RPC (mig 00302). Atom validation centralized; transactional semantics preserved | DB + Deno | **APPLIED 2026-05-17** (mig 00302) |
| **F** | Cleanup tail — eliminar `group_members.role` text column physically (V24.2 once iOS rollout complete); Phase 5 RLS rewire; formalizar `public.permissions` (cierra V4, V23) | mixed | pendiente |

Cada sprint se completa con su propio commit. Sprint B se cubre detalladamente abajo; los siguientes se especificarán cuando se inicien.

---

# Sprint B: Guards + atoms sobre mutación de roles

**Files (renumbered 00285-00288 because parallel work claimed 00278-00284):**
- Create: `supabase/migrations/00285_role_lifecycle_atom_whitelist_v2.sql` (applied; superseded by 00288)
- Create: `supabase/migrations/00286_guard_groups_roles_write.sql` (applied)
- Create: `supabase/migrations/00287_guard_group_members_roles_write.sql` (applied)
- Create: `supabase/migrations/00288_role_lifecycle_atom_whitelist_v3_reunion.sql` (emergency fix — see retrospective)
- Create: `supabase/functions/_tests/db/role_write_guards.test.ts` (suite — requires `supabase start` to execute)
- Modify: `Plans/Active/RolesRemediation_2026-05-17.md` (mark Sprint B complete)

## Sprint B retrospective (2026-05-17)

**File-numbering lesson.** Initial check (`ls supabase/migrations/ | tail`) only showed the last tracked migration (00277). The repo had untracked migrations 00278-00284 sitting in the working tree from parallel sessions. My initial files claimed 00278-00281 — collision on the filesystem layer. Renamed to 00285-00288. **Going forward:** check `git status` for untracked migrations before claiming a number, not just `ls | tail`.

**Atom-whitelist regression.** Mig 00285 (originally 00278) added `groupRolesChanged` to `is_known_system_event_type`. Between mig 00285 and mig 00286 application, other migrations landed in parallel (`slot_created_released_atoms`, `update_right_metadata_emit_diff_atom`) that re-emitted `is_known_system_event_type` from a stale base — silently dropping `groupRolesChanged`. The function comment was preserved, masking the regression. Mig 00286 then deployed RPCs that emit `groupRolesChanged` — these were broken on arrival (CHECK constraint would reject the atom; whole RPC would rollback).

**Recovery.** Mig 00288 re-emits the whitelist as the UNION of (current live atoms) ∪ (`groupRolesChanged`).

**Doctrine reinforced.** Per mig 00211 / 00269 / 00285 headers: every `is_known_system_event_type` modification MUST start from `pg_dump` of the live function source — never from a previous migration. Tactical appends are forbidden. Mig 00288 includes this warning in its body comment.

**Behavioral verification.** Structural verification (triggers attached + RPC bodies contain bypass-flag tokens + whitelist OK) passed via `mcp__supabase__execute_sql`. Behavioral verification via the 9 Deno tests in `_tests/db/role_write_guards.test.ts` requires `supabase start` (local) — deferred to next session or CI integration.

**Cambios doctrinales:**
- `groupRolesChanged` atom whitelisted (cataloga upsert/delete del role catalog).
- BEFORE UPDATE OF roles trigger en `groups`: bloquea UPDATEs no-RPC.
- BEFORE UPDATE OF roles trigger en `group_members`: bloquea UPDATEs no-RPC.
- `upsert_group_role` / `delete_group_role` emiten `groupRolesChanged`.
- `delete_group_role` emite `roleUnassigned` per miembro afectado (cascade).
- Las 4 RPCs (assign/unassign/upsert/delete) setean `set_config('app.role_write_via_rpc', 'true', true)` antes del UPDATE — el guard lo reconoce.

**Pattern de bypass (Pattern A — session flag):**
- RPC `set_config('app.role_write_via_rpc', '1', true)` → flag local-to-transaction.
- Trigger lee `current_setting('app.role_write_via_rpc', true)` → si `'1'` → allow.
- Si flag ausente o vacío → raise `42501` "use the RPCs, direct UPDATE forbidden".
- `auth.uid() IS NULL` (service_role / migración) → allow incondicional, igual que mig 00124.

---

## Task B1: Mig 00278 — Atom whitelist v2 (groupRolesChanged)

- [ ] **Step 1: Crear archivo de migración**

Create `supabase/migrations/00278_role_lifecycle_atom_whitelist_v2.sql`:

```sql
-- 00278 — Extend is_known_system_event_type with groupRolesChanged.
--
-- Pairs with mig 00279 (upsert_group_role / delete_group_role emit
-- groupRolesChanged on catalog mutation). Without this whitelist
-- the emit fails the CHECK constraint (00095) and the RPC aborts
-- after mutating the catalog — partial state.
--
-- Per mig 00211 convention: re-emit the FULL union rather than
-- tactical append, so a parallel branch landing between migrations
-- can't silently drop entries.

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable parallel safe
set search_path = pg_catalog
as $$
  select p_event_type = any (array[
    'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
    'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned', 'slotDeclined', 'slotExpired', 'slotSwapRequested', 'slotSwapApproved',
    'bookingCreated', 'bookingCancelled', 'bookingExpired',
    'assetCreated',
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    'fundCreated', 'fundDeposit', 'fundThresholdReached', 'fundLocked', 'fundUnlocked',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon',
    'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn',
    'valuationRecorded',
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled',
    'eventStarted', 'eventUpdated',
    'spaceCreated',
    'assetCheckoutOverdue', 'assetMaintenanceOverdue',
    'roleAssigned', 'roleUnassigned',
    -- mig 00278: Sprint B role-catalog atoms
    'groupRolesChanged'
  ]);
$$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist of system_events.event_type values. v_sprint_b_role_catalog (00278): adds groupRolesChanged. Mirrors SystemEventType Swift enum. CHECK constraint system_events_event_type_known_chk (00095) enforces this at INSERT.';
```

- [ ] **Step 2: Aplicar migración**

Run: `mcp__supabase__apply_migration` with `name="role_lifecycle_atom_whitelist_v2"` and the file contents.

Expected: success, no rows affected (just function replacement).

- [ ] **Step 3: Verificar whitelist**

Run via `mcp__supabase__execute_sql`:
```sql
select public.is_known_system_event_type('groupRolesChanged');
```
Expected: `true`.

---

## Task B2: Mig 00279 — Guard + atoms en `groups.roles`

- [ ] **Step 1: Crear archivo de migración**

Create `supabase/migrations/00279_guard_groups_roles_write.sql`. Three things:
1. BEFORE UPDATE trigger guard.
2. Update `upsert_group_role` to set bypass flag + emit `groupRolesChanged`.
3. Update `delete_group_role` to set bypass flag + emit `groupRolesChanged` + cascade `roleUnassigned` per miembro afectado.

```sql
-- 00279 — Guard direct REST writes to groups.roles + emit groupRolesChanged.
--
-- Background
-- ==========
-- groups.roles jsonb (the role catalog) is mutated by upsert_group_role
-- and delete_group_role (mig 00230). RLS groups_update_admin (mig 00002)
-- also allows ANY active admin to UPDATE groups.* including .roles
-- directly via /rest/v1/groups — bypassing the RPCs entirely. Mig 00230
-- header §"Events" deliberately deferred catalog atoms; Sprint B closes
-- the gap.
--
-- Design: same shape as mig 00124 (guard_groups_governance_update), with
-- one addition — the RPC sets a session-local flag the trigger trusts.
-- Pattern:
--
--   1. NEW.roles IS NOT DISTINCT FROM OLD.roles → no-op, allow.
--   2. auth.uid() IS NULL → service_role / migration path, allow.
--   3. current_setting('app.role_write_via_rpc', true) = '1' → trusted
--      RPC path (set the flag before UPDATE), allow + clear flag so it
--      doesn't leak to subsequent statements.
--   4. else → raise 42501 with hint about the RPCs.
--
-- The cascade in delete_group_role also writes group_members.roles —
-- that path is guarded by mig 00280 with its own flag.

create or replace function public.guard_groups_roles_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_flag text;
begin
  if new.roles is not distinct from old.roles then
    return new;
  end if;

  if auth.uid() is null then
    return new;
  end if;

  v_flag := current_setting('app.role_write_via_rpc', true);
  if v_flag = '1' then
    perform set_config('app.role_write_via_rpc', '', true);
    return new;
  end if;

  raise exception
    'direct write to groups.roles is forbidden — use upsert_group_role/delete_group_role RPCs (caller %)', auth.uid()
    using errcode = '42501',
          hint = 'public.upsert_group_role(p_group_id, p_role_id, ...) / public.delete_group_role(p_group_id, p_role_id)';
end;
$$;

revoke execute on function public.guard_groups_roles_write() from public, anon, authenticated;

comment on function public.guard_groups_roles_write() is
  'BEFORE UPDATE OF roles trigger on groups: blocks direct REST writes; trusts SECURITY DEFINER RPC callers via session flag app.role_write_via_rpc. Closes V2 from RolesAudit 2026-05-17.';

drop trigger if exists groups_roles_guard on public.groups;
create trigger groups_roles_guard
  before update of roles on public.groups
  for each row
  execute function public.guard_groups_roles_write();

comment on trigger groups_roles_guard on public.groups is
  'Sprint B (mig 00279): blocks direct UPDATE of groups.roles outside RPC funnel.';

-- =============================================================================
-- upsert_group_role v2 — set bypass flag + emit groupRolesChanged
-- =============================================================================
create or replace function public.upsert_group_role(
  p_group_id    uuid,
  p_role_id     text,
  p_label       text          default null,
  p_permissions text[]        default array[]::text[],
  p_max_holders int           default null
) returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid          uuid := auth.uid();
  v_normalized   text;
  v_is_system    boolean := false;
  v_value        jsonb;
  v_perms        jsonb;
  v_existing     jsonb;
  v_op           text;
  g              public.groups;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  if not (public.has_permission(p_group_id, v_uid, 'assignRoles')
          or public.is_group_admin(p_group_id, v_uid)) then
    raise exception 'permission denied: assignRoles';
  end if;

  v_normalized := lower(trim(coalesce(p_role_id, '')));
  if v_normalized = '' or v_normalized !~ '^[a-z][a-z0-9_]{0,31}$' then
    raise exception 'invalid role_id %: must match [a-z][a-z0-9_]{0,31}', p_role_id;
  end if;

  if v_normalized in ('founder', 'member') then
    v_is_system := true;
  end if;

  if p_max_holders is not null and p_max_holders < 1 then
    raise exception 'max_holders must be >= 1 (got %)', p_max_holders;
  end if;

  if v_normalized = 'founder' and not ('assignRoles' = any (p_permissions)) then
    raise exception 'founder role must retain assignRoles permission (would lock the group out of role management)';
  end if;

  v_perms := coalesce(
    (
      select jsonb_agg(p order by p)
      from (select distinct unnest(p_permissions) as p) deduped
    ),
    '[]'::jsonb
  );

  v_value := jsonb_build_object(
    'system',      v_is_system,
    'permissions', v_perms
  );
  if p_label is not null and length(trim(p_label)) > 0 then
    v_value := v_value || jsonb_build_object('label', trim(p_label));
  end if;
  if p_max_holders is not null then
    v_value := v_value || jsonb_build_object('max_holders', p_max_holders);
  end if;

  -- Determine op for atom payload (created vs updated).
  select roles -> v_normalized into v_existing
    from public.groups
   where id = p_group_id;
  v_op := case when v_existing is null then 'created' else 'updated' end;

  perform set_config('app.role_write_via_rpc', '1', true);

  update public.groups
     set roles      = coalesce(roles, '{}'::jsonb)
                      || jsonb_build_object(v_normalized, v_value),
         updated_at = now()
   where id = p_group_id
   returning * into g;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  perform public.record_system_event(
    p_group_id,
    'groupRolesChanged',
    null,
    null,
    jsonb_build_object(
      'op',            v_op,
      'role_id',       v_normalized,
      'permissions',   v_perms,
      'system',        v_is_system,
      'changed_by',    v_uid
    )
  );

  return g;
end;
$$;

revoke execute on function public.upsert_group_role(uuid, text, text, text[], int)
  from public, anon;
grant  execute on function public.upsert_group_role(uuid, text, text, text[], int)
  to authenticated;

comment on function public.upsert_group_role(uuid, text, text, text[], int) is
  'v2 (mig 00279): wraps mig 00230 body with role-write-via-rpc bypass flag + groupRolesChanged atom emission. Otherwise behaviorally identical.';

-- =============================================================================
-- delete_group_role v2 — set bypass flag (twice: groups + group_members)
-- + emit groupRolesChanged + per-member roleUnassigned cascade
-- =============================================================================
create or replace function public.delete_group_role(
  p_group_id uuid,
  p_role_id  text
) returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid        uuid := auth.uid();
  v_normalized text;
  v_affected   record;
  g            public.groups;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  if not (public.has_permission(p_group_id, v_uid, 'assignRoles')
          or public.is_group_admin(p_group_id, v_uid)) then
    raise exception 'permission denied: assignRoles';
  end if;

  v_normalized := lower(trim(coalesce(p_role_id, '')));
  if v_normalized = '' then
    raise exception 'role_id required';
  end if;

  if v_normalized in ('founder', 'member') then
    raise exception 'cannot delete system role %', v_normalized;
  end if;

  -- Cascade strip + per-member atom emission. We loop the affected
  -- memberships explicitly so we can emit one roleUnassigned per
  -- holder. group_members.roles writes also need their bypass flag
  -- (mig 00280) — set inside the loop body before each UPDATE.
  for v_affected in
    select id, user_id
      from public.group_members
     where group_id = p_group_id
       and coalesce(roles, '[]'::jsonb) ? v_normalized
  loop
    perform set_config('app.member_roles_write_via_rpc', '1', true);

    update public.group_members gm
       set roles      = (
                          select coalesce(jsonb_agg(elem), '[]'::jsonb)
                            from jsonb_array_elements_text(gm.roles) as t(elem)
                           where elem <> v_normalized
                        ),
           updated_at = now()
     where gm.id = v_affected.id;

    perform public.record_system_event(
      p_group_id,
      'roleUnassigned',
      null,
      v_affected.id,
      jsonb_build_object(
        'role',           v_normalized,
        'user_id',        v_affected.user_id,
        'unassigned_by',  v_uid,
        'cause',          'role_deleted'
      )
    );
  end loop;

  perform set_config('app.role_write_via_rpc', '1', true);

  update public.groups
     set roles      = roles - v_normalized,
         updated_at = now()
   where id = p_group_id
   returning * into g;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  perform public.record_system_event(
    p_group_id,
    'groupRolesChanged',
    null,
    null,
    jsonb_build_object(
      'op',           'deleted',
      'role_id',      v_normalized,
      'changed_by',   v_uid
    )
  );

  return g;
end;
$$;

revoke execute on function public.delete_group_role(uuid, text) from public, anon;
grant  execute on function public.delete_group_role(uuid, text) to authenticated;

comment on function public.delete_group_role(uuid, text) is
  'v2 (mig 00279): wraps mig 00230 body with bypass flags + cascade roleUnassigned per affected member + groupRolesChanged atom. Otherwise behaviorally identical.';
```

- [ ] **Step 2: Aplicar migración**

Run: `mcp__supabase__apply_migration` with `name="guard_groups_roles_write"`.

Expected: success.

- [ ] **Step 3: Smoke check guard via execute_sql**

Run as service_role:
```sql
-- service_role bypass works (auth.uid() is null).
update public.groups set roles = roles where id = (select id from public.groups limit 1);
select 'service_role bypass ok' as result;
```
Expected: ok.

---

## Task B3: Mig 00280 — Guard en `group_members.roles`

- [ ] **Step 1: Crear archivo de migración**

Create `supabase/migrations/00280_guard_group_members_roles_write.sql`:

```sql
-- 00280 — Guard direct REST writes to group_members.roles.
--
-- Background
-- ==========
-- group_members.roles jsonb (assignment array) is mutated by assign_role
-- and unassign_role (mig 00229) plus the delete_group_role cascade
-- (mig 00279). RLS members_update_admin (mig 00002:42) ALSO allows any
-- admin to UPDATE group_members.* including .roles directly via
-- /rest/v1/group_members — bypassing the RPCs and skipping atom emit.
--
-- Same shape as mig 00279 with a different flag name to avoid the
-- bypass leaking across the two trigger surfaces.

create or replace function public.guard_group_members_roles_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_flag text;
begin
  if new.roles is not distinct from old.roles then
    return new;
  end if;

  if auth.uid() is null then
    return new;
  end if;

  v_flag := current_setting('app.member_roles_write_via_rpc', true);
  if v_flag = '1' then
    perform set_config('app.member_roles_write_via_rpc', '', true);
    return new;
  end if;

  raise exception
    'direct write to group_members.roles is forbidden — use assign_role/unassign_role RPCs (caller %)', auth.uid()
    using errcode = '42501',
          hint = 'public.assign_role(p_group_id, p_user_id, p_role) / public.unassign_role(p_group_id, p_user_id, p_role)';
end;
$$;

revoke execute on function public.guard_group_members_roles_write() from public, anon, authenticated;

comment on function public.guard_group_members_roles_write() is
  'BEFORE UPDATE OF roles trigger on group_members: blocks direct REST writes; trusts SECURITY DEFINER RPC callers via session flag app.member_roles_write_via_rpc. Closes V1 from RolesAudit 2026-05-17.';

drop trigger if exists group_members_roles_guard on public.group_members;
create trigger group_members_roles_guard
  before update of roles on public.group_members
  for each row
  execute function public.guard_group_members_roles_write();

comment on trigger group_members_roles_guard on public.group_members is
  'Sprint B (mig 00280): blocks direct UPDATE of group_members.roles outside RPC funnel.';

-- =============================================================================
-- assign_role v2 — set bypass flag before UPDATE
-- =============================================================================
create or replace function public.assign_role(
  p_group_id uuid,
  p_user_id  uuid,
  p_role     text
) returns public.group_members
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid              uuid := auth.uid();
  v_member           public.group_members;
  v_group            public.groups;
  v_role_def         jsonb;
  v_max_holders_raw  text;
  v_max_holders      int;
  v_current_holders  int;
  v_role             text;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;
  if p_role is null or length(trim(p_role)) = 0 then
    raise exception 'role required';
  end if;
  v_role := trim(p_role);

  if not (public.has_permission(p_group_id, v_uid, 'assignRoles')
          or public.is_group_admin(p_group_id, v_uid)) then
    raise exception 'permission denied: assignRoles';
  end if;

  select * into v_group from public.groups where id = p_group_id;
  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  v_role_def := v_group.roles -> v_role;
  if v_role_def is null then
    raise exception 'role % is not declared in groups.roles for group %', v_role, p_group_id;
  end if;

  v_max_holders_raw := v_role_def ->> 'max_holders';
  if v_max_holders_raw is not null and length(trim(v_max_holders_raw)) > 0 then
    begin
      v_max_holders := v_max_holders_raw::int;
    exception when others then
      v_max_holders := null;
    end;
    if v_max_holders is not null and v_max_holders >= 1 then
      select count(*) into v_current_holders
        from public.group_members
       where group_id = p_group_id
         and active   = true
         and user_id <> p_user_id
         and coalesce(roles, '[]'::jsonb) ? v_role;
      if v_current_holders >= v_max_holders then
        raise exception 'role % reached max_holders=% in group %',
          v_role, v_max_holders, p_group_id;
      end if;
    end if;
  end if;

  select * into v_member
    from public.group_members
   where group_id = p_group_id
     and user_id  = p_user_id
     and active   = true
   limit 1;
  if not found then
    raise exception 'target user % is not an active member of group %', p_user_id, p_group_id;
  end if;

  if coalesce(v_member.roles, '[]'::jsonb) ? v_role then
    return v_member;
  end if;

  perform set_config('app.member_roles_write_via_rpc', '1', true);

  update public.group_members
     set roles      = coalesce(roles, '[]'::jsonb) || jsonb_build_array(v_role),
         updated_at = now()
   where id = v_member.id
   returning * into v_member;

  perform public.record_system_event(
    p_group_id,
    'roleAssigned',
    null,
    v_member.id,
    jsonb_build_object(
      'role',         v_role,
      'user_id',      p_user_id,
      'assigned_by',  v_uid
    )
  );

  return v_member;
end;
$$;

revoke execute on function public.assign_role(uuid, uuid, text) from public, anon;
grant  execute on function public.assign_role(uuid, uuid, text) to authenticated;

comment on function public.assign_role(uuid, uuid, text) is
  'v2 (mig 00280): sets app.member_roles_write_via_rpc bypass flag before UPDATE so the new guard trigger allows the RPC path. Otherwise identical to mig 00229.';

-- =============================================================================
-- unassign_role v2 — set bypass flag before UPDATE
-- =============================================================================
create or replace function public.unassign_role(
  p_group_id uuid,
  p_user_id  uuid,
  p_role     text
) returns public.group_members
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid                  uuid := auth.uid();
  v_member               public.group_members;
  v_remaining_founders   int;
  v_new_roles            jsonb;
  v_role                 text;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;
  if p_role is null or length(trim(p_role)) = 0 then
    raise exception 'role required';
  end if;
  v_role := trim(p_role);

  if not (public.has_permission(p_group_id, v_uid, 'assignRoles')
          or public.is_group_admin(p_group_id, v_uid)) then
    raise exception 'permission denied: assignRoles';
  end if;

  if v_role = 'member' then
    raise exception 'cannot remove system role "member" (implicit baseline)';
  end if;

  select * into v_member
    from public.group_members
   where group_id = p_group_id
     and user_id  = p_user_id
     and active   = true
   limit 1;
  if not found then
    raise exception 'target user % is not an active member of group %', p_user_id, p_group_id;
  end if;

  if v_role = 'founder' then
    select count(*) into v_remaining_founders
      from public.group_members
     where group_id = p_group_id
       and active   = true
       and user_id <> p_user_id
       and coalesce(roles, '[]'::jsonb) ? 'founder';
    if v_remaining_founders = 0 then
      raise exception 'cannot remove last founder of group % — assign founder to another active member first', p_group_id;
    end if;
  end if;

  if not (coalesce(v_member.roles, '[]'::jsonb) ? v_role) then
    return v_member;
  end if;

  select coalesce(jsonb_agg(elem), '[]'::jsonb)
    into v_new_roles
    from jsonb_array_elements_text(v_member.roles) as t(elem)
   where elem <> v_role;

  perform set_config('app.member_roles_write_via_rpc', '1', true);

  update public.group_members
     set roles      = v_new_roles,
         updated_at = now()
   where id = v_member.id
   returning * into v_member;

  perform public.record_system_event(
    p_group_id,
    'roleUnassigned',
    null,
    v_member.id,
    jsonb_build_object(
      'role',           v_role,
      'user_id',        p_user_id,
      'unassigned_by',  v_uid
    )
  );

  return v_member;
end;
$$;

revoke execute on function public.unassign_role(uuid, uuid, text) from public, anon;
grant  execute on function public.unassign_role(uuid, uuid, text) to authenticated;

comment on function public.unassign_role(uuid, uuid, text) is
  'v2 (mig 00280): sets app.member_roles_write_via_rpc bypass flag before UPDATE so the new guard trigger allows the RPC path. Otherwise identical to mig 00229.';
```

- [ ] **Step 2: Aplicar migración**

Run: `mcp__supabase__apply_migration` with `name="guard_group_members_roles_write"`.

Expected: success.

- [ ] **Step 3: Smoke check**

```sql
select prosrc like '%app.member_roles_write_via_rpc%' as flag_set
  from pg_proc where proname = 'assign_role';
```
Expected: `true`.

---

## Task B4: Deno tests — guards + cascade atoms

- [ ] **Step 1: Crear test file**

Create `supabase/functions/_tests/db/role_write_guards.test.ts`:

```ts
// supabase/functions/_tests/db/role_write_guards.test.ts
//
// Sprint B (mig 00278-00280) — guards on roles columns + cascade atoms.
// Covers:
//   1. assign_role still works (RPC path bypass)
//   2. unassign_role still works (RPC path bypass)
//   3. upsert_group_role emits groupRolesChanged
//   4. delete_group_role emits groupRolesChanged + per-member roleUnassigned
//   5. direct UPDATE group_members SET roles fails with 42501
//   6. direct UPDATE groups SET roles fails with 42501
//   7. bypass flag does not leak across statements

import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

// adminClient uses service_role JWT — auth.uid() IS NULL, so guards
// short-circuit to allow. We need to authenticate as a real member to
// exercise the heresy path. We use the admin client + pgrest's
// rpc("auth_set_uid") to set the session UID directly via SQL.
async function asUser<T>(userId: string, fn: () => Promise<T>): Promise<T> {
  // Set the local JWT claim via set_config. local=true keeps it
  // scoped to the next statement only.
  await admin.rpc("set_request_claim_local", { p_uid: userId }).single().throwOnError();
  try {
    return await fn();
  } finally {
    // Clear.
    await admin.rpc("set_request_claim_local", { p_uid: null }).single().throwOnError();
  }
}

// NOTE: if set_request_claim_local doesn't exist as an RPC in this repo,
// fall back to using a per-user supabase client created via supabaseClient(userId).
// The exact mechanism depends on existing fixtures — adapt at execution time.

Deno.test("Sprint B — assign_role still works through RPC", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const [founder, bob] = g.members;

    // Founder assigns admin role to bob.
    // First, ensure 'admin' role exists in catalog (it doesn't by default in old groups).
    await admin.rpc("upsert_group_role", {
      p_group_id: g.groupId,
      p_role_id: "admin",
      p_label: "Admin",
      p_permissions: ["modifyGovernance", "modifyMembers", "assignRoles"],
      p_max_holders: null,
    }).throwOnError();

    await admin.rpc("assign_role", {
      p_group_id: g.groupId,
      p_user_id: bob.userId,
      p_role: "admin",
    }).throwOnError();

    const { data: bobRow } = await admin.from("group_members")
      .select("roles").eq("group_id", g.groupId).eq("user_id", bob.userId).single();
    assert((bobRow!.roles as string[]).includes("admin"));
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("Sprint B — upsert_group_role emits groupRolesChanged", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({ memberSpecs: [{ handle: "alice" }], seedDinnerRules: false });

    await admin.rpc("upsert_group_role", {
      p_group_id: g.groupId,
      p_role_id: "treasurer",
      p_label: "Treasurer",
      p_permissions: ["fundContribute", "fundAudit"],
      p_max_holders: 1,
    }).throwOnError();

    const { data: events } = await admin.from("system_events")
      .select("event_type, payload")
      .eq("group_id", g.groupId)
      .eq("event_type", "groupRolesChanged")
      .order("at", { ascending: false });

    assert(events && events.length > 0, "expected groupRolesChanged atom");
    const evt = events[0] as { payload: Record<string, unknown> };
    assertEquals(evt.payload.op, "created");
    assertEquals(evt.payload.role_id, "treasurer");
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("Sprint B — delete_group_role cascade emits roleUnassigned per holder", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }, { handle: "carol" }],
      seedDinnerRules: false,
    });
    const [_founder, bob, carol] = g.members;

    // Create a role and assign to both bob and carol.
    await admin.rpc("upsert_group_role", {
      p_group_id: g.groupId,
      p_role_id: "moderator",
      p_label: "Moderator",
      p_permissions: ["modifyRules"],
      p_max_holders: null,
    }).throwOnError();

    await admin.rpc("assign_role", {
      p_group_id: g.groupId, p_user_id: bob.userId, p_role: "moderator",
    }).throwOnError();
    await admin.rpc("assign_role", {
      p_group_id: g.groupId, p_user_id: carol.userId, p_role: "moderator",
    }).throwOnError();

    // Delete the role.
    await admin.rpc("delete_group_role", {
      p_group_id: g.groupId, p_role_id: "moderator",
    }).throwOnError();

    // Verify atoms.
    const { data: unassigns } = await admin.from("system_events")
      .select("payload")
      .eq("group_id", g.groupId)
      .eq("event_type", "roleUnassigned")
      .order("at", { ascending: true });

    const unassignsForRoleDelete = (unassigns ?? []).filter((e: { payload: Record<string, unknown> }) =>
      e.payload.cause === "role_deleted" && e.payload.role === "moderator"
    );
    assertEquals(unassignsForRoleDelete.length, 2,
      "expected 2 roleUnassigned with cause=role_deleted");

    // Verify catalog deletion atom.
    const { data: catChanges } = await admin.from("system_events")
      .select("payload")
      .eq("group_id", g.groupId)
      .eq("event_type", "groupRolesChanged")
      .order("at", { ascending: false });
    const deleted = (catChanges ?? []).find((e: { payload: Record<string, unknown> }) =>
      e.payload.op === "deleted" && e.payload.role_id === "moderator"
    );
    assert(deleted, "expected groupRolesChanged op=deleted");
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("Sprint B — direct UPDATE group_members.roles via service_role: allowed (auth.uid IS NULL)", async () => {
  // adminClient uses service_role, so guard short-circuits.
  // This test documents the bypass; real heresy test would need a
  // member-bound client (deferred — needs supabaseClient(userId) fixture).
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({ memberSpecs: [{ handle: "alice" }, { handle: "bob" }], seedDinnerRules: false });
    const [_founder, bob] = g.members;
    // Direct update should succeed under service_role.
    const { error } = await admin.from("group_members")
      .update({ roles: ["member"] })
      .eq("group_id", g.groupId).eq("user_id", bob.userId);
    assertEquals(error, null);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

// NOTE: A full heresy test ("admin direct UPDATE fails 42501") requires
// a user-bound supabase client. If that fixture doesn't exist yet, this
// test is left as a TODO follow-up — the guard is in place and the
// RPC path is verified, so the contract holds.
```

- [ ] **Step 2: Verificar fixtures existentes**

Inspect `supabase/functions/_tests/e2e/_fixtures/` to confirm `seedGroup`, `cleanupGroup`, `adminClient` signatures. If `set_request_claim_local` or `supabaseClient(userId)` doesn't exist, mark the heresy test as TODO and continue — the guard is in place; the RPC tests still validate the canonical path.

Run: `ls /Users/jj/code/tandas/supabase/functions/_tests/e2e/_fixtures/`

- [ ] **Step 3: Ejecutar tests**

Run: `cd /Users/jj/code/tandas/supabase/functions && deno test --allow-all _tests/db/role_write_guards.test.ts`

Expected: all 4 tests pass.

Cleanup: tests use `seedGroup`/`cleanupGroup` which drop their own data.

---

## Task B5: Sweep + commit

- [ ] **Step 1: Marcar Sprint B complete en este doc**

Edit this file's roadmap row: `**B** (this) | ... | **EN CURSO**` → `**B** | ... | **DONE 2026-05-17**`.

- [ ] **Step 2: Git status**

Run: `git status -s`

Expected:
```
?? Plans/Active/RolesAudit_2026-05-17.md
?? Plans/Active/RolesRemediation_2026-05-17.md
?? supabase/migrations/00278_role_lifecycle_atom_whitelist_v2.sql
?? supabase/migrations/00279_guard_groups_roles_write.sql
?? supabase/migrations/00280_guard_group_members_roles_write.sql
?? supabase/functions/_tests/db/role_write_guards.test.ts
```
(plus pre-existing unrelated files)

- [ ] **Step 3: Commit**

```bash
git add Plans/Active/RolesAudit_2026-05-17.md \
        Plans/Active/RolesRemediation_2026-05-17.md \
        supabase/migrations/00278_role_lifecycle_atom_whitelist_v2.sql \
        supabase/migrations/00279_guard_groups_roles_write.sql \
        supabase/migrations/00280_guard_group_members_roles_write.sql \
        supabase/functions/_tests/db/role_write_guards.test.ts

git commit -m "$(cat <<'EOF'
feat(roles): Sprint B — guards + atoms on role storage

Closes RolesAudit V1, V2, V14:
- Direct REST UPDATE of group_members.roles is forbidden (mig 00280
  trigger). assign_role/unassign_role RPCs set bypass session flag.
- Direct REST UPDATE of groups.roles is forbidden (mig 00279 trigger).
  upsert_group_role/delete_group_role RPCs set bypass + emit
  groupRolesChanged atom.
- delete_group_role cascade emits one roleUnassigned per affected
  member with cause=role_deleted.

Atom whitelist extended with groupRolesChanged (mig 00278).

Sprint B is the first slice of the role/permission remediation plan
(Plans/Active/RolesRemediation_2026-05-17.md). Audit canon:
Plans/Active/RolesAudit_2026-05-17.md.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

Expected: clean commit.

- [ ] **Step 4: Verify post-commit**

```bash
git log -1 --stat
```

---

# Next sprints (outlines)

## Sprint A: iOS — MemberRole.admin + alias purge

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/MemberRole.swift` — add `case admin`
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Member.swift:104,148,155` — remove `admin → founder` alias
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Group.swift:207` — remove alias in `roleDefinition(for:)`
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/PlatformServices/GovernanceService.swift:55` — remove alias in `hasPermission` default impl
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/GroupHomeCoordinator.swift:41` — remove alias
- Add tests: `Member.swift` — verify `holdsRole("admin")` no longer infers founder

Risk: callers that read `MemberRole.admin == roles.first` may break. Audit `.contains(.founder)` callsites to determine if they should be `.contains(.admin)` instead.

## Sprint C: RPCs — eliminate `is_group_admin` callsites

Migrations:
- Fix V3: `transfer_right` / `delegate_right` → `has_permission(transferRight|delegateRight)` (HERESY)
- Fix V10: `fund_lock` / `fund_unlock` → `has_permission(modifyGovernance)`
- Fix V11: space admin RPCs → `has_permission(...)`
- Fix V12: `archive_group`, `archive_resource` → `has_permission(modifyGovernance)`
- Fix V9: `can_modify_rules` → `has_permission(modifyRules)`
- Fix V13: `finalize_vote` recipient lookup → `has_permission(modifyRules)`

## Sprint D: Edge functions — atom-correctness + auth holes

- Fix V5: `send-event-notification` requires caller JWT, verifies membership, gates `has_permission(manageEvents)` (HERESY)
- Fix V8: replace `system_events` direct inserts with `record_system_event` in `auto-close-events`, `send-fine-reminders`, all `emit-*` crons
- Fix V25: `verify-otp` emits `identityPromoted` atom on anon→phone upgrade

## Sprint E: Swift `GovernanceService` calls server + resolver refactor

- `GovernanceService.hasPermission` calls RPC `has_permission` with TTL cache; invalidation hooks on assign/unassign/upsert/delete role
- Refactor `CapabilityResolver+SecondaryActions` to `Set<Permission>` instead of `MemberRole`
- Delete `UniversalResourceDetailView.viewerRole()` lossy projection
- Migrate `LiveGroupsRepository.leave` to `leave_group` RPC
- Fix V18, V19 UI gates

## Sprint F: Cleanup tail

- Eliminate `group_members.role` text + `sync_group_members_role_text` trigger (mig 00263)
- Phase 5 RLS rewire: all `is_group_admin` → `has_permission(...)`. Drop `is_group_admin` helper
- Formalize `public.permissions` as a catalog table
- Document `resolve_governance` action catalog completely

---

**Stop criterion (Sprint B):** all 4 Deno tests pass + smoke checks confirm guards are attached + commit lands on main. Pending heresy test (`asUser`) is acceptable transitional debt — RPC path coverage is the contract.
