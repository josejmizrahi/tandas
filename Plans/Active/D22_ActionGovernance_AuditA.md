# D.22 — Action Governance Layer · FASE A (Auditoría)

**Fecha:** 2026-05-31
**Status:** FASE A entregada, FASE B–I pendiente de aprobación.
**Source of truth:** live DB (`fpfvlrwcskhgsjuhrjpz`) + repo `ios/Packages/RuulCore/Sources/RuulCore/API/SupabaseRuulRPCClient.swift`.

> Antes de implementar el catálogo, resolver y executor (FASES B–E), validar esta auditoría con el founder. Toda la matriz se construyó leyendo verbatim:
> - 175 funciones `public.*` (140 DEFINER de dominio)
> - `permissions` (53 keys, 12 categorías)
> - `decision_templates_catalog` (12 templates)
> - `membership_state_transitions_catalog` (14 transitions)
> - `execute_decision` body (9 reference_kinds)
> - 80+ call sites iOS concentrados en `SupabaseRuulRPCClient.swift`

---

## 1. Hallazgos cabeza

### 1.1 Lo que YA existe (no reconstruir)

| Pieza | Ubicación | Cumple |
|---|---|---|
| Dispatcher polimórfico | `execute_decision()` switch on `reference_kind` + `metadata.action`/`target_state` | Sí — 9 ramas: sanction, dispute, mandate_grant, mandate_revoke, dissolution, membership, rule, pool_charge, resource (4 sub-actions). |
| Catálogo de decisiones | `decision_templates_catalog` (D.18) | Parcial — 12 templates: membership (5), resource (2), rule (1), money (2: budget+expense), custom. Falta engine.toggle, payout, role.update, mandate.grant, group.dissolve etc. |
| Catálogo de transiciones membership | `membership_state_transitions_catalog` | Parcial — sólo `banned→active` marca `requires_decision=true`. `active→banned/removed/suspended` quedan como permission-only, contradicción con doctrine D.20. |
| Permisos canónicos | `permissions` (53 keys) | Sí — granularidad fina (members.invite/pause/suspend/remove, resources.archive/transfer/update_value, rule.create/publish/archive, engine.toggle, group.dissolve, etc.). |
| iOS API surface concentrada | `SupabaseRuulRPCClient.swift` (1 archivo, ~80 RPCs) | Sí — ningún feature view llama RPC directo. Migrar a `request_or_execute_action()` se hace en un solo archivo. |

### 1.2 Lo que NO existe (gaps de la capa)

| Gap | Severidad |
|---|---|
| **A.** No hay tabla `action_catalog` ni columna `action_key` en `group_decisions`. Hoy se infiere de `(reference_kind, metadata.action)`. Funciona pero no es introspectable ni configurable por grupo. | Alta |
| **B.** No hay `resolve_action_governance()`. Cada RPC enforce su propio `assert_permission()` pero ninguno consulta "¿debería esto pasar por decisión?". | Alta |
| **C.** No hay `request_or_execute_action()`. iOS llama RPC final directo y nunca recibe `decision_opened`. | Alta |
| **D.** Múltiples RPCs callables directo a pesar de tener template de decisión definido (ver §3 gap matrix). | Crítica |
| **E.** `decision_templates_catalog.metadata` no soporta umbrales (threshold/currency). `money.record_expense` no tiene forma declarativa de decir "> X → decisión". | Media |
| **F.** `membership_state_transitions_catalog` sólo enforce decision en `banned→active`. Drift contra doctrine D.20. | Media |
| **G.** iOS no tiene UX para responder `status=decision_opened` (sólo maneja success/void/uuid). | Alta |

---

## 2. Inventario completo: action_key → RPC → iOS → governance

Convención: `<dominio>.<verbo>` o `<dominio>.<entidad>.<verbo>`.

**Leyenda de columnas:**
- **Perm.** = `permissions.key` que el RPC ya hoy enforce vía `assert_permission()`.
- **Decisión hoy** = ¿la única forma de invocar la acción canónicamente es vía `execute_decision`? (`direct` / `decision-only` / `dual`).
- **Debería** = mi recomendación: `direct` (ok), `decision` (riesgo alto → pasar siempre por voto), `threshold` (gating por monto), `self-only` (self-scoped, ok direct).
- **Gap** = qué falta para alinear "hoy" con "debería".

### 2.1 Identity (self-scoped) — 4 acciones · Tier 0 todas

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `identity.profile.read` | `my_profile` | `getMyProfile` :1461 | — | direct | self-only | — |
| `identity.profile.update` | `update_my_profile` | `updateMyProfile` :1472 | — | direct | self-only | — |
| `identity.gdpr.delete_export` | `delete_and_export_my_data` | (no wired) | — | direct | self-only | iOS missing wire. |
| `identity.token.register` | `register_my_notification_token` | `registerNotificationToken` :1163 | — | direct | self-only | — |

### 2.2 Group lifecycle — 5 acciones

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `group.create` | `create_group` | `createGroup` :22 | (any auth) | direct | direct | — |
| `group.purpose.set` | `set_group_purpose` | :258 | `purpose.set` | direct | direct | — |
| `group.purpose.archive` | `archive_group_purpose` | (no wired) | `purpose.set` | direct | direct | — |
| `group.visibility.set` | `set_group_visibility` | :1182 | `group.update` | direct | **decision** | Cambio doctrinal del grupo → no debería ser admin-direct. **Falta template `decision.group_visibility`.** |
| `group.boundary.set` | `set_group_boundary_policy` | :1289 | `group.update` (?) | direct | **decision** | Cambia política de entrada/salida → autoridad. **Falta template `decision.group_boundary`.** |

### 2.3 Group meta — governance & engine — 3 acciones (todas META)

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `group.decision_rules.set` | `set_decision_rules` | :825 | `roles.manage` (?) | direct | **decision (meta)** | Cambiar cómo se decide = decisión sobre decisiones. **Falta template `decision.governance_change`.** |
| `engine.toggle` | `set_group_engine_active` | :426 | `engine.toggle` | direct | **decision** | Activar/desactivar autoridad automática del grupo. **Falta template `decision.engine_toggle`.** |
| `group.dissolve.start` | `propose_dissolution` | :1207 | `group.dissolve` | direct | direct (es propose) | — |
| `group.dissolve.approve` | `approve_dissolution` | — | `group.dissolve` | via `execute_decision` (reference_kind='dissolution') | decision | OK — ya gateado. |
| `group.dissolve.finalize` | `finalize_dissolution` | :1215 | `group.dissolve` | direct | decision | Debería sólo ejecutarse post-aprobación. |
| `group.dissolve.record_step` | `record_liquidation_step` | (no wired) | `group.dissolve` | direct | direct | — |

### 2.4 Membership — 9 acciones (CRÍTICO)

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `membership.invite` | `invite_member` | :37 | `members.invite` | direct | direct (gated por boundary policy) | — |
| `membership.invite.revoke` | `revoke_invite` | :46 | `members.invite` | direct | direct | — |
| `membership.invite.accept` | `accept_invite` | :51 | (self con code) | direct | self-only | — |
| `membership.request` | `request_membership` | :1565 | (any auth) | direct | direct | — |
| `membership.request.approve` | `approve_membership_request` | :545 | `members.invite` | direct | direct (o decisión si boundary.entry=vote) | Falta gate por `groups.boundary.entry_mode='vote'` → template `decision.membership_accept`. |
| `membership.leave` | `leave_group` | :60 | (self) | direct | self-only | — |
| `membership.pause` | `set_membership_state('paused')` | :656 | `members.pause` | direct | direct | — |
| `membership.suspend` | `set_membership_state('suspended')` | :656 | `members.suspend` | direct | **decision** | Template `decision.membership_suspend` existe pero RPC se puede llamar directo. **Cerrar puerta directa o validar contra `groups.governance.policy`.** |
| `membership.remove` | `set_membership_state('removed')` | :656 | `members.remove` | direct | **decision** | Template `decision.membership_remove_reversible` existe. Idem cerrar puerta directa. |
| `membership.ban` | `set_membership_state('banned')` | :656 | `members.remove` | direct | **decision** | Template `decision.membership_remove` existe (target_state='banned'). Idem. |
| `membership.reinstate_banned` | (via `execute_decision`) | :656 (intentado direct) | `members.update` | **decision-only** (enforced por `membership_state_transitions_catalog`) | decision | OK. |
| `membership.reinstate_other` | `set_membership_state('active')` from paused/suspended/removed/left | :656 | `members.update` | direct | direct (paused/suspended) / decision (removed) | Drift catálogo. |
| `membership.confirm_provisional` | `confirm_provisional` | (no wired) | `members.update` | direct | direct | — |

### 2.5 Resource lifecycle — 18 acciones

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `resource.create` | `create_group_resource` / `create_resource` | :638 | `resources.create` | direct | direct | — |
| `resource.update` | `update_resource` | :688 | `resources.update` | direct | direct | — |
| `resource.archive` | `archive_resource` | :648 | `resources.archive` | direct | **decision** | Template `decision.resource_archive` existe. RPC directo bypassa governance. |
| `resource.unarchive` | `revert_archive_resource` | (no wired) | `resources.archive` | direct | decision | Falta template. |
| `resource.transfer` | `set_resource_ownership` | :664 | `resources.transfer` | direct | **decision** | Template `decision.resource_transfer` existe. RPC directo bypassa. |
| `resource.value.update` | `update_resource_value` | (no wired) | `resources.update_value` | direct | **threshold** | Sin umbral declarativo. **Necesita threshold metadata.** |
| `resource.valuation.record` | `record_asset_valuation` | :721 | `resources.update_value` | direct | direct | — |
| `resource.event.lifecycle` | `record_resource_lifecycle_event` | (no wired) | `resources.record_event` | direct | direct | — |
| `resource.custodian.assign` | `assign_asset_custodian` | :708 | `resources.update` | direct | direct | — |
| `resource.custodian.release` | `release_asset_custodian` | :712 | `resources.update` | direct | direct | — |
| `resource.condition.mark` | `mark_asset_condition` | :716 | `resources.record_event` | direct | direct | — |
| `resource.book` | `book_resource` | :744 | `bookings.create` | direct | direct | — |
| `resource.book.cancel` | `cancel_booking` | :748 | `bookings.cancel` | direct | direct | — |
| `resource.right.grant` | `grant_right` | :765 | (varies) | direct | direct | — |
| `resource.right.transfer` | `transfer_right` | :769 | direct | direct | — |
| `resource.right.revoke` | `revoke_right` | :773 | direct | direct | — |
| `resource.slot.assign` | `assign_slot` | :783 | direct | direct | — |
| `resource.slot.release` | `release_slot` | :787 | direct | direct | — |
| `resource.fund.lock` | `lock_fund` | :730 | direct | direct | — |
| `resource.fund.unlock` | `unlock_fund` | :734 | direct | direct | — |
| `resource.fund.set_threshold` | `set_fund_threshold` | :738 | direct | direct | — |
| `resource.capability.enable` | `enable_resource_capability` | (no wired) | direct | direct | — |
| `resource.capability.disable` | `disable_resource_capability` | (no wired) | direct | direct | — |
| `resource.rsvp.submit` | `submit_rsvp` | (via series) | `rsvp.submit` | direct | self-only | — |
| `resource.checkin.submit` | `submit_check_in` | (via series) | `check_in.submit` | direct | self-only | — |
| `resource.checkin.no_show` | `mark_no_show` | (no wired) | direct | direct | — |
| `resource.series.create` | `create_resource_series` | :1321 | `resources.create` | direct | direct | — |
| `resource.series.update` | `update_resource_series` | :1329 | `resources.update` | direct | direct | — |

### 2.6 Money — 14 acciones (CRÍTICO: threshold gating)

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `money.expense.record` | `record_expense` | :67 | `expense.record` (+ `.record_for_others` si paid_by ≠ self) | direct | **threshold** | Falta umbral declarativo. Template `decision.expense_approval` existe pero NO se invoca para gastos altos. |
| `money.settlement.record` | `record_settlement` | :72 | `settlement.record` (+ `.record_for_others`) | direct | direct | — |
| `money.contribution.record` | `record_contribution` | :88 | `contribution.record` | direct | direct | — |
| `money.contribution.log` | `log_contribution` | :934 | `contribution.record` | direct | direct | — |
| `money.contribution.verify` | `verify_contribution` | :942 | `contribution.verify` | direct | direct | — |
| `money.contribution.non_monetary` | `record_non_monetary_contribution` | (no wired) | direct | direct | — |
| `money.pool_charge.create` | `record_pool_charge` | :107 | `pool_charge.record` | direct | **threshold** | Sin umbral. Template `decision.expense_approval` con metadata charge_kind='fee' existe pero no se invoca. |
| `money.pool_charge.batch` | `record_pool_charge_batch` | :121 | `pool_charge.record` | direct | **threshold** | Idem. |
| `money.payout` | `record_payout` | (no wired) | `payout.record` | direct | **decision** | NO existe template. Payout = salida de capital del grupo. Alto riesgo. |
| `money.peer_obligation.record` | `record_peer_obligation` | (no wired) | direct | direct | — |
| `money.transaction.reverse` | `reverse_transaction` | (no wired) | `money.transaction.reverse` | direct | **decision** | Alto riesgo. Falta template `decision.transaction_reverse`. |
| `money.sanction.issue` | `issue_sanction` | :1351 | `sanctions.create` | direct | direct (o decision si rule no auto) | OK como manual. Sanciones por engine ya son auto. |
| `money.sanction.pay` | `pay_sanction` | :80 | (self) | direct | self-only | — |
| `money.sanction.update_status` | `update_sanction_status` | (via revert) | `sanctions.update` | direct | direct | — |
| `money.sanction.dispute` | `dispute_sanction` | :1072 | `sanctions.dispute` | direct | direct | — |
| `money.payment_plan.propose` | `propose_sanction_payment_plan` | :587 | direct | direct | — |
| `money.payment_plan.cancel` | `cancel_sanction_payment_plan` | :600 | direct | direct | — |

### 2.7 Rule — 6 acciones

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `rule.propose` | `propose_rule` | (no wired direct) | `rules.create` | direct | direct (es propose) | — |
| `rule.create_text` | `create_text_rule` | :283 | `rules.create` | direct | direct | — |
| `rule.create_engine` | `create_engine_rule` | :330 | `rules.create` | direct | direct | — |
| `rule.publish` | `publish_rule_version` | (no wired) | `rules.publish` | direct | **decision** | Publicar = vincula a todo el grupo. Template `decision.rule_change` existe parcial. |
| `rule.archive` | `archive_rule` | :297 | `rules.archive` | direct | **decision** | Template `decision.rule_change` (action='archive') existe pero RPC directo bypassa. |
| `rule.activate` | (via `execute_decision` rule action='activate') | — | (decision-only) | decision-only | decision | OK. |

### 2.8 Decision (meta) — 7 acciones

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `decision.create` | `start_vote` | :1417 | `decisions.create` | direct | direct | — |
| `decision.vote` | `cast_vote` | :1425 | `decisions.vote` | direct | direct | — |
| `decision.vote.ranked` | `cast_ranked_vote` | :1433 | `decisions.vote` | direct | direct | — |
| `decision.finalize` | `finalize_vote` | :1442 | `decisions.resolve` | direct | direct | — |
| `decision.execute` | `execute_decision` | :472 | `decisions.execute` | direct | direct | OK — ejecuta side effects post-passed. |
| `decision.cancel` | `cancel_vote` | :1450 | `decisions.resolve` | direct | direct | — |
| `decision.template.apply` | `apply_decision_template` | :515 | `decisions.create` | direct | direct | — |

### 2.9 Sanction / Dispute — 6 acciones

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `dispute.open` | `open_dispute` | :1108 | `disputes.open` | direct | direct | — |
| `dispute.event.append` | `append_dispute_event` | :1116 | direct | direct | — |
| `dispute.mediator.assign` | `assign_mediator` | (no wired) | `disputes.mediate` | direct | direct | — |
| `dispute.resolve` | `record_dispute_resolution` | :1124 | `disputes.resolve` | direct | direct | — |
| `dispute.escalate_to_vote` | `escalate_dispute_to_vote` | :1132 | direct | direct | — |

### 2.10 Mandate — 4 acciones

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `mandate.grant` | `grant_mandate` | :964 | `mandates.grant` | direct (o via decision con `reference_kind='mandate_grant'`) | **decision** | Mandato = delegación de autoridad. Falta template `decision.mandate_grant`. |
| `mandate.revoke` | `revoke_mandate` | :972 | `mandates.revoke` | direct (o via decision) | dual | OK como dual. |
| `mandate.report` | `report_on_mandate` | (no wired) | direct | direct | — |
| `mandate.expiring.emit` (cron) | `emit_mandate_expiring_events` | — | (internal) | — | — | — |

### 2.11 Role / Permissions — 4 acciones

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `role.create` | `create_custom_role` | :1242 | `roles.manage` | direct | **decision** | Crear rol = ampliar estructura de autoridad. Falta template `decision.role_create`. |
| `role.update_permissions` | `update_role_permissions` | :1250 | `roles.manage` | direct | **decision** | Cambiar permisos de un rol = redistribución de poder. Falta template `decision.role_update`. |
| `role.assign` | `assign_role_to_member` | :1258 | `roles.manage` | direct | direct (o decision si rol founder/admin) | Tiered: direct para member, decision para roles privilegiados. |
| `role.revoke` | `revoke_role_from_member` | :1266 | `roles.manage` | direct | direct (o decision si rol founder/admin) | Idem. |

### 2.12 Cultural norm — 4 acciones

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `norm.propose` | `propose_cultural_norm` / `propose_norm` | :994 | `culture.propose` | direct | direct | — |
| `norm.endorse` | `endorse_cultural_norm` / `endorse_norm` | :1003 | `culture.endorse` | direct | direct | — |
| `norm.retire` | `retire_cultural_norm` / `retire_norm` | :1011 | direct | direct | — |
| `norm.promote_to_rule` | `promote_norm_to_rule` | :1020 | `rules.create` | direct | **decision** (acoplada a rule.publish) | Falta template. |

### 2.13 Reputation — 2 acciones

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `reputation.event.record` | `record_reputation_event` | :904 | `reputation.record` | direct | direct | — |
| `reputation.event.retract` | `retract_reputation_event` | (no wired) | direct | direct | — |

### 2.14 Inbox / Notifications — 4 acciones (todas self-scoped)

| action_key | RPC | iOS | Perm. | Decisión hoy | Debería | Gap |
|---|---|---|---|---|---|---|
| `inbox.mark_read` | `mark_inbox_read` | :1521 | (self) | direct | self-only | — |
| `inbox.mark_all_read` | `mark_all_inbox_read` | :1530 | (self) | direct | self-only | — |
| `notification.preference.set` | `set_notification_preference` | :1154 | (self) | direct | self-only | — |
| `notification.token.register` | `register_my_notification_token` | :1163 | (self) | direct | self-only | — |

### 2.15 Internal/cron/system — sin action_key

- `record_system_event`, `evaluate_rules_for_event`, `emit_mandate_expiring_events`, `assert_*`, `atom_*_guard`, `handle_new_auth_user`, `set_updated_at`, `validate_rule_shape`, `rule_shape_compatibility`, `unaccent*`, `decision_provenance`, `membership_provenance`, `system_event_engine_provenance`, `rule_evaluation_lineage`, `*_summary`, `*_detail`, `list_*`, `group_*` (reads), `has_group_permission`, `is_group_member`, `assert_member_of_group` → reads/internals, no son acciones canónicas.

---

## 3. Gap matrix priorizada

### 3.1 Acciones críticas con bypass directo (`direct` hoy, debería ser `decision`)

| # | action_key | Template existe | Severidad | Mig necesaria |
|---|---|---|---|---|
| 1 | `resource.archive` | sí (`decision.resource_archive`) | Alta | Closing direct: gating en `archive_resource` con check `decisions.execute` |
| 2 | `resource.transfer` | sí (`decision.resource_transfer`) | Alta | Idem `set_resource_ownership` |
| 3 | `rule.publish` | parcial (`decision.rule_change`) | Alta | Gating + extender template a 'publish' |
| 4 | `rule.archive` | sí (`decision.rule_change` action='archive') | Alta | Idem `archive_rule` |
| 5 | `membership.ban` | sí (`decision.membership_remove`) | Alta | Cerrar puerta directa o validar contra group policy |
| 6 | `membership.remove` (reversible) | sí (`decision.membership_remove_reversible`) | Media | Idem |
| 7 | `membership.suspend` | sí (`decision.membership_suspend`) | Media | Idem (puede ser policy-dependent) |
| 8 | `money.payout` | NO | Alta | Crear template `decision.payout` |
| 9 | `money.transaction.reverse` | NO | Alta | Crear template `decision.transaction_reverse` |
| 10 | `engine.toggle` | NO | Media | Crear template `decision.engine_toggle` |
| 11 | `group.decision_rules.set` | NO | **Crítica (meta)** | Crear template `decision.governance_change` |
| 12 | `group.boundary.set` | NO | Media | Crear template `decision.group_boundary` |
| 13 | `group.visibility.set` | NO | Media | Crear template `decision.group_visibility` |
| 14 | `role.create` | NO | Media | Crear template `decision.role_create` |
| 15 | `role.update_permissions` | NO | Media | Crear template `decision.role_update` |
| 16 | `mandate.grant` | NO (parcial via decision opt-in) | Media | Crear template `decision.mandate_grant` |

### 3.2 Acciones threshold-driven (3)

| action_key | RPC | Necesita |
|---|---|---|
| `money.expense.record` | `record_expense` | Metadata `{threshold, currency}` en `decision_templates_catalog` + check en `resolve_action_governance`. |
| `money.pool_charge.create` | `record_pool_charge` | Idem. |
| `resource.value.update` | `update_resource_value` | Idem. |

### 3.3 Catálogo de transiciones membership — drift contra doctrine

`membership_state_transitions_catalog` hoy:

| from | to | requires_decision |
|---|---|---|
| active | banned | **false** ⚠ (doctrine D.20: debería ser true) |
| active | removed | **false** ⚠ |
| active | suspended | **false** (medio — policy-dependent) |
| banned | active | **true** ✓ |

→ La auditoría D.20.1 declaró que ban directo es legítimo si el actor tiene `members.remove`. La doctrine D.22 propone elevar todos los **terminales irreversibles** a decision-only. Decisión founder requerida.

### 3.4 iOS contract gaps

- **Stores hoy no manejan `decision_opened`.** Cada método retorna `UUID` / `Void` / dominio específico. El nuevo executor retornaría:
  ```swift
  enum ActionOutcome {
    case executed(effects: [String: Any])
    case decisionOpened(decisionId: UUID, templateKey: String)
    case denied(reason: String, missingPermission: String?)
  }
  ```
- Mensajes UI (Spanish, doctrine-aligned):
  - `executed` → toast/silent OK.
  - `decisionOpened` → "Se abrió una votación para esta acción" + link a DecisionDetailView.
  - `denied` → existing `UserFacingError` flow.
- 22 call sites en `SupabaseRuulRPCClient.swift` mutan estado crítico. Migración propuesta: añadir `func requestOrExecute(actionKey, target, payload)` y refactorizar gradualmente, NO reescribir cada método.

---

## 4. Recomendación de FASES B–H

Ordenadas por dependencia. Cada una self-contained.

### FASE B — Catálogo (1 mig, backend-only, read-only test)
- Crear `action_catalog` (action_key PK, domain, display_name, description, risk_level, default_required_permission, default_requires_decision, default_decision_template_key, executable_rpc, target_kind, metadata).
- Seed con todas las action_keys de §2 (≈ 90 filas).
- RPC read-only `list_action_catalog(p_group_id)` para introspección.

### FASE C — Resolver (1 mig, RPC pura, sin side effects)
- Crear `resolve_action_governance(p_group_id, p_action_key, p_target_kind, p_target_id, p_payload)`.
- Sólo decide. Devuelve `{allowed, direct_execute, requires_decision, decision_template_key, reason, missing_permission}`.
- Llama internamente `has_group_permission` + lee `action_catalog`.

### FASE D — Templates faltantes (1 mig)
- 9 templates nuevos: payout, transaction_reverse, engine_toggle, governance_change, group_boundary, group_visibility, role_create, role_update, mandate_grant.
- Extender `decision.rule_change` para action='publish'.
- Añadir columna `metadata.threshold` + `metadata.currency` para money templates.

### FASE E — Executor (1 mig)
- `request_or_execute_action()` orquesta resolver + dispatch.
- Reusa `execute_decision` para side effects.
- Devuelve `(status, decision_id, effects, denial_reason)`.

### FASE F — Cierre de puertas directas (1 mig per grupo de RPCs)
- Añadir guard en `archive_resource`, `set_resource_ownership`, `archive_rule`, `publish_rule_version`, `set_membership_state` (terminales), `record_payout`, `reverse_transaction`, `set_group_engine_active`, `set_decision_rules`, `set_group_boundary_policy`, `set_group_visibility`, `create_custom_role`, `update_role_permissions`, `grant_mandate`.
- Guard: `IF NOT _called_from_execute_decision() AND action_requires_decision(...) THEN RAISE EXCEPTION`.
- Alternativa más limpia: hacer estas RPCs `_internal_*` y SOLO callables desde `execute_decision` / `request_or_execute_action`.

### FASE G — iOS contract migration
- Añadir `ActionOutcome` enum + helper `requestOrExecute(...)` en `RuulRPCClient`.
- Mantener métodos existentes pero hacer que las acciones críticas pasen por el nuevo helper internamente.
- Adaptar UI sites de las 16 acciones críticas para mostrar `decision_opened` correctamente.

### FASE H — Smoke tests
- T1-T10 según el plan. 10 smokes, todos en `_smoke_action_governance`.

---

## 5. Lock-ins founder (resueltos 2026-05-31)

1. **`membership.suspend`** → admin-direct con `members.suspend`. NO decisión por default.
2. **`membership.ban` y `membership.remove`** → SÍ requieren decisión, salvo **founder emergency override**.
3. **`active→banned` y `active→removed`** → elevar `requires_decision=true` en `membership_state_transitions_catalog`.
4. **`paused`** → no decisión. Self-service (voluntaria) o admin (administrativa).
5. **Tiers role** (jerarquía de autoridad):
   - **founder** — puede ejecutar directo acciones críticas de emergencia (override), emite event `action.founder_emergency_override` para auditoría.
   - **admin** — solicita/ejecuta operativas, NO constitucionales (decision_rules.set, role.update_permissions, governance_change, group.dissolve, engine.toggle, group.boundary.set, group.visibility.set).
   - **member** — solicita acciones críticas (abre decisión), no ejecuta crítico. Ejecuta acciones tier 0 (self + low-risk).
   - **guest/observer/external** — read/participación limitada. Puede votar si tiene `decisions.vote`. No ejecuta acciones críticas.
6. **Umbrales money** — por grupo, configurables en `groups.governance.action_thresholds.<action_key>`. Default global como fallback en `action_catalog.default_threshold_amount`. Threshold actions: `money.expense.record`, `money.pool_charge.create`, `update_resource_value`. Debajo + permiso → directo; arriba → decisión.
7. **`ActionOutcome` enum iOS:** `executed`, `decisionOpened`, `denied`, `unsupported`, `failed`.

**Apertura de gating en `decision_templates_catalog`:**
- Founder override aplica a **acciones críticas no-constitucionales** (membership.ban/remove, resource.archive/transfer, money.payout/transaction.reverse).
- **Constitucionales** (governance_change, role.update_permissions, group.dissolve.finalize, engine.toggle) NUNCA bypass — ni founder.
- Cambios `groups.governance.action_overrides` permiten **elevar** una acción a decision (no bajar).

---

## 6. Hand-off

**Entregables FASE A:**
- ✅ Inventario de 80+ action_keys con RPC + iOS + perm + estado hoy + recomendación.
- ✅ Gap matrix con 16 acciones críticas + 3 threshold-driven + 7 preguntas founder.
- ✅ Plan FASE B–H con 5 migraciones backend + 1 wave iOS + 10 smokes.

**Siguiente paso bloqueado en founder:** responder las 7 preguntas de §5. Sin eso, FASE B (catálogo) saldría con guesses doctrinales en `default_requires_decision`.

**Tiempo estimado total D.22 post-aprobación:** ≈ 3 sesiones (B+C+D, E+F, G+H). Comparable a D.18 Decisions Deep (5 migs en 1 sesión).
