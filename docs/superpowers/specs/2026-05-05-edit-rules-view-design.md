# EditRulesView — Design Spec

**Date:** 2026-05-05
**Roadmap reference:** `Plans/Roadmap.md` §3 Fase 0 item #5; `Plans/UICompleteCoverage.md` P0 #1.
**Status:** Approved (brainstorm 2026-05-05), pending implementation plan.
**Companion enum work shipped pre-spec:** `e266a16` (added `ruleEnabledChanged` + `ruleAmountChanged` to SystemEventType).

---

## Goal

Lift the read-only restriction on `RulesView`. Founders (and other roles per group governance) gain the ability to toggle a preset rule on/off, edit its flat fine amount, and propose archiving — all from a dedicated `EditRulesView` reachable from the existing read-only list. This closes the V1 product gap that ruul cannot honor its central promise ("each group writes its own social contract") for any group past onboarding step 6.

## Motivation

`Plans/UICompleteCoverage.md` P0 #1 calls out that `RulesView` is read-only after onboarding. Today, founders cannot raise a fine amount, pause a rule, or remove a rule that does not fit the group's evolving norms. With four production groups already running on `recurring_dinner`, this is the most visible product gap. Effort estimate: 4–5h of focused work given the scope refinements documented below.

## Decisions

| # | Decision | Notes |
|---|---|---|
| 1 | **V1 scope: edit + toggle + archive on the 5 preset rules of `recurring_dinner`.** | "Add new rule from template" collapses to "re-enable a disabled preset" because every group already has the 5 presets seeded (`00015_seed_template_rules.sql` + `00018_backfill_platform_rules.sql`). Insertion of genuinely new rules deferred to Fase 5 visual builder. |
| 2 | **Vote ceremony only for `archive`.** Toggle and edit-amount are direct UPDATEs gated by RLS. | Aligns with "cero RPCs nuevos" while keeping audit honesty via Postgres trigger. |
| 3 | **UI blocks + educates when governance gate ≠ `.allowed` for the actor.** Pencil hidden in those cases. | Pure UI-side change; backend behavior unchanged. |
| 4 | **Postgres trigger emits `ruleEnabledChanged` / `ruleAmountChanged`** atomically with the UPDATE. | Closes the audit window between mutation and event emission. ~20 LOC SQL. |
| 5 | **Unique index `(vote_type, reference_id) WHERE status='open'`** on votes. | Prevents accidental double-open of a `rule_repeal` vote (or any reference-based vote_type). |
| 6 | **Edit-amount supports flat fines only in V1.** Escalating fines display read-only with explainer. | 4 of 5 presets are flat; 1 escalating ("Tarde a evento"). Visual builder in Fase 5 covers escalating. |
| 7 | **`rules.action` (legacy column) is NOT updated.** Single-write to `consequences`. | Verified 2026-05-05: zero readers of `rules.action` in the iOS or edge-function code. |

## Out of scope (V1)

- **Insert genuinely new rules.** No `propose_rule` calls from EditRulesView in V1. Fase 5 visual builder owns this.
- **Edit rule name, description, trigger, conditions.** Read-only context in V1. Fase 5 visual builder.
- **Edit escalating fine breakdown** (`baseAmount`, `stepAmount`, `stepMinutes`). Read-only display in V1.
- **"Archive + Propose new" flow for `whoCanModifyRules == majorityVote` groups.** Those groups have NO access to EditRulesView in V1 (pencil hidden). Known gap; revisit in Fase 5 with the visual builder.
- **Realtime governance revocation** (live-update pencil visibility when another admin changes governance mid-session). Out of V1; check is on-view-appear only.
- **Multi-locale `RuleSummaryFormatter`.** V1 ships es-MX only.

## Architecture

```
RulesView (existing, read-only)
  ↓ pencil button (only if governance.canPerform(.modifyRules) == .allowed)
EditRulesView (new)
  ├─ Header: "Reglas pre-armadas"
  ├─ List of 5 cards (stable order by created_at ASC):
  │   ├─ Card body: title, brief description, "Multa: $XXX" display-only
  │   ├─ Inline toggle (enabled/disabled) with sync indicator while in-flight
  │   └─ Tap card → EditRuleSheet
  ├─ Footer (passive, centered, secondary tone):
  │   "Las reglas personalizadas estarán disponibles en una próxima versión."
  └─ "Votación pendiente" badge on cards with open rule_repeal vote

EditRuleSheet (new, modal)
  ├─ Title (display only)
  ├─ Section "CÓMO FUNCIONA" (display only — no chevron, no tap):
  │     trigger summary, conditions summary
  ├─ Section "MULTA" (editable for .flat shape only):
  │     "Monto" row → tap activates inline edit + keyboard,
  │     save explícito via nav-bar "Save" button
  └─ Destructive: "Archivar regla" (red text, full-width)
        opens confirmation → start_vote(rule_repeal) → existing vote machinery
```

### Files

**New:**
- `ios/Tandas/Features/Rules/EditRulesView.swift` (~250 LOC)
- `ios/Tandas/Features/Rules/EditRuleSheet.swift` (~180 LOC)
- `ios/Tandas/Features/Rules/EditRulesCoordinator.swift` (~120 LOC)
- `ios/Tandas/Features/Rules/RuleSummaryFormatter.swift` (~80 LOC) — maps `eventType + config` → human-readable Spanish strings.
- `ios/Tandas/Platform/Models/GroupRule+FineShape.swift` (~40 LOC) — the `FineShape` enum and `var fineShape` helper.
- `supabase/migrations/00024_rule_mutation_audit.sql` (trigger + `can_modify_rules` function — bundled if `can_modify_rules` is not yet referenced by the rules RLS policy).
- `supabase/migrations/00024_rollback.sql`
- `supabase/migrations/00025_unique_open_vote_per_reference.sql`
- `supabase/migrations/00025_rollback.sql`
- `ios/TandasTests/Rules/RuleFineShapeTests.swift`
- `ios/TandasTests/Rules/EditRulesCoordinatorTests.swift`
- `ios/TandasTests/Rules/RulesRepositoryTests.swift`
- `supabase/functions/_tests/rule_mutation_audit.test.ts`
- `supabase/functions/_tests/vote_unique_open.test.ts`
- `supabase/functions/_tests/can_modify_rules.test.ts`
- `supabase/functions/_tests/rls_update_rules.test.ts`

**Modified:**
- `ios/Tandas/Features/Rules/RulesView.swift` — adds the conditional pencil button in nav. No other changes.
- `ios/Tandas/Features/Rules/RulesCoordinator.swift` — exposes `canEditRules: Bool` consulted by the pencil. Kept as a simple `@Published` flag.
- `ios/Tandas/Platform/Repositories/RulesRepository.swift` — adds `setEnabled`, `setFlatFineAmount`, `pendingRepealVote`.
- `ios/TandasTests/Platform/CodableEnumsTests.swift` — append rendering check for `ruleEnabledChanged` / `ruleAmountChanged` via `HistoryItemPresentation`.

## EditRulesView (the list)

### Layout

- Nav back to RulesView. No title bar action besides the back chevron (the sheet manages its own actions).
- `ScrollView` with `VStack(spacing: RuulSpacing.s3)`.
- Header: `"Reglas pre-armadas"` (display-only). No count.
- 5 rule cards. Stable order by `created_at ASC`. Disabled cards rendered with `opacity(0.55)` (matches existing `RulesView` pattern for inactive rules).
- Each card:
  - Title (line-limit 2)
  - Description (line-limit 3, secondary tone)
  - "Multa: $XXX" or "Multa escalonada" (display only)
  - Inline `Toggle` bound to `rule.enabled`
  - Sync indicator: small dot/spinner adjacent to the toggle while a `setEnabled` call is in flight. Implementation: `@State var inFlightToggleIDs: Set<UUID>` on the coordinator; card consults membership.
- Tap on the card body (anywhere except the toggle) pushes `EditRuleSheet` modal.
- Footer (passive, centered, `secondary` tone, no tap target):
  > "Las reglas personalizadas estarán disponibles en una próxima versión."

### Toggle behavior

- **Optimistic flip**: UI mutates immediately on tap.
- **Repository call**: `RulesRepository.setEnabled(ruleId, enabled)` UPDATEs `rules.enabled`. Postgres trigger emits `ruleEnabledChanged`.
- **In flight**: sync indicator visible. If `Task` runs >5s, indicator continues without timeout (the user can still tap to revert).
- **Success**: indicator disappears. No toast.
- **Failure**: indicator disappears, UI reverts to prior state, toast shown at bottom. RLS denial errors get a custom message: "La gobernanza del grupo cambió. Tirá pull-to-refresh para ver los permisos actuales." (matches the 5.2 mid-session edge case).

### Pending repeal vote badge

When the rule has an open `rule_repeal` vote (`votes` row with `vote_type='rule_repeal'`, `reference_id=rule.id`, `status='open'`):

- Card shows badge: "Votación pendiente · cierra en 2d 4h" (using `closes_at` countdown).
- Toggle on the card is disabled (no inline edit while a repeal is being voted).
- Tap → `EditRuleSheet` opens in "Esta regla está siendo votada para archivar" mode: amount/toggle disabled, link to the vote.
- When vote resolves (`status='passed'` or `'rejected'`):
  - Passed → rule is archived server-side via existing `close_vote`. EditRulesView refresh → archived rule disappears (V1 hides archived).
  - Rejected → badge disappears on next refresh, rule returns to editable state.

### Defensive empty state (should never trigger in production)

If `coordinator.rules.isEmpty` (e.g., a group somehow restored without seed rules):
> "Este grupo no tiene reglas configuradas."

In this state the passive Fase 5 footer is **not** rendered — only the empty-state copy. Avoids the user seeing two competing explanations. Groups with 1–4 presets render those cards + the footer normally; the empty-state copy only triggers when zero rules exist.

This state is checked manually in QA #17 below.

## EditRuleSheet (the modal)

### Layout

```
┌─────────────────────────────────┐
│ Cancelar      Editar regla   Save│  ← Save activates only when dirty
├─────────────────────────────────┤
│  Tarde a evento                 │  ← rule.title (display)
│                                 │
│  CÓMO FUNCIONA                  │  ← display-only section
│  Cuando alguien hace check-in   │
│  más de 15 minutos tarde        │
│                                 │
│  MULTA                          │  ← editable section (flat only)
│  Monto                  $200  > │  ← tap to edit inline
│                                 │
│  [ Archivar regla ]             │  ← destructive
│   Abre votación del grupo       │
└─────────────────────────────────┘
```

### Sections

1. **Title** — display-only `Text` of `rule.title`.
2. **"CÓMO FUNCIONA"** — display-only context section:
   - Trigger summary from `RuleSummaryFormatter.summarize(trigger:)`.
   - Conditions summary from `RuleSummaryFormatter.summarize(conditions:)`. Empty → no row rendered.
   - Plain text, no chevron, no tap target.
3. **"MULTA"** — editable iff `rule.fineShape == .flat`:
   - **Flat**: row "Monto" + amount + chevron. Tap → field becomes editable inline; keyboard slides up. Nav-bar "Save" activates while dirty. Validation: `amount > 0 && amount ≤ 1_000_000`. Save: optimistic, repo call → UPDATE `consequences[0].config.amount` → trigger emits `ruleAmountChanged`. Cancel button (nav-bar) reverts.
   - **Escalating**: row displays "Base: $200 · cada 30 min suma $50" with a one-line note: "Multas escalonadas se editan en una próxima versión."
   - **Unknown / none**: section hidden entirely (defensive).
4. **Destructive — "Archivar regla"**:
   - Red full-width button.
   - Tap → `Alert("¿Archivar 'Tarde a evento'? Se abrirá una votación del grupo. Si pasa, la regla deja de aplicarse.", primaryButton: .destructive("Sí, abrir votación"), secondaryButton: .cancel)`.
   - Confirm → `start_vote` RPC with `vote_type='rule_repeal'`, `reference_id=rule.id`. On success, sheet dismisses; EditRulesView refresh shows the "Votación pendiente" badge.

### Pending repeal mode

When `pendingRepealVote(rule.id)` returns non-nil:
- Title rendered as normal.
- Banner at top: "Esta regla está siendo votada para archivar — cierra en 2d 4h."
- "MULTA" amount field disabled (gray, non-tappable).
- "Archivar regla" button disabled.
- Link: "Ver votación →" navigates to the existing vote detail view.

## Backend interaction

### Repository contract

```swift
extension RulesRepository {
    /// Toggles enabled/disabled. RLS gates by group membership + governance.
    /// Postgres trigger emits `ruleEnabledChanged` system_event atomically.
    func setEnabled(ruleId: UUID, enabled: Bool) async throws

    /// Updates the flat fine amount. UI must pre-validate via Rule.fineShape;
    /// repository defends with `RulesRepositoryError.notFlatFine`.
    /// Postgres trigger emits `ruleAmountChanged` system_event atomically.
    func setFlatFineAmount(rule: GroupRule, amount: Int) async throws

    /// Reads pending rule_repeal vote, if any. Used to render
    /// "Votación pendiente" badge.
    func pendingRepealVote(ruleId: UUID) async throws -> Vote?
}

public enum RulesRepositoryError: Error {
    case notFlatFine
    case rlsDenied
    case other(Error)
}
```

UPDATE statements via supabase-swift:

```swift
// Toggle:
try await client.from("rules").update(["enabled": enabled])
    .eq("id", value: ruleId).execute()

// Amount edit (flat only — pre-validated by guard case .flat):
let newConsequences = [["type": "fine", "config": ["amount": amount]]]
try await client.from("rules").update(["consequences": newConsequences])
    .eq("id", value: ruleId).execute()
```

The `action` legacy column is intentionally not updated (zero readers verified 2026-05-05).

### Postgres trigger (migration 00024)

```sql
-- Emits ruleEnabledChanged or ruleAmountChanged whenever rules.enabled or
-- rules.consequences mutates. Atomic with the UPDATE — no client-side
-- audit window. Resolves the actor's group_member_id via auth.uid().

create or replace function public.emit_rule_mutation_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
begin
  select id into v_member_id
  from public.group_members
  where group_id = new.group_id
    and user_id = auth.uid()
    and active
  limit 1;

  if new.enabled is distinct from old.enabled then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (new.group_id, 'ruleEnabledChanged', new.id, v_member_id, jsonb_build_object(
      'rule_title', new.title,
      'before', old.enabled,
      'after', new.enabled
    ));
  end if;

  if new.consequences is distinct from old.consequences then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (new.group_id, 'ruleAmountChanged', new.id, v_member_id, jsonb_build_object(
      'rule_title', new.title,
      'before', old.consequences,
      'after', new.consequences
    ));
  end if;

  return new;
end;
$$;

create trigger rules_mutation_audit
after update on public.rules
for each row
execute function public.emit_rule_mutation_events();

comment on function public.emit_rule_mutation_events() is
  'Emits ruleEnabledChanged / ruleAmountChanged system_events atomically on UPDATE. '
  'Added 2026-05-XX as part of EditRulesView (Plan UI P0 #1).';
```

Rollback (`00024_rollback.sql`):
```sql
drop trigger if exists rules_mutation_audit on public.rules;
drop function if exists public.emit_rule_mutation_events();
```

**Interaction with `close_vote`**: when a `rule_repeal` vote passes, `close_vote` runs `UPDATE rules SET status='archived', enabled=false WHERE id = v.subject_id;`. That UPDATE flips `enabled` from true to false, which fires the trigger and emits `ruleEnabledChanged` in addition to the `voteResolved` event the vote machinery already emits. The history therefore shows two related entries for an archive event: "Se cerró una votación" and "<actor> cambió el estado de una regla". This dual emission is accepted as-is for V1 — both entries are factually correct and add audit context. If it becomes UX noise, a future refinement can suppress the trigger emission when `auth.uid()` is null (i.e., when the UPDATE comes from a security-definer function) or pass an explicit "skip audit" flag via session variable.

### `can_modify_rules` function (bundled in 00024 if needed)

```sql
create or replace function public.can_modify_rules(p_group_id uuid, p_user_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_governance_value text;
  v_member group_members;
begin
  select * into v_member
  from public.group_members
  where group_id = p_group_id and user_id = p_user_id and active
  limit 1;
  if not found then return false; end if;

  select governance->>'whoCanModifyRules' into v_governance_value
  from public.groups where id = p_group_id;

  return case v_governance_value
    when 'founder'   then v_member.role = 'founder'
    when 'anyMember' then true
    -- 'majorityVote' / 'supermajorityVote' / 'host' / 'treasurer' all
    -- require routing through a vote (or a non-V1 path); direct UPDATE
    -- is denied so client checks must funnel users to the vote flow.
    else false
  end;
end;
$$;
```

### RLS policy on rules (verified pre-implementation)

The implementation plan's first migration task verifies the existing `rules` UPDATE policy and either extends it to consult `can_modify_rules` or replaces it. The expected final policy:

```sql
drop policy if exists rules_update on public.rules;
create policy rules_update on public.rules
  for update
  using (public.can_modify_rules(group_id, auth.uid()))
  with check (public.can_modify_rules(group_id, auth.uid()));
```

If the current policy already gates UPDATE through `is_group_admin` or similar, the implementation plan documents the swap and verifies behavior with `rls_update_rules.test.ts`.

### Unique index (migration 00025)

```sql
-- Prevent two open votes simultaneously for the same (vote_type, reference_id).
-- Protects rule_repeal, fine_appeal, and any other reference-based vote_type
-- from accidental double-opens (race condition in start_vote).
-- General-proposal votes without reference_id are exempt.

create unique index uniq_open_vote_per_reference
on public.votes (vote_type, reference_id)
where status = 'open' and reference_id is not null;

comment on index public.uniq_open_vote_per_reference is
  'Prevents simultaneous open votes for the same (vote_type, reference_id). '
  'Added 2026-05-XX as part of EditRulesView (Plan UI P0 #1).';
```

Pre-flight check (verified 2026-05-05): zero violators in production.

Rollback:
```sql
drop index if exists public.uniq_open_vote_per_reference;
```

### Pending repeal vote query

```swift
let response = try await client.from("votes")
    .select("id, reference_id, closes_at, status")
    .eq("group_id", value: groupId)
    .eq("vote_type", value: "rule_repeal")
    .eq("status", value: "open")
    .execute()
// Map reference_id → Vote, attach to the matching GroupRule.
```

## Governance gating

### Timing

`canPerform(.modifyRules)` runs **on-view-appear** in `RulesView.task` and `EditRulesCoordinator.refresh()`. Result stored as `coordinator.canEditRules: Bool`. Pencil button reads this flag.

Re-evaluation happens on:
- Pull-to-refresh
- Push-to-EditRulesView
- App foreground after backgrounding
- Manual `await coordinator.refresh()` calls

NOT re-evaluated on every render (overhead without payoff — `governance` jsonb is quasi-static).

### Mid-session governance changes

Pencil **does not disappear live** from an open EditRulesView. Re-checked on next refresh. RLS is the authoritative gate; if a stale-state user attempts to save, the UPDATE fails and the custom error message ("La gobernanza del grupo cambió...") points them to pull-to-refresh.

### Defense in depth

Client check is for UI affordance; RLS policy is the security boundary. The `can_modify_rules` SQL function is the single source of truth — both the iOS client (via `GovernanceService.canPerform`) and the RLS policy consult it (the `GovernanceService` reads `groups.governance` directly today; consider routing it through the same SQL function in a follow-up).

### Error states

`canPerform` failure → `canEditRules = false` (fail-closed silently). No badge, no toast. Symmetric assumption: if the check is failing, mutations would fail anyway, so hiding the affordance prevents user frustration.

Mutation failure (e.g., RLS denied because governance changed mid-session) → loud toast with the custom message above.

## Test plan

### A. iOS unit tests (`ios/TandasTests/`)

1. **`RuleFineShapeTests`**:
   - Parse `[{"type":"fine","config":{"amount":200}}]` → `.flat(amount: 200)`.
   - Parse `[{"type":"fine","config":{"baseAmount":200,"stepAmount":50,"stepMinutes":30}}]` → `.escalating(base: 200, step: 50, stepMinutes: 30)`.
   - Parse `[]` → `.none`.
   - Parse `[{"type":"fine","config":{"unknownField":"x"}}]` → `.unknown(rawConfig: ...)`.
   - Parse multiple consequences → only the first one matters; assertion uses index 0.
   - Parse config with extra fields beyond the recognized shape → still classified correctly (forward-compat).

2. **`HistoryItemPresentationTests`** (extends existing `CodableEnumsTests`): for `ruleEnabledChanged` and `ruleAmountChanged`, verify `(icon, title, tone)` matches what `e266a16` seeded.

3. **`EditRulesCoordinatorTests`**:
   - Default `canEditRules == false`.
   - Refresh with governance returning `.allowed` → `canEditRules == true`.
   - Refresh with governance throwing → `canEditRules == false` (fail-closed, no UI banner).
   - Refresh with governance returning `.requiresVote` → `canEditRules == false` (V1 treats as denied; covers Fase 5 ground without drifting).
   - Refresh with governance returning `.denied` → `canEditRules == false`.

4. **`RulesRepositoryTests`**:
   - `setFlatFineAmount` with `.escalating` rule → throws `RulesRepositoryError.notFlatFine`. No mock client call made.
   - `setEnabled` happy path → mock client receives expected payload `{"enabled": Bool}`.

### B. Postgres tests (deno, `supabase/functions/_tests/`)

5. **`rule_mutation_audit.test.ts`**:
   - Apply migration 00024. INSERT a rule. UPDATE `enabled` flip → exactly 1 `system_events` row with `event_type='ruleEnabledChanged'`, payload `{rule_title, before, after}` correct.
   - UPDATE `consequences` → exactly 1 `ruleAmountChanged` row.
   - Combined UPDATE (`enabled` and `consequences` in same statement) → 2 rows emitted.
   - UPDATE that does NOT touch enabled or consequences (e.g., changes `title`) → 0 rows emitted (verifies `is distinct from` works as expected and trigger does not spam).

6. **`vote_unique_open.test.ts`**:
   - Apply migration 00025. INSERT first open vote (`vote_type='rule_repeal'`, `reference_id=X`). Second INSERT same key → fails with unique violation.
   - Close first (`status='passed'`), retry second → succeeds.

### C. RLS / governance tests (deno)

7. **`can_modify_rules.test.ts`**:
   - Founder + governance.whoCanModifyRules='founder' → true.
   - Founder + governance='majorityVote' → false (must vote).
   - anyMember + governance='anyMember' → true.
   - anyMember + governance='founder' → false.
   - Host (non-founder) + governance='founder' → false.
   - Member with `active=false` but role='founder' → false (inactive membership does not qualify).
   - User who is not in the group at all → false.

8. **`rls_update_rules.test.ts`**: UPDATE rules.enabled as authenticated user via PostgREST:
   - Cases (a)/(c) above succeed.
   - Cases (b)/(d)/(e)/(f)/(g) fail with `42501 (insufficient_privilege)`.

### D. Manual QA checklist (in PR description, pre-merge)

9. EditRulesView pencil visible only when actor passes `.modifyRules`. Test 4 cases: (founder × founder-gov) ✓ visible; (member × founder-gov) ✗ hidden; (founder × majorityVote-gov) ✗ hidden; (member × anyMember-gov) ✓ visible.

10. Optimistic toggle: simulator with network throttled. Toggle UI flips immediately. After ~5s, reverts + toast shown.

11. Edit amount on flat rule → succeeds; GroupHistoryView shows "Jose editó la multa de una regla".

12. Try edit amount on escalating rule ("Tarde a evento") → row is read-only with explainer "Multas escalonadas se editan en una próxima versión."

13. Open repeal vote: tap "Archivar regla" → confirm → vote opens → return to EditRulesView → "Votación pendiente · cierra en 2d 4h" badge visible. Tap card → sheet shows pending banner; amount/toggle disabled; "Ver votación →" works.

14. Vote resolves passed (admin-close via SQL) → rule disappears from EditRulesView. Vote resolves rejected → badge disappears, rule editable again.

15. RLS denial path: alter governance via second authenticated client mid-session, retry edit → toast says "La gobernanza del grupo cambió. Tirá pull-to-refresh para ver los permisos actuales."

16. Empty-state-equivalent: group with all 5 presets enabled → list shows 5 active cards + the passive footer. Footer renders even without any disabled card present (do not assume disabled rows trigger the footer).

17. Defensive fallback: group seeded with **0 presets** (manually set up a test group) → empty state copy "Este grupo no tiene reglas configuradas." renders, and the Fase 5 footer is suppressed. Groups with 1–4 presets render their cards + the footer normally (do not trigger empty state).

18. CI: push → both `codegen.yml` and `ios-ci.yml` workflows green.

### Test coverage notes

- The `HistoryItemPresentation` arms for `ruleEnabledChanged` / `ruleAmountChanged` already shipped in `e266a16`. Test 2 confirms they render.
- `RuleSummaryFormatter` is not formally tested in V1 (snapshot tests deferred). Manual QA #11 / #12 indirectly verify the strings.

## Success Criteria

1. A founder of a `whoCanModifyRules='founder'` group can toggle a preset rule on/off and edit a flat fine amount via EditRulesView. Both actions emit the corresponding system_event visible in GroupHistoryView.
2. Archiving a rule opens a `rule_repeal` vote; the rule remains active until the vote resolves; the UI surfaces the pending state.
3. Members of `whoCanModifyRules='majorityVote'` groups see no pencil button. Their existing path of voting via the rule_repeal flow remains functional. (Add+Propose flow for these groups is an explicit Fase 5 follow-up, not a V1 deliverable.)
4. RLS test 8 demonstrates the security boundary holds: tampered clients cannot bypass governance to UPDATE rules.
5. Roadmap §3 Fase 0 item #5's first checkbox (`EditRulesView`) marked done after all manual QA items pass and CI is green.

## Follow-ups for Fase 5

- Visual rule builder composer (WHEN/IF/THEN with typed pickers).
- Edit name, description, trigger, conditions of existing rules.
- Edit escalating fine breakdown (`baseAmount`, `stepAmount`, `stepMinutes`).
- "Archive + Propose new" flow for `majorityVote` / `supermajorityVote` groups (the current V1 gap).
- "Crear regla custom" entry point becoming functional (replaces the passive footer).
- Realtime governance revocation (5.2 mid-session live revoke).
- Multi-locale `RuleSummaryFormatter` (en-US, es-MX-variants, etc.).
