# CanonicalSchema_RPCs.md — Catálogo canónico de RPCs (DRAFT)

> Anexo de `Plans/Active/CanonicalSchema.sql` + `CanonicalSchema_RLS.md`.
> Define la **superficie write** completa que iOS llama. Toda mutación pasa
> por aquí. Cuando esté aprobado, las firmas y bodies se concatenan al
> `00001_canonical_schema.sql` antes de A4 (apply en branch).

---

## 0. Convenciones

### Forma estándar

Cada RPC es `language plpgsql security definer set search_path = public`,
con `client_id text default null` cuando aplica idempotencia, y emite al
menos un `group_events` row server-side.

```sql
create or replace function public.<verb_subject>(
  p_param  type,
  p_client_id text default null
)
returns <output_type>
language plpgsql security definer
set search_path = public
as $$
declare …
begin
  -- 1. permission gate: has_group_permission(...)
  -- 2. validation: pre-conditions, FOR UPDATE locks
  -- 3. mutation: insert/update on canonical tables
  -- 4. memory: insert into group_events
  -- 5. side effects: notifications_outbox, reputation_events, etc.
  -- 6. return
end;
$$;
```

### Idempotencia

RPCs que aceptan `p_client_id` usan `unique (group_id, client_id)` en
la tabla destino para hacer la operación re-ejecutable. Si llega un
client_id ya visto, se devuelve el resultado original sin duplicar.

### Locking

RPCs que mutan obligaciones, settlements, sanciones o decisiones lockean
filas con `for update` antes de leer estados derivados.

### Permission check

Cada RPC empieza por `if not has_group_permission(p_group_id, '<key>') then raise ...`.
Lista exacta de keys en `permissions` catalog (CanonicalSchema.sql §17).

### Memory write

Toda RPC que cambia estado relevante escribe a `group_events` (event_type
namespaced por dominio: `member.invited`, `sanction.issued`, etc).

### Retorno

RPCs devuelven el id del row principal afectado, o un compuesto
`(id uuid, group_events_id bigint)` cuando hace falta el cursor de memoria.

---

## 1. Identity & Membership

### `create_group(p_name, p_slug?, p_category?, p_purpose_declared?)`

Ya definida en `CanonicalSchema.sql §19`. Crea grupo + founder membership +
system roles + permisos baseline + propósito declarado opcional + memoria.

**Returns:** `uuid` (group_id).

### `invite_member(p_group_id, p_email?, p_phone?, p_role_key?, p_membership_type?, p_message?)`

- **Permiso:** `members.invite`.
- **Crea:** row en `group_invites` con `token_hash`, expires_at, code.
- **Si no hay user existente:** crea placeholder en `group_memberships` con
  `status='invited'`, `membership_type=p_membership_type ?? 'member'`.
- **Emite:** `group_events` ('member.invited'), `notifications_outbox` push/email.
- **Returns:** `uuid` (invite_id).

### `accept_invite(p_token text)`

- **Permiso:** ninguno explícito; el token es la autorización (verificado contra `token_hash`).
- **Valida:** invite no expirado/revocado/aceptado.
- **Acciones:**
  - Si existe placeholder membership con `joined_via='placeholder'`: claim it (linkea user_id, status → 'active', confirmed_at).
  - Si no: inserta membership con `joined_via='invite_code'`, status='active'.
- **Emite:** `group_membership_events`, `group_events` ('member.joined'), reputation_events si aplica.
- **Returns:** `(group_id uuid, membership_id uuid)`.

### `request_membership(p_group_id, p_message?)`

- **Permiso:** ninguno (público).
- **Para:** grupos `visibility='public'|'unlisted'` con flujo apply.
- **Crea:** membership con `status='requested'`.
- **Emite:** `group_events`, notif a admins.
- **Returns:** `uuid` (membership_id).

### `set_membership_state(p_membership_id, p_new_state, p_reason?, p_until?)`

- **Permiso:** `members.update` o `members.suspend` según transición.
  - Self → 'left' permitido sin permiso (uno mismo se va).
  - 'suspended' requiere `members.suspend`.
  - 'banned'/'removed' requiere `members.remove`.
- **Valida transición:** state machine `invited→active|left|banned`, `active→suspended|left|removed`, etc.
- **Acciones:** update membership, cierra mandates activos del miembro si pasa a left/banned/removed, marca pending obligations.
- **Emite:** `group_membership_events`, `group_events`.
- **Returns:** `void`.

### `leave_group(p_group_id, p_reason?)`

- **Permiso:** ninguno (self).
- **Pre-condición:** no obligaciones abiertas con balance > 0, o `force=true` que las marca `voided` con razón 'member_left'.
- **Acciones:** wrapper de `set_membership_state` con `p_new_state='left'`.
- **Returns:** `void`.

### `confirm_provisional(p_membership_id)`

- **Permiso:** `members.update`.
- **Valida:** state `active` + type `provisional` + `provisional_until` no expirado.
- **Acciones:** type='member', confirmed_at=now().
- **Returns:** `void`.

---

## 2. Purpose

### `set_group_purpose(p_group_id, p_kind, p_body, p_visibility?)`

- **Permiso:** `purpose.set`.
- **Acciones:** archiva el row activo previo de ese `kind`, inserta nuevo `status='active'`.
- **Emite:** `group_events` ('purpose.set').
- **Returns:** `uuid` (purpose_id).

### `archive_group_purpose(p_purpose_id)`

- **Permiso:** `purpose.set`.
- **Returns:** `void`.

---

## 3. Roles & Permissions

### `create_custom_role(p_group_id, p_key, p_name, p_description, p_permission_keys[])`

- **Permiso:** `roles.manage`.
- **Acciones:** insert `group_roles` (is_system=false) + inserts en `group_role_permissions`.
- **Returns:** `uuid` (role_id).

### `update_role_permissions(p_role_id, p_permission_keys[])`

- **Permiso:** `roles.manage` para el grupo del rol.
- **Acciones:** diff add/remove en `group_role_permissions`.
- **Returns:** `void`.

### `assign_role_to_member(p_membership_id, p_role_id)`

- **Permiso:** `roles.manage`.
- **Validates:** same-group via trigger.
- **Acciones:** insert `group_member_roles`.
- **Returns:** `void`.

### `revoke_role_from_member(p_membership_id, p_role_id)`

- **Permiso:** `roles.manage`.
- **Pre-condición:** el miembro debe quedar con al menos un rol (no se queda sin rol).
- **Returns:** `void`.

### `list_member_permissions(p_group_id, p_user_id?)`

- **Permiso:** `members.read` (o self si `p_user_id` = caller).
- **Returns:** `setof text` (permission keys vigentes para el miembro).

---

## 4. Mandates

### `grant_mandate(p_group_id, p_holder_membership_id, p_mandate_type, p_scope, p_ends_at?, p_source_decision_id?)`

- **Permiso:** `mandates.grant`. Si `decision_rules` exige voto, requiere `p_source_decision_id` con status='passed'.
- **Acciones:** insert `group_mandates` status='active'.
- **Emite:** `group_events`.
- **Returns:** `uuid` (mandate_id).

### `revoke_mandate(p_mandate_id, p_reason?)`

- **Permiso:** `mandates.revoke`. Si el mandate fue granted_by_vote_id, exige voto pass.
- **Acciones:** status='revoked', revoked_at, revoked_reason.
- **Returns:** `void`.

### `report_on_mandate(p_mandate_id, p_summary, p_payload jsonb)`

- **Permiso:** ninguno (self — solo el holder).
- **Acciones:** emite `group_events` ('mandate.report') con payload.
- **Returns:** `void`.

---

## 5. Rules

### `propose_rule(p_group_id, p_title, p_rule_type, p_severity?, p_slug?)`

- **Permiso:** `rules.create`.
- **Acciones:** insert `group_rules` status='draft'.
- **Returns:** `uuid` (rule_id).

### `publish_rule_version(p_rule_id, p_execution_mode, p_body?, p_trigger_event_type?, p_condition_tree?, p_consequences?, p_shape_key?)`

- **Permiso:** `rules.publish`.
- **Acciones:**
  - `effective_until` del version actual ← now() (única columna mutable de rule_versions).
  - Insert new `group_rule_versions` con version+1, effective_from=now().
  - Update `group_rules.current_version_id` + status='active'.
- **Valida:** `execution_mode='engine'` ⇒ shape_key debe existir en catalog; condition_tree y consequences no null.
- **Emite:** `group_events`.
- **Returns:** `uuid` (rule_version_id).

### `archive_rule(p_rule_id, p_reason?)`

- **Permiso:** `rules.archive`.
- **Acciones:** status='archived'. effective_until del current_version_id.
- **Returns:** `void`.

### `evaluate_rules_for_event(p_event_uuid_id uuid)`

- **Permiso:** ninguno (interno, llamado por trigger o cron).
- **Acciones:** lookup rules con `current_version_id` cuyo `trigger_event_type` matchea; ejecuta `condition_tree`; emite consequences (sanctions / votes / contributions / notifications) en `group_rule_evaluations` con `idempotency_key=event_uuid_id||rule_version_id`.
- **Returns:** `setof uuid` (evaluation ids).

---

## 6. Resources — envelope

### `create_resource(p_group_id, p_type, p_name, p_subtype_payload jsonb, p_visibility?, p_ownership_kind?, p_series_id?)`

- **Permiso:** `resources.create`.
- **Acciones:**
  - Insert `group_resources`.
  - Insert en la tabla subtipo correspondiente (`group_resource_events|funds|slots|spaces|assets|rights`) leyendo `p_subtype_payload`.
  - Si `p_series_id`: liga.
- **Emite:** `group_events` ('resource.created'), `notifications_outbox`.
- **Returns:** `uuid` (resource_id).

### `update_resource(p_resource_id, p_name?, p_description?, p_visibility?, p_metadata?, p_subtype_payload?)`

- **Permiso:** `resources.update`.
- **Acciones:** update envelope + subtype si payload presente.
- **Emite:** `group_events` ('resource.updated' con diff).
- **Returns:** `void`.

### `set_resource_ownership(p_resource_id, p_kind, p_owner_membership_id?, p_metadata)`

- **Permiso:** `resources.transfer`.
- **Acciones:** update ownership_kind + owner_membership_id + ownership_metadata. Emite `group_events` ('resource.ownership_changed').
- **Returns:** `void`.

### `archive_resource(p_resource_id, p_reason?)`

- **Permiso:** `resources.archive`.
- **Pre:** sin obligaciones abiertas vinculadas (o force=true que las void).
- **Returns:** `void`.

### `revert_archive_resource(p_resource_id, p_reason?)`

- **Permiso:** `resources.update`.
- **Returns:** `void`.

---

## 7. Resource series & capabilities

### `create_resource_series(p_group_id, p_resource_type, p_cadence, p_pattern jsonb, p_starts_on?, p_ends_on?, p_ritual_meaning?, p_ritual_marker_kind?, p_template_payload?)`

- **Permiso:** `resources.create`.
- **Returns:** `uuid` (series_id).

### `update_resource_series(p_series_id, p_pattern?, p_ritual_meaning?, p_ritual_marker_kind?, p_template_payload?, p_ends_on?)`

- **Permiso:** `resources.update`.
- **Returns:** `void`.

### `enable_resource_capability(p_resource_id, p_capability_key, p_config?)`

- **Permiso:** `resources.update`.
- **Returns:** `void`.

### `disable_resource_capability(p_resource_id, p_capability_key)`

- **Permiso:** `resources.update`.
- **Returns:** `void`.

---

## 8. Resource ops — bookings, RSVP, check-in

### `book_resource(p_resource_id, p_starts_at, p_ends_at?, p_reason?, p_client_id?)`

- **Permiso:** `bookings.create`. Caller debe ser miembro activo.
- **Validación:** no overlap si capability `single_booking` enabled.
- **Acciones:** insert `group_resource_bookings` status='confirmed'.
- **Emite:** `group_events`, side-effect rules.
- **Returns:** `uuid` (booking_id).

### `cancel_booking(p_booking_id, p_reason?)`

- **Permiso:** owner del booking o `bookings.cancel`.
- **Acciones:** insert nueva fila con `status='cancelled'` (append-only).
- **Returns:** `uuid` (new booking row id).

### `submit_rsvp(p_resource_id, p_rsvp_status, p_note?, p_client_id?)`

- **Permiso:** `rsvp.submit` + member del grupo del resource.
- **Acciones:** insert `group_rsvp_actions` (latest wins por seq).
- **Emite:** `group_events` ('rsvp.submitted'), notif host si rsvp_status='not_going' tardío.
- **Returns:** `uuid` (rsvp_action_id).

### `submit_check_in(p_resource_id, p_check_in_method, p_location_verified?, p_client_id?)`

- **Permiso:** `check_in.submit`.
- **Acciones:** insert `group_check_in_actions`.
- **Returns:** `uuid` (check_in_id).

### `mark_no_show(p_resource_id, p_membership_id)`

- **Permiso:** host del resource o `resources.update`.
- **Acciones:** emite `group_events` ('check_in.missed'). Si hay rule con trigger 'check_in.missed', evaluate.
- **Returns:** `void`.

---

## 9. Money 2.0 — value movements

### `record_expense(p_group_id, p_resource_id?, p_amount, p_unit, p_paid_by_membership_id, p_description?, p_split_mode, p_split_breakdown?, p_in_kind?, p_client_id?)`

- **Permiso:** `expense.record`. Doctrina "registrar ≠ aprobar": cualquier miembro registra.
- **Acciones:**
  - Insert `group_resource_transactions` (transaction_type='expense', amount, source_entity_kind=null).
  - Si `p_split_mode!='none'`: materializa `group_obligations` por participante (FIFO read order).
  - Emite `group_events` ('money.expense_recorded').
- **Returns:** `uuid` (transaction_id).

### `record_contribution(p_group_id, p_resource_id?, p_amount, p_unit, p_from_membership_id, p_description?, p_in_kind?, p_client_id?)`

- **Permiso:** `contribution.record`.
- **Acciones:** transaction_type='contribution'. Si in_kind, no afecta balance monetario.
- **Returns:** `uuid` (transaction_id).

### `record_non_monetary_contribution(p_group_id, p_membership_id, p_contribution_type, p_title, p_description, p_source_resource_id?)`

- **Permiso:** `contribution.record`.
- **Acciones:** insert `group_contributions` (no toca ledger).
- **Emite:** `group_events` ('contribution.recorded').
- **Returns:** `uuid` (contribution_id).

### `verify_contribution(p_contribution_id, p_outcome 'verified'|'rejected', p_note?)`

- **Permiso:** `records.read` (sí: leer + decidir, no inventar permission nueva).
- **Returns:** `void`.

### `record_settlement(p_group_id, p_paid_by_membership_id, p_paid_to_membership_id?, p_paid_to_kind 'member'|'pool'|'vendor'|'group', p_amount, p_unit, p_notes?, p_client_id?)`

- **Permiso:** `settlement.record`.
- **Acciones (en transacción):**
  - Insert `group_settlements` status='confirmed' (o 'initiated' si el receptor debe confirmar).
  - **Lock con FOR UPDATE:** todas las `group_obligations` open|partially_settled de `(owed_by=paid_by, owed_to=paid_to)`.
  - **FIFO closure:** itera oldest first, decrementa amount_outstanding, inserta `group_settlement_obligations`. Si hay sobrante, queda en settlement.metadata.unallocated.
  - Insert `group_resource_transactions` (transaction_type='settlement_payment', source_entity_kind='settlement', source_entity_id=settlement_id).
  - Emite reputation_event ('commitment_kept') por cada obligation cerrada.
- **Returns:** `(settlement_id, transaction_id)`.

### `record_pool_charge(p_group_id, p_target_membership_id, p_amount, p_unit, p_charge_kind 'quota'|'buy_in'|'fee', p_reason, p_client_id?)`

- **Permiso:** `pool_charge.record`.
- **Acciones:** insert `group_obligations` (obligation_kind='pool_charge', owed_to_kind='pool'). NO inserta transaction (todavía no se mueve dinero).
- **Returns:** `uuid` (obligation_id).

### `record_payout(p_group_id, p_to_membership_id, p_amount, p_unit, p_source_resource_id?, p_reason?, p_client_id?)`

- **Permiso:** `payout.record`.
- **Acciones:** transaction_type='payout'.
- **Returns:** `uuid` (transaction_id).

### `reverse_transaction(p_transaction_id, p_reason)`

- **Permiso:** `records.read` + ser quien creó la entrada o tener `resources.update` para entries de resources.
- **Acciones:** insert nueva fila con transaction_type='reversal', reversed_entry_id, amount = entry.amount.
- **Returns:** `uuid` (reversal_transaction_id).

### `record_asset_valuation(p_resource_id, p_value, p_unit, p_basis)`

- **Permiso:** `resources.update`.
- **Acciones:** insert `group_resource_asset_valuations`. Actualiza `group_resource_assets.current_value/current_value_unit`.
- **Returns:** `uuid` (valuation_id).

---

## 10. Sanctions

### `issue_sanction(p_group_id, p_target_membership_id, p_sanction_kind, p_reason, p_amount?, p_unit?, p_ends_at?, p_rule_version_id?, p_source_event_id?, p_client_id?)`

- **Permiso:** `sanctions.create`.
- **Acciones:**
  - Insert `group_sanctions` status='active' (o 'proposed' si decision_rules exige voto previo).
  - Si `sanction_kind='monetary'`: insert `group_obligations` (kind='fine', amount).
  - Si `sanction_kind='suspension'`: programar `set_membership_state(..., 'suspended', suspended_until=ends_at)`.
  - Si `sanction_kind='loss_of_role'`: ejecuta `revoke_role_from_member`.
  - Emite `group_events`, reputation_event ('rule_violation' si rule_version_id presente).
- **Returns:** `uuid` (sanction_id).

### `update_sanction_status(p_sanction_id, p_new_status 'reversed'|'completed'|'cancelled', p_reason?)`

- **Permiso:** `sanctions.update`.
- **Acciones:** update. Si reversed: emite reputation_event ('repaired_trust') si vino de dispute_pass.
- **Returns:** `void`.

### `dispute_sanction(p_sanction_id, p_summary)`

- **Permiso:** target del sanction o `sanctions.dispute`.
- **Acciones:** wrapper que llama `open_dispute(subject_kind='sanction', subject_id=p_sanction_id, ...)`.
- **Returns:** `uuid` (dispute_id).

---

## 11. Disputes

### `open_dispute(p_group_id, p_subject_kind, p_subject_id, p_title, p_description?, p_respondent_membership_id?)`

- **Permiso:** `disputes.open`.
- **Acciones:** insert `group_disputes` status='open'. Inserta `group_dispute_events` ('opened').
- **Returns:** `uuid` (dispute_id).

### `assign_mediator(p_dispute_id, p_mediator_membership_id)`

- **Permiso:** `disputes.mediate` o admin.
- **Acciones:** update mediator + status='mediation'. Emite dispute_event.
- **Returns:** `void`.

### `append_dispute_event(p_dispute_id, p_event_type 'comment'|'evidence_added'|'mediation_note', p_body, p_metadata?)`

- **Permiso:** involucrado (opener/respondent/mediator) o `disputes.mediate`.
- **Acciones:** insert `group_dispute_events`.
- **Returns:** `uuid` (event_id).

### `record_dispute_resolution(p_dispute_id, p_method, p_resolution_text, p_outcome jsonb?)`

- **Permiso:** mediator del dispute o `disputes.resolve`.
- **Acciones:** update status='resolved' + resolution. Si subject_kind='sanction' y outcome=='reverse': llama `update_sanction_status(reversed)`.
- **Emite:** reputation_event ('conflict_resolved') para ambas partes.
- **Returns:** `void`.

### `escalate_dispute_to_vote(p_dispute_id, p_decision_title, p_decision_method 'majority'|'supermajority'|'consensus', p_closes_at)`

- **Permiso:** mediator del dispute.
- **Acciones:** crea `group_decisions` (decision_type='sanction_appeal', reference_kind='dispute', reference_id=p_dispute_id). Linkea `group_disputes.escalated_decision_id`. Status='escalated'.
- **Returns:** `uuid` (decision_id).

---

## 12. Decisions

### `start_vote(p_group_id, p_title, p_body?, p_decision_type, p_method, p_legitimacy_source, p_opens_at?, p_closes_at, p_threshold_pct?, p_quorum_pct?, p_committee_only?, p_reference_kind?, p_reference_id?, p_options jsonb?)`

- **Permiso:** `decisions.create`.
- **Acciones:** insert `group_decisions` + `group_decision_options` (si options[]). Status='open'.
- **Emite:** notif a todos los electores.
- **Returns:** `uuid` (decision_id).

### `cast_vote(p_decision_id, p_option_id?, p_vote_value 'yes'|'no'|'abstain'|'block', p_weight?, p_reason?)`

- **Permiso:** `decisions.vote`. Voter membership del caller.
- **Pre:** decision.status='open', dentro de la ventana. Si committee_only, voter on committee.
- **Acciones:** insert `group_votes`. Voto vigente = última fila por seq.
- **Returns:** `uuid` (vote_id).

### `cancel_vote(p_decision_id, p_reason)`

- **Permiso:** `decisions.resolve`.
- **Acciones:** status='cancelled'.
- **Returns:** `void`.

### `finalize_vote(p_decision_id)`

- **Permiso:** `decisions.resolve` o llamado por cron `finalize_votes_cron`.
- **Pre:** closes_at ≤ now() o cancelable manual.
- **Acciones:**
  - Computa current_votes con DISTINCT ON.
  - Aplica method + threshold + quorum.
  - Update status='passed'|'rejected' + decided_at + result jsonb.
  - **Aplica side-effects según reference_kind:**
    - `'rule'` → `publish_rule_version` o `archive_rule`.
    - `'sanction'` o dispute escalation → `update_sanction_status`.
    - `'mandate_grant'` → `grant_mandate` con source_decision_id.
    - `'mandate_revoke'` → `revoke_mandate`.
    - `'dissolution'` → `approve_dissolution`.
    - `'member'` → `set_membership_state`.
- **Returns:** `text` ('passed'|'rejected'|'no_quorum').

### `current_vote_for(p_decision_id, p_voter_membership_id)`

- **Helper read-only.** Returns `group_votes` row (latest seq).

---

## 13. Reputation

### `record_reputation_event(p_group_id, p_subject_membership_id, p_reputation_type, p_reason?, p_evidence_entity_kind?, p_evidence_entity_id?, p_visibility?)`

- **Permiso:** `reputation.record` para entradas manuales.
- **Acciones:** insert `group_reputation_events`.
- **Returns:** `uuid` (event_id).

### Triggers automáticos (server-side, sin RPC exposed)

- `obligation_settled` → reputation_type='commitment_kept'
- `sanction_active` con `sanction_kind in ('monetary','suspension')` → reputation_type='commitment_broken'
- `dispute_resolved` → 'conflict_resolved' para opener y respondent
- `contribution_verified` → 'contribution_recognized'
- `rsvp.no_show` (rule consecuence) → 'reliability_signal' (kind='miss')

### `retract_reputation_event(p_event_id, p_reason)`

- **Permiso:** issuer del event o `reputation.record`.
- **Acciones:** update status='retracted' (única columna mutable junto a visibility).
- **Returns:** `void`.

---

## 14. Culture

### `propose_norm(p_group_id, p_norm_type, p_title, p_body?, p_visibility?)`

- **Permiso:** `culture.propose`.
- **Returns:** `uuid` (norm_id).

### `endorse_norm(p_norm_id)`

- **Permiso:** `culture.endorse`.
- **Acciones:** increment endorsed_count, si pasa threshold (groups.settings.norm_endorse_threshold), promueve a status='endorsed'.
- **Returns:** `void`.

### `retire_norm(p_norm_id, p_reason?)`

- **Permiso:** `culture.endorse` o proposed_by.
- **Returns:** `void`.

---

## 15. Dissolution

### `propose_dissolution(p_group_id, p_reason, p_plan jsonb, p_asset_disposition jsonb, p_obligations_plan jsonb)`

- **Permiso:** `group.dissolve`.
- **Acciones:** insert `group_dissolutions` status='proposed'. Crea `group_decisions` para aprobación (decision_type='dissolution', reference_kind='dissolution', reference_id=dissolution_id). Update `groups.status='dissolving'`.
- **Returns:** `uuid` (dissolution_id).

### `approve_dissolution(p_dissolution_id)`

- **Permiso:** ninguno (interno, called by `finalize_vote` cuando decision passes).
- **Acciones:** status='approved'. Inicia liquidation.
- **Returns:** `void`.

### `record_liquidation_step(p_dissolution_id, p_step_kind 'obligation_voided'|'asset_disposed'|'fund_distributed'|'record_archived', p_payload jsonb)`

- **Permiso:** `group.dissolve`.
- **Acciones:** append a `group_dissolutions.plan.steps[]`. Emite group_events.
- **Returns:** `void`.

### `finalize_dissolution(p_dissolution_id)`

- **Permiso:** `group.dissolve`.
- **Pre:** todos los `group_obligations` del grupo en status='settled'|'voided'. Sin pending settlements.
- **Acciones:** status='executed', executed_at, `groups.status='dissolved'`, `groups.dissolved_at`. Marca todas las memberships status='left' con reason='dissolution'.
- **Returns:** `void`.

---

## 16. Memory & helpers

### `record_system_event(p_group_id, p_event_type, p_entity_kind?, p_entity_id?, p_summary?, p_payload?)`

- **Permiso:** ninguno (interno, llamado por todas las RPCs anteriores).
- **Acciones:** insert `group_events`. Si rule engine tiene rules matcheando trigger_event_type, programa `evaluate_rules_for_event` async.
- **Returns:** `bigint` (event id) + `uuid` (uuid_id).

### `member_balance_in_group(p_group_id, p_membership_id)`

- **View wrapper read-only.** Suma transactions − obligations open.
- **Returns:** `numeric`.

### `member_obligation_summary(p_group_id, p_membership_id)`

- **Returns:** `setof (obligation_id, kind, amount_outstanding, owed_to_kind, owed_to_label)`.

### `current_votes_for_decision(p_decision_id)`

- **Returns:** `setof group_votes` con DISTINCT ON (voter_membership_id) ORDER BY seq DESC.

### `group_summary(p_group_id)`

- **Composite read** for iOS landing: counts of members, open decisions, open disputes, open obligations, recent events.

---

## 17. Auth helpers (Supabase wrappers)

### `request_otp(p_phone, p_locale?)`

- **Permiso:** ninguno (pre-login).
- **Wrapper de:** `supabase.auth.signInWithOtp` server-side (via `auth.admin.invoke`).
- **Returns:** `text` ('sent' | 'rate_limited' | 'invalid').

### `verify_otp(p_phone, p_code)`

- **Wrapper de:** `auth.verifyOtp`.
- **Side effect:** trigger `on_auth_user_phone_sync` mirror a `profiles.phone`.
- **Returns:** `(user_id uuid, session_token text)`.

### `delete_and_export_my_data()`

- **Permiso:** caller is self.
- **Acciones (GDPR):**
  - Export jsonb completo de toda data del user (profile + memberships + contributions + votes + sanctions + ...).
  - Marca `profiles.deleted_at`, anonimiza display_name/avatar.
  - Cierra mandates, suspende memberships.
- **Returns:** `jsonb` (export blob).

---

## 18. Permission key wrap-up

Todas las RPCs anteriores usan los 44 keys de `permissions` definidos en
`CanonicalSchema.sql §17`. Si alguna RPC requiere un key nuevo, se agrega al
catalog en migration follow-up.

---

## 19. Pendientes / decisiones por confirmar

1. **`request_membership` para grupos públicos.** ¿V1 lo necesita o esperar a tener flujo de "apply"? Tentativa: definir la RPC pero no exponerla en iOS V1.
2. **Mandates con autoridad de `spend`.** ¿`record_settlement`/`record_expense` deben aceptar un `mandate_id` opcional como prueba de autorización? Útil para casos como "tesorero gasta del pool". Recomendado: sí.
3. **`evaluate_rules_for_event` sync vs async.** Sync = bloquea la RPC que disparó el evento. Async = via pg_cron/edge function. Default propuesto: **async** para mantener latencia baja en iOS, con fallback sync si edge function falla.
4. **Rate limiting** en RPCs públicas (request_otp, accept_invite). Lo dejo fuera de este anexo; vive en edge functions (Supabase Auth ya tiene built-in).

Cuando el catálogo esté aprobado, los bodies SQL se redactan en orden y se concatenan al `00001_canonical_schema.sql` después del bloque RLS.
