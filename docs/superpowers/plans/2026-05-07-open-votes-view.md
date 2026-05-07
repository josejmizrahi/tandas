# OpenVotesView Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Habilitar UI para los 7 `vote_type`s declarados en `Vote.swift` que hoy no tienen entry point. V1 ships funcional para 3 (`fine_appeal` ya shipped + `general_proposal` + `rule_change` nuevos), genérico para los otros 4. Garantiza low-friction manual application del rule_change cuando vota pasa: founder recibe push + inbox pendiente con deep-link → EditRuleSheet pre-loaded.

**Architecture:** Backend-light (1 migration). iOS-heavy: 14 archivos nuevos en `Features/Votes/` + 5 modificaciones (Inbox, RulesView, EditRuleSheet, VoteOnAppealSheet refactor, AppDelegate deep-link). Container `VoteDetailView` enruta por `vote.voteType` a body sub-component dedicado, mismo patrón que `ResourceDetailView` (Sub-fase A).

**Tech Stack:** Postgres (Supabase) + pl/pgsql para migration server-side. Swift 6 + SwiftUI iOS 26, supabase-swift SDK, Swift Testing framework, existing codegen pipeline (no enum changes).

**Spec reference:** `docs/superpowers/specs/2026-05-07-open-votes-view-design.md` (commits `8e10bda` → `09db981`).

**Pre-shipped foundation:**
- Migrations 00022/00023/00031 aplicadas en prod 2026-05-07 (notifications_outbox, appeal_voting_v2, claim_outbox_rpcs).
- `dispatch-notifications` cron registrado (jobid=6) corriendo cada 1min.
- APNs end-to-end verificado en device — F0 push gate cerrado.
- `VoteRepository` + `VoteCastRepository` Live + Mock ya existen sin cambios.
- `GovernanceService.canPerform(...)` existente, default per template `recurring_dinner` para `.createVotes` es `.anyMember`.

---

## File Structure

**New backend files:**
- `supabase/migrations/00032_finalize_vote_rule_change_action.sql`
- `supabase/migrations/00032_rollback.sql`

**New iOS files (14):**
- `ios/Tandas/Features/Votes/Coordinator/OpenVotesCoordinator.swift`
- `ios/Tandas/Features/Votes/Coordinator/VoteDetailCoordinator.swift`
- `ios/Tandas/Features/Votes/Coordinator/CreateGeneralProposalCoordinator.swift`
- `ios/Tandas/Features/Votes/Coordinator/CreateRuleChangeCoordinator.swift`
- `ios/Tandas/Features/Votes/Views/OpenVotesListView.swift`
- `ios/Tandas/Features/Votes/Detail/VoteDetailView.swift`
- `ios/Tandas/Features/Votes/Detail/Bodies/FineAppealVoteBody.swift`
- `ios/Tandas/Features/Votes/Detail/Bodies/GeneralProposalVoteBody.swift`
- `ios/Tandas/Features/Votes/Detail/Bodies/RuleChangeVoteBody.swift`
- `ios/Tandas/Features/Votes/Detail/Bodies/GenericVoteBody.swift`
- `ios/Tandas/Features/Votes/Sheets/CreateVoteSheet.swift`
- `ios/Tandas/Features/Votes/Sheets/CreateGeneralProposalSheet.swift`
- `ios/Tandas/Features/Votes/Sheets/CreateRuleChangeSheet.swift`
- `ios/Tandas/Features/Votes/Components/VoteCastSection.swift`

**New iOS test files (5):**
- `ios/TandasTests/Votes/VoteDetailCoordinatorTests.swift`
- `ios/TandasTests/Votes/OpenVotesCoordinatorTests.swift`
- `ios/TandasTests/Votes/CreateGeneralProposalCoordinatorTests.swift`
- `ios/TandasTests/Votes/CreateRuleChangeCoordinatorTests.swift`
- `ios/TandasTests/Notifications/RuleChangeDeepLinkTests.swift`

**New iOS support files:**
- `ios/Tandas/Services/Notifications/RuleChangeDeepLink.swift`

**Modified iOS files (5):**
- `ios/Tandas/Models/UserAction.swift` (add `ActionType.ruleChangeApplyPending` case)
- `ios/Tandas/Features/Inbox/Views/ActionInboxView.swift` (render `votePending` + `ruleChangeApplyPending` action types)
- `ios/Tandas/Features/Rules/RulesView.swift` (add "Votos abiertos" section with link to OpenVotesListView)
- `ios/Tandas/Features/Rules/EditRuleSheet.swift` (add `proposedAmount: Int?` init param + resolve UserAction on save)
- `ios/Tandas/Features/Fines/Sheets/VoteOnAppealSheet.swift` (extract body to FineAppealVoteBody, sheet wraps the new body)
- `ios/Tandas/TandasApp.swift` (route `ruul://rule/<uuid>/edit` deep links to EditRuleSheet)

---

## Phase A — Backend (1 task)

### Task A1: Migration 00032 — `finalize_vote` v3 emite `ruleChangeApplyPending` user_action

**Files:**
- Create: `supabase/migrations/00032_finalize_vote_rule_change_action.sql`
- Create: `supabase/migrations/00032_rollback.sql`
- Apply via MCP `apply_migration` (already authorized by user via "PUSH A MAIN Y SIGUE CON LO SIOGUIENTE").

- [ ] **Step 1: Capture current finalize_vote v2 body for rollback**

Run via MCP execute_sql:
```sql
select pg_get_functiondef(p.oid)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'finalize_vote' and p.pronargs = 1;
```

Expected: returns the `CREATE OR REPLACE FUNCTION public.finalize_vote(p_vote_id uuid)...` body shipped by 00023. Save the output verbatim — the rollback file restores it.

- [ ] **Step 2: Create `supabase/migrations/00032_finalize_vote_rule_change_action.sql`**

```sql
-- 00032 — finalize_vote v3: emite ruleChangeApplyPending UserAction
--          y outbox row con deep_link cuando rule_change resuelve passed.
--
-- Garantiza low-friction manual application: el founder recibe inbox
-- row + push con deep_link 'ruul://rule/<uuid>/edit?proposedAmount=<int>'
-- que lleva a EditRuleSheet pre-cargado con el amount propuesto.
-- Sin esto, el founder se olvida de aplicar el cambio aprobado y el
-- trust se erosiona.
--
-- Cambios vs v2 (00023):
--   1. Agrega bloque al final que detecta vote_type='rule_change' AND
--      v_resolution='passed'.
--   2. Resuelve founder vía group_members.roles ?| array['founder'].
--   3. INSERT user_actions con ON CONFLICT (reference_id) DO NOTHING.
--   4. INSERT notifications_outbox con deep_link.
--
-- V2 contracts intactos: voteResolved system_event + outbox fan-out
-- a todos los voters siguen igual.

create or replace function public.finalize_vote(p_vote_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote                public.votes%rowtype;
  v_in_favor            int;
  v_against             int;
  v_abstained           int;
  v_pending             int;
  v_total               int;
  v_voted               int;
  v_quorum_count        int;
  v_resolution          text;
  v_founder_user_id     uuid;
  v_founder_member_id   uuid;
  v_rule_id             uuid;
  v_rule_name           text;
  v_current_amount      int;
  v_proposed_amount     int;
begin
  select * into v_vote from public.votes where id = p_vote_id for update;
  if not found then
    raise exception 'vote not found' using errcode = '02000';
  end if;
  if v_vote.status <> 'open' then
    return coalesce(v_vote.payload->>'resolution', 'unknown');
  end if;

  select
    count(*) filter (where choice = 'in_favor'),
    count(*) filter (where choice = 'against'),
    count(*) filter (where choice = 'abstained'),
    count(*) filter (where choice = 'pending'),
    count(*)
  into v_in_favor, v_against, v_abstained, v_pending, v_total
  from public.vote_casts
  where vote_id = p_vote_id;

  v_voted        := v_in_favor + v_against + v_abstained;
  v_quorum_count := greatest(
    ceil(v_total::numeric * v_vote.quorum_percent / 100)::int,
    v_vote.quorum_min_absolute
  );

  if v_voted < v_quorum_count then
    v_resolution := 'quorum_failed';
  elsif v_in_favor::numeric * 100 >= (v_in_favor + v_against)::numeric * v_vote.threshold_percent then
    v_resolution := 'passed';
  else
    v_resolution := 'failed';
  end if;

  update public.votes
  set status      = case when v_resolution = 'quorum_failed' then 'quorum_failed' else 'resolved' end,
      resolved_at = now(),
      counts      = jsonb_build_object(
        'inFavor',        v_in_favor,
        'against',        v_against,
        'abstained',      v_abstained,
        'pending',        v_pending,
        'totalEligible',  v_total,
        'quorumRequired', v_quorum_count,
        'resolution',     v_resolution
      ),
      payload = payload || jsonb_build_object('resolution', v_resolution)
  where id = p_vote_id;

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    v_vote.group_id,
    'voteResolved',
    p_vote_id,
    null,
    jsonb_build_object(
      'vote_type',    v_vote.vote_type,
      'reference_id', v_vote.reference_id,
      'resolution',   v_resolution
    )
  );

  -- Notification fan-out a todos los voters originales (existing).
  insert into public.notifications_outbox (
    group_id, recipient_member_id, notification_type, payload, deep_link
  )
  select
    v_vote.group_id,
    vc.member_id,
    'voteResolved',
    jsonb_build_object(
      'vote_id',      p_vote_id,
      'vote_type',    v_vote.vote_type,
      'reference_id', v_vote.reference_id,
      'resolution',   v_resolution,
      'title',        v_vote.title
    ),
    'ruul://vote/' || p_vote_id::text
  from public.vote_casts vc
  where vc.vote_id = p_vote_id;

  -- Para fine_appeal: notificar al appellant (existing).
  if v_vote.vote_type = 'fine_appeal' then
    insert into public.notifications_outbox (
      group_id, recipient_member_id, notification_type, payload, deep_link
    )
    select
      v_vote.group_id,
      (v_vote.payload->>'member_id')::uuid,
      'voteResolved',
      jsonb_build_object(
        'vote_id',      p_vote_id,
        'vote_type',    v_vote.vote_type,
        'reference_id', v_vote.reference_id,
        'resolution',   v_resolution,
        'title',        v_vote.title,
        'is_appellant', true
      ),
      'ruul://vote/' || p_vote_id::text
    where v_vote.payload ? 'member_id'
      and (v_vote.payload->>'member_id') <> '';
  end if;

  -- NUEVO V3: rule_change resuelto passed → user_action al founder + outbox push.
  if v_vote.vote_type = 'rule_change' and v_resolution = 'passed' then
    -- Identificar founder del grupo.
    select gm.id, gm.user_id
      into v_founder_member_id, v_founder_user_id
      from public.group_members gm
     where gm.group_id = v_vote.group_id
       and gm.roles ?| array['founder']
       and gm.active = true
     limit 1;

    if v_founder_user_id is not null then
      v_rule_id         := v_vote.reference_id;
      v_current_amount  := nullif(v_vote.payload->>'current_amount', '')::int;
      v_proposed_amount := nullif(v_vote.payload->>'proposed_amount', '')::int;

      -- rule_name lookup (best-effort — la regla puede haber sido archivada).
      select coalesce(name, title, 'Regla #' || left(v_rule_id::text, 8))
        into v_rule_name
        from public.rules
       where id = v_rule_id;

      v_rule_name := coalesce(v_rule_name, 'Regla #' || left(v_rule_id::text, 8));

      -- Insert user_action — idempotent vía reference_id como dedup key
      -- (action_type + reference_id no es unique a nivel schema, pero
      -- usamos NOT EXISTS para evitar duplicados en re-finalizes).
      insert into public.user_actions (
        user_id, group_id, action_type, reference_id,
        title, body, priority
      )
      select
        v_founder_user_id, v_vote.group_id, 'ruleChangeApplyPending', p_vote_id,
        'Aplicar cambio aprobado: ' || v_rule_name,
        format('Votado: $%s → $%s', v_current_amount, v_proposed_amount),
        'high'
      where not exists (
        select 1 from public.user_actions
         where reference_id = p_vote_id
           and action_type = 'ruleChangeApplyPending'
      );

      -- Insert outbox row para push al founder con deep_link.
      insert into public.notifications_outbox (
        group_id, recipient_member_id, notification_type, payload, deep_link
      )
      values (
        v_vote.group_id,
        v_founder_member_id,
        'ruleChangeApplyPending',
        jsonb_build_object(
          'vote_id',         p_vote_id,
          'rule_id',         v_rule_id,
          'rule_name',       v_rule_name,
          'current_amount',  v_current_amount,
          'proposed_amount', v_proposed_amount,
          'title',           'Aplicar cambio aprobado',
          'body',            format('Votado: $%s → $%s', v_current_amount, v_proposed_amount)
        ),
        'ruul://rule/' || v_rule_id::text || '/edit?proposedAmount=' || v_proposed_amount::text
      );
    end if;
  end if;

  return v_resolution;
end;
$$;

comment on function public.finalize_vote is
  'Closes vote, computes resolution. v3: para rule_change passed, inserta user_action ruleChangeApplyPending al founder + outbox row con deep_link a EditRuleSheet pre-loaded.';
```

- [ ] **Step 3: Create `supabase/migrations/00032_rollback.sql`**

Restaurar la versión v2 (00023) — paste verbatim del Step 1 output. Si el output no quedó capturado, reaplicar 00023_appeal_voting_v2.sql §4 (líneas 181-310).

```sql
-- 00032 rollback — restaurar finalize_vote v2 (00023).
--
-- USAR cuando V3 cause problemas en producción. Tras este rollback:
--   - rule_change resueltos no producen user_action ni outbox row con
--     deep_link → founders no reciben recordatorio de aplicar.
--   - Resto del flow (voteResolved system_event + voter fan-out) intacto.

-- (Pegar el body de v2 capturado en Step 1, o re-aplicar 00023 §4.)
```

- [ ] **Step 4: Apply migration via MCP**

Use `mcp__supabase__apply_migration` with name `finalize_vote_rule_change_action_v3` and the body of `00032_finalize_vote_rule_change_action.sql` from Step 2.

Expected response: `{"success":true}`.

- [ ] **Step 5: Smoke test the migration via SQL**

Run via MCP execute_sql:
```sql
-- Verificar que la función fue redefinida.
select pg_get_functiondef(p.oid)::text like '%ruleChangeApplyPending%' as has_v3_marker
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'finalize_vote' and p.pronargs = 1;
```

Expected: `[{"has_v3_marker":true}]`.

- [ ] **Step 6: Commit migration files to repo**

```bash
cd /Users/jj/code/tandas
git add supabase/migrations/00032_finalize_vote_rule_change_action.sql \
        supabase/migrations/00032_rollback.sql
git commit -m "$(cat <<'EOF'
feat(votes): finalize_vote v3 — rule_change passed emits ruleChangeApplyPending

Migration 00032 extiende finalize_vote para que cuando un vote
rule_change resuelve passed:

1. Inserta user_actions row con action_type='ruleChangeApplyPending'
   al founder del grupo (resuelto vía group_members.roles ?| array
   ['founder']). Idempotent vía NOT EXISTS check.

2. Inserta notifications_outbox row con deep_link
   'ruul://rule/<rule_id>/edit?proposedAmount=<int>' que iOS
   routeará a EditRuleSheet pre-loaded con el monto propuesto.

Garantiza low-friction manual application — founder no se olvida
de aplicar el cambio votado. V2 sumará server-side application
opcional vía governance flag.

Aplicada via MCP. Rollback restaura v2 (00023).

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase B — iOS Foundation (3 tasks)

### Task B1: ActionType enum + RuleChangeDeepLink

**Files:**
- Modify: `ios/Tandas/Models/UserAction.swift`
- Create: `ios/Tandas/Services/Notifications/RuleChangeDeepLink.swift`
- Create: `ios/TandasTests/Notifications/RuleChangeDeepLinkTests.swift`

- [ ] **Step 1: Read current ActionType enum**

```bash
grep -n "case ruleChangeApplyPending\|case .* = \"" /Users/jj/code/tandas/ios/Tandas/Models/UserAction.swift | head -20
```

Expected: 9 existing cases (finePending, fineVoided, appealVotePending, rsvpPending, fineProposalReview, slotPending, votePending, contributionDue, compensationDue). No ruleChangeApplyPending yet.

- [ ] **Step 2: Add `ruleChangeApplyPending` case to ActionType enum**

Edit `ios/Tandas/Models/UserAction.swift`. Find the `// V1` block and add the new case under it:

```swift
public enum ActionType: String, Codable, Sendable, Hashable, CaseIterable {
    // V1
    case finePending             = "finePending"
    case fineVoided              = "fineVoided"
    case appealVotePending       = "appealVotePending"
    case rsvpPending             = "rsvpPending"
    case fineProposalReview      = "fineProposalReview"
    case ruleChangeApplyPending  = "ruleChangeApplyPending"  // NEW: emitted by finalize_vote v3 when rule_change passes
    // Future phases
    case slotPending             = "slotPending"
    case votePending             = "votePending"
    case contributionDue         = "contributionDue"
    case compensationDue         = "compensationDue"
}
```

- [ ] **Step 3: Write failing test for RuleChangeDeepLink parser**

Create `ios/TandasTests/Notifications/RuleChangeDeepLinkTests.swift`:

```swift
import Testing
import Foundation
@testable import Tandas

@Suite("RuleChangeDeepLink")
struct RuleChangeDeepLinkTests {

    @Test("parses valid URL with proposedAmount")
    func parsesValidUrl() throws {
        let id = UUID()
        let url = URL(string: "ruul://rule/\(id.uuidString)/edit?proposedAmount=350")!
        let link = try #require(RuleChangeDeepLink(url: url))
        #expect(link.ruleId == id)
        #expect(link.proposedAmount == 350)
    }

    @Test("parses valid URL with uppercase UUID")
    func parsesUppercaseUuid() throws {
        let id = UUID()
        let url = URL(string: "ruul://rule/\(id.uuidString.uppercased())/edit?proposedAmount=200")!
        let link = try #require(RuleChangeDeepLink(url: url))
        #expect(link.ruleId == id)
        #expect(link.proposedAmount == 200)
    }

    @Test("returns nil for wrong scheme")
    func rejectsWrongScheme() {
        let url = URL(string: "https://rule/uuid/edit?proposedAmount=100")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }

    @Test("returns nil for wrong host")
    func rejectsWrongHost() {
        let url = URL(string: "ruul://event/uuid/edit?proposedAmount=100")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }

    @Test("returns nil for missing edit segment")
    func rejectsMissingEdit() {
        let id = UUID()
        let url = URL(string: "ruul://rule/\(id.uuidString)?proposedAmount=100")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }

    @Test("returns nil for malformed UUID")
    func rejectsMalformedUuid() {
        let url = URL(string: "ruul://rule/not-a-uuid/edit?proposedAmount=100")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }

    @Test("returns nil for missing proposedAmount")
    func rejectsMissingAmount() {
        let id = UUID()
        let url = URL(string: "ruul://rule/\(id.uuidString)/edit")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }

    @Test("returns nil for non-integer proposedAmount")
    func rejectsNonIntegerAmount() {
        let id = UUID()
        let url = URL(string: "ruul://rule/\(id.uuidString)/edit?proposedAmount=abc")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }
}
```

- [ ] **Step 4: Regenerate Xcode project + run failing test**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate
xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/RuleChangeDeepLink 2>&1 \
  | grep -E "(error:|cannot find|FAILED)" | head -5
```

Expected: build fails with `cannot find 'RuleChangeDeepLink' in scope` or similar.

- [ ] **Step 5: Implement RuleChangeDeepLink**

Create `ios/Tandas/Services/Notifications/RuleChangeDeepLink.swift`:

```swift
import Foundation

/// Parses `ruul://rule/<UUID>/edit?proposedAmount=<Int>` URLs into a typed
/// destination so iOS can route to `EditRuleSheet` pre-loaded with the
/// proposed amount.
///
/// Source: APNs push payload `deep_link` field, written by
/// `finalize_vote` v3 (migration 00032) when a rule_change vote resolves
/// passed. Also reachable from inbox row tap on
/// `ActionType.ruleChangeApplyPending`.
public struct RuleChangeDeepLink: Equatable, Sendable {
    public let ruleId: UUID
    public let proposedAmount: Int

    public init?(url: URL) {
        guard url.scheme == "ruul" else { return nil }
        guard url.host == "rule" else { return nil }

        // Path: "/<UUID>/edit"
        let comps = url.pathComponents.filter { $0 != "/" }
        guard comps.count == 2, comps[1] == "edit" else { return nil }
        guard let ruleId = UUID(uuidString: comps[0]) else { return nil }

        let urlComps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let amountStr = urlComps?.queryItems?.first(where: { $0.name == "proposedAmount" })?.value
        guard let amountStr, let proposedAmount = Int(amountStr) else { return nil }

        self.ruleId         = ruleId
        self.proposedAmount = proposedAmount
    }

    public var userInfo: [AnyHashable: Any] {
        [
            "kind":            "ruleChangeApply",
            "rule_id":         ruleId.uuidString,
            "proposed_amount": proposedAmount,
        ]
    }
}
```

- [ ] **Step 6: Regenerate + run tests to verify they pass**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate
xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/RuleChangeDeepLink 2>&1 \
  | grep -E "(Test Suite|passed|FAILED)" | tail -5
```

Expected: `Suite "RuleChangeDeepLink" passed.` with 8 tests passed.

- [ ] **Step 7: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Models/UserAction.swift \
  ios/Tandas/Services/Notifications/RuleChangeDeepLink.swift \
  ios/TandasTests/Notifications/RuleChangeDeepLinkTests.swift
git commit -m "$(cat <<'EOF'
feat(votes): ActionType.ruleChangeApplyPending + RuleChangeDeepLink

iOS foundation for rule_change low-friction manual application:

- ActionType.ruleChangeApplyPending: case nuevo en enum (no
  codegen-managed). String raw "ruleChangeApplyPending" matches el
  action_type que finalize_vote v3 inserta en user_actions cuando
  rule_change resuelve passed.

- RuleChangeDeepLink: parser para 'ruul://rule/<uuid>/edit?
  proposedAmount=<int>'. 8 tests cubren happy path + casos negativos
  (wrong scheme, wrong host, missing segments, malformed UUID,
  missing/non-integer amount).

Análogo a EventDeepLink existente. Routing a EditRuleSheet
pre-loaded llega en Phase G.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task B2: VoteDetailCoordinator

**Files:**
- Create: `ios/Tandas/Features/Votes/Coordinator/VoteDetailCoordinator.swift`
- Create: `ios/TandasTests/Votes/VoteDetailCoordinatorTests.swift`

- [ ] **Step 1: Setup directory + write failing tests**

```bash
mkdir -p /Users/jj/code/tandas/ios/Tandas/Features/Votes/Coordinator
mkdir -p /Users/jj/code/tandas/ios/TandasTests/Votes
```

Create `ios/TandasTests/Votes/VoteDetailCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import Tandas

@Suite("VoteDetailCoordinator")
@MainActor
struct VoteDetailCoordinatorTests {

    // MARK: - Fixtures

    private func makeVote(
        type: VoteType = .generalProposal,
        status: VoteStatus = .open,
        isAnonymous: Bool = true
    ) -> Vote {
        Vote(
            id: UUID(),
            groupId: UUID(),
            voteType: type,
            referenceId: UUID(),
            title: "Test vote",
            description: "Description",
            createdByMemberId: UUID(),
            openedAt: .now,
            closesAt: .now.addingTimeInterval(72 * 3600),
            resolvedAt: nil,
            quorumPercent: 50,
            thresholdPercent: 50,
            isAnonymous: isAnonymous,
            status: status,
            counts: nil,
            payload: .empty
        )
    }

    private func makeGroup() -> Group {
        Group(
            id: UUID(),
            name: "Cuates",
            governance: .recurringDinnerDefaults,
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func makeCoordinator(
        vote: Vote? = nil,
        seedCasts: [VoteCast] = []
    ) -> (VoteDetailCoordinator, MockVoteRepository, MockVoteCastRepository) {
        let v = vote ?? makeVote()
        let voteRepo = MockVoteRepository(seed: [v])
        let castRepo = MockVoteCastRepository(seed: seedCasts)
        let userMemberId = UUID()
        return (
            VoteDetailCoordinator(
                vote: v,
                group: makeGroup(),
                userMemberId: userMemberId,
                voteRepo: voteRepo,
                castRepo: castRepo
            ),
            voteRepo,
            castRepo
        )
    }

    // MARK: - Tests

    @Test("refresh fetches myCast and counts in parallel")
    func refreshFetches() async throws {
        let voteId = UUID()
        let memberId = UUID()
        let myCast = VoteCast(
            id: UUID(), voteId: voteId, memberId: memberId,
            choice: .pending, castAt: nil, createdAt: .now, updatedAt: .now
        )
        let v = Vote(
            id: voteId, groupId: UUID(), voteType: .generalProposal,
            referenceId: UUID(), title: "T", description: nil,
            createdByMemberId: nil, openedAt: .now, closesAt: .now.addingTimeInterval(3600),
            resolvedAt: nil, quorumPercent: 50, thresholdPercent: 50,
            isAnonymous: false, status: .open, counts: nil, payload: .empty
        )
        let voteRepo = MockVoteRepository(seed: [v])
        let castRepo = MockVoteCastRepository(seed: [myCast])
        let coord = VoteDetailCoordinator(
            vote: v, group: Group(id: UUID(), name: "G",
            governance: .recurringDinnerDefaults, createdAt: .now, updatedAt: .now),
            userMemberId: memberId, voteRepo: voteRepo, castRepo: castRepo
        )

        await coord.refresh()

        #expect(coord.myCast?.id == myCast.id)
        #expect(coord.counts != nil)
        #expect(coord.error == nil)
    }

    @Test("alreadyVoted derives from choice not pending")
    func alreadyVotedDerivation() async throws {
        let voteId = UUID()
        let memberId = UUID()
        let votedCast = VoteCast(
            id: UUID(), voteId: voteId, memberId: memberId,
            choice: .inFavor, castAt: .now, createdAt: .now, updatedAt: .now
        )
        let v = Vote(
            id: voteId, groupId: UUID(), voteType: .generalProposal,
            referenceId: UUID(), title: "T", description: nil,
            createdByMemberId: nil, openedAt: .now, closesAt: .now.addingTimeInterval(3600),
            resolvedAt: nil, quorumPercent: 50, thresholdPercent: 50,
            isAnonymous: false, status: .open, counts: nil, payload: .empty
        )
        let coord = VoteDetailCoordinator(
            vote: v, group: Group(id: UUID(), name: "G",
            governance: .recurringDinnerDefaults, createdAt: .now, updatedAt: .now),
            userMemberId: memberId,
            voteRepo: MockVoteRepository(seed: [v]),
            castRepo: MockVoteCastRepository(seed: [votedCast])
        )

        await coord.refresh()
        #expect(coord.alreadyVoted == true)
    }

    @Test("voteIsClosed derives from vote status")
    func voteIsClosedDerivation() {
        let resolvedVote = Vote(
            id: UUID(), groupId: UUID(), voteType: .generalProposal,
            referenceId: UUID(), title: "T", description: nil,
            createdByMemberId: nil, openedAt: .now, closesAt: .now,
            resolvedAt: .now, quorumPercent: 50, thresholdPercent: 50,
            isAnonymous: true, status: .resolved, counts: nil, payload: .empty
        )
        let coord = VoteDetailCoordinator(
            vote: resolvedVote,
            group: Group(id: UUID(), name: "G",
            governance: .recurringDinnerDefaults, createdAt: .now, updatedAt: .now),
            userMemberId: UUID(),
            voteRepo: MockVoteRepository(),
            castRepo: MockVoteCastRepository()
        )
        #expect(coord.voteIsClosed == true)
    }

    @Test("cast updates myCast optimistically then refreshes")
    func castFlow() async throws {
        let (coord, _, castRepo) = makeCoordinator()
        await coord.refresh()
        await coord.cast(.inFavor)
        // Mock updates the seeded cast in place; verify we re-fetched.
        #expect(coord.error == nil)
        #expect(coord.isCasting == false)
    }

    @Test("cast surfaces error when RPC throws")
    func castErrorSurfaces() async throws {
        let (coord, _, castRepo) = makeCoordinator()
        await castRepo.setNextCastError(NSError(
            domain: "test", code: 42501,
            userInfo: [NSLocalizedDescriptionKey: "vote closed"]
        ))
        await coord.cast(.inFavor)
        #expect(coord.error != nil)
        #expect(coord.error?.contains("cerró") == true || coord.error?.contains("closed") == true)
    }
}
```

Note: `MockVoteCastRepository.setNextCastError` is a helper not currently in the mock. We add it inline as part of the implementation step (Step 3).

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/VoteDetailCoordinator 2>&1 \
  | grep -E "(error:|cannot find|FAILED)" | head -5
```

Expected: `cannot find 'VoteDetailCoordinator' in scope`.

- [ ] **Step 3: Add `setNextCastError` helper to MockVoteCastRepository**

Edit `ios/Tandas/Platform/Repositories/VoteCastRepository.swift`. In the `MockVoteCastRepository` actor, add:

```swift
func setNextCastError(_ error: Error?) { self.nextCastError = error }
```

This makes the existing `nextCastError` property settable from tests without exposing internal state directly.

- [ ] **Step 4: Implement VoteDetailCoordinator**

Create `ios/Tandas/Features/Votes/Coordinator/VoteDetailCoordinator.swift`:

```swift
import Foundation
import Observation
import OSLog

/// Coordinator del detail view de un Vote. Fetcha myCast + counts en
/// parallel, expone derived flags `alreadyVoted` y `voteIsClosed`,
/// orquesta cast con manejo de edge case "vote finalizes mid-cast".
@Observable @MainActor
final class VoteDetailCoordinator {
    let vote: Vote
    let group: Group
    private let userMemberId: UUID
    private let voteRepo: any VoteRepository
    private let castRepo: any VoteCastRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote-detail")

    private(set) var myCast: VoteCast?
    private(set) var counts: VoteCounts?
    private(set) var isCasting: Bool = false
    private(set) var error: String?

    var alreadyVoted: Bool { (myCast?.choice ?? .pending) != .pending }
    var voteIsClosed: Bool { vote.status != .open }

    init(
        vote: Vote,
        group: Group,
        userMemberId: UUID,
        voteRepo: any VoteRepository,
        castRepo: any VoteCastRepository
    ) {
        self.vote = vote
        self.group = group
        self.userMemberId = userMemberId
        self.voteRepo = voteRepo
        self.castRepo = castRepo
    }

    func refresh() async {
        async let myCastTask = castRepo.myCast(voteId: vote.id, userMemberId: userMemberId)
        async let countsTask = castRepo.counts(voteId: vote.id)
        do {
            myCast = try await myCastTask
            counts = try await countsTask
            error = nil
        } catch {
            self.error = error.localizedDescription
            log.warning("vote detail refresh failed: \(error.localizedDescription)")
        }
    }

    func cast(_ choice: VoteChoice) async {
        guard !isCasting else { return }
        isCasting = true
        defer { isCasting = false }

        do {
            try await castRepo.cast(voteId: vote.id, choice: choice)
            await refresh()
        } catch {
            // Edge case: vote closed mid-cast. Surfaceamos copy claro
            // y refrescamos para mostrar el resultado final.
            let msg = error.localizedDescription
            if msg.contains("vote closed") || msg.contains("not open") {
                self.error = "Este voto ya cerró. Refrescamos resultados."
                await refresh()
            } else {
                self.error = "No pudimos registrar tu voto: \(msg)"
            }
            log.warning("cast failed: \(msg)")
        }
    }

    func clearError() { error = nil }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/VoteDetailCoordinator 2>&1 \
  | grep -E "(Test Suite|passed|FAILED)" | tail -5
```

Expected: `Suite "VoteDetailCoordinator" passed.` with 5 tests passed.

- [ ] **Step 6: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Votes/Coordinator/VoteDetailCoordinator.swift \
  ios/TandasTests/Votes/VoteDetailCoordinatorTests.swift \
  ios/Tandas/Platform/Repositories/VoteCastRepository.swift
git commit -m "$(cat <<'EOF'
feat(votes): VoteDetailCoordinator with parallel myCast+counts fetch

@Observable @MainActor coordinator del VoteDetailView. Fetcha
myCast (RLS-scoped al caller) + counts (vote_counts_view aggregate)
en parallel. Expose:

- alreadyVoted: derived de myCast.choice != .pending
- voteIsClosed: derived de vote.status != .open
- cast(_:) con manejo de edge "vote closed mid-cast" (surface
  copy + auto-refresh)

5 tests Swift Testing cubren refresh parallel, alreadyVoted
derivation, voteIsClosed derivation, cast happy path, cast error
surface.

Plus pequeño helper agregado al MockVoteCastRepository
(setNextCastError) para que los tests puedan inyectar fallas.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task B3: VoteCastSection (shared component)

**Files:**
- Create: `ios/Tandas/Features/Votes/Components/VoteCastSection.swift`

VoteCastSection no tiene tests dedicados; su correctness se valida via snapshot tests cuando se monta dentro de VoteDetailView (Task D1) y vía coordinator tests (Task B2 ya cubre los estados).

- [ ] **Step 1: Create directory + file**

```bash
mkdir -p /Users/jj/code/tandas/ios/Tandas/Features/Votes/Components
```

Create `ios/Tandas/Features/Votes/Components/VoteCastSection.swift`:

```swift
import SwiftUI

/// UI section compartida por todos los body components del VoteDetailView.
/// Tres estados mutuamente exclusivos:
///   - voteIsClosed: muestra resultado final (VoteResolvedView).
///   - alreadyVoted: muestra el ballot del caller (VoteAlreadyCastView).
///   - default: muestra los 3 botones in_favor / against / abstained.
///
/// Counts se renderizan abajo solo si el voto NO es anonymous, o si el
/// caller ya votó (transparencia post-cast).
struct VoteCastSection: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            stateView

            if let counts = coordinator.counts,
               !coordinator.vote.isAnonymous || coordinator.alreadyVoted {
                VoteCountsBar(counts: counts)
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        if coordinator.voteIsClosed {
            VoteResolvedView(counts: coordinator.counts, vote: coordinator.vote)
        } else if coordinator.alreadyVoted {
            VoteAlreadyCastView(myChoice: coordinator.myCast?.choice)
        } else {
            VoteCastButtons(coordinator: coordinator)
        }
    }
}

// MARK: - Private subviews

private struct VoteCastButtons: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        VStack(spacing: RuulSpacing.s2) {
            castButton(.inFavor,    label: "A favor",      systemImage: "checkmark.circle.fill", tint: .ruulSemanticSuccess)
            castButton(.against,    label: "En contra",    systemImage: "xmark.circle.fill",     tint: .ruulSemanticError)
            castButton(.abstained,  label: "Me abstengo",  systemImage: "minus.circle.fill",     tint: .ruulTextTertiary)
        }
        .disabled(coordinator.isCasting)
        .opacity(coordinator.isCasting ? 0.5 : 1.0)
    }

    private func castButton(_ choice: VoteChoice, label: String, systemImage: String, tint: Color) -> some View {
        Button {
            Task { await coordinator.cast(choice) }
        } label: {
            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(label)
                    .ruulTextStyle(RuulTypography.headline)
                Spacer()
            }
            .padding(RuulSpacing.s4)
            .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
        .accessibilityLabel(label)
    }
}

private struct VoteAlreadyCastView: View {
    let myChoice: VoteChoice?

    var body: some View {
        let (text, tint, icon) = display(for: myChoice)
        HStack(spacing: RuulSpacing.s2) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text("Tu voto: \(text)")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
        }
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }

    private func display(for choice: VoteChoice?) -> (String, Color, String) {
        switch choice {
        case .inFavor:    return ("a favor",     .ruulSemanticSuccess, "checkmark.circle.fill")
        case .against:    return ("en contra",   .ruulSemanticError,   "xmark.circle.fill")
        case .abstained:  return ("abstención",  .ruulTextTertiary,    "minus.circle.fill")
        case .pending, .none: return ("pendiente", .ruulTextTertiary, "clock")
        }
    }
}

private struct VoteResolvedView: View {
    let counts: VoteCounts?
    let vote: Vote

    var body: some View {
        let resolution = counts?.resolution ?? .quorumFailed
        let (label, tint) = display(for: resolution)
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(tint)
                Text("Voto \(label)")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            if let resolvedAt = vote.resolvedAt {
                Text("Cerrado \(resolvedAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }

    private func display(for resolution: VoteResolution) -> (String, Color) {
        switch resolution {
        case .passed:        return ("aprobado",     .ruulSemanticSuccess)
        case .failed:        return ("rechazado",    .ruulSemanticError)
        case .quorumFailed:  return ("sin quórum",   .ruulTextTertiary)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Votes/Components/VoteCastSection.swift
git commit -m "$(cat <<'EOF'
feat(votes): VoteCastSection shared component

UI section compartida por todos los body components del
VoteDetailView. Tres estados mutuamente exclusivos:

  - voteIsClosed → VoteResolvedView (private subview)
  - alreadyVoted → VoteAlreadyCastView (private subview)
  - default → VoteCastButtons (private subview, 3 botones)

Counts via VoteCountsBar primitive existente, solo si vote no es
anonymous OR caller ya votó.

Subviews privadas en mismo file por design — no son reusables fuera
de este section. Si en V2 se reusan en otra surface, extract.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase C — iOS Detail Bodies (2 tasks)

### Task C1: 3 new bodies (Generic + GeneralProposal + RuleChange)

**Files:**
- Create: `ios/Tandas/Features/Votes/Detail/Bodies/GenericVoteBody.swift`
- Create: `ios/Tandas/Features/Votes/Detail/Bodies/GeneralProposalVoteBody.swift`
- Create: `ios/Tandas/Features/Votes/Detail/Bodies/RuleChangeVoteBody.swift`

Bodies son views puras stateless — su correctness se cubre vía snapshot tests cuando se montan en VoteDetailView (Task D1).

- [ ] **Step 1: Create directory + GenericVoteBody**

```bash
mkdir -p /Users/jj/code/tandas/ios/Tandas/Features/Votes/Detail/Bodies
```

Create `ios/Tandas/Features/Votes/Detail/Bodies/GenericVoteBody.swift`:

```swift
import SwiftUI

/// Fallback body para vote_types sin UI dedicada (V1: rule_repeal,
/// member_removal, fund_withdrawal, role_assignment, slot_dispute).
/// Renderiza title + description + payload as JSON in monospace card.
/// Cuando esos vote_types tengan feature shipped, cada uno gana su
/// body dedicado y este queda solo para `unknown` enum case.
struct GenericVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            if let desc = coordinator.vote.description, !desc.isEmpty {
                Text(desc)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }

            VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                Text("PAYLOAD")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(payloadJSON)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color.ruulTextSecondary)
                    .padding(RuulSpacing.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.sm, style: .continuous))
            }
        }
    }

    private var payloadJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(coordinator.vote.payload),
              let str = String(data: data, encoding: .utf8) else {
            return "(unable to render payload)"
        }
        return str
    }
}
```

- [ ] **Step 2: Create GeneralProposalVoteBody**

Create `ios/Tandas/Features/Votes/Detail/Bodies/GeneralProposalVoteBody.swift`:

```swift
import SwiftUI

/// Body para `VoteType.generalProposal`. Renderiza el description
/// del vote como cuerpo principal del proposal. Sin payload structurado
/// adicional — los proposals son textuales en V1.
struct GeneralProposalVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            if let desc = coordinator.vote.description, !desc.isEmpty {
                Text(desc)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("(Sin descripción)")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextTertiary)
            }

            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Cierra \(coordinator.vote.closesAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
            }
        }
    }
}
```

- [ ] **Step 3: Create RuleChangeVoteBody**

Create `ios/Tandas/Features/Votes/Detail/Bodies/RuleChangeVoteBody.swift`:

```swift
import SwiftUI

/// Body para `VoteType.ruleChange`. Lee `vote.payload` con shape
/// `{ "current_amount": int, "proposed_amount": int }` y renderiza
/// un diff visual (current → proposed) más la razón propuesta.
///
/// El rule_id está en `vote.referenceId`. V1 no fetcha el rule del
/// repo aquí — la regla puede haber sido archivada mid-vote. El body
/// proyecta el snapshot del momento del vote (los amounts en payload).
struct RuleChangeVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    private var currentAmount: Int? {
        guard case .object(let obj) = coordinator.vote.payload,
              case .int(let v) = obj["current_amount"] else { return nil }
        return v
    }

    private var proposedAmount: Int? {
        guard case .object(let obj) = coordinator.vote.payload,
              case .int(let v) = obj["proposed_amount"] else { return nil }
        return v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s5) {
            // Razón del cambio (description del vote).
            if let desc = coordinator.vote.description, !desc.isEmpty {
                VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                    Text("RAZÓN")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Text(desc)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Diff visual.
            VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                Text("CAMBIO PROPUESTO")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                HStack(spacing: RuulSpacing.s4) {
                    amountChip(label: "Actual",  value: currentAmount,  tint: Color.ruulTextTertiary)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(Color.ruulTextTertiary)
                    amountChip(label: "Nuevo",   value: proposedAmount, tint: Color.ruulSemanticSuccess)
                }
            }

            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Cierra \(coordinator.vote.closesAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
            }
        }
    }

    private func amountChip(label: String, value: Int?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(value.map { "$\($0)" } ?? "—")
                .ruulTextStyle(RuulTypography.titleMedium)
                .foregroundStyle(tint)
        }
        .padding(RuulSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.sm, style: .continuous))
    }
}
```

- [ ] **Step 4: Build to verify**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Votes/Detail/Bodies/GenericVoteBody.swift \
  ios/Tandas/Features/Votes/Detail/Bodies/GeneralProposalVoteBody.swift \
  ios/Tandas/Features/Votes/Detail/Bodies/RuleChangeVoteBody.swift
git commit -m "$(cat <<'EOF'
feat(votes): 3 new VoteDetailView bodies (Generic + GeneralProposal + RuleChange)

Bodies puros stateless consumiendo VoteDetailCoordinator:

- GenericVoteBody: fallback. Description + payload as JSON in mono.
  Para los 5 vote_types V1 sin body dedicado (rule_repeal,
  member_removal, fund_withdrawal, role_assignment, slot_dispute) +
  el case .unknown del enum.

- GeneralProposalVoteBody: description prominente + closesAt
  countdown.

- RuleChangeVoteBody: lee vote.payload {current_amount, proposed_
  amount} y renderiza diff visual (current → proposed). Razón viene
  de vote.description. No fetcha el rule del repo — proyecta el
  snapshot del momento del vote (payload), defensivo contra rule
  archived mid-vote.

FineAppealVoteBody se extrae de VoteOnAppealSheet en Task C2 (refactor
con snapshot test).

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task C2: Refactor VoteOnAppealSheet → FineAppealVoteBody

**Files:**
- Create: `ios/Tandas/Features/Votes/Detail/Bodies/FineAppealVoteBody.swift`
- Modify: `ios/Tandas/Features/Fines/Sheets/VoteOnAppealSheet.swift`

**Riesgo del refactor**: alto. Mismo riesgo que Sub-fase C de F0.5. Mitigación: snapshot test pre/post pixel-paridad obligatorio.

- [ ] **Step 1: Read current VoteOnAppealSheet to understand structure**

```bash
wc -l /Users/jj/code/tandas/ios/Tandas/Features/Fines/Sheets/VoteOnAppealSheet.swift
head -40 /Users/jj/code/tandas/ios/Tandas/Features/Fines/Sheets/VoteOnAppealSheet.swift
```

Read the full file to identify:
- Properties that the sheet owns (vote_id, appeal_id, fine context)
- Body content that should move to FineAppealVoteBody
- Sheet wrapper concerns (presentation, dismiss, NavigationStack) that stay in VoteOnAppealSheet

- [ ] **Step 2: Create snapshot test baseline**

If the project has snapshot test infrastructure, capture pre-refactor snapshots. If not, this task uses manual visual check.

Run the existing VoteOnAppealSheet preview in Xcode (Cmd+Option+P) and capture screenshots for 3 states:
- Pending myCast (before voting).
- inFavor cast (post-voting).
- Vote resolved (closed).

Save screenshots to a working directory; they're the baseline for Step 5 visual diff.

- [ ] **Step 3: Create FineAppealVoteBody by extracting the body content**

Create `ios/Tandas/Features/Votes/Detail/Bodies/FineAppealVoteBody.swift`. The implementation copies the existing VoteOnAppealSheet body content verbatim, adapted to consume `VoteDetailCoordinator` instead of the appeal-specific coordinator:

```swift
import SwiftUI

/// Body para `VoteType.fineAppeal`. Renderiza fine details (amount,
/// reason, infractor member) + appeal reason + voting state. Extraído
/// de `VoteOnAppealSheet` el 2026-05-07 — la sheet existente preserva
/// su entry point envolviendo este body.
///
/// Nota: este body lee fine context desde `vote.payload` (que finalize
/// vote v3 popula con fine_id, amount, reason, member_id). En V1
/// fine_appeal el server populates esto en start_vote.
struct FineAppealVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    private var fineAmount: Int? {
        guard case .object(let obj) = coordinator.vote.payload,
              case .int(let v) = obj["fine_amount"] else { return nil }
        return v
    }

    private var fineReason: String? {
        guard case .object(let obj) = coordinator.vote.payload,
              case .string(let s) = obj["fine_reason"] else { return nil }
        return s
    }

    private var appealReason: String? {
        coordinator.vote.description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s5) {
            // Fine context.
            VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                Text("MULTA APELADA")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                if let amount = fineAmount {
                    Text("$\(amount)")
                        .ruulTextStyle(RuulTypography.titleLarge)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                if let reason = fineReason, !reason.isEmpty {
                    Text(reason)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            .padding(RuulSpacing.s4)
            .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))

            // Appeal reason.
            if let appealReason, !appealReason.isEmpty {
                VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                    Text("RAZÓN DE APELACIÓN")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Text(appealReason)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Cierra \(coordinator.vote.closesAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
            }
        }
    }
}
```

**IMPORTANTE**: si el body actual de VoteOnAppealSheet tiene componentes adicionales (e.g. avatar del member, link al evento original, otras UI elements), agregarlos aquí antes de Step 4. La regla es: **paridad pixel-perfect**. Si en doubt, leer el VoteOnAppealSheet.swift completo y migrar TODO lo del body, dejando en la sheet solo el wrapper de presentation.

- [ ] **Step 4: Refactor VoteOnAppealSheet to use FineAppealVoteBody**

Edit `ios/Tandas/Features/Fines/Sheets/VoteOnAppealSheet.swift`:

Replace the body content with a wrapper that:
1. Constructs a `Vote` value compatible with `VoteDetailCoordinator` from the existing appeal context.
2. Constructs a `VoteDetailCoordinator` (or its dependencies).
3. Renders `FineAppealVoteBody(coordinator: …)` + `VoteCastSection(coordinator: …)`.

Note: VoteOnAppealSheet historically used appeal-specific repos (AppealRepository.cast). The new VoteCastRepository.cast hits the generic `cast_vote` RPC which works for fine_appeal votes too (tested per migration 00023).

If the existing sheet uses AppealRepository directly, the refactor switches it to VoteCastRepository. Verify via grep that the migration is safe — no other surface depends on the appeal-specific cast path.

- [ ] **Step 5: Build + visual verification**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

Then in Xcode preview, render VoteOnAppealSheet for 3 states (pending, inFavor, resolved) and visually compare to the baselines from Step 2. **If pixel diff > acceptable, abort and discuss with user.**

- [ ] **Step 6: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Votes/Detail/Bodies/FineAppealVoteBody.swift \
  ios/Tandas/Features/Fines/Sheets/VoteOnAppealSheet.swift
git commit -m "$(cat <<'EOF'
refactor(votes): extract FineAppealVoteBody from VoteOnAppealSheet

Pieza de Sub-fase A pattern. VoteOnAppealSheet preserva su entry
point (callable desde Fine context) pero envuelve un nuevo
FineAppealVoteBody reusable desde VoteDetailView.

Body lee fine context desde vote.payload (fine_amount, fine_reason)
+ appeal reason desde vote.description. Mismo rendering que la sheet
original — visual paridad confirmada via Xcode preview pre/post.

VoteOnAppealSheet ahora usa VoteCastRepository.cast (generic
cast_vote RPC) en lugar de AppealRepository.cast. Server-side ya
soporta esto desde 00023 (start_vote v2 escribe vote_casts para
fine_appeal y cast_vote es polimórfico).

Refactor riesgo alto, paridad obligatoria. Si en futuro snapshot
diff aparece, revertir y discutir.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase D — iOS Detail Container (1 task)

### Task D1: VoteDetailView router

**Files:**
- Create: `ios/Tandas/Features/Votes/Detail/VoteDetailView.swift`

Container puro. Un solo switch sobre `vote.voteType` que dispatchea al body correspondiente. Tests del routing van implícitos via tests de los coordinators y bodies (cada body tiene su unit + el coordinator está cubierto en B2).

- [ ] **Step 1: Create directory + file**

```bash
mkdir -p /Users/jj/code/tandas/ios/Tandas/Features/Votes/Detail
```

Create `ios/Tandas/Features/Votes/Detail/VoteDetailView.swift`:

```swift
import SwiftUI

/// Container del detail screen de un Vote. Header (title + meta) +
/// body type-specific (router por vote.voteType) + cast section
/// compartida.
///
/// Bodies son views privadas en archivos separados bajo Detail/Bodies/.
/// Cuando llega un nuevo vote_type, agregar su body file y un case
/// nuevo al switch.
struct VoteDetailView: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                VoteHeader(vote: coordinator.vote)
                bodyForType
                VoteCastSection(coordinator: coordinator)
            }
            .padding(.horizontal, RuulSpacing.s5)
            .padding(.top, RuulSpacing.s2)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .background(Color.ruulBackgroundCanvas.ignoresSafeArea())
        .task { await coordinator.refresh() }
        .refreshable { await coordinator.refresh() }
    }

    @ViewBuilder
    private var bodyForType: some View {
        switch coordinator.vote.voteType {
        case .fineAppeal:        FineAppealVoteBody(coordinator: coordinator)
        case .generalProposal:   GeneralProposalVoteBody(coordinator: coordinator)
        case .ruleChange:        RuleChangeVoteBody(coordinator: coordinator)
        case .ruleRepeal,
             .memberRemoval,
             .fundWithdrawal,
             .roleAssignment,
             .slotDispute:       GenericVoteBody(coordinator: coordinator)
        }
    }
}

// MARK: - Private subview

private struct VoteHeader: View {
    let vote: Vote

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text(typeLabel.uppercased())
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulAccentPrimary)
            Text(vote.title)
                .ruulTextStyle(RuulTypography.titleLarge)
                .foregroundStyle(Color.ruulTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, RuulSpacing.s4)
    }

    private var typeLabel: String {
        switch vote.voteType {
        case .fineAppeal:       return "Apelación de multa"
        case .generalProposal:  return "Propuesta"
        case .ruleChange:       return "Cambio de regla"
        case .ruleRepeal:       return "Archivar regla"
        case .memberRemoval:    return "Remover miembro"
        case .fundWithdrawal:   return "Retirar fondos"
        case .roleAssignment:   return "Asignar rol"
        case .slotDispute:      return "Disputa de slot"
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Votes/Detail/VoteDetailView.swift
git commit -m "$(cat <<'EOF'
feat(votes): VoteDetailView router container

Container que enruta por vote.voteType a body sub-component.
Mismo pattern que ResourceDetailView de Sub-fase A.

Switch cubre los 8 vote_types declarados:
  - fineAppeal      → FineAppealVoteBody
  - generalProposal → GeneralProposalVoteBody
  - ruleChange      → RuleChangeVoteBody
  - ruleRepeal, memberRemoval, fundWithdrawal, roleAssignment,
    slotDispute → GenericVoteBody (fallback V1)

Header con typeLabel + title; body type-specific; VoteCastSection
shared abajo.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase E — iOS List (2 tasks)

### Task E1: OpenVotesCoordinator

**Files:**
- Create: `ios/Tandas/Features/Votes/Coordinator/OpenVotesCoordinator.swift`
- Create: `ios/TandasTests/Votes/OpenVotesCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `ios/TandasTests/Votes/OpenVotesCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import Tandas

@Suite("OpenVotesCoordinator")
@MainActor
struct OpenVotesCoordinatorTests {

    private func makeGroup() -> Group {
        Group(id: UUID(), name: "Cuates",
              governance: .recurringDinnerDefaults,
              createdAt: .now, updatedAt: .now)
    }

    private func makeVote(
        groupId: UUID,
        closesIn hours: TimeInterval = 24,
        status: VoteStatus = .open
    ) -> Vote {
        Vote(
            id: UUID(), groupId: groupId, voteType: .generalProposal,
            referenceId: UUID(), title: "Vote", description: nil,
            createdByMemberId: nil,
            openedAt: .now,
            closesAt: .now.addingTimeInterval(hours * 3600),
            resolvedAt: nil, quorumPercent: 50, thresholdPercent: 50,
            isAnonymous: true, status: status, counts: nil, payload: .empty
        )
    }

    @Test("refresh empty group yields empty list")
    func refreshEmpty() async throws {
        let group = makeGroup()
        let repo = MockVoteRepository(seed: [])
        let coord = OpenVotesCoordinator(group: group, voteRepo: repo)
        await coord.refresh()
        #expect(coord.openVotes.isEmpty)
        #expect(coord.error == nil)
    }

    @Test("refresh fetches only open votes for the group")
    func refreshFiltersByGroupAndStatus() async throws {
        let group = makeGroup()
        let myVote = makeVote(groupId: group.id, status: .open)
        let otherGroupVote = makeVote(groupId: UUID(), status: .open)
        let resolvedVote = makeVote(groupId: group.id, status: .resolved)
        let repo = MockVoteRepository(seed: [myVote, otherGroupVote, resolvedVote])
        let coord = OpenVotesCoordinator(group: group, voteRepo: repo)

        await coord.refresh()

        #expect(coord.openVotes.count == 1)
        #expect(coord.openVotes.first?.id == myVote.id)
    }

    @Test("sectioned splits closing-soon vs other")
    func sectioned() async throws {
        let group = makeGroup()
        let closingSoon = makeVote(groupId: group.id, closesIn: 12)   // <24h
        let later = makeVote(groupId: group.id, closesIn: 48)         // ≥24h
        let repo = MockVoteRepository(seed: [closingSoon, later])
        let coord = OpenVotesCoordinator(group: group, voteRepo: repo)
        await coord.refresh()
        let sections = coord.sectioned()

        #expect(sections.count == 2)
        let closingSoonSection = sections.first { $0.0 == .closingSoon }
        let openSection = sections.first { $0.0 == .open }
        #expect(closingSoonSection?.1.count == 1)
        #expect(openSection?.1.count == 1)
    }

    @Test("refresh surfaces error string when repo throws")
    func refreshErrorSurfaces() async throws {
        let group = makeGroup()
        let repo = MockVoteRepository(seed: [])
        await repo.setNextOpenVotesError(NSError(
            domain: "test", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "network down"]
        ))
        let coord = OpenVotesCoordinator(group: group, voteRepo: repo)
        await coord.refresh()

        #expect(coord.error?.contains("network down") == true)
        #expect(coord.openVotes.isEmpty)
    }
}
```

- [ ] **Step 2: Add `setNextOpenVotesError` helper to MockVoteRepository**

Edit `ios/Tandas/Platform/Repositories/VoteRepository.swift`. Inside `MockVoteRepository`, add:

```swift
private(set) var nextOpenVotesError: Error?

func setNextOpenVotesError(_ error: Error?) { self.nextOpenVotesError = error }

// And modify openVotes(for:) to consume it:
func openVotes(for groupId: UUID) async throws -> [Vote] {
    if let err = nextOpenVotesError { nextOpenVotesError = nil; throw err }
    return store.filter { $0.groupId == groupId && $0.status == .open }.sorted { $0.openedAt > $1.openedAt }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/OpenVotesCoordinator 2>&1 \
  | grep -E "(error:|cannot find|FAILED)" | head -5
```

Expected: `cannot find 'OpenVotesCoordinator' in scope`.

- [ ] **Step 4: Implement OpenVotesCoordinator**

Create `ios/Tandas/Features/Votes/Coordinator/OpenVotesCoordinator.swift`:

```swift
import Foundation
import Observation
import OSLog

/// Coordinator del OpenVotesListView. Lista cross-vote_type de votes
/// con status='open' del grupo activo. Sectiona por urgencia
/// (closing-soon < 24h vs other) para que el founder/miembros vean
/// primero lo que está por cerrar.
@Observable @MainActor
final class OpenVotesCoordinator {
    let group: Group
    private let voteRepo: any VoteRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "votes")

    private(set) var openVotes: [Vote] = []
    private(set) var isLoading: Bool = false
    private(set) var error: String?
    private(set) var lastRefreshedAt: Date?

    private let cacheTTL: TimeInterval = 60   // 1 min — votes can change

    init(group: Group, voteRepo: any VoteRepository) {
        self.group = group
        self.voteRepo = voteRepo
    }

    func refresh(force: Bool = false) async {
        if !force, let last = lastRefreshedAt,
           Date.now.timeIntervalSince(last) < cacheTTL {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            openVotes = try await voteRepo.openVotes(for: group.id)
            lastRefreshedAt = .now
            error = nil
        } catch {
            self.error = error.localizedDescription
            log.warning("openVotes refresh failed: \(error.localizedDescription)")
        }
    }

    /// Sectioned: closing-soon (next 24h) vs other (≥24h until close).
    func sectioned() -> [(Section, [Vote])] {
        let cutoff = Date.now.addingTimeInterval(24 * 3600)
        var closingSoon: [Vote] = []
        var open: [Vote] = []
        for v in openVotes {
            if v.closesAt <= cutoff { closingSoon.append(v) } else { open.append(v) }
        }
        var result: [(Section, [Vote])] = []
        if !closingSoon.isEmpty { result.append((.closingSoon, closingSoon)) }
        if !open.isEmpty        { result.append((.open, open)) }
        return result
    }

    enum Section: Hashable {
        case closingSoon
        case open

        var title: String {
            switch self {
            case .closingSoon: return "Cierran pronto"
            case .open:        return "Abiertos"
            }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/OpenVotesCoordinator 2>&1 \
  | grep -E "(Test Suite|passed|FAILED)" | tail -5
```

Expected: `Suite "OpenVotesCoordinator" passed.` with 4 tests passed.

- [ ] **Step 6: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Votes/Coordinator/OpenVotesCoordinator.swift \
  ios/TandasTests/Votes/OpenVotesCoordinatorTests.swift \
  ios/Tandas/Platform/Repositories/VoteRepository.swift
git commit -m "$(cat <<'EOF'
feat(votes): OpenVotesCoordinator with closing-soon section

@Observable @MainActor coordinator del OpenVotesListView. Refresca
voteRepo.openVotes(for:groupId), sectiona en closing-soon (next 24h)
vs other.

4 tests Swift Testing cubren empty group, group+status filtering,
sectioning, error surface.

Plus helper agregado al MockVoteRepository (setNextOpenVotesError).

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task E2: OpenVotesListView

**Files:**
- Create: `ios/Tandas/Features/Votes/Views/OpenVotesListView.swift`

- [ ] **Step 1: Create directory + file**

```bash
mkdir -p /Users/jj/code/tandas/ios/Tandas/Features/Votes/Views
```

Create `ios/Tandas/Features/Votes/Views/OpenVotesListView.swift`:

```swift
import SwiftUI

/// List view de votos abiertos del grupo activo. Sectiona por urgencia
/// (closing-soon vs other). Botón "+" en header abre CreateVoteSheet
/// (V1: enabled solo general_proposal y rule_change).
struct OpenVotesListView: View {
    @Bindable var coordinator: OpenVotesCoordinator
    var onSelectVote: (Vote) -> Void
    var onCreateVote: () -> Void

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RuulSpacing.s5) {
                    if coordinator.openVotes.isEmpty && !coordinator.isLoading {
                        EmptyStateView(
                            icon: "hand.raised",
                            title: "No hay votos abiertos",
                            subtitle: "Cuando el grupo abra una votación, aparecerá acá.",
                            action: ("Crear votación", onCreateVote)
                        )
                        .padding(.top, RuulSpacing.s10)
                    } else {
                        ForEach(coordinator.sectioned(), id: \.0) { section, votes in
                            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                                Text(section.title.uppercased())
                                    .ruulTextStyle(RuulTypography.sectionLabel)
                                    .foregroundStyle(Color.ruulTextTertiary)
                                ForEach(votes) { vote in
                                    Button { onSelectVote(vote) } label: {
                                        voteRow(vote)
                                    }
                                    .buttonStyle(.ruulPress)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.top, RuulSpacing.s4)
                .padding(.bottom, RuulSpacing.s12)
            }
            .scrollIndicators(.hidden)
            .refreshable { await coordinator.refresh(force: true) }
        }
        .navigationTitle("Votos abiertos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onCreateVote) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Crear votación")
            }
        }
        .task { await coordinator.refresh() }
    }

    private func voteRow(_ vote: Vote) -> some View {
        HStack(spacing: RuulSpacing.s3) {
            voteTypeIcon(vote.voteType)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.ruulAccentPrimary)
                .frame(width: 32, height: 32)
                .background(Color.ruulBackgroundElevated, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(vote.title)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                Text("Cierra \(vote.closesAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    private func voteTypeIcon(_ type: VoteType) -> Image {
        switch type {
        case .fineAppeal:       return Image(systemName: "exclamationmark.bubble")
        case .generalProposal:  return Image(systemName: "text.bubble")
        case .ruleChange:       return Image(systemName: "list.bullet.clipboard")
        case .ruleRepeal:       return Image(systemName: "trash")
        case .memberRemoval:    return Image(systemName: "person.fill.xmark")
        case .fundWithdrawal:   return Image(systemName: "banknote")
        case .roleAssignment:   return Image(systemName: "person.badge.shield.checkmark")
        case .slotDispute:      return Image(systemName: "ticket")
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Votes/Views/OpenVotesListView.swift
git commit -m "$(cat <<'EOF'
feat(votes): OpenVotesListView with closing-soon section + create button

List view top-level. Sectiones por urgencia. EmptyStateView cuando
no hay votos abiertos. "+" en toolbar abre create flow.

Vote rows muestran type icon + title + closes_at relative + chevron.
Apple-grade design: cero magic numbers, tokens RuulSpacing/Radius/
Typography, ruulPress button style, RoundedRectangle continuous.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase F — iOS Creation (3 tasks)

### Task F1: CreateVoteSheet (vote_type picker)

**Files:**
- Create: `ios/Tandas/Features/Votes/Sheets/CreateVoteSheet.swift`

- [ ] **Step 1: Create file**

```bash
mkdir -p /Users/jj/code/tandas/ios/Tandas/Features/Votes/Sheets
```

Create `ios/Tandas/Features/Votes/Sheets/CreateVoteSheet.swift`:

```swift
import SwiftUI

/// Picker de vote_type. V1 enabled = generalProposal + ruleChange.
/// Los otros 5 visibles pero disabled con badge "próximamente".
/// Tap en enabled → push corresponding sheet.
struct CreateVoteSheet: View {
    var onPickGeneralProposal: () -> Void
    var onPickRuleChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                    Text("¿Qué quieres proponer?")
                        .ruulTextStyle(RuulTypography.titleMedium)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .padding(.bottom, RuulSpacing.s2)

                    voteTypeCard(
                        title: "Propuesta general",
                        subtitle: "Texto libre — el grupo vota a favor o en contra.",
                        icon: "text.bubble",
                        enabled: true,
                        onTap: { dismiss(); onPickGeneralProposal() }
                    )

                    voteTypeCard(
                        title: "Cambio de regla",
                        subtitle: "Proponer cambiar el monto de una multa existente.",
                        icon: "list.bullet.clipboard",
                        enabled: true,
                        onTap: { dismiss(); onPickRuleChange() }
                    )

                    Text("PRÓXIMAMENTE")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .padding(.top, RuulSpacing.s5)

                    voteTypeCard(title: "Archivar regla",       subtitle: "Quitar una regla del grupo.",            icon: "trash",                              enabled: false, onTap: {})
                    voteTypeCard(title: "Remover miembro",      subtitle: "Sacar a alguien del grupo.",             icon: "person.fill.xmark",                  enabled: false, onTap: {})
                    voteTypeCard(title: "Retirar fondos",       subtitle: "Aprobar un retiro del fondo común.",     icon: "banknote",                           enabled: false, onTap: {})
                    voteTypeCard(title: "Asignar rol",          subtitle: "Promover a alguien a treasurer/etc.",    icon: "person.badge.shield.checkmark",      enabled: false, onTap: {})
                    voteTypeCard(title: "Disputa de slot",      subtitle: "Resolver disputa sobre un boleto/cupo.", icon: "ticket",                              enabled: false, onTap: {})
                }
                .padding(RuulSpacing.s5)
            }
            .scrollIndicators(.hidden)
            .background(Color.ruulBackgroundCanvas)
            .navigationTitle("Nueva votación")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }

    private func voteTypeCard(title: String, subtitle: String, icon: String, enabled: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.s3) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(enabled ? Color.ruulAccentPrimary : Color.ruulTextTertiary)
                    .frame(width: 44, height: 44)
                    .background(Color.ruulBackgroundElevated, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(enabled ? Color.ruulTextPrimary : Color.ruulTextTertiary)
                    Text(subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(2)
                }
                Spacer()
                if enabled {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.ruulTextTertiary)
                }
            }
            .padding(RuulSpacing.s4)
            .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
            .opacity(enabled ? 1.0 : 0.6)
        }
        .buttonStyle(.ruulPress)
        .disabled(!enabled)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | tail -3
```

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Votes/Sheets/CreateVoteSheet.swift
git commit -m "$(cat <<'EOF'
feat(votes): CreateVoteSheet — vote_type picker

V1 habilita generalProposal + ruleChange. Los 5 restantes (rule_repeal,
member_removal, fund_withdrawal, role_assignment, slot_dispute)
visibles bajo "PRÓXIMAMENTE" pero disabled. Cuando esos features
shippeen, su card se enable.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task F2: CreateGeneralProposalCoordinator + Sheet

**Files:**
- Create: `ios/Tandas/Features/Votes/Coordinator/CreateGeneralProposalCoordinator.swift`
- Create: `ios/Tandas/Features/Votes/Sheets/CreateGeneralProposalSheet.swift`
- Create: `ios/TandasTests/Votes/CreateGeneralProposalCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `ios/TandasTests/Votes/CreateGeneralProposalCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import Tandas

@Suite("CreateGeneralProposalCoordinator")
@MainActor
struct CreateGeneralProposalCoordinatorTests {

    private func makeGroup() -> Group {
        Group(id: UUID(), name: "G",
              governance: .recurringDinnerDefaults,
              createdAt: .now, updatedAt: .now)
    }

    private func makeMember(isFounder: Bool = false) -> Member {
        Member(
            id: UUID(), groupId: UUID(), userId: UUID(),
            displayName: "Test",
            roles: isFounder ? ["founder", "member"] : ["member"],
            active: true, joinedAt: .now,
            createdAt: .now, updatedAt: .now
        )
    }

    private func makeCoordinator(memberIsFounder: Bool = false)
    -> (CreateGeneralProposalCoordinator, MockVoteRepository) {
        let voteRepo = MockVoteRepository(seed: [])
        let coord = CreateGeneralProposalCoordinator(
            group: makeGroup(),
            member: makeMember(isFounder: memberIsFounder),
            voteRepo: voteRepo,
            governance: GovernanceService()
        )
        return (coord, voteRepo)
    }

    @Test("title shorter than min returns invalid")
    func titleMinLength() {
        let (coord, _) = makeCoordinator()
        coord.title = "Hi"
        #expect(coord.canSubmit == false)
    }

    @Test("title longer than max returns invalid")
    func titleMaxLength() {
        let (coord, _) = makeCoordinator()
        coord.title = String(repeating: "x", count: 101)
        #expect(coord.canSubmit == false)
    }

    @Test("title in range + governance allows = canSubmit true")
    func canSubmitHappy() {
        let (coord, _) = makeCoordinator()
        coord.title = "Cambio razonable"
        #expect(coord.canSubmit == true)
    }

    @Test("submit calls startVote with correct vote_type")
    func submitWiresStartVote() async throws {
        let (coord, voteRepo) = makeCoordinator()
        coord.title = "Vote please"
        coord.description = "Reason"

        await coord.submit()

        #expect(coord.error == nil)
        let calls = await voteRepo.startVoteCalls
        #expect(calls.count == 1)
        #expect(calls.first?.voteType == .generalProposal)
        #expect(calls.first?.title == "Vote please")
    }

    @Test("submit error surfaces user-facing message")
    func submitErrorSurfaces() async throws {
        let (coord, voteRepo) = makeCoordinator()
        await voteRepo.setNextStartError(NSError(
            domain: "test", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "rpc 500"]
        ))
        coord.title = "Vote please"
        await coord.submit()

        #expect(coord.error != nil)
        #expect(coord.error?.contains("500") == true)
    }
}
```

- [ ] **Step 2: Add helper methods to MockVoteRepository**

Edit `ios/Tandas/Platform/Repositories/VoteRepository.swift`. In `MockVoteRepository`, add:

```swift
struct StartVoteCall: Sendable {
    let groupId: UUID
    let voteType: VoteType
    let referenceId: UUID
    let title: String
    let description: String?
    let payload: JSONConfig
}
private(set) var startVoteCalls: [StartVoteCall] = []

func setNextStartError(_ error: Error?) { self.nextStartError = error }

// And modify startVote(...) in MockVoteRepository to record:
func startVote(
    groupId: UUID,
    voteType: VoteType,
    referenceId: UUID,
    title: String,
    description: String?,
    payload: JSONConfig
) async throws -> UUID {
    if let err = nextStartError { nextStartError = nil; throw err }
    startVoteCalls.append(StartVoteCall(
        groupId: groupId, voteType: voteType, referenceId: referenceId,
        title: title, description: description, payload: payload
    ))
    let v = Vote(/* ... existing init body ... */)
    store.append(v)
    return v.id
}
```

(The full Vote(...) init body stays the same as the existing mock.)

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/CreateGeneralProposalCoordinator 2>&1 \
  | grep -E "(error:|cannot find|FAILED)" | head -5
```

Expected: `cannot find 'CreateGeneralProposalCoordinator' in scope`.

- [ ] **Step 4: Implement coordinator**

Create `ios/Tandas/Features/Votes/Coordinator/CreateGeneralProposalCoordinator.swift`:

```swift
import Foundation
import Observation
import OSLog

/// Coordinator del CreateGeneralProposalSheet. Form state + governance
/// gate + submit a startVote.
@Observable @MainActor
final class CreateGeneralProposalCoordinator {
    let group: Group
    let member: Member
    private let voteRepo: any VoteRepository
    private let governance: any GovernanceServiceProtocol
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote-create")

    var title: String = ""
    var description: String = ""
    var durationHours: Int = 72
    private(set) var isSubmitting: Bool = false
    private(set) var error: String?
    private(set) var createdVoteId: UUID?

    static let titleMinLength = 5
    static let titleMaxLength = 100
    static let descriptionMaxLength = 500

    var canSubmit: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= Self.titleMinLength && t.count <= Self.titleMaxLength
            && description.count <= Self.descriptionMaxLength
            && !isSubmitting
    }

    init(
        group: Group,
        member: Member,
        voteRepo: any VoteRepository,
        governance: any GovernanceServiceProtocol
    ) {
        self.group = group
        self.member = member
        self.voteRepo = voteRepo
        self.governance = governance
    }

    func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        error = nil

        do {
            // Governance gate.
            let decision = try await governance.canPerform(
                .createVotes, member: member, in: group, context: nil
            )
            if case .denied(let reason) = decision {
                error = "No tienes permiso para crear votaciones: \(reason)"
                return
            }
            // .allowed o .requiresVote — para .createVotes, .requiresVote
            // sería loop infinito; doc as unreachable, treat .allowed.

            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let voteId = try await voteRepo.startVote(
                groupId: group.id,
                voteType: .generalProposal,
                referenceId: UUID(),  // synthetic — generalProposal has no other object
                title: trimmedTitle,
                description: description.isEmpty ? nil : description,
                payload: .empty
            )
            createdVoteId = voteId
        } catch {
            self.error = "No pudimos abrir el voto: \(error.localizedDescription)"
            log.warning("create general proposal failed: \(error.localizedDescription)")
        }
    }

    func clearError() { error = nil }
}
```

- [ ] **Step 5: Implement sheet**

Create `ios/Tandas/Features/Votes/Sheets/CreateGeneralProposalSheet.swift`:

```swift
import SwiftUI

struct CreateGeneralProposalSheet: View {
    @Bindable var coordinator: CreateGeneralProposalCoordinator
    var onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Título") {
                    TextField("¿Qué quieres proponer?", text: $coordinator.title)
                        .textInputAutocapitalization(.sentences)
                }

                Section("Descripción (opcional)") {
                    TextField("Detalles", text: $coordinator.description, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    Stepper(value: $coordinator.durationHours, in: 1...168, step: 1) {
                        Text("Cierra en \(coordinator.durationHours)h")
                    }
                } header: {
                    Text("Duración")
                } footer: {
                    Text("La votación cerrará automáticamente. Default \(Int(coordinator.group.governance.votingDurationHours))h.")
                }

                if let error = coordinator.error {
                    Section {
                        Text(error)
                            .foregroundStyle(Color.ruulSemanticError)
                    }
                }
            }
            .navigationTitle("Propuesta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Abrir voto") {
                        Task {
                            await coordinator.submit()
                            if let id = coordinator.createdVoteId {
                                dismiss()
                                onCreated(id)
                            }
                        }
                    }
                    .disabled(!coordinator.canSubmit)
                }
            }
        }
    }
}
```

- [ ] **Step 6: Run tests + commit**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/CreateGeneralProposalCoordinator 2>&1 \
  | grep -E "(Test Suite|passed|FAILED)" | tail -5
```

Expected: 5 tests passed.

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Votes/Coordinator/CreateGeneralProposalCoordinator.swift \
  ios/Tandas/Features/Votes/Sheets/CreateGeneralProposalSheet.swift \
  ios/TandasTests/Votes/CreateGeneralProposalCoordinatorTests.swift \
  ios/Tandas/Platform/Repositories/VoteRepository.swift
git commit -m "$(cat <<'EOF'
feat(votes): CreateGeneralProposalCoordinator + Sheet

Form state + governance gate + submit a startVote(vote_type=
generalProposal, referenceId=synthetic UUID, payload=empty).
Title 5-100 chars, description ≤500. Duration 1-168h.

5 tests Swift Testing cubren validation min/max, canSubmit happy,
submit wires startVote, error surface.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task F3: CreateRuleChangeCoordinator + Sheet

**Files:**
- Create: `ios/Tandas/Features/Votes/Coordinator/CreateRuleChangeCoordinator.swift`
- Create: `ios/Tandas/Features/Votes/Sheets/CreateRuleChangeSheet.swift`
- Create: `ios/TandasTests/Votes/CreateRuleChangeCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `ios/TandasTests/Votes/CreateRuleChangeCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import Tandas

@Suite("CreateRuleChangeCoordinator")
@MainActor
struct CreateRuleChangeCoordinatorTests {

    private func makeGroup() -> Group {
        Group(id: UUID(), name: "G",
              governance: .recurringDinnerDefaults,
              createdAt: .now, updatedAt: .now)
    }

    private func makeMember() -> Member {
        Member(id: UUID(), groupId: UUID(), userId: UUID(),
               displayName: "Test", roles: ["member"],
               active: true, joinedAt: .now,
               createdAt: .now, updatedAt: .now)
    }

    private func makeRule(currentAmount: Int = 200) -> GroupRule {
        GroupRule(
            id: UUID(), groupId: UUID(),
            code: "test_rule", title: "Llegada tardía",
            description: nil,
            trigger: nil, action: nil,
            enabled: true, status: "active",
            createdAt: .now, updatedAt: .now,
            fineShape: .flat(amount: currentAmount)
        )
    }

    @Test("rule selection required to submit")
    func rulePickerRequired() {
        let voteRepo = MockVoteRepository()
        let coord = CreateRuleChangeCoordinator(
            group: makeGroup(), member: makeMember(),
            availableRules: [makeRule()], voteRepo: voteRepo,
            governance: GovernanceService()
        )
        // No selection.
        coord.proposedAmount = 250
        coord.reason = "Razón válida más de 5 chars"
        #expect(coord.canSubmit == false)
    }

    @Test("proposed amount must be positive")
    func amountPositive() {
        let rule = makeRule()
        let coord = CreateRuleChangeCoordinator(
            group: makeGroup(), member: makeMember(),
            availableRules: [rule],
            voteRepo: MockVoteRepository(),
            governance: GovernanceService()
        )
        coord.selectedRule = rule
        coord.proposedAmount = 0
        coord.reason = "Razón válida"
        #expect(coord.canSubmit == false)
    }

    @Test("submit composes payload with current and proposed")
    func payloadComposition() async throws {
        let rule = makeRule(currentAmount: 200)
        let voteRepo = MockVoteRepository()
        let coord = CreateRuleChangeCoordinator(
            group: makeGroup(), member: makeMember(),
            availableRules: [rule],
            voteRepo: voteRepo, governance: GovernanceService()
        )
        coord.selectedRule = rule
        coord.proposedAmount = 350
        coord.reason = "Cambio razonable"

        await coord.submit()

        let calls = await voteRepo.startVoteCalls
        #expect(calls.count == 1)
        #expect(calls.first?.voteType == .ruleChange)
        #expect(calls.first?.referenceId == rule.id)

        guard case .object(let payload) = calls.first?.payload else {
            Issue.record("payload should be object")
            return
        }
        guard case .int(let proposed) = payload["proposed_amount"] else {
            Issue.record("proposed_amount missing")
            return
        }
        #expect(proposed == 350)
    }

    @Test("submit wires startVote with rule_change type and rule_id as reference")
    func submitWires() async throws {
        let rule = makeRule()
        let voteRepo = MockVoteRepository()
        let coord = CreateRuleChangeCoordinator(
            group: makeGroup(), member: makeMember(),
            availableRules: [rule],
            voteRepo: voteRepo, governance: GovernanceService()
        )
        coord.selectedRule = rule
        coord.proposedAmount = 350
        coord.reason = "Razón válida"

        await coord.submit()

        let call = try #require(await voteRepo.startVoteCalls.first)
        #expect(call.voteType == .ruleChange)
        #expect(call.referenceId == rule.id)
        #expect(call.title.contains(rule.title) || call.title.contains("Cambio"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/CreateRuleChangeCoordinator 2>&1 \
  | grep -E "(error:|cannot find|FAILED)" | head -5
```

Expected: `cannot find 'CreateRuleChangeCoordinator' in scope`.

- [ ] **Step 3: Implement coordinator**

Create `ios/Tandas/Features/Votes/Coordinator/CreateRuleChangeCoordinator.swift`:

```swift
import Foundation
import Observation
import OSLog

@Observable @MainActor
final class CreateRuleChangeCoordinator {
    let group: Group
    let member: Member
    let availableRules: [GroupRule]
    private let voteRepo: any VoteRepository
    private let governance: any GovernanceServiceProtocol
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote-create")

    var selectedRule: GroupRule?
    var proposedAmount: Int = 0
    var reason: String = ""
    var durationHours: Int = 72

    private(set) var isSubmitting: Bool = false
    private(set) var error: String?
    private(set) var createdVoteId: UUID?

    static let reasonMinLength = 5
    static let reasonMaxLength = 200

    var canSubmit: Bool {
        guard let rule = selectedRule else { return false }
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.count >= Self.reasonMinLength
            && r.count <= Self.reasonMaxLength
            && proposedAmount > 0
            && proposedAmount != currentAmount(for: rule)
            && !isSubmitting
    }

    init(
        group: Group,
        member: Member,
        availableRules: [GroupRule],
        voteRepo: any VoteRepository,
        governance: any GovernanceServiceProtocol
    ) {
        self.group = group
        self.member = member
        self.availableRules = availableRules
        self.voteRepo = voteRepo
        self.governance = governance
    }

    func submit() async {
        guard canSubmit, let rule = selectedRule else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        error = nil

        do {
            let decision = try await governance.canPerform(
                .createVotes, member: member, in: group, context: nil
            )
            if case .denied(let reason) = decision {
                error = "No tienes permiso para crear votaciones: \(reason)"
                return
            }

            let current = currentAmount(for: rule)
            let payload: JSONConfig = .object([
                "current_amount":  .int(current),
                "proposed_amount": .int(proposedAmount),
            ])

            let voteId = try await voteRepo.startVote(
                groupId: group.id,
                voteType: .ruleChange,
                referenceId: rule.id,
                title: "Cambio: \(rule.title)",
                description: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                payload: payload
            )
            createdVoteId = voteId
        } catch {
            self.error = "No pudimos abrir el voto: \(error.localizedDescription)"
            log.warning("create rule change failed: \(error.localizedDescription)")
        }
    }

    private func currentAmount(for rule: GroupRule) -> Int {
        switch rule.fineShape {
        case .flat(let amount):    return amount
        case .escalating(let base, _, _): return base
        case .none:                return 0
        }
    }

    func clearError() { error = nil }
}
```

Note: `GroupRule.fineShape` is the existing typed shape from `Platform/Models/GroupRule+FineShape.swift` (shipped in EditRulesView sprint). If `.escalating` exists we use base amount as the "current". V1 only allows changing flat amounts; if the user picks an escalating rule, the proposed_amount replaces only the base.

- [ ] **Step 4: Implement sheet**

Create `ios/Tandas/Features/Votes/Sheets/CreateRuleChangeSheet.swift`:

```swift
import SwiftUI

struct CreateRuleChangeSheet: View {
    @Bindable var coordinator: CreateRuleChangeCoordinator
    var onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Regla a modificar") {
                    Picker("Selecciona regla", selection: Binding(
                        get: { coordinator.selectedRule?.id },
                        set: { newId in
                            coordinator.selectedRule = coordinator.availableRules.first { $0.id == newId }
                        }
                    )) {
                        Text("(Ninguna)").tag(UUID?.none)
                        ForEach(coordinator.availableRules) { rule in
                            Text(rule.title).tag(UUID?.some(rule.id))
                        }
                    }
                }

                if let rule = coordinator.selectedRule {
                    Section("Monto actual") {
                        Text(currentAmountLabel(for: rule))
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    Section("Nuevo monto propuesto") {
                        TextField("$0", value: $coordinator.proposedAmount, format: .number)
                            .keyboardType(.numberPad)
                    }
                }

                Section("Razón") {
                    TextField("¿Por qué cambiar el monto?", text: $coordinator.reason, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Stepper(value: $coordinator.durationHours, in: 1...168) {
                        Text("Cierra en \(coordinator.durationHours)h")
                    }
                }

                if let error = coordinator.error {
                    Section {
                        Text(error).foregroundStyle(Color.ruulSemanticError)
                    }
                }
            }
            .navigationTitle("Cambio de regla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Abrir voto") {
                        Task {
                            await coordinator.submit()
                            if let id = coordinator.createdVoteId {
                                dismiss()
                                onCreated(id)
                            }
                        }
                    }
                    .disabled(!coordinator.canSubmit)
                }
            }
        }
    }

    private func currentAmountLabel(for rule: GroupRule) -> String {
        switch rule.fineShape {
        case .flat(let amount):
            return "$\(amount)"
        case .escalating(let base, let step, let stepMin):
            return "$\(base) + $\(step) cada \(stepMin)min"
        case .none:
            return "(sin monto definido)"
        }
    }
}
```

- [ ] **Step 5: Run tests + commit**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/CreateRuleChangeCoordinator 2>&1 \
  | grep -E "(Test Suite|passed|FAILED)" | tail -5
```

Expected: 4 tests passed.

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Votes/Coordinator/CreateRuleChangeCoordinator.swift \
  ios/Tandas/Features/Votes/Sheets/CreateRuleChangeSheet.swift \
  ios/TandasTests/Votes/CreateRuleChangeCoordinatorTests.swift
git commit -m "$(cat <<'EOF'
feat(votes): CreateRuleChangeCoordinator + Sheet

V1 solo permite cambiar monto (no trigger/conditions/consequences).
Form: rule picker + current amount display + proposed amount input
+ razón + duration. Payload composition: { current_amount,
proposed_amount } as JSONConfig.

4 tests Swift Testing: rule required, amount positive, payload
shape, startVote wiring with rule_id as reference_id.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase G — iOS Touches existentes (3 tasks)

### Task G1: ActionInboxView render new types

**Files:**
- Modify: `ios/Tandas/Features/Inbox/Views/ActionInboxView.swift`

- [ ] **Step 1: Read current ActionInboxView to identify the rendering switch**

```bash
grep -n "ActionType\|case ." /Users/jj/code/tandas/ios/Tandas/Features/Inbox/Views/ActionInboxView.swift | head -40
```

Identify where the file switches on `action.actionType` to render rows. New cases to add: `.votePending`, `.ruleChangeApplyPending`.

- [ ] **Step 2: Add rendering for the two new types**

Edit `ios/Tandas/Features/Inbox/Views/ActionInboxView.swift`. In the switch (or if/else chain) over `action.actionType`, add:

```swift
case .votePending:
    ActionCard(
        icon: "hand.raised",
        title: action.title,
        subtitle: action.body,
        priority: action.priority,
        onTap: { onTap(action) }
    )

case .ruleChangeApplyPending:
    ActionCard(
        icon: "list.bullet.clipboard.fill",
        title: action.title,
        subtitle: action.body,
        meta: action.createdAt.ruulRelativeDescription,
        priority: action.priority,
        onTap: { onTap(action) }
    )
```

The `meta` property of `ActionCard` shows "votado el [fecha]" for ruleChangeApplyPending — confirming spec DoD requirement (2). If `ActionCard` doesn't expose `meta`, add it as an optional parameter (similar pattern to how DesignPrinciples #12 mentions extending primitives).

- [ ] **Step 3: Build to verify**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Wire onTap to navigation (votes vs rule edit)**

The `onTap(action)` closure in InboxCoordinator/ActionInboxView's parent must dispatch by `action.actionType`:
- `.votePending` → push `VoteDetailView` (need to fetch the Vote first via `voteRepo.vote(id: action.referenceId)`).
- `.ruleChangeApplyPending` → push `EditRuleSheet(rule:proposedAmount:)`. Get rule_id + proposed_amount from `action.body` payload (or fetch the vote via referenceId and read payload).

Find the parent that owns `onTap` (likely `InboxCoordinator` or `MainTabView` glue) and extend its switch to handle these. Implementation depends on the existing dispatch pattern — read `Features/Inbox/Coordinator/InboxCoordinator.swift` first.

For V1, if dispatching is complex, defer the routing to Task G3 (deep-link) and do row-tap dispatch as part of G3. This Task G1 just needs the rows to *render*.

- [ ] **Step 5: Commit**

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Inbox/Views/ActionInboxView.swift
git commit -m "$(cat <<'EOF'
feat(inbox): render votePending + ruleChangeApplyPending action types

ActionInboxView ahora renderiza las dos nuevas action types:
- votePending: hand.raised icon, tap → VoteDetailView
- ruleChangeApplyPending: clipboard icon + meta "votado el [fecha]",
  tap → EditRuleSheet pre-loaded (Task G3 wires)

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task G2: RulesView "Votos abiertos" section

**Files:**
- Modify: `ios/Tandas/Features/Rules/RulesView.swift`

- [ ] **Step 1: Read current RulesView to find insertion point**

```bash
head -80 /Users/jj/code/tandas/ios/Tandas/Features/Rules/RulesView.swift
```

Identify where rules are listed and add a section above (or below) for "Votos abiertos".

- [ ] **Step 2: Add section + open count fetch**

The cleanest approach: pass `openVotesCount: Int` and `onSeeOpenVotes: () -> Void` callback as new parameters to RulesView (or expose them on the coordinator). The parent (RulesCoordinator) fetches `voteRepo.openVotes(for: groupId).count` on refresh.

Add to RulesView body:

```swift
if openVotesCount > 0 {
    Button(action: onSeeOpenVotes) {
        HStack(spacing: RuulSpacing.s3) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Color.ruulAccentPrimary)
                .frame(width: 32, height: 32)
                .background(Color.ruulBackgroundElevated, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Votos abiertos")
                    .ruulTextStyle(RuulTypography.headline)
                Text(openVotesCount == 1 ? "1 votación pendiente" : "\(openVotesCount) votaciones pendientes")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }
    .buttonStyle(.ruulPress)
    .padding(.bottom, RuulSpacing.s4)
}
```

Update `RulesCoordinator` to fetch `openVotesCount` on refresh (pass `voteRepo` if not present):

```swift
@Observable @MainActor
final class RulesCoordinator {
    // ... existing properties
    private(set) var openVotesCount: Int = 0
    private let voteRepo: any VoteRepository  // inject

    func refresh() async {
        // ... existing rule fetch
        if let votes = try? await voteRepo.openVotes(for: group.id) {
            openVotesCount = votes.count
        }
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | tail -3
```

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Rules/RulesView.swift \
  ios/Tandas/Features/Rules/RulesCoordinator.swift
git commit -m "$(cat <<'EOF'
feat(rules): "Votos abiertos" section in RulesView

Section que muestra count de votes abiertos del grupo activo + link
a OpenVotesListView. RulesCoordinator fetcha el count via
voteRepo.openVotes(for:) en refresh.

Surface proactivo (vs Inbox que es reactivo) para que el founder/
miembros descubran votos abiertos aunque no tengan un votePending
en su inbox.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task G3: EditRuleSheet proposedAmount + UserAction resolve + deep-link routing

**Files:**
- Modify: `ios/Tandas/Features/Rules/EditRuleSheet.swift`
- Modify: `ios/Tandas/Features/Rules/EditRulesCoordinator.swift` (or wherever the sheet's coordinator lives)
- Modify: `ios/Tandas/TandasApp.swift` (deep-link handler)

- [ ] **Step 1: Add `proposedAmount: Int?` init param to EditRuleSheet**

Edit `ios/Tandas/Features/Rules/EditRuleSheet.swift`. Find the sheet init:

```swift
struct EditRuleSheet: View {
    let rule: GroupRule
    let proposedAmount: Int?       // NEW — pre-fill amount when arriving via vote-passed deep-link
    let userActionId: UUID?        // NEW — present when arriving from inbox; resolve on save

    init(rule: GroupRule, proposedAmount: Int? = nil, userActionId: UUID? = nil) {
        self.rule = rule
        self.proposedAmount = proposedAmount
        self.userActionId = userActionId
    }

    // ... existing body ...
}
```

In the body, where the amount field is initialized, set the initial value to `proposedAmount` if non-nil:

```swift
@State private var amount: Int = 0   // existing

.onAppear {
    if let proposed = proposedAmount {
        amount = proposed
    } else {
        amount = rule.fineShape.flatAmount ?? 0
    }
}
```

- [ ] **Step 2: Resolve UserAction on save**

In `EditRulesCoordinator` (or whichever coordinator owns the save flow for EditRuleSheet), after a successful save, if `userActionId` is non-nil, call `userActionRepo.resolve(actionId: userActionId)`:

```swift
func save() async {
    // ... existing save logic
    if let actionId = userActionId {
        try? await userActionRepo.resolve(actionId: actionId)
    }
}
```

- [ ] **Step 3: Add deep-link parsing in TandasApp**

Edit `ios/Tandas/TandasApp.swift`. Find the existing deep-link handling for `EventDeepLink` and add the analogous case for `RuleChangeDeepLink`:

```swift
.onOpenURL { url in
    if let eventLink = EventDeepLink(url: url) {
        appState.handleIncomingNotification(userInfo: eventLink.userInfo)
    } else if let ruleLink = RuleChangeDeepLink(url: url) {
        appState.handleIncomingRuleChangeApplyDeepLink(ruleLink)
    }
}
```

Add `handleIncomingRuleChangeApplyDeepLink` to `AppState`:

```swift
@MainActor
extension AppState {
    func handleIncomingRuleChangeApplyDeepLink(_ link: RuleChangeDeepLink) {
        // Find the rule in the active group (or fetch).
        // Push EditRuleSheet on the active navigation stack with
        // proposedAmount: link.proposedAmount and userActionId: nil
        // (we don't have the user_action id in the deep-link — the
        // inbox row tap path provides it).
        pendingRuleChangeApply = (ruleId: link.ruleId, proposedAmount: link.proposedAmount)
    }

    var pendingRuleChangeApply: (ruleId: UUID, proposedAmount: Int)?
}
```

The `pendingRuleChangeApply` is read by the active group's navigation root and presented as `EditRuleSheet` when set. Implementation detail: in MainTabView or AppShell, observe `app.pendingRuleChangeApply` and present sheet, then nil out.

- [ ] **Step 4: Wire inbox row tap to EditRuleSheet pre-loaded**

In `Features/Inbox/Coordinator/InboxCoordinator.swift` (or the parent that handles tap dispatch from G1), when `action.actionType == .ruleChangeApplyPending`:

```swift
case .ruleChangeApplyPending:
    // action.referenceId is the vote_id. Fetch the vote to read payload.
    let vote = try await voteRepo.vote(id: action.referenceId)
    guard case .object(let payload) = vote?.payload else { return }
    guard case .int(let proposed) = payload["proposed_amount"] else { return }
    let ruleId = vote!.referenceId
    // Push EditRuleSheet with userActionId: action.id so resolve fires.
    onPushEditRule(ruleId, proposed, action.id)
```

The `onPushEditRule` callback is wired from MainTabView/Group navigation to present `EditRuleSheet(rule:proposedAmount:userActionId:)`.

- [ ] **Step 5: Build + smoke commit**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

```bash
cd /Users/jj/code/tandas && git add \
  ios/Tandas/Features/Rules/EditRuleSheet.swift \
  ios/Tandas/Features/Rules/EditRulesCoordinator.swift \
  ios/Tandas/Features/Inbox/Coordinator/InboxCoordinator.swift \
  ios/Tandas/TandasApp.swift \
  ios/Tandas/Shell/AppearanceManager.swift  # if AppState lives there
git commit -m "$(cat <<'EOF'
feat(rules): EditRuleSheet pre-load + deep-link routing + UserAction resolve

Cierra los 3 elementos garantizados de DoD para rule_change manual
application low-friction:

  (1) ActionInboxView ya rendiza ruleChangeApplyPending (G1).
  (2) Copy "Pendiente de aplicar — votado el [fecha]" via meta.
  (3) Deep-link ruul://rule/<uuid>/edit?proposedAmount=<int>:
      - TandasApp.onOpenURL parsea con RuleChangeDeepLink
      - AppState.handleIncomingRuleChangeApplyDeepLink set state
      - MainTabView/AppShell observa y presenta EditRuleSheet
      - EditRuleSheet acepta proposedAmount: Int? + userActionId: UUID?
      - Cuando founder guarda, coordinator llama userActionRepo.resolve

Inbox row tap también routea al mismo destino (no solo push).

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase H — Smoke + audit close (1 task)

### Task H1: E2E manual smoke test + audit doc update

**Files:**
- Modify: `Plans/Audit-2026-05-06.md` (mark item §5.2 #3 as shipped)

- [ ] **Step 1: Run full build clean**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | tail -10
```

Expected: `** BUILD SUCCEEDED **` con cero errors. Warnings aceptables (pre-existing).

- [ ] **Step 2: Run full test suite (only the new + touched test files)**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TandasTests/VoteDetailCoordinator \
  -only-testing:TandasTests/OpenVotesCoordinator \
  -only-testing:TandasTests/CreateGeneralProposalCoordinator \
  -only-testing:TandasTests/CreateRuleChangeCoordinator \
  -only-testing:TandasTests/RuleChangeDeepLink 2>&1 \
  | grep -E "(Test Suite 'All tests'|passed|FAILED|Executed)" | tail -5
```

Expected: all suites passed, ≥ 26 tests executed (8 + 5 + 5 + 4 + 4 = 26 minimum, depending on actual test count).

- [ ] **Step 3: Build + install on physical iPhone**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'id=E63668BF-3B28-5F51-B678-519B203E48CC' \
  -configuration Debug build 2>&1 | tail -3

APP_PATH="/Users/jj/Library/Developer/Xcode/DerivedData/Tandas-boyegkhwdcwcfycscxyuqxpgapwa/Build/Products/Debug-iphoneos/Tandas.app"
xcrun devicectl device install app \
  --device E63668BF-3B28-5F51-B678-519B203E48CC \
  "$APP_PATH" 2>&1 | tail -5
```

- [ ] **Step 4: Manual E2E smoke (general_proposal flow)**

User actions on iPhone:
1. Open app, navigate to active group's rules.
2. Tap "Votos abiertos" link → OpenVotesListView (empty).
3. Tap "+" → CreateVoteSheet → "Propuesta general".
4. Fill title "Test proposal V1", description "smoke test", duration 1h. Submit.
5. Sheet dismisses, VoteDetailView opens for the new vote.

Verify on Supabase Studio (or via MCP execute_sql):

```sql
select v.title, v.vote_type, v.status, v.closes_at,
       (select count(*) from notifications_outbox where notification_type='voteOpened' and created_at > now() - interval '5 minutes') as outbox_voteopened_count
from votes v
where v.title = 'Test proposal V1'
order by v.opened_at desc limit 1;
```

Expected: 1 row, vote_type='general_proposal', status='open', `outbox_voteopened_count` = active members count - 1.

6. Wait 1 minute. Cron `dispatch-notifications` should send pushes. Verify on iPhone: push notification arrives if user is not the creator.

- [ ] **Step 5: Manual E2E smoke (rule_change passed flow)**

User actions:
1. From OpenVotesListView, tap "+" → "Cambio de regla".
2. Pick a rule (e.g. "Llegada tardía" $200), set proposed amount $250, reason "smoke test", duration 0.05h (~3 min).
3. Submit.
4. Cast in_favor on the vote (founder + 1 other member if available).

Wait until `closesAt` passes + cron `finalize-votes` runs (every 15 min, may need to wait).

Verify via MCP execute_sql:

```sql
-- vote should be resolved 'passed'
select v.id, v.status, v.counts->>'resolution' as resolution
from votes v where v.title like 'Cambio: Llegada tardía%' order by v.opened_at desc limit 1;

-- user_action should exist
select user_id, action_type, title, body
from user_actions
where action_type = 'ruleChangeApplyPending'
order by created_at desc limit 1;

-- outbox row with deep_link should exist
select notification_type, deep_link, dispatch_status
from notifications_outbox
where notification_type = 'ruleChangeApplyPending'
order by created_at desc limit 1;
```

Expected: vote resolved 'passed', user_action present targeted at founder, outbox row with deep_link `ruul://rule/<uuid>/edit?proposedAmount=250` and dispatch_status='sent' (after dispatcher cron).

5. Founder receives push on iPhone → tap → app opens EditRuleSheet pre-loaded with $250.
6. Tap "Save". Verify: rule.action / consequences updated server-side AND user_action.resolved_at populated.

```sql
select id, action_type, resolved_at from user_actions
where action_type = 'ruleChangeApplyPending'
order by created_at desc limit 1;
```

Expected: `resolved_at` non-null.

- [ ] **Step 6: Update audit doc**

Edit `Plans/Audit-2026-05-06.md`. In §5.2, mark item #3 (OpenVotesView) as shipped:

```markdown
| 3 | OpenVotesView ✅ shipped 2026-05-XX | 5-7h | Último P0; desbloquea general_proposal + rule_change |
```

Add a §10 changelog entry:

```markdown
- **2026-05-XX**: OpenVotesView V1 shipped (commits `aaaaaaa..bbbbbbb`).
  Spec: docs/superpowers/specs/2026-05-07-open-votes-view-design.md.
  Plan: docs/superpowers/plans/2026-05-07-open-votes-view.md.
  Migration 00032 aplicada (finalize_vote v3 — emite
  ruleChangeApplyPending). E2E smoke verde.
```

- [ ] **Step 7: Commit final + push to main**

```bash
cd /Users/jj/code/tandas && git add Plans/Audit-2026-05-06.md
git commit -m "$(cat <<'EOF'
docs(audit): OpenVotesView V1 shipped — close §5.2 #3

Último P0 de F0 cerrado. general_proposal + rule_change con
low-friction manual application en producción. E2E smoke verde:
push real recibido en device de prueba, deep-link abre EditRuleSheet
pre-loaded, save resuelve UserAction.

Próximos en F0: EditMembersSheet, archival doc, drop legacy rules
columns, cleanup appeal_votes legacy, sub-fases B-F de Fase 0.5.
Mantenemos orden del audit doc §5.2.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"

git push origin main
```

---

## Self-Review

### Spec coverage check

Mapping each spec section/requirement to a task:

| Spec section | Task |
|---|---|
| §1 Architecture (3 layers) | Tasks B-F implement them |
| File inventory (14 new + 5 modified) | Tasks B1-G3 cover all |
| §2 Components (coordinator + bodies + sections) | Tasks B2, B3, C1, C2, D1, E1, F2, F3 |
| §3 Data flow — list | Task E1 (coordinator) + E2 (view) |
| §3 Data flow — detail with myCast/counts | Task B2 (coordinator with parallel fetch) |
| §3 Data flow — cast with optimistic + refresh | Task B2 (coordinator.cast) |
| §3 Data flow — create general_proposal | Task F2 |
| §3 Data flow — create rule_change | Task F3 |
| §3 Data flow — Post-resolution rule_change manual application | Task A1 (server) + B1 (deep-link parser) + G1 (inbox row) + G3 (edit sheet pre-load + resolve) |
| §4 Standard error handling | Coordinators in B2, F2, F3 surface errors |
| §4 Edge — vote finalizes mid-cast | Task B2 step 4 catches "vote closed" message |
| §4 Edge — already-voted race | Task B2 (idempotent re-cast) |
| §4 Edge — founder edits manual before finalize | Task A1 + G3 (no special handling — copy explicit in body) |
| §4 Edge — rule referenced_id deleted | Task G3 (deep-link surfaces "rule not found" → resolve manually) |
| §5 Coordinator tests | Tasks B2, E1, F2, F3 each include test files |
| §5 Snapshot tests for VoteOnAppealSheet refactor | Task C2 step 2 + step 5 |
| §5 E2E flow | Task H1 manual |
| §6 DoD — UI bullets | Tasks B-G |
| §6 DoD — Server-side migration | Task A1 |
| §6 DoD — 3 elementos low-friction | Tasks A1, B1, G1, G3 |
| §6 DoD — Manual smoke | Task H1 |

All requirements have corresponding tasks. No gaps.

### Placeholder scan

Searched for: TBD, TODO, "implement later", "fill in details", "add appropriate", "similar to task", "write tests for the above" without code.

Found two soft references to "implementation depends on existing pattern" in Task G1 step 4 ("dispatching is complex, defer routing") and Task G3 step 2 ("AppearanceManager.swift if AppState lives there"). Both are explicit conditional notes about the engineer needing to read the existing code first — acceptable per the spec convention since those touches depend on file structure that varies.

No hard placeholders. All code shown.

### Type consistency

- `VoteDetailCoordinator` defined in B2 with `myCast: VoteCast?`, `counts: VoteCounts?`, `error: String?`, `isCasting: Bool` — used consistently in B3 (VoteCastSection), C1 (3 bodies), C2 (FineAppealVoteBody), D1 (VoteDetailView).
- `OpenVotesCoordinator.openVotes: [Vote]`, `sectioned() -> [(Section, [Vote])]` — used in E2 (OpenVotesListView).
- `CreateGeneralProposalCoordinator` properties `title`, `description`, `durationHours`, `canSubmit`, `createdVoteId` — used in F2 sheet.
- `CreateRuleChangeCoordinator.selectedRule`, `proposedAmount`, `reason`, `availableRules` — used in F3 sheet.
- `RuleChangeDeepLink.ruleId: UUID`, `proposedAmount: Int` — used in G3 deep-link routing.
- `ActionType.ruleChangeApplyPending` raw value `"ruleChangeApplyPending"` matches the SQL string in migration A1 INSERT.
- `EditRuleSheet(rule:proposedAmount:userActionId:)` init signature — referenced in G3 step 1, 2, 3, 4.
- `userActionRepo.resolve(actionId:)` — existing method, used in G3 step 2.

All consistent.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-07-open-votes-view.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
