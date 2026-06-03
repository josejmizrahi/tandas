# D24P10B — Governance Routing Matrix

**Status:** SHIPPED 2026-06-01. iOS BuildProject verde. Cero migrations.
**Doctrina:** esta tabla es la **constitución operacional** de Ruul: para cada acción mutante, qué se puede hacer direct vs qué exige governance, y con qué threshold.

---

## Cómo leer

- **Action key**: el slug canónico en `action_catalog`.
- **Direct allowed**: cuándo el actor con permiso puede ejecutar inmediato (sin abrir voto).
- **Governance required**: cuándo se debe abrir decisión vía `request_or_execute_action`. El resolver (`resolve_action_governance`) decide.
- **Threshold**: el corte que separa direct de governance. `N/A` cuando es per-rol o per-target.
- **iOS callsite**: dónde se invoca desde iOS, y qué store/repo lo maneja.

Todas las rows con governance pasan por la pipeline `ActionOutcome` (`.executed / .decisionOpened / .denied / .unsupported / .failed`).

---

## Constitution Matrix — Actions P0/P1

### P0 — Constitutional (must pass governance)

| Action key | Direct allowed | Governance required | Threshold | iOS callsite |
|---|---|---|---|---|
| `membership.suspend` / `membership.pause` / `membership.reinstate.from_banned` | none — siempre sheet | siempre via `setMembershipStateViaGovernance` | N/A | `MembersStore.saveStateDraft` (sheet) |
| `membership.leave` (self) | self always direct | non-self via governance | N/A | `MembersStore.rejectRequest` direct (self-only doctrine) |
| `membership.ban` / `membership.remove` | none — siempre sheet | siempre via governance | N/A | `MembersStore.saveStateDraft` |
| `role.assign` | role-key ∈ {custom roles} → direct con `roles.manage` | role-key ∈ {founder, admin} → governance | role-key | `RolesStore.assignRole(membershipId, roleId, groupId)` D24P10B |
| `role.revoke` | role-key ∈ {custom roles} → direct con `roles.manage` | role-key ∈ {founder, admin} → governance | role-key | `RolesStore.revokeRole(membershipId, roleId, groupId)` D24P10B |
| `role.create` | none | siempre governance (rol nuevo = constitution) | N/A | `RolesStore` `createCustomRoleViaGovernance` |
| `role.update_permissions` | none | siempre governance | N/A | `RolesStore` `updateRolePermissionsViaGovernance` |
| `group.visibility.set` | founder direct (override) | else governance | N/A | `PrivacyStore.changeVisibility` via `setVisibilityViaGovernance` |
| `group.boundary.set` | none | siempre governance | N/A | `BoundaryPolicyStore.saveDraft` via `setPolicyViaGovernance` |
| `group.decision_rules.set` | none | siempre governance | N/A | `DecisionRulesStore.saveDraft` via `setDecisionRulesViaGovernance` |
| `engine.toggle` | admin con `engine.toggle` direct via execute_decision branch | member solicita | role | `GroupEngineSettingsView` via execute_decision |
| `resource.transfer` (ownership) | self → direct si actor es current owner | else governance | actor==owner | `ResourcesStore.saveTransfer` via `transferOwnershipViaGovernance` |
| `resource.archive` | actor con `resources.archive` y resource sin obligations vivas → direct | con obligations vivas o member sin perm → governance | obligations | `ResourcesStore.archive` via `archiveResourceViaGovernance` |
| `mandate.grant` | none | siempre governance (delegar autoridad = constitutional) | N/A | `MandatesStore.saveDraft` via `grantViaGovernance` |
| `mandate.revoke` (D24P10B) | admin con `mandates.revoke` y mandate granted_by==caller → direct | else governance | granter==actor | `MandatesStore.revoke(mandateId, reason, groupId)` D24P10B |
| `dispute.resolve` (D24P10B) | admin con `disputes.mediate` direct para casos no sancionatorios | resolución con sanción asociada → governance | mediator vs vote | `DisputesStore.saveResolveDraft` via `recordResolutionViaGovernance` D24P10B |
| `sanction.dispute` (start appeal) | target o admin con `sanctions.dispute` direct | N/A — el appeal abre decisión per se | target/perm | `start_sanction_appeal` direct (PHASE 8) |
| `decision.create/vote/finalize/cancel` | pipeline misma (no se gobierna a sí misma) | N/A | N/A | `DecisionsStore.*` direct |
| `group.dissolve.start` | admin con `group.dissolve` direct | N/A — el propose abre el flujo | starter | `DissolutionStore.propose` direct |
| `group.dissolve.finalize` | none | siempre via execute_decision | N/A | backend-only via execute_decision.dissolution |
| `rule.archive` | admin con `rules.archive` → direct si rule.author==actor | else governance | author==actor | `RulesStore.archive` via `archiveRuleViaGovernance` |
| `rule.publish` (publish_rule_version) | none | siempre via execute_decision (post-vote) | N/A | backend-only |

### P1 — High risk (governance recomendado bajo threshold)

| Action key | Direct allowed | Governance required | Threshold | iOS callsite |
|---|---|---|---|---|
| `money.sanction.issue` (D24P10B) | `sanctions.create` para non-monetary → direct | monetary > threshold → governance | `groups.governance.action_thresholds.money_sanction_issue` (default backend) | `SanctionsStore.saveDraft` via `issueSanctionViaGovernance` D24P10B |
| `resource.fund.lock` (D24P10B) | none (lock irreversible) | siempre governance | N/A | `ResourcesStore.confirmLockFund(groupId)` via `lockFundViaGovernance` D24P10B |
| `resource.fund.unlock` | admin con `bookings.cancel` o similar → direct | none | N/A | `ResourcesStore.confirmUnlockFund` direct (revertir lock = más fácil) |
| `resource.right.transfer` (D24P10B) | self (holder==caller) → direct | non-self → governance | holder==actor | `ResourcesStore.saveTransferRight(groupId)` via `transferRightViaGovernance` D24P10B |
| `resource.right.revoke` | actor con `resources.update` → direct | non-revoker target → governance | role-based | `ResourcesStore.revokeRight` direct (P1, deferred wrap) |
| `money.transaction.reverse` | none | siempre via execute_decision.money_movement | N/A | backend-only |
| `money.payout` | none | siempre via execute_decision.money.payout | N/A | backend-only |
| `resource.value.update` | actor con `resources.update_value` → direct | cambio > X% delta → governance (FUTURE) | delta % | `RecordValuationSheet` direct (P1, deferred) |
| `norm.promote_to_rule` | none | siempre via execute_decision.norm | N/A | backend-only |
| `sanction.appeal.execute` (upheld/reduced/overturned) | none | siempre via execute_decision (PHASE 8) | N/A | backend-only |

### P2 — Operational (mantener direct + perm gate)

| Action key | Notes |
|---|---|
| `money.expense.record`, `money.settlement.record`, `money.contribution.record/log/non_monetary/verify` | Ledger entries. Doctrine `registrar≠aprobar` — todo miembro registra. |
| `money.peer_obligation.record` | Engine emit. |
| `money.payment_plan.propose/cancel` | Target o admin. |
| `money.sanction.pay` | Target paga. |
| `external_parties.read/manage` | Admin CRUD operativo. |
| `culture.propose/endorse/retire` (norms) | Cultural process. |
| `reputation.record/retract` | Per doctrine. |
| `members.invite/revoke/request/approve` | Membership boundary tiene su propia governance interna. |
| Resources operacionales | RSVP, booking, check-in, assign/release slot, mark condition, valuation record, custodian assign/release. |

### P3 — Low risk

| Action key | Notes |
|---|---|
| Calendar events (`create/update/cancel/archive/respond/add_attendee/remove_attendee/add_reminder/remove_reminder`) | OK direct (D.24 P1 consolidated) |
| Resources CRUD operacional (`create_*_resource`, `update`, `create_resource_series`, `update_resource_series`, capabilities enable/disable) | OK direct |
| Comments (`create_group_comment/archive_group_comment`) | OK direct (D.24 P6) |
| Attachments (`create_group_attachment_metadata/archive_group_attachment`) | OK direct (D.24 P7A) |
| Self-service (`my_profile/update_my_profile/mark_inbox_read/mark_all_inbox_read/set_notification_preference/register_my_notification_token/delete_and_export_my_data`) | OK direct (user actúa sobre su propia info) |
| Internal helpers (`record_system_event/evaluate_rules_for_event/handle_new_auth_user/expire_mandate_if_due`) | OK direct (system, not user-facing) |

---

## Cambios shipped en D24P10B (resumen)

**3 repos extendidos con variantes `*ViaGovernance`:**

1. `CanonicalMandatesRepository.revokeViaGovernance(groupId, mandateId, reason?)` → `mandate.revoke`
2. `CanonicalRolesRepository.assignRoleViaGovernance / revokeRoleViaGovernance` → `role.assign / role.revoke`
3. `CanonicalDisputesRepository.recordResolutionViaGovernance` → `dispute.resolve`
4. `CanonicalSanctionsRepository.issueSanctionViaGovernance` → `money.sanction.issue`
5. `CanonicalResourcesRepository.lockFundViaGovernance` → `resource.fund.lock`
6. `CanonicalResourcesRepository.transferRightViaGovernance` → `resource.right.transfer`

(Boundary policy ya estaba en governance — el audit P10A se equivocó al flagear.)

**6 stores actualizadas con switch ActionOutcome:**

1. `MandatesStore.revoke(mandateId, reason, groupId)` — nueva firma + outcome handling
2. `RolesStore.assignRole(membershipId, roleId, groupId) / revokeRole(...)` — nueva firma. Lookup interno por `role.key`: founder/admin → governance, custom → direct.
3. `DisputesStore.saveResolveDraft` — outcome handling
4. `SanctionsStore.saveDraft` — outcome handling
5. `ResourcesStore.confirmLockFund(groupId)` — nueva firma + outcome handling
6. `ResourcesStore.saveTransferRight(groupId)` — nueva firma + outcome handling

**2 stores que ya tenían `lastGovernanceOutcome`:** `MembersStore`, `MandatesStore`, `BoundaryPolicyStore`, `RolesStore`, `ResourcesStore`, `RulesStore`, `DecisionRulesStore`, `PrivacyStore`.

**3 stores ahora con `lastGovernanceOutcome` agregado:** `DisputesStore` (D24P10B), `SanctionsStore` (D24P10B).

**3 call-sites iOS modificados:**
- `MemberDetailView.toggle(role:)` — pasa `groupId`
- `ResourceDetailView` fund lock confirm dialog — pasa `groupId`
- `TransferRightSheet.save()` — pasa `groupId`

---

## Threshold doctrine

Per memory `doctrine_action_governance_tiers.md`: thresholds por grupo viven en `groups.governance.action_thresholds` jsonb. Hoy solo `money.sanction.issue` y `engine.toggle` lo consultan. El resto usan defaults backend o role-tier.

**Recommended thresholds per group (default backend si grupo no lo override):**

| Action | Default threshold | Override key |
|---|---|---|
| `money.sanction.issue` | monetary && amount > $500 MXN | `groups.governance.action_thresholds.money_sanction_issue` |
| `money.payout` | amount > $1,000 MXN | `money_payout` (future) |
| `money.transaction.reverse` | always governance | N/A |
| `resource.value.update` | delta > 25% | `resource_value_update_pct` (future) |
| `engine.toggle` | role=member solicita | role-based |

---

## Smoke / validación

D24P10B es iOS-only (3 repos + 6 stores + 3 callsites). Backend ya tenía `action_catalog` y `request_or_execute_action` listos.

**Smoke iOS:** BuildProject verde tras Wave 1, Wave 2 y full.

**Smoke backend pendiente (D24P10C):** test cada nuevo action_key con `role=member` sin perm → governance dispara (no error). Founder spec: "después de D24P10B, ahí sí D24P10C".

---

## Pending implications

### iOS UX (sesiones futuras opcionales)

Para mostrar `lastGovernanceOutcome.decisionOpened` en cada store, las views ya tienen el patrón (memory `doctrine_action_governance_tiers.md`):
- `MandatesListView` → banner "Decisión abierta para revocar mandato"
- `RolesListView` / `RoleEditorView` → banner "Decisión abierta para asignar/revocar rol founder/admin"
- `ResolveDisputeView` → banner "Resolución pasará por voto"
- `IssueSanctionSheet` → banner "Sanción monetaria > threshold pasará por voto"
- `ResourceDetailView` fund lock → banner "Lock irreversible pasará por voto"
- `TransferRightSheet` → banner "Transferencia a tercero pasará por voto"

Hoy el outcome se almacena en `*Store.lastGovernanceOutcome` y la sheet/dialog se cierra; pero la UI no muestra el banner explícito en todos los casos (`MembersStore` ya lo hace). Banner uniforme = sesión iOS UX separada.

### Backend smoke (D24P10C — recomendado)

```sql
-- Por cada action_key wrapped, verificar:
-- 1. role=member sin perm → ActionOutcome decisionOpened
-- 2. role=admin con perm → ActionOutcome directAllowed → side effects aplicados
-- 3. role=member con perm (raro) → directAllowed
-- 4. action_key inexistente → unsupported
```

### Constitución viva

Este doc debe regenerarse cada vez que se agregue un nuevo action_key o que se cambie el threshold de un dominio. Es la fuente de verdad de "qué necesita voto, qué no".
