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

## Fase 2 — Corto plazo

Estado actualizado 2026-06-11 (segunda tanda del PR #161, `audit_7`…`audit_10`):

1. ✅ **Registro de deprecación de RPCs** (`audit_8`, COMMENT ON sin drops):
   `set_event_participant_plus_one`, `request_governed_action`, `actor_inbox_items`,
   `decision_results` (drift live-only; el DO block la salta en replay). Excluidas tras
   verificar callers: `governance_policy` (la consume record_expense R.9.C),
   `update_governance_policy`, `current_person_actor_id` (alias intencional R.4A),
   `mark_notification_*` (R.4D pendiente), overloads `*_available_actions` (→ ítem 2).
   Contrato §15.2.
2. ✅(veredicto)/⬜(drops) **Overloads** (`audit_12`, verificación completa iOS + cadena):
   - NO legacy (APIs duales intencionales, no dropear): `record_game_result`
     (iOS usa winner/loser; el batch jsonb es API de motor) y los 3
     `*_available_actions` (1-arg = caller-derived usada por descriptors/smokes;
     2-arg = actor-explícito del governance-mode r7_d).
   - Legacy reales **consolidados como wrappers delegantes** (`audit_13`): las dos
     firmas eran implementaciones independientes duplicadas; ahora `create_rule`
     8-args delega a la firma con targeting (defaults originales conservados:
     42P13 exige replicarlos) y `resolve_reservation_conflict` 2-args delega al
     modelo `'winner'` de r2s_7 (equivalencia verificada rama por rama: loser→
     rejected, winner→approved, mismos activity events, no_op sobre no-open).
     Verificado con la suite `_smoke_mvp2_*` COMPLETA en live. El drop físico de
     las firmas queda para cuando se modernicen el dispatcher r7_x y los smokes
     posicionales — ya sin lógica duplicada, solo firmas de cortesía.
3. ✅ **Policies `{public}` → `TO authenticated`** (`audit_7`, 6 tablas, quals idénticos).
4. ✅ **`void_transaction`** (`audit_9` + smoke `_smoke_mvp2_audit_void_transaction`):
   reversa append-only de ledger, cancelación de obligaciones `open` vinculadas, guards
   (no settlement, no referenciada, no obligaciones netted), idempotente. Contrato §15.1.
   Bonus `audit_10`: el baseline cazó en vivo `settlement.payment_claimed` sin catalogar
   → catalogados los 2 tipos restantes del handshake r5z (`payment_claimed`,
   `payment_rejected`). Nota: `money.fine_recorded` NO se cataloga — `_emit_activity`
   lo mapea al canónico `fine.created`.
5. ✅ **Taxonomía vs primitivas** (`audit_14`, reversible flipeando el flag):
   `resource_subtypes.is_creatable` (false para clases `obligation` y `event`, 9
   subtipos); el picker (`list_resource_subtypes`, aterrizada en disco como shim de
   drift junto con `list_resource_classes`) solo lista creables; guard duro en el
   trigger de derivación SOLO para clase `obligation` (la clase `event` no se
   bloquea a nivel trigger: el mapping legacy `game→recurring_event` es legítimo).
   Smoke `_smoke_mvp2_audit_subtype_creatable` con ejecución inline. iOS sin
   cambios (solo ve menos opciones en el picker).
   `audit_15`: assert 7 del baseline exenta los fixtures negativos del smoke r2s_4
   (`custom.%`/`totally.bogus_type`) — el baseline es re-ejecutable en live, no
   solo en replay fresco.
6. ✅ **Anti-bypass governance** (`audit_11`, smoke `_smoke_mvp2_audit_governance_antibypass`
   con ejecución inline): con `member_ban_requires_vote` activa, `remove_member` directo
   Y con `p_force => true` quedan bloqueados con la membresía intacta; al desactivar la
   policy el camino directo vuelve a operar. El happy path request→vote→execute ya lo
   cubren los smokes R.5/R.7.
7. ⬜ **Auth dashboard**: habilitar leaked password protection; revisar rate limits OTP.
   (No es migración; checklist de release.)

## Fase 3 — Mediano plazo (cuando el producto lo pida)

Adelantos ya ejecutados (2026-06-11, "barato hoy, épico mañana"):

- ✅ **RLS fast-path de membresías** (`audit_18`): `my_context_ids()` STABLE +
  reescritura 1:1 de las 10 policies cuyo qual era exactamente
  `is_context_member(context_actor_id)` (calendar_events, decisions, rules,
  context_invites, governance_actions/policies, roles, role_assignments,
  vote_delegations, resource_conflicts) a `context_actor_id IN (SELECT
  my_context_ids())`. Verificado con EXPLAIN: `hashed SubPlan` (una evaluación
  por query) en vez del lookup SPI por fila. Las policies compuestas
  (activity_events, actors, resources, money) quedan para reescritura dedicada
  por tabla cuando su tamaño lo amerite.
- ✅ **PKs particionables** (`audit_16`): `activity_events` y `ledger_entries` (las dos
  tablas de crecimiento infinito) ahora tienen PK `(id, occurred_at)` — el particionado
  declarativo por rango queda habilitado sin migración futura. Verificado: cero FKs las
  referencian.
- ✅ **Invariante contable en la base** (`audit_17`): constraint trigger DEFERRED sobre
  `money_splits` que valida al COMMIT `sum(splits) = 2×amount` por transacción (pata del
  pagador + pata de deudores/beneficiarios). Invariante verificado empíricamente contra
  toda la data viva y contra la suite completa (incluye pools R8 y settlement handshake).

Pendientes (sin fecha):

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
