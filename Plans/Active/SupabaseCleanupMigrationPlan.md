# Supabase Cleanup — Plan de migración (additive-first)

Ejecuta las correcciones de `SupabaseArchitectureAudit.md` hacia
`SupabaseTargetArchitecture.md`. Regla madre: **cada fase deja el sistema funcionando**;
nada se borra sin compat layer; iOS no se entera de la Fase 1.

## §0 — Regla de proceso (vigente desde ya)

Todo `apply_migration` vía MCP aterriza el SQL idéntico en `supabase/migrations/` en el
mismo PR. El replay de CI (`edge-tests.yml`) + `_smoke_mvp2_*` son el contrato; si live y
disco divergen, se repara con shim explícito (precedente `r9_g`), nunca silenciosamente.

---

## Fase 1 — Ejecutada en esta auditoría (2026-06-11) ✅

Migraciones pequeñas, atómicas, 100% additive o de hardening sin cambio de
comportamiento. Aplicadas a live vía MCP y aterrizadas en disco:

| Migration | Contenido | Riesgo |
|---|---|---|
| `audit_1_function_hygiene_search_path_and_anon` | Pinea `search_path = public, auth` en toda función app sin config (30 en live; barrido genérico defensivo para replay) + revoca EXECUTE de `anon` en cualquier función app que lo tuviera (no-op en live; normaliza drift en replay) | Nulo: no cambia semántica; las funciones referencian objetos de `public`/`auth` |
| `audit_2_hot_path_fk_indexes` | ~24 índices `IF NOT EXISTS` en FKs calientes: activity (resource/decision/obligation/subject), money_transactions (from/to/event/obligation), money_splits(actor), obligations (4 sources + status,due_at), settlement (items por actor, batches por contexto+status), decision_votes(voter), calendar_events(host), documents (resource/event/decision), subscriptions (5 targets), reservation_conflicts, resource_reservations (context, reserved_for) | Nulo (additive; tablas chicas, sin CONCURRENTLY necesario) |
| `audit_3_child_tables_audit_columns` | `created_at`/`updated_at` + touch triggers en tablas hijas mutables: `event_participants` (+both), `settlement_items` (+both), `money_splits` (+created_at), `decision_options` (+updated_at), `decision_votes` (+updated_at) | Bajo: columnas nuevas con default `now()`; **los rows preexistentes quedan estampados con la fecha de la migración** (documentado; la fecha real histórica vive en activity) |
| `audit_4_activity_catalog_gap_closure` | Inserta los 20 event_types emitidos y no catalogados (context.child.*, context.merged/unmerged, context.parent.*, decision.updated, document.expiring, event.updated, event.host_rotation_set, event.next_host_overridden, event.next_occurrence_created, governance.approved/executed, obligation.overdue/updated, reservation.starting_soon, resource.action_executed, rule.updated) con domain + is_system_generated correctos | Nulo (ON CONFLICT DO NOTHING) |
| `audit_5_smoke_baseline` | `_smoke_mvp2_audit_baseline()`: vuelve invariantes de CI los 6 puntos del baseline de seguridad (RLS+policy en todo, anon=0, search_path pineado, touch triggers, actividad catalogada, índices hot) | Nulo |

Verificación: smoke ejecutado en live ✅; advisor `function_search_path_mutable` debe caer
de 30 → 0 en el próximo run.

## Fase 2 — Corto plazo (requiere decisiones puntuales del founder)

Orden sugerido; cada ítem es 1 migración + smoke:

1. **Registro de deprecación de RPCs** (sin drop): `COMMENT ON FUNCTION ... 'DEPRECATED:
   usar X'` + sección §15 en `MVP2_iOS_Contract.md` para: `set_event_participant_plus_one`,
   `request_governed_action`, `governance_policy`, `actor_inbox_items`, `decision_results`,
   `current_person_actor_id`, variantes 1-arg de `*_available_actions`.
2. **Drop de overloads viejos** (uno por migración, tras grep de call-sites internos en
   toda la cadena + iOS): `create_rule` 8-args, `record_game_result` winner/loser,
   `resolve_reservation_conflict` 2-args, `*_available_actions` 1-arg si los descriptors
   ya cubren 100%.
3. **Policies `{public}` → `TO authenticated`** (6 tablas: actor_context_preferences,
   decision_options, event_guests, pool_accounts, pool_basis_entries,
   rule_attention_items). Cosmético-defensivo, no-op funcional.
4. **`void_transaction`**: RPC de reversa (status→voided + ledger compensatorio +
   `transaction.voided` catalogado + idempotencia). Cierra el hueco de reversas.
5. **Taxonomía vs primitivas** (decisión producto): flag `is_creatable boolean default
   true` en `resource_subtypes`; poner `false` a los subtipos de clase
   `obligation`/`event`, o enrutar como intents. Smoke: `create_resource` con subtipo
   no-creable falla limpio.
6. **Anti-bypass governance**: smoke dedicado que active una policy
   (`member.remove` p.ej.) y verifique que `remove_member(p_force)` y el resto de caminos
   directos quedan bloqueados para no-admins y redirigidos a governance.
7. **Auth dashboard**: habilitar leaked password protection; revisar rate limits OTP.
   (No es migración; checklist de release.)

## Fase 3 — Mediano plazo (cuando el producto lo pida)

- **Baseline squash opcional** de la cadena (231 archivos + ledger con ~250 entradas
  pre-MVP2): `pg_dump --schema-only` como `baseline_v1` + smokes; la cadena actual se
  archiva (no se borra). Solo si el replay de CI se vuelve lento u oneroso.
- **`rule_versions`** o snapshot completo en activity payload (historial de reglas).
- **Multi-moneda**: `currency_catalog` ISO-4217 + CHECK; FX solo si aparece segunda
  moneda real.
- **Renombres con compat** (solo si reescribimos la tabla por otra razón):
  `money_splits.transaction_id` → `money_transaction_id`;
  `obligations.obligation_type` → `money_subtype`. Receta: columna nueva + vista compat o
  generated column + ventana de doble lectura + drop al final. **No hacerlos en frío**:
  el costo/beneficio no paga.
- **Plantillas de rol compartidas** si `role_permissions` (hoy 1,170 filas) crece
  superlinealmente con contextos.
- **Unused indexes**: re-evaluar los 19 reportados con tráfico real antes de dropear.

## Backfills

Fase 1 no requiere backfill (defaults `now()` documentados). Cualquier backfill futuro:
batch ≤ 5k filas, idempotente, con smoke de conteo antes/después, y NUNCA en la misma
migración que el DDL.

## Rollback

- `audit_1`: re-`ALTER FUNCTION ... RESET search_path` (no debería necesitarse).
- `audit_2`: `DROP INDEX IF EXISTS` (lista en el archivo).
- `audit_3`: `ALTER TABLE ... DROP COLUMN` + `DROP TRIGGER` (solo si algo decodifica mal;
  iOS ignora columnas desconocidas).
- `audit_4`: `DELETE FROM activity_event_catalog WHERE event_type IN (...)` (los 20 keys
  listados en el archivo).
- `audit_5`: `DROP FUNCTION public._smoke_mvp2_audit_baseline()`.

## Smoke tests (estado)

- Suite existente `_smoke_mvp2_*` (CI los corre todos): cubre contexto/membresía/recursos/
  eventos/money/governance/rules/activity/contrato iOS.
- Nuevo `_smoke_mvp2_audit_baseline` (Fase 1): seguridad estructural permanente.
- Pendientes Fase 2: smoke anti-bypass governance (ítem 6), smoke subtipos no creables
  (ítem 5).

## Criterio de éxito

1. Advisors: 0 WARN de search_path; los 211 WARN de "secdef executable by authenticated"
   quedan documentados como diseño (RPC-first) — son falsos positivos para esta
   arquitectura.
2. CI verde con `_smoke_mvp2_audit_baseline` como guardia permanente.
3. Cero cambios visibles para iOS en Fase 1; deprecations comunicadas vía contrato en
   Fase 2.
4. Los tres documentos (`Audit`, `TargetArchitecture`, este plan) se mantienen vivos: toda
   release que toque el schema actualiza el que corresponda.
