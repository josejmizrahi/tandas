# CanonicalRPCs_Contract.md — contrato canónico de RPCs (Fase B gate)

> Doctrina fuente:
> - `doctrine_rule_eval_sync_async.md` — toda RPC de dominio evalúa reglas SYNC para consecuencias canónicas; async solo para side effects.
> - `doctrine_mandate_in_money_rpcs.md` — money RPCs aceptan `p_mandate_id`; persistencia obligatoria; `authority_path` en `group_events.payload`.
> - `doctrine_fase_b_starts_with_rpc_contract.md` — este documento es el gate para tocar iOS.
> - `doctrine_canonical_schema_decisions.md` — modelo de datos subyacente.
>
> Estado del schema: aplicado en dev `wyvkqveienzixinonhum`. Ver `project_canonical_apply_dev.md`. Las 5 money RPCs ya aceptan `p_mandate_id`, persisten autoridad, y evalúan reglas SYNC (`canonical_followup_04..08`, refinados con `_17..20` tras la revisión founder del 2026-05-26).

---

## 0. Cómo leer este documento

Cada RPC declara 9 campos. Para el bloque **money**, se documenta en prosa (la implementación toca dinero — cero ambigüedad). Para los otros bloques se documenta en tabla compacta.

| Campo | Significado |
|---|---|
| 1. **Signature** | Nombre + firma completa con tipos y `default` cuando aplica. |
| 2. **Permission (direct_permission only)** | Key del catálogo `permissions` que `assert_permission` exige **únicamente cuando el path resuelto es `direct_permission`**. `self_party` y `mandate` NO requieren permission check. `—` si no hay path `direct_permission`. |
| 3. **Authority paths** | Lista de `direct_permission` / `mandate` / `self_party` / `token` válidos para esta RPC. |
| 4. **Acepta mandate_id** | `sí` (con scope mínimo requerido) / `no`. Si `sí`, el campo se persiste en la fila afectada. |
| 5. **Emite group_event** | event_type emitido server-side. `—` si la RPC no escribe a memoria. |
| 6. **Evalúa reglas SYNC** | `sí` si llama `evaluate_rules_for_event(p_mode='sync')` antes del commit; `no` si nunca; `vía evento` si la regla se gatilla por el `group_event` y la propia RPC ya dispara la evaluación. |
| 7. **Errores canónicos** | Mensajes `raise exception` que iOS debe reconocer (regex-friendly). |
| 8. **Tablas mutadas** | Tablas que cambian dentro de la transacción de la RPC. |
| 9. **Side effects async** | Filas que la RPC inserta en `notifications_outbox` u otros queues. `—` si ninguno. |

---

## 1. Authority paths

Cada acción canónica debe inscribirse en uno de cuatro caminos. El campo se persiste en `group_events.payload.authority_path` y, cuando aplica, también en la columna `mandate_id` / `source_mandate_id` de la fila mutada.

| Path | Cuándo |
|---|---|
| `self_party` | El actor es parte natural de la operación: deudor de la obligación que liquida, RSVP propio, check-in propio, gasto propio que reparte, voto propio, retiro de su propia membresía, etc. Detectable porque la fila apunta al actor (no a un tercero). NO requiere permission check. |
| `direct_permission` | El actor tiene un permiso vigente del catálogo `permissions` que cubre la acción. No actúa por delegación. `assert_permission` se aplica solo en este path. |
| `mandate` | El actor ejecuta por autoridad delegada. Requiere `p_mandate_id` válido + scope cubriendo la acción. Se persiste en la fila + en `group_events.payload.mandate_id`. NO requiere permission check (la autoridad es el mandato). |
| `token` | Solo `accept_invite`. La autorización es el código del invite + `auth.uid()` no-null. No es self_party (el actor todavía no es miembro). No es mandate. No es direct_permission. |

### Precedencia (resolución del path)

La doctrina founder (2026-05-26) lock:

1. **Mandate explícito gana siempre**. Si la RPC recibe `p_mandate_id != null`, el path resuelto es `mandate` y la única validación es `_assert_mandate_authorizes`. No se evalúa self_party ni direct_permission.
2. **Sin mandate_id**: se evalúa primero `self_party`. Si aplica, ese es el path; no se llama `assert_permission`.
3. **Sin mandate y sin self_party**: path es `direct_permission`. Se llama `assert_permission(<perm>)`.

Implementación: helper `public._resolve_authority_path(...)` encapsula la precedencia. Toda RPC con múltiples paths la invoca al inicio. Se evita por completo llamar `assert_permission` al tope de la RPC cuando hay paths alternativos.

### Por qué importa

Sin esta precedencia, un actor con permission `expense.record` que también pasa `p_mandate_id` se registraba como `direct_permission` y el mandato quedaba sin persistirse — perdiendo el audit trail. Con el lock, el mandato explícito siempre se persiste.

---

## 2. Money RPCs — contrato completo

Estos 9 endpoints son la superficie financiera. Cero ambigüedad sobre autoridad, persistencia y trazabilidad.

### 2.1 `record_expense`

1. **Signature**: `record_expense(p_group_id uuid, p_resource_id uuid, p_amount numeric, p_unit text, p_paid_by_membership_id uuid, p_description text default null, p_split_mode text default 'even', p_split_breakdown jsonb default null, p_in_kind boolean default false, p_mandate_id uuid default null, p_client_id text default null) returns uuid`
2. **Permission (direct_permission only)**: `expense.record_for_others` (P7 — NO incluido en baseline `member` role; solo founder/admin/treasurer lo tienen).
3. **Authority paths**:
   - `self_party` — `p_paid_by_membership_id = actor`. Sin permission check. Cualquier miembro registra su propio gasto.
   - `direct_permission` — `p_paid_by_membership_id <> actor` AND `p_mandate_id is null` → requiere `expense.record_for_others`. Sin este permiso elevado, miembros baseline NO pueden registrar gasto a nombre de otro.
   - `mandate` — `p_mandate_id is not null` (gana precedencia). Scope `spend` o `expense` con `max_amount >= p_amount` y `unit = p_unit`.
4. **Acepta `mandate_id`**: sí. Persistido en `group_resource_transactions.mandate_id` y en `group_obligations.source_mandate_id` para las shares materializadas.
5. **Emite group_event**: `money.expense_recorded` con payload `{amount, unit, authority_path, mandate_id?, paid_by_membership_id, split_mode}`.
6. **Evalúa reglas SYNC**: sí. Reglas con `trigger_event_type='money.expense_recorded'` pueden materializar obligaciones extra, abrir disputas o emitir sanctions; todo dentro del mismo commit.
7. **Errores canónicos**:
   - `caller is not an active member of group <uuid>`
   - `caller lacks permission expense.record_for_others in group <uuid>` (cuando intenta registrar para otro sin mandate)
   - `amount must be positive`
   - `resource <uuid> not in group <uuid>`
   - `custom split sum <N> does not match amount <M>`
   - `mandate does not authorize this action: <reason>`
   - `rule evaluation depth N exceeds max 5 for event <uuid>`
8. **Tablas mutadas**: `group_resource_transactions` (1 fila); `group_obligations` (0..N filas según split); `group_events` (1 fila).
9. **Side effects async**: `notifications_outbox` push a cada `owed_by_membership_id` materializado (categoría `money.you_owe`). **Pendiente de implementación V1** — actualmente solo `evaluate_rules_for_event` modo `'async'` encola; las RPCs llaman `'sync'`.

### 2.2 `record_contribution`

1. **Signature**: `record_contribution(p_group_id uuid, p_resource_id uuid default null, p_amount numeric default null, p_unit text default 'MXN', p_from_membership_id uuid default null, p_description text default null, p_in_kind boolean default false, p_mandate_id uuid default null, p_client_id text default null) returns uuid`
2. **Permission**: `contribution.record`
3. **Authority paths**:
   - `self_party` — `p_from_membership_id = actor`.
   - `direct_permission` — actor con `contribution.record` registra por otro (in-kind doctrina, ver `doctrine_in_kind_contributions.md`).
   - `mandate` — registrar contribución en nombre del grupo o de un fondo restringido.
4. **Acepta `mandate_id`**: sí. Scope `contribute`; `scope.resource_id` cubre `p_resource_id` si fund protegido.
5. **Emite group_event**: `money.contribution_recorded` con payload `{amount, unit, in_kind, authority_path, mandate_id?}`.
6. **Evalúa reglas SYNC**: sí (umbral de fund alcanzado → consecuencias).
7. **Errores canónicos**:
   - `amount required`
   - `caller lacks permission contribution.record in group <uuid>`
   - `mandate does not authorize this action`
8. **Tablas mutadas**: `group_resource_transactions` (1 fila, type=`contribution`); `group_events` (1).
9. **Side effects async**: `notifications_outbox` para el grupo (categoría `money.fund_progress`) si fund tiene threshold_target.

### 2.3 `record_non_monetary_contribution`

1. **Signature**: `record_non_monetary_contribution(p_group_id uuid, p_membership_id uuid, p_contribution_type text, p_title text, p_description text default null, p_source_resource_id uuid default null) returns uuid`
2. **Permission**: `contribution.record`
3. **Authority paths**:
   - `self_party` — `p_membership_id = actor`.
   - `direct_permission` — actor registra contribución de otro miembro.
4. **Acepta `mandate_id`**: no. Acciones no-monetarias (care/moderation/docs/etc) no requieren delegación financiera.
5. **Emite group_event**: `contribution.recorded`.
6. **Evalúa reglas SYNC**: sí (puede haber reglas que reconozcan contribuciones automáticamente).
7. **Errores canónicos**:
   - `caller lacks permission contribution.record in group <uuid>`
   - `contribution_type` inválido (CHECK constraint).
8. **Tablas mutadas**: `group_contributions`; `group_events`.
9. **Side effects async**: `notifications_outbox` al subject (categoría `reputation.thanks`) si la regla lo dispara.

### 2.4 `verify_contribution`

1. **Signature**: `verify_contribution(p_contribution_id uuid, p_outcome text, p_note text default null) returns void`
2. **Permission (direct_permission only)**: `contribution.verify` (P4 — permiso de escritura específico; NO se usa `records.read` para acciones que mutan).
3. **Authority paths**: `direct_permission` exclusivamente. **Self-check enforced server-side**: el verificador NO puede ser el `subject_membership_id` (doble check). El body raise antes de mutar.
4. **Acepta `mandate_id`**: no.
5. **Emite group_event**: `contribution.verified` o `contribution.rejected`.
6. **Evalúa reglas SYNC**: sí. Una contribución verificada puede gatillar payout, badge, ajuste de obligation.
7. **Errores canónicos**:
   - `invalid outcome`
   - `contribution not found`
   - `caller is not an active member of group <uuid>`
   - `verifier cannot be the contribution subject`
   - `caller lacks permission contribution.verify in group <uuid>`
8. **Tablas mutadas**: `group_contributions` (status, verified_by, metadata); `group_reputation_events` si `outcome='verified'`; `group_events`.
9. **Side effects async**: `notifications_outbox` al `subject_membership_id`. **Pendiente de implementación V1**.

### 2.5 `record_settlement`

1. **Signature**: `record_settlement(p_group_id uuid, p_paid_by_membership_id uuid, p_paid_to_membership_id uuid, p_paid_to_kind text, p_amount numeric, p_unit text, p_notes text default null, p_mandate_id uuid default null, p_client_id text default null) returns table (settlement_id uuid, transaction_id uuid)`
2. **Permission (direct_permission only)**: `settlement.record_for_others` (P10 — simétrico con `expense.record_for_others`. NO en baseline; solo founder/admin/treasurer). `record_settlement` cierra obligations + actualiza outstanding + crea transaction + emite `commitment_kept` reputation — es demasiado poder para baseline.
3. **Authority paths**:
   - `self_party` — `p_paid_by_membership_id = actor` (yo liquido mi propia deuda). Sin permission check.
   - `direct_permission` — `p_paid_by_membership_id <> actor` AND `p_mandate_id is null` → requiere `settlement.record_for_others`.
   - `mandate` — `p_mandate_id is not null` (precedencia). Scope `settle` o `pay`; cubre `paid_to_kind`.
4. **Acepta `mandate_id`**: sí. Persistido en `group_settlements.mandate_id` + en el `group_resource_transactions.mandate_id` resultante.
5. **Emite group_event**: `money.settlement_recorded` con payload `{amount, unit, authority_path, mandate_id?, paid_by_membership_id, paid_to_kind, unallocated}`.
6. **Evalúa reglas SYNC**: sí. Reglas sobre `commitment_kept` se evalúan; obligation cerradas emiten `group_reputation_events` dentro del mismo commit.
7. **Errores canónicos**:
   - `caller is not an active member of group <uuid>`
   - `caller lacks permission settlement.record_for_others in group <uuid>` (cuando intenta cerrar deuda de tercero sin mandate)
   - `invalid paid_to_kind`
   - `amount must be positive`
   - `mandate does not authorize this action: <reason>`
   - `cross-tenant violation: group_id mismatch`
8. **Tablas mutadas**: `group_settlements`; `group_settlement_obligations` (FIFO 0..N); `group_obligations` (update outstanding/status); `group_resource_transactions` (1 fila `settlement_payment`); `group_reputation_events` (0..N `commitment_kept`); `group_events`.
9. **Side effects async**: `notifications_outbox` al `paid_to_membership_id` o al grupo entero (si `paid_to_kind = 'pool'`). **Pendiente de implementación V1**.

### Idempotency (clarification)

Si `p_client_id` se repite, la función devuelve el `(settlement_id, transaction_id)` original SIN duplicar. El `return next` está corregido para respetar el `returns table`. (El smoke aún no tiene un step dedicado a settlement idempotency — solo a expense idempotency en `7.idempotency_expense`. TODO menor: agregar `7.idempotency_settlement` análogo.)

### 2.6 `record_pool_charge`

1. **Signature**: `record_pool_charge(p_group_id uuid, p_target_membership_id uuid, p_amount numeric, p_unit text, p_charge_kind text, p_reason text default null, p_mandate_id uuid default null, p_client_id text default null) returns uuid`
2. **Permission**: `pool_charge.record`
3. **Authority paths**:
   - `direct_permission` — admin con `pool_charge.record` crea cuota.
   - `mandate` — representante crea cuota por decisión delegada.
   - `self_party` — **no aplica**: las cuotas son siempre "alguien decidiendo por el grupo que un tercero debe pagar".
4. **Acepta `mandate_id`**: sí. Scope `charge` o `represent` con principal=`group`; `scope.max_amount >= p_amount`. Persistido en `group_obligations.source_mandate_id`.
5. **Emite group_event**: `money.pool_charge_created` con payload `{amount, unit, kind, target, authority_path, mandate_id?}`.
6. **Evalúa reglas SYNC**: sí (reglas sobre threshold de pool, recordatorios).
7. **Errores canónicos**:
   - `caller lacks permission pool_charge.record in group <uuid>`
   - `amount must be positive`
   - `invalid charge_kind`
   - `mandate does not authorize this action`
8. **Tablas mutadas**: `group_obligations` (1 fila kind=`pool_charge`, owed_to_kind=`pool`); `group_events`.
9. **Side effects async**: `notifications_outbox` al `p_target_membership_id` (categoría `money.you_owe`).

### 2.7 `record_payout`

1. **Signature**: `record_payout(p_group_id uuid, p_to_membership_id uuid, p_amount numeric, p_unit text, p_source_resource_id uuid default null, p_reason text default null, p_mandate_id uuid default null, p_client_id text default null) returns uuid`
2. **Permission**: `payout.record`
3. **Authority paths**:
   - `direct_permission` — admin con `payout.record`.
   - `mandate` — tesorero ejecuta payout desde pool por decisión delegada.
4. **Acepta `mandate_id`**: sí. Scope `payout` o `spend` cubriendo pool; `scope.max_amount >= p_amount`. Persistido en `group_resource_transactions.mandate_id`.
5. **Emite group_event**: `money.payout_recorded` con payload `{amount, unit, to, source_resource_id, authority_path, mandate_id?}`.
6. **Evalúa reglas SYNC**: sí.
7. **Errores canónicos**:
   - `caller lacks permission payout.record in group <uuid>`
   - `amount must be positive`
   - `mandate does not authorize this action`
8. **Tablas mutadas**: `group_resource_transactions` (1 fila type=`payout`); `group_events`.
9. **Side effects async**: `notifications_outbox` al `p_to_membership_id` (categoría `money.you_received`).

### 2.8 `reverse_transaction`

1. **Signature**: `reverse_transaction(p_transaction_id uuid, p_reason text) returns uuid`
2. **Permission (direct_permission only)**: `money.transaction.reverse` (P5 — NO se reutiliza `records.read`; revertir dinero es una acción de escritura con su propio permiso).
3. **Authority paths**:
   - `self_party` — `v_tx.recorded_by = auth.uid()` (el actor registró la transacción original).
   - `direct_permission` — otro actor con `money.transaction.reverse` corrige una entrada ajena.
   - mandate: NO en V1 (si se quiere reversal delegado en V2, se añade columna `mandate_id` al ledger entry de reversal).
4. **Acepta `mandate_id`**: no en V1.
5. **Emite group_event**: `money.transaction_reversed` con payload `{reversal_id, reason, authority_path}`.
6. **Evalúa reglas SYNC**: no (reversal explícito; no se quiere cascada automática).
7. **Dependent guard (P5)**: la RPC **rechaza** reversal cuando la transacción original:
   - Tiene `group_obligations` con `source_transaction_id = p_transaction_id` (no podemos dejar deudas huérfanas).
   - Es `ledger_entry_id` de un `group_settlement` (revierte el pago pero deja la obligación cerrada).
   - Es de tipo `'reversal'` (no se revierte una reversal).
   - Ya fue revertida (tiene `reversed_entry_id` apuntándole).
   En esos casos: `transaction has dependent obligations or settlements; use domain-specific reversal`. V2 expondrá `reverse_expense` / `void_settlement` con la cascada correcta.
8. **Tablas mutadas**: `group_resource_transactions` (1 fila type=`reversal`, `reversed_entry_id` apunta al original); `group_events`. **NUNCA** muta la fila original (append-only doctrine).
9. **Side effects async**: `notifications_outbox` al involucrado de la transacción original. **Pendiente de implementación V1**.

### 2.9 `record_asset_valuation`

1. **Signature**: `record_asset_valuation(p_resource_id uuid, p_value numeric, p_unit text, p_basis text default 'member_estimate') returns uuid`
2. **Permission**: `resources.update`
3. **Authority paths**:
   - `direct_permission` — actor con `resources.update`.
4. **Acepta `mandate_id`**: no en V1.
5. **Emite group_event**: `asset.valuation_recorded` con payload `{value, unit, basis, authority_path}`.
6. **Evalúa reglas SYNC**: no (registro pasivo de hecho).
7. **Errores canónicos**:
   - `resource not found`
   - `caller lacks permission resources.update in group <uuid>`
8. **Tablas mutadas**: `group_resource_asset_valuations` (append-only); `group_resource_assets` (update `current_value` + `current_value_unit` — el único campo mutable es el "current"; la historia vive en la tabla append-only); `group_events`.
9. **Side effects async**: `notifications_outbox` a los `custodian_membership_id` si cambia el valor significativamente.

---

## 3. Identity & Membership (tabular)

| RPC | Permission | Authority paths | mandate? | Emite event | Rule eval | Errores clave | Muta | Async |
|---|---|---|---|---|---|---|---|---|
| `create_group(p_name, p_slug?, p_category?, p_purpose_declared?)` | — (cualquier autenticado) | self_party | no | `group.created` | no | `must be authenticated` | groups, group_memberships, group_membership_events, group_roles, group_role_permissions, group_member_roles, group_purposes, group_events | — |
| `invite_member(p_group_id, p_email?, p_phone?, p_membership_type?, p_message?)` | `members.invite` | direct_permission | no | `member.invited` | no | `invite requires email or phone`, `caller lacks permission members.invite` | group_invites, group_events, notifications_outbox | push al invitado si user existe |
| `accept_invite(p_code)` | — (token) | token | no | `member.joined` | sí | `invite not found or already used`, `invite expired`, `invite token mismatch` | group_invites, group_memberships, group_membership_events, group_member_roles (auto default role), group_events | — |
| `request_membership(p_group_id, p_message?)` | — | self_party | no | `member.requested` | no | `group is not open to membership requests` | group_memberships, group_membership_events, group_events | push a admins |
| `set_membership_state(p_membership_id, p_new_state, p_reason?, p_until?)` | `members.update`/`suspend`/`remove` o self→`left` | self_party para `left`; direct_permission para otros | no | `member.state_changed` | sí | `caller cannot move membership to left`, `invalid membership state` | group_memberships, group_membership_events, group_mandates (revoke en transitions), group_events | push al subject |
| `leave_group(p_group_id, p_reason?)` | — (self) | self_party | no | `member.state_changed` | sí | `no active membership to leave` | (via set_membership_state) | push a admins |
| `confirm_provisional(p_membership_id)` | `members.update` | direct_permission | no | `member.confirmed` | sí | `membership is not provisional` | group_memberships, group_membership_events, group_events | push al subject |

---

## 4. Purpose, Roles & Mandates (tabular)

| RPC | Permission | Authority paths | mandate? | Emite event | Rule eval | Muta | Async |
|---|---|---|---|---|---|---|---|
| `set_group_purpose(p_group_id, p_kind, p_body, p_visibility?)` | `purpose.set` | direct_permission | no | `purpose.set` | no | group_purposes, groups.purpose_summary, group_events | — |
| `archive_group_purpose(p_purpose_id)` | `purpose.set` | direct_permission | no | `purpose.archived` | no | group_purposes, group_events | — |
| `create_custom_role(p_group_id, p_key, p_name, p_description, p_permission_keys[])` | `roles.manage` | direct_permission | no | `role.created` | no | group_roles, group_role_permissions, group_events | — |
| `update_role_permissions(p_role_id, p_permission_keys[])` | `roles.manage` | direct_permission | no | `role.permissions_updated` | no | group_role_permissions, group_events | — |
| `assign_role_to_member(p_membership_id, p_role_id)` | `roles.manage` | direct_permission | no | `role_assigned` (en group_membership_events) | no | group_member_roles, group_membership_events | — |
| `revoke_role_from_member(p_membership_id, p_role_id)` | `roles.manage` | direct_permission | no | `role_revoked` | no | group_member_roles, group_membership_events | — |
| `list_member_permissions(p_group_id, p_user_id?)` | `members.read` o self | self_party / direct_permission | no | — (read) | — | — | — |
| `grant_mandate(p_group_id, p_representative_membership_id, p_mandate_type, p_principal_type?, p_principal_id?, p_scope?, p_ends_at?, p_source_decision_id?)` | `mandates.grant` | direct_permission (o vía decisión si decision_rules lo exige) | no — esta RPC otorga, no usa | `mandate.granted` | no | group_mandates, group_events | push al representative |
| `revoke_mandate(p_mandate_id, p_reason?)` | `mandates.revoke` | direct_permission | no | `mandate.revoked` | no | group_mandates, group_events | push al representative |
| `report_on_mandate(p_mandate_id, p_summary, p_payload?)` | — (holder) | self_party | no | `mandate.report` | no | group_events | — |

---

## 5. Rules (tabular)

| RPC | Permission | Authority paths | mandate? | Emite event | Rule eval | Muta | Async |
|---|---|---|---|---|---|---|---|
| `propose_rule(p_group_id, p_title, p_rule_type, p_severity?, p_slug?)` | `rules.create` | direct_permission | no | `rule.proposed` | no | group_rules, group_events | — |
| `publish_rule_version(p_rule_id, p_execution_mode, p_body?, p_trigger_event_type?, p_condition_tree?, p_consequences?, p_shape_key?)` | `rules.publish` | direct_permission | no | `rule.published` | no | group_rules, group_rule_versions, group_events | — |
| `archive_rule(p_rule_id, p_reason?)` | `rules.archive` | direct_permission | no | `rule.archived` | no | group_rules, group_rule_versions, group_events | — |
| `evaluate_rules_for_event(p_event_uuid_id, p_mode)` | — (interno) | — | no | — | n/a (ESTA es la función) | group_rule_evaluations | notifications_outbox si `p_mode='async'` |

Esta última se invoca DESDE las RPCs de dominio antes de su commit (`p_mode='sync'`), no por iOS directamente. EXECUTE revocado a anon/public.

---

## 6. Resources — envelope + subtipos (tabular)

| RPC | Permission | Authority paths | mandate? | Emite event | Rule eval | Muta | Async |
|---|---|---|---|---|---|---|---|
| `create_resource(p_group_id, p_resource_type, p_name, p_subtype_payload?, p_visibility?, p_ownership_kind?, p_series_id?, p_metadata?)` | `resources.create` | direct_permission, mandate (V2) | no en V1 | `resource.created` | sí | group_resources + subtype, group_events | push al host si event con host_membership_id |
| `update_resource(p_resource_id, p_name?, p_description?, p_visibility?, p_metadata?, p_subtype_payload?)` | `resources.update` | direct_permission | no en V1 | `resource.updated` | sí | group_resources + subtype, group_events | — |
| `set_resource_ownership(p_resource_id, p_ownership_kind, p_owner_membership_id?, p_metadata?)` | `resources.transfer` | direct_permission, mandate (V2) | no en V1 | `resource.ownership_changed` | sí | group_resources, group_events | push al previous + new owner |
| `archive_resource(p_resource_id, p_reason?)` | `resources.archive` | direct_permission | no | `resource.archived` | sí | group_resources, group_events | — |
| `revert_archive_resource(p_resource_id, p_reason?)` | `resources.update` | direct_permission | no | `resource.unarchived` | no | group_resources, group_events | — |
| `create_resource_series(...)` | `resources.create` | direct_permission | no | `resource_series.created` | no | group_resource_series, group_events | — |
| `update_resource_series(p_series_id, ...)` | `resources.update` | direct_permission | no | `resource_series.updated` | no | group_resource_series, group_events | — |
| `enable_resource_capability(p_resource_id, p_capability_key, p_config?)` | `resources.update` | direct_permission | no | `resource.capability_enabled` | no | group_resource_capabilities, group_events | — |
| `disable_resource_capability(p_resource_id, p_capability_key)` | `resources.update` | direct_permission | no | `resource.capability_disabled` | no | group_resource_capabilities, group_events | — |

---

## 7. Resource ops — bookings, RSVP, check-in (tabular)

| RPC | Permission | Authority paths | mandate? | Emite event | Rule eval | Muta | Async |
|---|---|---|---|---|---|---|---|
| `book_resource(p_resource_id, p_starts_at, p_ends_at?, p_reason?, p_client_id?)` | `bookings.create` | self_party (booking propio), direct_permission | no en V1 | `booking.created` | sí | group_resource_bookings, group_events | push al owner/custodian del recurso |
| `cancel_booking(p_booking_id, p_reason?)` | owner del booking o `bookings.cancel` | self_party / direct_permission | no | `booking.cancelled` | sí | group_resource_bookings (append `status='cancelled'`), group_events | push al owner del recurso |
| `submit_rsvp(p_resource_id, p_rsvp_status, p_note?, p_client_id?)` | `rsvp.submit` | self_party | no | `rsvp.submitted` | sí | group_rsvp_actions (append), group_events | push al host si `rsvp_status='not_going'` tardío |
| `submit_check_in(p_resource_id, p_check_in_method, p_location_verified?, p_client_id?)` | `check_in.submit` | self_party | no | `check_in.submitted` | sí | group_check_in_actions (append), group_events | — |
| `mark_no_show(p_resource_id, p_membership_id)` | host del recurso o `resources.update` | direct_permission | no | `check_in.missed` | sí | group_events | push al subject |

---

## 8. Decisions (tabular)

| RPC | Permission | Authority paths | mandate? | Emite event | Rule eval | Muta | Async |
|---|---|---|---|---|---|---|---|
| `start_vote(...)` | `decisions.create` | direct_permission | no | `decision.started` | no | group_decisions, group_decision_options, group_events | push al grupo |
| `cast_vote(p_decision_id, p_option_id?, p_vote_value?, p_reason?)` | — (self_party only) | self_party | no | `decision.vote_cast` (silent — no incluye vote_value en payload, solo voter_membership_id) | sí | group_votes (append), group_events | — |
| `cancel_vote(p_decision_id, p_reason?)` | `decisions.resolve` | direct_permission | no | `decision.cancelled` | no | group_decisions, group_events | — |
| `finalize_vote(p_decision_id)` | `decisions.resolve` (o cron) | direct_permission | no | `decision.finalized` | sí (post-passage triggers) | group_decisions; cascada via update_sanction_status / revoke_mandate / approve_dissolution; group_events | push a interesados |
| `current_vote_for(p_decision_id, p_voter_membership_id)` | (read) | — | no | — | — | — | — |
| `current_votes_for_decision(p_decision_id)` | (read) | — | no | — | — | — | — |

---

## 9. Sanctions (tabular)

| RPC | Permission | Authority paths | mandate? | Emite event | Rule eval | Muta | Async |
|---|---|---|---|---|---|---|---|
| `issue_sanction(p_group_id, p_target_membership_id, p_sanction_kind, p_reason, p_amount?, p_unit?, p_ends_at?, p_rule_version_id?, p_source_event_id?, p_client_id?)` | `sanctions.create` | direct_permission, mandate (V2) | no en V1 | `sanction.issued` | sí | group_sanctions; si monetary: group_obligations; si suspension: group_memberships via set_membership_state; group_reputation_events; group_events | push al target |
| `update_sanction_status(p_sanction_id, p_new_status, p_reason?)` | `sanctions.update` | direct_permission | no | `sanction.<status>` | sí | group_sanctions, group_obligations (void si reversed), group_events | push al target |
| `dispute_sanction(p_sanction_id, p_summary)` | target o `sanctions.dispute` | self_party / direct_permission | no | `dispute.opened` (via open_dispute) | sí | group_sanctions (status='disputed', dispute_id), group_disputes, group_dispute_events, group_events | push al issuer |

---

## 10. Disputes (tabular)

| RPC | Permission | Authority paths | mandate? | Emite event | Rule eval | Muta | Async |
|---|---|---|---|---|---|---|---|
| `open_dispute(p_group_id, p_subject_kind, p_subject_id, p_title, p_description?, p_respondent_membership_id?)` | `disputes.open` | self_party (opener) | no | `dispute.opened` | sí | group_disputes, group_dispute_events, group_events | push al respondent |
| `assign_mediator(p_dispute_id, p_mediator_membership_id)` | `disputes.mediate` | direct_permission | no | `dispute.mediator_assigned` | no | group_disputes, group_dispute_events, group_events | push al mediator |
| `append_dispute_event(p_dispute_id, p_event_type, p_body, p_metadata?)` | involucrado o `disputes.mediate` | self_party / direct_permission | no | — (silent timeline) | no | group_dispute_events | — |
| `record_dispute_resolution(p_dispute_id, p_method, p_resolution_text, p_outcome?)` | mediator o `disputes.resolve` | self_party (mediator) / direct_permission | no | `dispute.resolved` | sí | group_disputes, group_dispute_events, group_sanctions (si outcome reverse), group_reputation_events, group_events | push a involved |
| `escalate_dispute_to_vote(p_dispute_id, p_decision_title, p_decision_method, p_closes_at)` | mediator | self_party | no | `dispute.escalated` (+ `decision.started`) | no | group_disputes, group_decisions, group_events | push al grupo |

---

## 11. Reputation, Culture, Dissolution (tabular)

| RPC | Permission | Authority paths | mandate? | Emite event | Rule eval | Muta | Async |
|---|---|---|---|---|---|---|---|
| `record_reputation_event(...)` | `reputation.record` | direct_permission | no | (silent; reputación es declarativa) | no | group_reputation_events | — |
| `retract_reputation_event(p_event_id, p_reason?)` | issuer o `reputation.record` | self_party / direct_permission | no | — | no | group_reputation_events (status='retracted') | — |
| `propose_norm(p_group_id, p_norm_type, p_title, p_body?, p_visibility?)` | `culture.propose` | self_party | no | `norm.proposed` | no | group_cultural_norms, group_events | — |
| `endorse_norm(p_norm_id)` | `culture.endorse` | direct_permission | no | `norm.endorsed` (si pasa threshold) | no | group_cultural_norms, group_events | push al proposer si endorsed |
| `retire_norm(p_norm_id, p_reason?)` | `culture.endorse` o proposer | self_party / direct_permission | no | `norm.retired` | no | group_cultural_norms, group_events | — |
| `propose_dissolution(p_group_id, p_reason, p_plan?, p_asset_disposition?, p_obligations_plan?)` | `group.dissolve` | direct_permission | no | `dissolution.proposed` (+ `decision.started`) | no | group_dissolutions, group_decisions, groups (status='dissolving'), group_events | push al grupo |
| `approve_dissolution(p_dissolution_id)` | — (interno, llamado por finalize_vote) | — | no | `dissolution.approved` | no | group_dissolutions, group_events | — |
| `record_liquidation_step(p_dissolution_id, p_step_kind, p_payload?)` | `group.dissolve` | direct_permission, mandate (V2) | no en V1 | `dissolution.step` | no | group_dissolutions (jsonb append), group_events | — |
| `finalize_dissolution(p_dissolution_id)` | `group.dissolve` | direct_permission | no | `dissolution.finalized` | no | group_dissolutions, groups (status='dissolved'), group_memberships (todos a 'left'), group_events | push al grupo |

---

## 12. Silent canonical writes (P8)

Algunas RPCs son canónicas pero **no emiten** `group_events` con el detalle público, o emiten un evento minimizado. Es intencional, no una falla del contrato §3 ("Toda mutación canónica emite group_event").

| Tabla / acción | Razón | Cómo se audita |
|---|---|---|
| `group_votes` (cast_vote) | El valor del voto puede ser secreto según `decision.method`. Emite `decision.vote_cast` con `voter_membership_id` pero **sin** `vote_value`. | La tabla `group_votes` es append-only y es la fuente de verdad del conteo. `finalize_vote` lee directo. |
| `group_dispute_events` (append_dispute_event) | La timeline de la disputa vive dentro de `group_dispute_events`. Duplicar cada comment en `group_events` ruidoso. | `group_dispute_events` es append-only y RLS la restringe a involucrados + mediator. |
| `group_reputation_events` (record_reputation_event, retract_reputation_event) | La reputación es declarativa y, según `visibility`, puede ser privada. Emitir `group_events` público filtraría visibilidad. | `group_reputation_events` es append-only; status='retracted' marca remoción lógica. |

Estas excepciones quedan acotadas. Ninguna otra RPC canónica puede ser "silent" sin justificación explícita aquí.

---

## 13. Reads & helpers (no contract row)

Lecturas puras o helpers internos. No mutan estado canónico ni emiten `group_events`. RLS sobre las tablas subyacentes gobierna acceso.

- `member_balance_in_group(p_group_id, p_membership_id) returns numeric`
- `member_obligation_summary(p_group_id, p_membership_id) returns table`
- `group_summary(p_group_id) returns jsonb`
- `current_vote_for(p_decision_id, p_voter_membership_id) returns group_votes`
- `current_votes_for_decision(p_decision_id) returns setof group_votes`
- `list_member_permissions(p_group_id, p_user_id?) returns setof text`

Helpers internos (revoked from anon/public; solo llamados por otras RPCs):
- `record_system_event(...)` — emite a `group_events`.
- `assert_member_of_group(p_group_id) returns uuid` — gate común.
- `assert_permission(p_group_id, p_permission) returns void` — gate común; **solo se llama en path direct_permission**.
- `_assert_mandate_authorizes(p_mandate_id, p_group_id, p_actor_membership, p_required_scope, p_amount?, p_unit?, p_resource_id?) returns void` — valida scope de un mandato (P1).
- `_resolve_authority_path(p_group_id, p_actor_membership, p_is_self_party, p_mandate_id, p_permission, p_mandate_scope?, p_amount?, p_unit?, p_resource_id?) returns text` — encapsula precedencia P1+P2.
- `evaluate_rules_for_event(p_event_uuid_id, p_mode) returns setof uuid` — invocado por RPCs de dominio con `'sync'`.
- `approve_dissolution(p_dissolution_id)` — invocado por `finalize_vote`.

---

## 14. `delete_and_export_my_data` (full contract row — P9)

Esta RPC NO es lectura; muta múltiples tablas. Por eso se documenta como contract row independiente.

1. **Signature**: `delete_and_export_my_data() returns jsonb`
2. **Permission (direct_permission only)**: — (no aplica; el path es `self_party` exclusivamente).
3. **Authority paths**: `self_party`. El actor solo puede borrar/exportar SU propio data. No hay otro path.
4. **Acepta `mandate_id`**: no. Una persona no delega su propio derecho GDPR.
5. **Emite group_events**: por cada grupo afectado:
   - `member.state_changed` (status='left', reason='user_deleted')
   - `mandate.revoked` (si tenía mandates activos)
   - `profile.anonymized` (uno, en payload global)
6. **Evalúa reglas SYNC**: sí, por cada salida de grupo (member.state_changed puede gatillar reglas tipo "si todos los hosts se van, cancelar evento futuro").
7. **Errores canónicos**:
   - `must be authenticated`
8. **Tablas mutadas**:
   - `profiles` (deleted_at, anonimiza display_name/avatar/bio).
   - `group_memberships` (todas a status='left', left_reason='user_deleted').
   - `group_membership_events` (1 por grupo).
   - `group_mandates` (todos los activos a status='revoked', revoked_reason='user_deleted').
   - `group_events` (uno por grupo afectado).
9. **Side effects async**: `notifications_outbox` a admins de cada grupo afectado para que sepan que el miembro se fue por borrado de cuenta. **Pendiente de implementación V1**.

### Consideración de naming

V2 puede splittear en dos RPCs separadas:
- `export_my_data() returns jsonb` — lectura pura.
- `delete_my_account() returns void` — mutación destructiva.

Por ahora se mantienen combinadas para satisfacer GDPR en una sola transacción.

---

## 15. Cambios aplicados para alinear código con contrato (C10)

> **Estado:** cerrados. Migraciones `canonical_followup_04..20` aplicadas en dev `wyvkqveienzixinonhum`.

| # | Cambio | Migración |
|---|---|---|
| 1 | Money RPCs aceptan `p_mandate_id uuid default null` con validación de scope vía `_assert_mandate_authorizes` | `_04..08` |
| 2 | Money RPCs llaman `evaluate_rules_for_event(uuid, 'sync')` antes del commit | `_05..08` |
| 3 | Idempotency en `record_settlement` corregida (early return respeta `returns table`) | `_07` |
| 4 | `record_expense` valida que `sum(p_split_breakdown[].amount) = p_amount` en modo custom | `_05` |
| 5 | `mark_no_show` migrado a `evaluate_rules_for_event(uuid, text)` | `_03` |
| 6 | Bugs descubiertos por smoke (pgcrypto schema, column shadowing, default role, resource nullable, min uuid, cleanup) | `_09..16` |
| 7 | **P1+P2**: mandate explícito gana precedencia; self_party bypassea `assert_permission`; `_resolve_authority_path` helper | `_17, _18` |
| 8 | **P7**: `expense.record_for_others` nuevo permiso, NO en baseline | `_17, _18` |
| 9 | **P3**: `cast_vote` elimina `p_weight` (server-side = 1 en V1); emite `decision.vote_cast` silent | `_19` |
| 10 | **P4**: `verify_contribution` usa `contribution.verify` (nuevo) + self-check | `_19` |
| 11 | **P5**: `reverse_transaction` usa `money.transaction.reverse` (nuevo) + dependent guard contra obligations/settlements | `_19` |
| 12 | **P6**: `invite_member` sin `p_role_key` | `_19` |
| 13 | Smoke ampliado: `4.authority_path_self_party` + `7.p7_third_party_blocked` | `_20` |
| 14 | **P10**: `settlement.record_for_others` nuevo permiso elevado; `record_settlement` ahora exige este permiso para direct_permission path | `_21` |
| 15 | Smoke incorpora user C baseline + step `7.p10_settlement_third_party_blocked` | `_22` |

---

## 16. Gate de cierre

Este documento se considera el contrato canónico de Fase B. iOS Foundation no se toca hasta que:

- [x] Los 5 cambios originales del §15 (ex-§13) aplicados en dev (`canonical_followup_04..08`).
- [x] 9 correcciones founder post-revisión aplicadas en dev (`_17..20`). P1-P7 backend, P8-P9-C10-C11 doc.
- [x] Smoke E2E `_smoke_money_flow()` retorna 18/18 verdes incluyendo:
  - `4.authority_path_self_party` — verifica que founder pagando su propio gasto se registra como `self_party`.
  - `7.p7_third_party_blocked` — verifica que baseline member NO puede registrar gasto a nombre de tercero sin mandate.
  - `7.p10_settlement_third_party_blocked` — verifica que baseline member NO puede cerrar deuda entre A y B sin mandate.
- [x] **Founder SIGNED 2026-05-26 — Phase B Foundation only.**

### Condiciones operativas de la firma (founder lock)

1. iOS Foundation NO expone RPCs deferred (lista en §16-bis).
2. iOS NO depende de `notifications_outbox` todavía — los pushes están marcados "Pendiente V1" en cada RPC y no se asumen activos.
3. iOS manda `null` explícito en `record_expense.p_resource_id` cuando sea shared_money (pool implícito).
4. iOS trata los errores canónicos como contrato estable; cambios al texto del raise rompen iOS.
5. Antes de cada build de device que toque money, correr `select * from public._smoke_money_flow();`. Todas las filas deben ser `ok=true`.
6. Si se toca `record_expense`, `record_settlement`, `accept_invite` o `create_group`, el smoke es obligatorio re-ejecutarlo.

### Tracking de issues abiertos aceptados como no bloqueantes

Quedan en §17, no entran a Foundation iOS, requieren su propia revisión antes de exponer:

- `record_contribution` para terceros
- `retract_reputation_event` vs append-only
- `record_contribution.p_unit default 'MXN'` (multi-país V2)
- `cancel_booking` append-only semantics
- Rate limiting (`invite_member`, `propose_norm`, etc)
- `record_payout` crédito negativo simétrico
- Mandates V2 en `create_resource`, `set_resource_ownership`, `issue_sanction`, `record_liquidation_step`
- Firmas con `(...)` quedan deferred (start_vote, create_resource_series, etc)

### Bugs colaterales descubiertos durante el smoke (ya parchados en migraciones follow-up)

| # | Bug | Fix |
|---|---|---|
| 1 | `gen_random_bytes` / `digest` no resolvían — pgcrypto vive en schema `extensions` no `public` | `canonical_followup_09` — prefix explícito en `invite_member`/`accept_invite` |
| 2 | Returns-table param `group_id` / `membership_id` shadowea columns dentro de `accept_invite` | `canonical_followup_10` + `_13` — qualify con table alias |
| 3 | `accept_invite` NO asignaba el rol default → nuevo miembro sin permisos baseline | `canonical_followup_12` — auto-assign `is_default = true` role |
| 4 | `group_resource_transactions.resource_id NOT NULL` impedía expenses sin resource específico (doctrine_shared_money) | `canonical_followup_11` — column ahora nullable + FK `on delete set null` |
| 5 | `min(uuid)` no existe en Postgres | `canonical_followup_14` — `select ... limit 1` filtrando NULLs |
| 6 | Cleanup del smoke falla por cascade a tablas append-only (group_membership_events, group_events) | `canonical_followup_16` — smoke deja la data, documentado |

Estos bugs estaban en el código aplicado antes del smoke; el smoke fue el detector.

### Cómo correr el smoke

```sql
select * from public._smoke_money_flow();
```

Devuelve 18 filas `(step text, ok boolean, detail text)`. Todas deben tener `ok = true`. La función crea 3 usuarios (A founder, B miembro, C baseline para tests de fraud) + 1 grupo + obligations + settlement nuevos cada vez (UUIDs aleatorios), así que es seguro re-ejecutar; solo deja garbage que se acumula en dev.

### Después del gate — Foundation iOS scope (C11)

Fase B-iOS arranca por el SupabaseClient layer en RuulCore, mapeando 1:1 a las firmas aquí declaradas. Solo las RPCs de **Foundation scope** se exponen en la primera rebanada:

| Foundation RPC | Para qué |
|---|---|
| `create_group` | Founder crea un grupo nuevo |
| `invite_member` | Founder invita miembros por email/teléfono |
| `accept_invite` | Invitado acepta vía código |
| `leave_group` | Self exit |
| `record_expense` | Registrar gasto self_party + split |
| `record_settlement` | Liquidar deuda self_party |
| `group_summary` (read) | Home screen del grupo: counts |
| `member_balance_in_group` (read) | Balance del miembro |
| `member_obligation_summary` (read) | Listado de deudas abiertas |

Todas las demás RPCs del contrato quedan **deferred** hasta que Foundation iOS esté validada en device. Incluye:
- `start_vote`, `cast_vote`, `finalize_vote` — decisiones formales.
- `issue_sanction`, `dispute_sanction`, `open_dispute` — sanciones y disputas.
- `propose_rule`, `publish_rule_version`, `evaluate_rules_for_event` — rule engine.
- `propose_norm`, `endorse_norm` — culture.
- `propose_dissolution`, `finalize_dissolution` — dissolution.
- `record_pool_charge`, `record_payout`, `reverse_transaction`, `record_asset_valuation` — money avanzado.
- `verify_contribution`, `record_non_monetary_contribution` — contributions sociales.
- `grant_mandate`, `revoke_mandate`, `report_on_mandate` — mandates.
- `delete_and_export_my_data` — privacidad/GDPR.

Las firmas marcadas `(...)` en este contrato (start_vote, create_resource_series, record_reputation_event, update_resource_series) NO entran a Foundation iOS y se redactan completas antes de la 2a rebanada.

---

## 17. Issues abiertos no bloqueantes (post-firma, post-Foundation)

Tracking de comentarios founder no-bloqueantes para Phase B continuación o V2:

- **`record_contribution.p_unit default 'MXN'`**: aceptable para V1 México. En V2 derivar de `groups.settings.default_unit` o exigir explícito.
- **`record_expense.p_resource_id`**: nullable a nivel schema; pasar `null` significa "expense del pool implícito" (doctrine_shared_money). iOS debe documentar este caso.
- **`cancel_booking` vs append-only**: hoy inserta nueva fila con `status='cancelled'`. Está alineado con append-only. La nota "append `status='cancelled'`" en §7 se refiere a INSERT de nueva fila, NO a update.
- **Rate limiting**: `invite_member`, `propose_norm`, `record_non_monetary_contribution` necesitan rate limit a nivel edge function. No bloquea Foundation iOS.
- **`record_payout` no genera obligation negativa (crédito)**: si V2 quiere reverse simétrico, definir flujo.
- **Mandate en `create_resource`, `set_resource_ownership`, `issue_sanction`, `record_liquidation_step`**: marcado V2 en tablas; añadir `p_mandate_id` cuando se necesite delegación.
- **`retract_reputation_event` vs append-only**: §11 dice que retract hace UPDATE `status='retracted'`, pero §12 marca `group_reputation_events` como append-only. Contradicción. Resolución antes de exponer reputation en V2: **opción B** (preferida) — record_reputation_event acepta `reputation_type='retraction'` con `evidence_entity_id` apuntando al evento original; sin UPDATEs. NO bloquea Foundation iOS porque reputation queda deferred.
- **`record_contribution` para terceros**: el mismo patrón P10 aplica conceptualmente (un miembro registrando contribución de otro). Riesgo menor que settlement (contribuciones son aditivas, no cierran obligations), pero antes de exponer `record_contribution` con `p_from_membership_id <> actor` en V2, considerar `contribution.record_for_others`. Por ahora baseline permite por simetría con la doctrina "registrar ≠ aprobar".
