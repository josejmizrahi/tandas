# D.24 Schema Consolidation Audit — Final Report (Operational Close)

**Status:** Operational close. 17/22 phases shipped (P0 + P1 + P2A + P3A + P4 + P5 + P6 + P7A + P8 + P9 + P9f + P10 + P10A + P10B + P10C + P12A + P12B-1..4).
**Pending:** P2B, P3B, P7B, P11, P12B-2/3/4 (the last three are shipped — pending list is P2B/P3B/P7B/P11/P13B if a follow-up is wanted).
**Dates:** Single-day burst, 2026-06-01.
**Founder gate:** Each phase was signed off explicitly before execution.

---

## 1. Executive Summary

D.24 entered as a schema consolidation audit triggered by a real testigo: D.23 had shipped Calendar Event the day before as a parallel model (`group_calendar_events*`) when `group_resources.resource_type='event'` was already in the canonical whitelist. The audit reframed: stop accumulating parallel domains, fold them back to `group_resources` with subtypes, and close the governance & observability gaps that were silently growing.

By the time of this report:
- Event is now `resource_type='event'` end-to-end (backend canonical, iOS consuming).
- Decision execution is observable (status / attempts / error surfaced on iOS).
- Role + mandate audit events emit on every change.
- Sanctions can be appealed and the appeal lives in the decision pipeline.
- External parties are first-class.
- Comments + attachments are universal (entity_kind/entity_id), with comments fully wired on backend.
- Resource creation is atomic per subtype, with client_id idempotency.
- Ownership v2 (`group_resource_owners`) is shipping in shadow of the legacy single-owner field.
- Governance routing matrix is documented and the 7 critical iOS RPCs route through `request_or_execute_action`.
- 6 read-model RPCs hidrate UI in single round-trips; 4 of them (`group_home_summary`, `resource_detail_summary`, `event_detail_summary`, `decision_live_result`) are consumed in iOS today.

A late-stage operational fix (cast_vote NULL weight) was also shipped after live testimony from the founder that voting silently failed — the bug was independent of D.24 but surfaced via D.24 stress.

---

## 2. Phases Executed

| Phase | What | Mig(s) / Commit | Result |
|---|---|---|---|
| **P0** | Audit-first inventory + classification | `Plans/Active/D24_Schema_Consolidation_Audit.md` | 22 phases identified, 13 sized, dependency graph drawn |
| **P1** | Event → resource_type='event' consolidation | `d24_p1_consolidate_event_to_resource` + `d24_p1_fix_rsvp_vocab_mapping` (17:06) | Calendar events folded onto group_resources subtype `group_resource_events`; RSVP iOS↔canon vocab mappers added; `get_event_detail` rewritten on top of canonical layer |
| **P5** | Decision Execution Observability | `d24_p5_decision_execution_observability` (17:17) | `group_decisions` += execution_status/attempts/error/payload cols + state machine; surface lift in `decision_live_result` later (P12A) |
| **P9** | Role + Mandate audit events | `d24_p9_role_mandate_audit_events` + `d24_p9_drop_legacy_role_rpc_overloads` (17:26) | `group_events` emits role/mandate.* on every assignment/revoke; ambiguous 2-arg role RPCs dropped |
| **P9f** | source_decision_id wiring for role assignments | bundled into `d24_p9_followup_and_p8_sanction_appeals` (17:33) | Role/mandate events now carry `source_decision_id` when origin is a passed decision |
| **P8** | Sanction Appeals | `d24_p9_followup_and_p8_sanction_appeals` + `d24_p8_fix_decision_rules_read` + `d24_p8_fix_status_ambiguous` (17:33–39) | `group_sanctions` += appealed_at/appeal_decision_id/appeal_status; appeal routes through `execute_decision` |
| **P4** | External Parties | `d24_p4_external_parties` (17:45) | `group_external_parties` first-class, party_types whitelist (10), perms, referenced by P3A owners |
| **P6** | Universal Comments | `d24_p6_comments` (17:49) | `group_comments` polymorphic (`entity_kind/entity_id`), status lifecycle, perms (`comments.*`), audit emit |
| **P7A** | Universal Attachments (backend) | `d24_p7a_attachments_backend` (17:53) | `group_attachments` shape mirror of comments, no Storage bucket yet (deferred to P7B) |
| **P2A** | Atomic resource creation RPCs | `d24_p2a_atomic_resource_creation_rpcs` (17:58) | 6 subtype wrappers (`create_event_resource`/`asset`/`fund`/`space`/`slot`/`right`) + `client_id` idempotency on `group_resources` |
| **P3A** | Ownership v2 (backend) | `d24_p3a_ownership_v2_backend` (18:02) | `group_resource_owners` first-class (member/external_party/group), pct≤100 guard, same-group enforcement, backfill 77 rows from legacy single-owner |
| **P10** | Governance bypass audit (report only) | `Plans/Active/D24_P10_Governance_Bypass_Audit.md` | 134 mutating RPCs classified P0–P3; 7 P0 iOS gaps named; constitutional matrix sketched |
| **P10A** | iOS callsite audit | `Plans/Active/D24P10A_iOS_Governance_Bypass_Callsite_Audit.md` | 7 stores flagged for wrap; one false-positive corrected (`BoundaryPolicyStore` was already governance-aware) |
| **P10B** | iOS governance wraps (7 RPCs) | commit `260fa59c` | 6 repos extended with `*ViaGovernance` variants + 7 stores switch on `ActionOutcome`; `D24P10B_Governance_Routing_Matrix.md` shipped as constitutional doc |
| **P10C** | Governance bypass smoke | (smoke run only) | 15/15 PASS — resolver behavior validated per action_key × role tier matrix |
| **P12A** | Read models (backend) | `d24_p12a_read_models` + `d24_p12a_event_detail_summary_fix_counts` + `d24_p12a_fix_decision_live_result_voter_col` (19:00–19:03) | 6 jsonb RPCs: `group_home_summary`, `resource_detail_summary`, `event_detail_summary`, `decision_live_result`, `member_balance_summary`, `activity_feed` |
| **P12B-1** | iOS adopt `group_home_summary` | commit `260fa59c` | `GroupHomeSummary` domain + store + repo + wired permissions on GroupHomeFeedView |
| **P12B-1.x** | Consume counts + recentActivity | commit `260fa59c` | `recentEvents` prefers summary; 3 count badges in section headers |
| **P12B-2** | ResourceDetail adopt `resource_detail_summary` | commit `bb0b9ad2` | `ResourceDetailSummary` + `ResourceOwnerItem` + `ResourceCapabilityItem`; participationSection rendered for real (owners + capabilities + counts) |
| **P12B-3** | CalendarEventDetail adopt `event_detail_summary` | commit `2f774bfe` | `CalendarEventDetailSummary` (superset + counts); 6 mutations recargan via `reloadDetailHydration` helper |
| **P12B-4** | DecisionDetail adopt `decision_live_result` | commit `c4670b5a` | `DecisionLiveResult` (complementary, not replacement); quorum/threshold rows show fresh progress; new executionStatusSection |
| **Hotfix** | cast_vote NULL weight | `fix_cast_vote_weight_null_default` (21:12) + commit `73b5f445` | `group_votes.weight` is `NOT NULL DEFAULT 1` — INSERT was overriding default with explicit NULL; fixed with `COALESCE(p_weight, 1)` |

**Total this audit:**
- 18 backend migrations applied to live + repo.
- 5 iOS commits to main.
- 5 design / audit docs in `Plans/Active`.

---

## 3. Schema State

### Before D.24
- **Parallel models:** `group_calendar_events*` table cluster duplicated what `group_resources` already supported via `resource_type='event'`.
- **Event audit:** `entity_kind` did not consistently use `'resource'` for events; some shipped with their own `'calendar_event'` kind.
- **Decisions:** Could pass but had no observable execution lifecycle — once `status='passed'`, what happened next was opaque.
- **Ownership:** Single `group_resources.owner_membership_id` field — no co-ownership, no percentages, no external parties as owners, no provenance to a decision.
- **External parties:** Absent. Resources could only be owned by group or member.
- **Comments / attachments:** Absent on backend. UI consistently said "TODO" or relied on `group_events.payload` for ad-hoc text.
- **Governance pipeline:** `action_catalog` + `request_or_execute_action` existed but iOS used legacy direct RPCs in 7 critical paths (mandates.revoke, role.assign/revoke, dispute.resolve, sanction.issue, resource.fund.lock, resource.right.transfer).
- **Read models:** Each detail screen made 2–5 separate RPCs to hidrate.
- **Resource creation:** Two-step (envelope then subtype) with no atomicity — partial failures could leave orphans.

### After D.24
- **Single canonical resource model:** Event lives in `group_resources` + `group_resource_events` subtype. RSVP/check-in actions on `group_*_actions` polymorphic tables. iOS `CalendarEvent` API is preserved as a façade.
- **First-class tables added:**
  - `group_external_parties` (P4)
  - `group_comments` (P6)
  - `group_attachments` (P7A — bucket pending)
  - `group_resource_owners` (P3A)
- **Decisions augmented:** `execution_status / execution_attempts / execution_error / execution_payload` columns + emitted state transitions.
- **Sanctions augmented:** `appealed_at / appeal_decision_id / appeal_status` + appeal flow through `execute_decision`.
- **Role/mandate audit:** Every assignment/revoke emits `role.*`/`mandate.*` with `source_decision_id` when applicable.
- **Resource creation atomic:** 6 subtype wrappers + `client_id` idempotency.
- **Governance pipeline applied:** 7 P0 RPCs in iOS route through `request_or_execute_action`; resolver behavior smoke-tested.
- **Read models:** 6 jsonb RPCs hidrate UI in single round-trips.

---

## 4. iOS State

| Screen | Read model adopted | Commit | Notes |
|---|---|---|---|
| GroupHomeFeedView | `group_home_summary` | `260fa59c` | Permissions + counts + recentActivity[10] consumed; section headers show count badges; fallback to legacy fetches if RPC fails |
| ResourceDetailView | `resource_detail_summary` | `bb0b9ad2` | Subtype polymorphic + owners + capabilities + counts + activity; participationSection rendered for real; legacy `loadDetail` + `loadActivity` as safety net |
| CalendarEventDetailView | `event_detail_summary` | `2f774bfe` | Strict superset + comments/attachments counts; `reloadDetailHydration` helper recarga summary+detail post-mutación |
| DecisionDetailView | `decision_live_result` | `c4670b5a` | Complementary to `decision_detail` — surfaces fresh tally + quorum/threshold progress + execution state |

**Governance wraps (P10B) — 6 repos extended:**
- `CanonicalMandatesRepository.revokeViaGovernance`
- `CanonicalRolesRepository.assignRoleViaGovernance` / `revokeRoleViaGovernance`
- `CanonicalDisputesRepository.recordResolutionViaGovernance`
- `CanonicalSanctionsRepository.issueSanctionViaGovernance`
- `CanonicalResourcesRepository.lockFundViaGovernance`
- `CanonicalResourcesRepository.transferRightViaGovernance`

**Stores updated to switch on `ActionOutcome`:**
- MandatesStore, RolesStore, DisputesStore, SanctionsStore, ResourcesStore

**Pending UX polish (not blocking):** uniform banner for `lastGovernanceOutcome.decisionOpened` in 5+ surfaces; currently only MembersStore has it.

---

## 5. Open Risks

### P2B — Block direct inserts to `group_resources`
**Risk:** Atomic creation RPCs (P2A) exist but callers can still INSERT directly bypassing subtype validation.
**Mitigation today:** All iOS code paths go through the atomic wrappers. Direct DB writes are admin-only.
**Why deferred:** Founder gating; deserves a follow-up sprint after iOS adoption is fully verified in the wild.

### P3B — Drop `group_resources.owner_membership_id`
**Risk:** Legacy single-owner field still load-bearing for code that hasn't migrated to `group_resource_owners`. Cannot drop until every reader is on the new table.
**Mitigation today:** Both fields coexist; P3A backfilled the legacy field into ownership rows.
**Why deferred:** Requires audit of every iOS surface that reads `ownerMembershipId`. ResourceDetailView's `participationSection` already reads owners[] from summary when available.

### P7B — Storage bucket + iOS PhotosPicker
**Risk:** `group_attachments` table exists but no Storage bucket configured. The iOS UI cannot upload yet.
**Mitigation today:** Counts surface in detail summaries (so the UI can show "0 attachments" without lying), but the picker is absent.
**Why deferred:** Operational task (bucket policy + signed URLs + RLS); not blocked architecturally.

### P11 — Double-entry ledger
**Risk:** Money movements still use single-entry. P11 was scoped as a design-doc-only deliverable; founder decided not to start until the consolidation dust settles.
**Mitigation today:** Existing money RPCs are correct; this is a future correctness/auditability upgrade.

### Operational risk surfaced during D.24
**cast_vote NULL weight (FIXED):** `group_votes.weight NOT NULL DEFAULT 1` plus explicit NULL in INSERT broke every non-weighted vote silently in production. Fixed in `73b5f445`. Lesson for future audits: when adding `NOT NULL DEFAULT` columns, audit every RPC that inserts that column and either drop the column from the explicit list or pass `COALESCE(p_x, default)`.

---

## 6. Metrics

| Metric | Count |
|---|---|
| New backend migrations (D.24) | 18 |
| New tables | 4 (`group_external_parties`, `group_comments`, `group_attachments`, `group_resource_owners`) |
| New SECURITY DEFINER RPCs (read models) | 6 |
| New SECURITY DEFINER RPCs (write / atomic) | 9 (6 subtype creators + `add_resource_owner` + `end_resource_owner` + `list_resource_owners`) |
| New audit event types | 8+ (role.*, mandate.*, resource.owner_added/removed, sanction.appealed/appeal_resolved, comment.*, attachment.*) |
| Columns added to existing tables | 7 (`group_decisions` × 4, `group_sanctions` × 3, plus `group_resources.client_id`) |
| Governance wraps (iOS) | 7 RPCs across 6 repositories |
| iOS commits | 5 (4 phase commits + 1 hotfix) |
| iOS files added | 5 (`GroupHomeSummary`, `GroupHomeSummaryStore`, `ResourceDetailSummary`, `DecisionLiveResult`, governance routing matrix doc) |
| Smoke test pass rate | 15/15 P10C + 9/9 P12A + per-phase smokes all green |

---

## 7. Resulting Doctrines (most important — formalize)

These are the load-bearing patterns this audit produced. Future work should treat them as constraints, not suggestions.

### 7.1 Event = Resource
> Any new gobernable object is a `group_resources` row with `resource_type` in the whitelist + a typed subtype in `group_resource_<type>`. **No parallel `group_<thing>_*` table clusters.**
- Audit doc: `doctrine_event_is_resource_type.md`
- Testigo: D.23 → D.24 P1 (folded back in 0 user-visible rows).

### 7.2 Ownership = `group_resource_owners`
> The source of truth for who owns / co-owns / stewards / custodies a resource is the `group_resource_owners` table. `group_resources.owner_membership_id` is legacy and will be dropped in P3B.
- 4 owner kinds: `member` / `external_party` / `group` / `other`.
- Pct ≤ 100 guard enforced per resource_id by trigger.
- Same-group enforcement: owner, resource, membership, external_party must all share group_id.
- Provenance: `source_decision_id` links to the decision that granted/changed ownership.

### 7.3 Governance = `action_catalog` + `request_or_execute_action`
> Any iOS mutation that maps to an `action_catalog` row must go through `request_or_execute_action`. The store branches on `ActionOutcome` (`.executed` / `.directAllowed` / `.decisionOpened` / `.denied` / `.unsupported` / `.failed`).
- Constitutional matrix: `Plans/Active/D24P10B_Governance_Routing_Matrix.md`.
- Resolver behavior is smoke-tested per action_key × role tier (P10C).
- Tier-aware: founder/admin/member/guest with privileged-target escalation (e.g., `role.assign` to founder always opens a decision regardless of caller role).

### 7.4 Read Models = source of UI hydration
> Detail screens prefer a single read-model RPC over N legacy fetches. The store loads the summary first (no-throws), and the view falls back to the legacy path if summary is nil.
- 6 read models in production: `group_home_summary`, `resource_detail_summary`, `event_detail_summary`, `decision_live_result`, `member_balance_summary`, `activity_feed`.
- Pattern: `LoadSummary` is best-effort; legacy fetchers stay as safety net until adoption is verified.
- iOS computed props branch on summary presence: `if let s = summary { ... } else { ... store.detail ... }`.

### 7.5 Comments are universal
> Any entity that should accept user comments uses `group_comments` with `entity_kind / entity_id`. No domain-specific comment tables.
- Status lifecycle: `active / hidden / deleted`.
- Counts surface in detail summaries (`comments_count`).

### 7.6 Attachments are universal
> Same shape as comments. Storage bucket + iOS uploader is P7B; the table is ready.
- Counts surface in detail summaries (`attachments_count`).

### 7.7 Auxiliary doctrines confirmed
- **Append-only audit:** `group_events` is append-only with `atom_no_delete_guard` + `atom_no_update_guard`. Read patterns use DISTINCT ON `(entity_id) ORDER BY occurred_at DESC` for latest-state queries.
- **Atomic creation:** Subtype writers (`create_event_resource` et al.) wrap envelope + subtype INSERT in PL/pgSQL transactions; partial failures roll back the envelope.
- **client_id idempotency:** Add `client_id text` + partial unique index `WHERE client_id IS NOT NULL` on any user-creatable canonical table. iOS passes a stable UUID to dedupe retries.
- **Same-group enforcement:** Cross-group references are blocked at the trigger level, not at app level.
- **NULL-safety on `NOT NULL DEFAULT` columns:** Always `COALESCE(p_x, default)` in INSERT lists. Explicit NULL overrides column default and dispatches the constraint.

---

## 8. After this Report — Recommended Sequence

Per founder firm:

```
P13A Final Report (← you are here)
        ↓
P2B  — Block direct inserts on group_resources
        ↓
P3B  — Drop group_resources.owner_membership_id
        ↓
P7B  — Storage bucket + PhotosPicker
        ↓
P11  — Double-entry ledger design doc
```

Rationale: P2B and P3B are natural consequences of the consolidation already done. P7B is operational delta with no architectural risk. P11 is the only phase that introduces a new architectural pattern — best done after the rest settles.

---

## 9. Appendix — Plans referenced

- `Plans/Active/D24_Schema_Consolidation_Audit.md` (P0)
- `Plans/Active/D24_P10_Governance_Bypass_Audit.md` (P10)
- `Plans/Active/D24P10A_iOS_Governance_Bypass_Callsite_Audit.md` (P10A)
- `Plans/Active/D24P10B_Governance_Routing_Matrix.md` (P10B — constitutional doc)

These remain in `Plans/Active/` until P2B/P3B/P7B/P11 close, at which point they can move to `Plans/Completed/` alongside this report.
