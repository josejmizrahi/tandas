# D.24 PHASE 10 — Governance Bypass Audit

**Status:** audit-only, **NO migrations, NO schema changes, NO iOS changes**.
**Verified against live DB** `wyvkqveienzixinonhum` 2026-06-01.
**Author note:** la salida de esta auditoría es la decisión "qué deprecar / qué wrappear / qué dejar". El founder firma cada acción derivada.

---

## Resumen ejecutivo

### Volumetría

- **201** funciones SECURITY DEFINER en `public` (excluyendo helpers `_*`).
- **134** mutan estado (INSERT/UPDATE/DELETE).
- **67** son read-only / reads / view helpers.
- **2** rutean explícitamente vía `request_or_execute_action` / `resolve_action_governance` (la pipeline misma).
- **102** mutan directo + tienen `assert_permission` o `has_group_permission` gate.
- **32** mutan directo sin perm gate (mayoría: callbacks de auth, self-service del propio user, helpers).

### Catálogo de acciones

`action_catalog` ya tiene **105 entradas** (`decision.create`, `membership.ban`, `resource.archive`, etc). Es la ABSTRACCIÓN — define qué puede pedirse a governance y con qué template. Pero hoy las RPCs ejecutoras NO consultan al catalog antes de actuar. El catalog y los RPCs viven como dos capas paralelas.

### Hallazgo central

> **El gating actual es `has_group_permission(perm_key)` directo, no `request_or_execute_action(action_key)`.** La capa de governance existe (`request_or_execute_action`, `resolve_action_governance`, `execute_decision`) pero solo cubre acciones que el iOS llama explícitamente vía governance executor. Los caminos legacy (la mayoría) llaman las RPCs ejecutoras directo.

Esto NO es necesariamente un bug. Por doctrina `engine_vs_vote`:
- Cambiar autoridad existente = governance (decisión + voto)
- Aplicar autoridad existente = engine/RPC direct

El gap real es: **algunas acciones que cambian autoridad pasan direct**. Esas son las que urge wrappear o deprecar.

---

## Clasificación P0-P3

### P0 — Constitutional / irreversible (MUST pass governance)

Tocan reglas fundacionales del grupo, identidad miembros, propiedad. No se vuelven atrás sin proceso.

| RPC | Dominio | Estado actual | Acción recomendada |
|---|---|---|---|
| `set_membership_state` | membership | direct + perm `members.{remove,pause,suspend}` | **Wrap**: forzar governance para banned/removed; permitir admin direct solo en paused/suspended/active |
| `set_resource_ownership` | ownership | direct + perm `resources.transfer` | **Wrap**: cambios de owner principal requieren `request_or_execute_action('resource.transfer')` |
| `add_resource_owner` (D.24 P3A) | ownership | direct + perm `resources.manage_ownership` | **Wrap-soft**: cambios de membership-owner con pct≥50% requieren governance |
| `end_resource_owner` (D.24 P3A) | ownership | direct + perm | **Wrap-soft**: si cierra primary owner, governance |
| `grant_mandate` | mandates | direct + perm `mandates.grant` | **Already partial via `execute_decision`** (mandate_grant kind). Audit if direct calls exist en iOS. |
| `revoke_mandate` | mandates | direct + perm `mandates.revoke` | **Already partial via `execute_decision`**. iOS revoca direct → wrap o requerir source_decision_id obligatorio. |
| `assign_role_to_member` | roles | direct + perm `roles.manage` | **Wrap**: rol founder/admin requiere governance |
| `revoke_role_from_member` | roles | direct + perm `roles.manage` | **Wrap**: revocar founder/admin requiere governance |
| `create_custom_role` | roles | direct + perm `roles.manage` | **Wrap**: rol nuevo en sistema = constitutional |
| `update_role_permissions` | roles | direct + perm `roles.manage` | **Wrap**: cambiar permisos de un rol = constitutional |
| `set_group_visibility` | governance | direct + perm `group.update` | **Wrap**: public→private o vice versa requiere governance |
| `set_group_boundary_policy` | governance | direct + perm `group.update` | **Wrap**: cambia quien puede entrar/salir |
| `set_decision_rules` | governance | direct + perm `group.update` | **Wrap**: cambiar reglas de decisión = constitutional puro |
| `set_group_engine_active` | governance | direct + perm `engine.toggle` | **Wrap**: ya tiene action.key=engine.toggle path; verificar iOS lo usa |
| `archive_rule` / `publish_rule_version` | rules | direct + perm `rules.archive/publish` | **Wrap**: regla activa cambiando = governance (esto ya existe via execute_decision.rule branch) |
| `propose_dissolution` / `approve_dissolution` / `finalize_dissolution` | dissolution | direct + perm `group.dissolve` | **Wrap fuerte**: 3 etapas deben pasar por execute_decision. Hoy `approve/finalize` se llaman desde execute_decision (✓); `propose` se llama direct desde iOS (revisar) |
| `record_dispute_resolution` | disputes | direct + perm | **Wrap**: resolver dispute = vinculante |
| `update_sanction_status` (a 'cancelled'/'reversed') | sanctions | direct + perm `sanctions.update` | **Wrap**: cancelar/reversar sanción = constitutional |

### P1 — High risk (governance recomendado, no obligatorio)

Mutación grave pero reversible / pequeña.

| RPC | Dominio | Estado | Acción |
|---|---|---|---|
| `issue_sanction` | sanctions | direct + perm `sanctions.create` | Allow direct para admin. **Wrap** sanctions monetarias > threshold |
| `dispute_sanction` / `start_sanction_appeal` (D.24 P8) | sanctions | direct + perm `sanctions.dispute` | OK direct (es el USUARIO disputando, no constitutional change) |
| `escalate_dispute_to_vote` | disputes | direct + perm `disputes.mediate` | OK direct |
| `open_dispute` | disputes | direct + perm `disputes.open` | OK direct (usuario abre proceso) |
| `archive_resource` / `revert_archive_resource` | resources | direct + perm `resources.archive` | **Wrap** para resources con money obligations vivas (ya existe guard parcial — verificar coverage) |
| `update_resource_value` | resources | direct + perm `resources.update_value` | **Wrap**: cambios > X% valor = governance |
| `lock_fund` / `unlock_fund` / `set_fund_threshold` | resources/fund | direct + perm | **Wrap**: lock_fund permanente = constitutional |
| `transfer_right` / `revoke_right` / `expire_right` | resources/right | direct + perm | OK direct para holder; **Wrap** revoke if non-self |
| `reverse_transaction` | money | direct + perm `money.transaction.reverse` | **Wrap**: ya tiene action_key=money.transaction.reverse via execute_decision; verificar iOS lo usa |
| `record_payout` | money | direct + perm `payout.record` | **Wrap**: payout > threshold requiere governance |
| `record_pool_charge` / `record_pool_charge_batch` | money | direct + perm `pool_charge.record` | OK admin direct (operativo); ya hay action_key path |
| `confirm_provisional` | membership | direct + perm | OK direct (admin confirma post-onboarding) |
| `assign_mediator` | disputes | direct + perm | OK direct (admin escoge mediador) |
| `promote_norm_to_rule` | culture | direct + perm | **Wrap**: convertir norma en regla = constitutional |

### P2 — Medium risk (mantener direct + perm gate)

| RPC | Dominio | Notas |
|---|---|---|
| `record_expense` / `record_settlement` / `record_contribution` / `record_non_monetary_contribution` / `verify_contribution` / `log_contribution` | money | Operational ledger entries. Doctrine `registrar≠aprobar` — todo miembro puede registrar. OK direct. |
| `record_peer_obligation` | money | OK direct (rule engine emit). |
| `propose_sanction_payment_plan` / `cancel_sanction_payment_plan` | money | OK direct |
| `pay_sanction` | money | OK direct (target paying) |
| `create_external_party` / `update_external_party` / `archive_external_party` (D.24 P4) | external_parties | OK direct + perm `external_parties.manage` |
| `propose_cultural_norm` / `endorse_cultural_norm` / `retire_cultural_norm` (legacy) | culture | OK direct |
| `record_reputation_event` / `retract_reputation_event` | reputation | OK direct (any member can record observation per doctrine `registrar≠aprobar`) |
| `invite_member` / `revoke_invite` / `accept_invite` / `request_membership` / `approve_membership_request` | membership | OK direct (proceso de boundary tiene su propia gobernanza interna; approve es la decisión real) |
| `submit_rsvp` / `submit_check_in` / `book_resource` / `cancel_booking` / `assign_slot` / `release_slot` / `mark_asset_condition` / `record_asset_valuation` / `assign_asset_custodian` / `release_asset_custodian` | resources | Pure operational. OK direct. |

### P3 — Low risk / operational

| RPC | Dominio | Notas |
|---|---|---|
| `create_event` / `update_event` / `cancel_event` / `archive_event` / `add_event_attendee` / `remove_event_attendee` / `respond_event` / `add_event_reminder` / `remove_event_reminder` | calendar events (consolidated D.24 P1) | OK direct |
| `create_event_resource` / `create_asset_resource` / `create_fund_resource` / `create_space_resource` / `create_slot_resource` / `create_right_resource` (D.24 P2A) | resources | OK direct |
| `create_resource` / `create_group_resource` / `update_resource` / `create_resource_series` / `update_resource_series` | resources | OK direct |
| `enable_resource_capability` / `disable_resource_capability` | resources | OK direct |
| `create_group_comment` / `archive_group_comment` (D.24 P6) | comments | OK direct |
| `create_group_attachment_metadata` / `archive_group_attachment` (D.24 P7A) | attachments | OK direct |
| `start_vote` / `cast_vote` / `cast_ranked_vote` / `finalize_vote` / `cancel_vote` / `apply_decision_template` / `execute_decision` | decisions | **Inherent governance** — son la pipeline misma. OK direct. |
| `propose_rule` / `create_text_rule` / `create_engine_rule` | rules | OK direct (propose, no publish) |
| `propose_norm` / `endorse_norm` / `retire_norm` | culture | OK direct |
| `my_profile` / `update_my_profile` / `mark_inbox_read` / `mark_all_inbox_read` / `set_notification_preference` / `register_my_notification_token` / `delete_and_export_my_data` | self-service | OK direct (user actúa sobre su propia info) |
| `record_system_event` / `evaluate_rules_for_event` / `handle_new_auth_user` / `expire_mandate_if_due` | internal helpers | OK direct (system, not user-facing) |

---

## Riesgo por dominio (snapshot)

| Dominio | Critical RPCs | Wrap-needed | Status |
|---|---|---|---|
| Membership | set_membership_state, approve_membership_request, confirm_provisional | Solo bans/removes via governance | Partial (banned→active vía execute_decision ya wrap) |
| Roles | assign/revoke_role_to/from_member, create_custom_role, update_role_permissions | Founder/admin assignments via governance | NO wrappers yet |
| Mandates | grant_mandate, revoke_mandate | Already partial via execute_decision | Verificar iOS no llama direct |
| Ownership | set_resource_ownership, add_resource_owner, end_resource_owner | Primary owner changes via governance | NO wrappers yet (D.24 P3A solo añade table) |
| Resources critical | archive_resource, value_update, lock_fund, transfer_right | Already partial via execute_decision.resource branch | OK con metadata.action |
| Money critical | reverse_transaction, record_payout | Already partial via execute_decision.money_movement | OK |
| Sanctions | issue, update_status (reverse/cancel) | Update_status='reversed'/'cancelled' via governance | Cancel ya vía execute_decision sanction_appeal (D.24 P8) |
| Rules | publish_rule_version, archive_rule | archive ya wrap via execute_decision.rule | publish_rule_version queda direct (OK — voto previo crea la versión) |
| Governance | set_decision_rules, set_group_visibility, set_group_boundary_policy, set_group_engine_active | Already partial via execute_decision.group | OK con action_key path |
| Dissolution | propose/approve/finalize_dissolution | approve+finalize ya vía execute_decision.dissolution | propose_dissolution queda direct (OK — start del proceso) |
| Disputes | resolve, escalate, assign_mediator | resolve via execute_decision.dispute | OK |
| Culture | promote_norm_to_rule | Already partial via execute_decision.norm | OK |
| Reputation | record_reputation_event | Direct OK per doctrine | OK |
| External parties | create/update/archive | Direct OK | OK |
| Comments/Attachments | create/archive | Direct OK | OK |

---

## Plan derivado — qué wrappear en sesiones futuras

### Urgencia inmediata (P0)

1. **`set_membership_state` para `banned/removed`**: revisar que iOS solo llegue ahí vía execute_decision. Si hay path direct, deprecar.
2. **`assign_role_to_member` / `revoke_role_from_member` para `founder/admin` keys**: forzar governance. Hoy admin puede mover otro admin direct.
3. **`create_custom_role` / `update_role_permissions`**: governance obligatoria. Permisos son constitution.
4. **`set_group_visibility` / `set_group_boundary_policy` / `set_decision_rules`**: hoy direct con `group.update`. Verificar que iOS NO ofrezca path direct cuando es member crítico. Force vía action_key.

### Sesiones recomendadas (orden)

- **D24P10A** — Audit iOS shell: grep por RPCs P0 que iOS llama direct. Output: lista de call sites a wrappear.
- **D24P10B** — Migrar 4 RPCs P0 (membership_state + role mgmt × 2 + governance × 3) a `request_or_execute_action` con `auto_execute` flag (admin sí ejecuta direct, member-or-bigger pasa por voto).
- **D24P10C** — Smoke: governance bypass detection. Test que valida que cada RPC P0 desde role=member sin perm → governance se dispara (no direct error).

### Lo que NO se debe hacer todavía

- NO migrar RPCs P2/P3 a governance — overhead innecesario.
- NO deprecar RPCs P0 todavía (rompería iOS). Solo agregar perm gate adicional + audit log si bypass detected.
- NO bloquear `set_decision_rules` direct hasta tener UI alternativa via execute_decision.group_action path.

---

## Compatibilidad iOS

Esta auditoría es solo lectura. Cero cambios iOS. Pero el plan derivado va a:

1. Necesitar `RuulRPCClient` extensions para algunos action keys nuevos (probablemente ya cubiertos por `requestOrExecuteAction` existente).
2. Forzar reroute de algunos sheets/buttons a `request_or_execute_action` en vez de RPC direct.
3. Mostrar el path "decisión abierta" cuando el outcome sea `decisionOpened` en vez de execución inmediata.

iOS impact futuro: bajo (la pipeline `ActionOutcome.decisionOpened/directAllowed/denied/unsupported/failed` ya existe — memory `doctrine_action_governance_tiers`).

---

## Estrategia de rollback

Como esta fase es audit-only, no aplica rollback. Para las sesiones derivadas (D24P10A-C): cada wrap es additive (RPC nuevo + delegación). Si rompe iOS, revertir = drop wrapper RPC, sin afectar el direct path.

---

## Conclusión

Ruul tiene **dos capas paralelas que aún no se han fusionado**:

1. **Action governance** (`action_catalog` + `request_or_execute_action` + `resolve_action_governance`) — la abstracción semántica.
2. **RPCs directas con perm gates** — los ejecutores legacy.

Hoy ambas capas funcionan, pero la "fusión" (RPCs P0 obligatoriamente vía action_gov) NO está completa. El gap es manejable porque las RPCs más críticas (decision execution, sanction status changes via decision, rule archival via decision) YA pasan por `execute_decision`. Pero hay un set de ~12-15 RPCs P0 que aún pueden llamarse direct.

**Recomendación firme:** ejecutar D24P10A (audit iOS call sites) y D24P10B (wrap 4 RPCs P0 más críticas) antes de tocar Storage, Read Models, o deprecaciones (P2B/P3B).

Sin esto, los "wrappers atómicos" de P2A y la `ownership 2.0` de P3A pueden burlarse vía RPCs legacy. La consolidación quedará incompleta.
