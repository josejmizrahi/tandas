# Supabase Target Architecture — Ruul (modelo canónico)

Compañero de `SupabaseArchitectureAudit.md` (2026-06-11). Este documento fija el modelo
objetivo: jerarquía de capas, convenciones de nombres, primitivas canónicas y los
contratos entre capas. El estado actual ya cumple ~90% de esto; las desviaciones y su
camino de convergencia viven en `SupabaseCleanupMigrationPlan.md`.

---

## 1. Jerarquía de capas (canónica)

```
N1 Identity      actors · person_profiles · actor_*_capabilities
N2 Social graph  actor_memberships · actor_relationships · roles/role_permissions/
                 role_assignments · permission_catalog · context_invites ·
                 actor_context_preferences · trust_edges · subscriptions
N3 Resources     resources · resource_rights · taxonomía (type/class/subtype) ·
                 capabilities · actions/forms/dispatch · relations · conflicts ·
                 documents · secciones/widgets server-driven
N4 Operations    calendar_events · event_participants · event_guests ·
                 resource_reservations · reservation_conflicts
N5 Money         obligations · money_transactions · money_splits · ledger_entries ·
                 settlement_batches/items · pool_accounts/pool_basis_entries
N6 Governance    decisions · decision_options · decision_votes · vote_delegations ·
                 decision_templates_catalog · governance_action_catalog ·
                 governance_actions · governance_policies
N7 Rules         rules · rule_evaluations · rule_attention_items
N8 Activity      activity_events · activity_event_catalog · notifications ·
                 notification_deliveries
N9 System        catálogos (permission/resource_type/action/activity/decision_templates/
                 governance_action) · pg_cron jobs · storage buckets
```

Regla de dependencia: una capa solo referencia capas ≤ a la suya (Activity referencia a
todas porque es memoria; Rules consume Activity como trigger y produce N5/N8).

## 2. Principios fundacionales (no negociables)

1. **Actor único**: no existen tablas "groups/orgs/teams". Todo conjunto social es un
   `actor` (`actor_kind=collective|legal_entity`) con `is_context` derivado. El subtipo
   (`family`, `company`, `community`, …) parametriza UI y capabilities, nunca el schema.
2. **Backend = autoridad**: escrituras SOLO vía RPC SECURITY DEFINER con `search_path`
   pineado; RLS de tablas es de lectura (salvo self-writes triviales: subscriptions,
   trust_edges). La UI gatea con `available_actions[]`, jamás re-implementa permisos.
3. **Intent-first**: toda acción visible nace de catálogos (`resource_action_catalog`,
   `governance_action_catalog`) + descriptors. Prohibido branchear por tipo en clientes.
4. **Append-only memory**: `activity_events` es la memoria institucional (trigger
   anti-update/delete). Todo RPC mutador emite actividad con tipo registrado en
   `activity_event_catalog` (invariante de CI desde `_smoke_mvp2_audit_baseline`).
5. **Gobernanza PULL**: las RPCs peligrosas consultan `governance_policies`; si la
   política lo exige, la acción se convierte en `governance_action` + `decision` en vez de
   ejecutarse. Ninguna RPC nueva del catálogo de gobernanza puede ejecutar directo sin
   pasar por `_aa_apply_governance_mode`/entrypoint canónico.
6. **Idempotencia en escrituras de riesgo**: `client_id` (idempotencia del cliente) en
   events/decisions/money/obligations/reservations/pools; claves internas
   (`idempotency_key`) para motores (rules, governance, settlement replay).
7. **text + CHECK, no enums**: los vocabularios cerrados viven en CHECK constraints o
   catálogos FK; los enums de Postgres quedan prohibidos (rigidez de ALTER).
8. **Disco = fuente única**: todo cambio aplicado por MCP debe aterrizar idéntico en
   `supabase/migrations/` en el mismo PR. El replay CI + smokes son el contrato.

## 3. Naming convention (canónica)

**Tablas**: plural `snake_case`; catálogos sufijo `_catalog` (o `_types` para tipos de
relación/conflicto); sin prefijos de release en tablas nuevas.

**Columnas**:
- `id uuid pk default gen_random_uuid()`; FKs `<rol>_actor_id` (`debtor_`, `holder_`,
  `host_`, `subscriber_`…), `context_actor_id` para el contexto, `resource_id`,
  `decision_id`, `event_id`, `rule_id`, `obligation_id`.
- `user_id`/`auth_user_id` SOLO en la frontera con auth (`person_profiles`).
- Timestamps base: `created_at` siempre; `updated_at` + touch trigger en toda tabla
  mutable; `metadata jsonb not null default '{}'`.
- Soft-states por dominio (taxonomía intencional, no inconsistencia):
  `archived_at` (recursos/documentos/reglas/actores), `revoked_at` (derechos,
  delegaciones, invites), `removed_at` (edges sociales), `cancelled_at` (operaciones),
  `left_at` (membresías), `resolved_at` (conflictos/pools/attention),
  `completed_at`/`forgiven` (obligaciones vía status).
- Autoría: `created_by_actor_id` en primitivas creables. NO se agregan
  `updated_by/archived_by` por columna: la autoría de cada mutación vive en
  `activity_events` (actor_id + payload), que es más rica y append-only.
- Idempotencia: `client_id text` + unique parcial `(scope, client_id) WHERE client_id IS NOT NULL`.

**Funciones**: `verbo_objeto` (`create_resource`, `record_expense`,
`request_governance_action`); lecturas `list_*`/`*_detail`/`*_summary`/`*_descriptor`;
explicabilidad `why_*`; helpers internos prefijo `_`; smokes `_smoke_mvp2_*`. Toda función
nueva: `SECURITY DEFINER` solo si muta o necesita visión ampliada, `SET search_path =
public, auth`, `REVOKE ... FROM public, anon` + grant explícito a `authenticated` (o a
nadie si es interna). Sin overloads: evolución de firma = nueva firma + drop del overload
viejo en la misma release (tras actualizar smokes/iOS).

## 4. Los tres planos de autorización (no fusionar)

| Plano | Tabla(s) | Pregunta que responde |
|---|---|---|
| Membership permissions | `permission_catalog` + roles | "¿Qué puede hacer este miembro EN este contexto?" (`members.manage`, `money.record`) |
| Resource rights | `resource_rights` | "¿Qué derecho tiene este actor SOBRE este recurso?" (OWN/USE/MANAGE/VIEW, %, vigencia) |
| Capabilities | `*_capabilities*` | "¿Qué permite la NATURALEZA de este tipo/subtipo/instancia?" (reservable, transferable) |

`available_actions[]` = intersección de los tres planos + estado + governance mode. Esa
intersección se computa SOLO en backend (`member_available_actions`, descriptors).

## 5. Resources — modelo objetivo

- Typing canónico: `resource_class_key` (17 clases) + `resource_subtype_key` (45+,
  extensible por catálogo, jamás por DDL). `resource_type` queda como columna legacy de
  lectura hasta Fase 3 (compat iOS), luego se convierte en generated/derivada.
- Primitivas NO son recursos: eventos (`calendar_events`), decisiones, reglas y
  obligaciones tienen tabla propia. Los subtipos de clase `event`/`obligation` del
  catálogo existen solo como taxonomía de UI; el picker debe (a) ocultarlos o (b)
  enrutar al intent correcto (decisión Fase 2). Nunca debe existir un "recurso-iou" con
  dinero real.
- Tipos/clases objetivo ya cubiertos: vehicle, real_estate(house/apartment/land/...),
  space, financial (bank_account/cash_pool/trust_fund/...), equipment, document,
  digital_asset, trip, membership, right, agreement, service, project, inventory,
  generic. Pendientes de producto: `task` (evaluado y diferido — ver
  `Plans/Active/Task_Primitive_Evaluation.md`), `location` (hoy `location_text`/metadata;
  primitiva propia solo si aparecen casos geo).

### 5.1 Conflictos: tabla tipada + superficie (regla canónica)

`reservation_conflicts` (hecho relacional entre dos reservas, con FKs, unique del
par y maquinaria winner/split/decision) es la FUENTE DE VERDAD de su dominio;
`resource_conflicts` es la SUPERFICIE unificada de atención (proyección, hoy vía
triggers espejo r5b_2; la resolución enruta de vuelta al dominio — verificado en
`resolve_resource_conflict`). Regla para toda fuente de conflicto futura:
¿tiene maquinaria propia de resolución? → tabla tipada + proyección a la
superficie. ¿Solo es "avisar y dismissear"? → directo a `resource_conflicts`
como los detectores. Fase 3 opcional: sustituir el espejo físico por
union/vista en las RPCs de lectura.

## 6. Money — modelo objetivo

```
obligations           (promesa: quién debe qué a quién, kind×type, lifecycle)
   ↓ settle/pay
money_transactions    (hecho económico atómico, posted/voided, client_id)
   + money_splits     (cómo se reparte el hecho)
   ⇒ ledger_entries   (proyección por trigger — saldo por actor/contexto/moneda)
   ⇒ actor_money_balances (vista invoker)
settlement_batches/items  (neteo min-cashflow por novación + handshake 2 vías)
pool_accounts/basis       (capital social: aportes con basis y resolución)
```

Invariantes objetivo (algunos ya, otros Fase 2/3):
- Toda mutación de dinero es RPC idempotente con lock (R9B ✓).
- `sum(money_splits.amount) = 2×amount` por transacción, garantizado por la BASE
  (constraint trigger deferred, audit_17 ✓) — no solo por los RPCs.
- `voided` solo vía `void_transaction` (✓ audit_9) con ledger compensatorio y
  actividad `transaction.voided` catalogada.
- Moneda: una por contexto de neteo (✓); catálogo ISO + FX cuando exista segunda moneda
  real (Fase 3). No diseñar FX antes de necesitarlo.
- Si Ruul llega a custodiar fondos: migrar ledger a doble partida estricta
  (`sum(amount)=0` por transaction_id, cuentas explícitas). El shape actual de
  `ledger_entries` lo permite sin romper lectores (additive).

## 7. Governance — modelo objetivo

- Único entrypoint para acciones peligrosas: `request_governance_action(action_key, …)` →
  resuelve política → ejecuta directo, o crea `governance_action` + `decision` con
  template; `execute_governance_action` corre post-aprobación (trigger). 
- Todo `action_key` nuevo se registra en `governance_action_catalog` con permisos
  request/vote/execute del `permission_catalog`. Smoke debe probar: con política activa,
  el camino directo queda bloqueado (anti-bypass).
- `decisions` es la primitiva de aprobación universal (también para reservas en disputa,
  membresías, recursos); los templates R4B son el puente decisión→efecto.

## 8. Rules — modelo objetivo

- DSL cerrado validado en trigger (✓), targeting por scope/filter (✓), dedup de
  evaluación por idempotency_key consciente de origen (✓), depth guard (✓), detectores
  virtuales vía pg_cron (✓).
- Pendiente Fase 3: snapshot de versión (payload completo de la regla en
  `rule.updated`/`rule.created` activity, o tabla `rule_versions` si aparece UI de
  historial). Hasta entonces, prohibido borrar reglas: solo `archived_at`.

## 9. Activity — modelo objetivo

- `activity_events` append-only; `event_type` con dominio.dot.notation; TODO tipo emitido
  debe existir en `activity_event_catalog` (invariante de CI ✓ desde audit_5).
- `notifications` = delivery por destinatario (badge/push), derivada de actividad o
  emitida por RPCs; nunca fuente de verdad.
- `attention_inbox()` = agregador cross-dominio de "qué requiere acción"; los items
  persistentes viven en su dominio (rule_attention_items, settlement pending, governance
  pending), no en una tabla inbox global.

## 10. Seguridad — baseline permanente (verificado por `_smoke_mvp2_audit_baseline`)

1. Toda tabla en `public`: RLS habilitado + ≥1 policy.
2. `anon`: 0 grants de tabla, 0 EXECUTE en funciones app.
3. Toda función app (no-extensión) con `search_path` pineado.
4. Toda tabla con `updated_at` tiene touch trigger.
5. Tipos de actividad emitidos ⊆ catálogo.
6. Índices de hot-path presentes.
7. Vistas: siempre `security_invoker=true`.

Pendientes fuera de SQL: leaked password protection ON (Dashboard), revisar rate limits
de OTP antes de abrir registro público.
