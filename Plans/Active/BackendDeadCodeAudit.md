# Backend Dead Code Audit (Phase 1 — Functions + Edge Functions)

Estado: **ACTIVO** desde 2026-05-24.
Alcance: Supabase `public` schema (226 functions) + 22 edge functions + 15 cron jobs.
Out of scope (Phase 2): tablas/columnas no leídas, vistas obsoletas, índices muertos.

## Metodología

Para cada función pública, intersección de tres fuentes de caller:

1. **iOS RPC calls** — grep `\.rpc\("…"\)` en `ios/Packages/` (~86 RPCs únicos)
2. **Edge function RPC calls** — grep `\.rpc\("…"\)` en `supabase/functions/**/*.ts` excluyendo `_tests/` (~50 RPCs únicos)
3. **Cron RPC calls** — `select * from cron.job` con SQL directo (5 RPCs)
4. **Internal DB callers** — `pg_proc.prosrc ~* '\m<fnname>\M'` cross-product (i.e. otra función la llama)

Si una función no aparece en ninguna de las 4 fuentes Y no es trigger/RLS-predicate (heurística por nombre), es candidato a drop.

## Inventario

| Categoría | Count |
|---|---|
| Funciones `public` schema | 226 |
| Llamadas desde iOS | 86 |
| Llamadas desde edge functions | 50 |
| Llamadas desde cron directo | 5 (`resolve_stale_fine_voided`, `reset_stale_outbox_claims`, `fail_stale_data_rights_requests`, `expire_due_rights`, `notify_rights_expiring_soon`) |
| Edge functions activos | 22 |
| Edge functions invocados desde iOS | 5 (`send-event-notification`, `send-otp`, `verify-otp`, `send-whatsapp-invite`, `create-placeholder-member`) |
| Edge functions en cron | 10 |

## Función Drop Candidates — Confianza Alta

Sin caller en iOS, edge fn, cron, ni internal helpers. Verificados por superseded-by relación o por orphan utility.

### 1. RPCs superseded por v2 / variantes nuevas

| Función | Por qué dead | Reemplazo |
|---|---|---|
| `create_event_rule(p_group_id, p_resource_id, p_name, p_trigger, p_conditions, p_consequences)` | iOS usa `create_resource_rule` polimórfico | `create_resource_rule` |
| `list_event_rules_with_inherited(p_event_id)` | iOS usa `list_resource_rules_with_inherited` | `list_resource_rules_with_inherited` |
| `update_group_config(...)` | Sustituida por setters individuales + `capability_configs` jsonb | individual RPCs + `groups.governance` jsonb |

**DROP migration (safe):** Sí, drop directo. Si algún edge fn los llamara y lo perdimos, el siguiente cron run fallaría visible.

### 2. Funciones huérfanas (utility nunca llamada)

| Función | Riesgo si DROP |
|---|---|
| `get_placeholder_history_summary(p_placeholder_uid)` | Bajo. Sin caller actual. |
| `list_member_permissions(p_member_id)` | Bajo. Sin caller actual; `has_permission` cubre el caso 1-1. |
| `list_members_with_permission(p_group_id, p_permission)` | Bajo. Sin caller actual; admin tools usan otras queries. |
| `seed_shared_pool_for_existing_group(p_group_id)` | Bajo. One-shot migration helper (probablemente ya corrió en backfill). |

**DROP migration (safe):** Sí, drop directo.

### 3. Funciones de test que viven en `public`

| Función | Por qué |
|---|---|
| `test_checkinmissed_emission` | Test helper en runtime |
| `test_hostassigned_atom_emission` | Test helper en runtime |
| `test_rsvp_atom_emission` | Test helper en runtime |

**DROP migration:** Recomendado mover a schema `test_` propio, o droppear si los tests reales viven solo en `supabase/functions/_tests/`. Verificar primero si CI las invoca.

## Función Drop Candidates — Confianza Media (verificar antes)

Pueden tener caller que mi grep no detectó (deeplinks, dynamic strings, admin tools).

| Función | Por qué dudoso |
|---|---|
| `remove_member(p_group_id, p_user_id, p_reason)` | CLAUDE.md menciona `rpc('remove_member')` pero iOS grep no encuentra. Verificar admin tool no migrado o dynamic rpc string. |
| `set_turn_order(p_group_id, p_user_ids)` | CLAUDE.md menciona. No iOS caller. Verificar onboarding o admin roles. |
| `accept_placeholder_claim`, `decline_placeholder_claim` | Flujo de claims existe en iOS (`PendingClaimsView`, `ClaimReviewView`). Probablemente llamados desde ahí — verificar por qué grep no encontró. |
| `regenerate_invite_code(p_group_id)` | UI feature visible (`RegenerateInviteCodeSheet.swift`). Verificar por qué grep falla — quizás llamada está envuelta. |
| `request_data_export`, `request_data_rectification` | Compliance / Settings privacy. Posible caller en Profile subscreens. |
| `claim_pending_outbox(p_limit)` | Probable cron NOT-active o llamada desde `dispatch-notifications` edge fn (verificar source). |

**Antes de DROP:** ejecutar grep más exhaustivo (variants de string-interpolation, dynamic dispatch). Si tras 2 horas de verificación no aparece caller, droppear.

## Edge Function Drop Candidates

### Confianza Alta

| Edge Fn | Estado | Razón |
|---|---|---|
| `generate-wallet-pass` | **PROBABLE DEAD** | Sin cron, sin iOS caller. Funcionalidad de Apple Wallet built pre-pivot a iOS nativo. Si Wallet sigue siendo un goal, debe wirearse desde iOS PassKit. |
| `export-user-data` | **PROBABLE DEAD** | Sin cron, sin iOS caller. Superseded por RPC `export_my_data` que iOS llama directo. |
| `finalize-appeal-votes` | **PROBABLE DEAD** | Sin cron, sin iOS caller. Superseded por `finalize-fine-reviews` + `finalize-votes` que sí están en cron. |

**Recomendación:** desactivar (no eliminar) primero — Supabase permite `status='PAUSED'`. Si en 30 días no se reporta nada, eliminar definitivamente.

### Confianza Media

| Edge Fn | Verificar |
|---|---|
| `evaluate-event-rules` | Sin cron actual. Pero el nombre sugiere uso desde rule engine. Verificar si `process-system-events` la invoca via HTTP. |
| `send-fine-reminders` | Sin cron. ¿La invoca `finalize-fine-reviews` cuando hay multas pendientes? |
| `emit-deadline-events` | Sin cron actual. ¿Reemplazada por `emit-event-reminder-events`? |
| `auto-generate-events` | Sin cron. ¿Disparada manualmente por admin? ¿Reemplazada por templates? |

## Inconsistencia Detectada

Edge function source code contiene esta línea:

```
.rpc("check_in_attendee", ...)
```

Pero en DB la función se llama `check_in_v2`. Si el edge fn intenta llamarla en runtime, **falla con "function not found"**. Buscar y reemplazar en source de edge fn antes del próximo deploy.

## Función Live — No tocar

86 RPCs iOS + 50 RPCs edge fn + 5 cron + N predicates + N triggers + N internal helpers = ~210 functions vivos de los 226. La lista completa está implícita en este audit (cualquier función fuera de "candidates" arriba se asume live).

## Próximos pasos (orden)

1. **Verificar Confianza Media** (RPCs y Edge Fns) — 2 horas de exploración exhaustiva. Posiblemente la mitad pasan a Confianza Alta.
2. **PR migration: drop Confianza Alta RPCs** (~7 funciones) — `DROP FUNCTION IF EXISTS ... CASCADE`. Migración numerada en `supabase/migrations/`.
3. **Edge fn cleanup**: pause first (Supabase Dashboard or `supabase functions delete`), monitor 30 days, then remove source files from repo.
4. **Phase 2 (separate audit)**: tables/columns no leídas. Requiere `EXPLAIN ANALYZE` o `pg_stat_user_tables` analysis de prod (mucho más caro).

## Anexo A — iOS RPC list (86)

archive_group, assign_custody, assign_slot, book_slot, book_space, build_resource_from_draft, bump_rule_version, cancel_booking, cancel_event, cancel_vote, cast_vote, check_in_asset, check_in_to_space, check_in_v2, check_out_asset, complete_maintenance, contribute_to_shared_money, create_asset, create_event_v2, create_group_with_admin, create_initial_rule, create_resource_rule, create_slot, create_space, delegate_right, delete_my_account, discover_pending_placeholders, exercise_right, export_my_data, finalize_vote, fund_contribute, fund_lock, fund_record_expense, fund_unlock, get_member_summary, grant_space_access, has_permission, issue_manual_fine, join_group_by_code, join_waitlist, link_resource_to_event, list_modules, list_resource_rules_with_inherited, list_rule_shapes, list_rule_templates, log_maintenance, mark_fund_protected, mark_invite_used, next_event_for_group, next_host_for_series, officialize_fine, pay_fine, promote_from_waitlist, promote_space_from_waitlist, publish_rule_composition, publish_rule_version, record_asset_usage, record_ledger_entry, record_settlement, record_shared_expense, record_system_event, record_valuation, release_custody, reopen_event, report_damage, request_slot_swap, restore_right, resolve_governance, reverse_ledger_entry, revoke_right, revoke_space_access, seed_module_rules, seed_template_rules, set_host_default_location, set_notification_preference, set_rsvp_v2, start_fine_appeal, start_vote, suspend_right, transfer_asset, transfer_right, unarchive_group, unlink_resource_from_event, update_event_metadata, update_right_metadata, update_space_metadata, void_fine.

## Anexo B — Edge Function source RPC list (50)

archive_resource, assign_role, assign_slot, book_slot, build_resource_from_draft, bulk_close_stale_events, can_modify_rules, cancel_booking, cast_vote, check_in_attendee *(stale ref)*, close_event, close_event_no_fines, create_asset, create_fund, create_right, create_slot, delete_group_role, expire_booking, finalize_placeholder_member, finalize_vote, fund_contribute, fund_lock, fund_record_expense, fund_unlock, has_permission, issue_manual_fine, lock_asset_bookings, mark_outbox_failed, mark_outbox_sent, mark_outbox_skipped, mark_slots_expired_batch, next_host_for_series, pay_fine, record_ledger_entry_system, record_settlement, record_system_event, record_system_events_batch, reopen_event, request_slot_swap, restore_right, revoke_right, start_fine_appeal, start_vote, suspend_right, transfer_right, unarchive_resource, unassign_role, unlock_asset_bookings, update_right_metadata, upsert_group_role, void_fine.
