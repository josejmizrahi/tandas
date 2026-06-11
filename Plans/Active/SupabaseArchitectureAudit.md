# Supabase Architecture Audit — Ruul MVP2 (2026-06-11)

Auditoría completa del proyecto `wyvkqveienzixinonhum` (schema `public` + storage + cron),
contrastada contra la cadena de migrations en `supabase/migrations/` (231 archivos,
`mvp2_000` → `r9_i`) y contra el consumo real del frontend iOS (143 RPCs detectadas vía
grep de `call("…")` en `SupabaseRuulRPCClient`).

**Metodología**: introspección viva (pg_class, pg_proc, pg_policies, pg_constraint,
pg_indexes, information_schema, cron.job, storage.buckets, pg_default_acl), advisors de
Supabase (security + performance), cruce función↔consumo iOS, y revisión de catálogos.

---

## 1. Veredicto general

La base **ya es actor-céntrica y canónica**: no existen tablas group-céntricas duplicadas,
no hay modelos paralelos de "groups vs contexts" (el reset `mvp2_000` los eliminó; el
ledger de migrations aún recuerda la era pre-MVP2 pero sus tablas no existen). La higiene
de seguridad base es alta:

| Dimensión | Estado |
|---|---|
| RLS habilitado | ✅ 69/69 tablas base |
| Tablas con ≥1 policy | ✅ 69/69 (71 policies; solo SELECT salvo `subscriptions`/`trust_edges` self-write) |
| Escrituras | ✅ Solo vía RPC SECURITY DEFINER (sin policies INSERT/UPDATE/DELETE salvo las 2 excepciones intencionales) |
| `auth.uid()` en policies | ✅ 0 policies con `auth.uid()` directo (todas wrapped → sin problema initplan) |
| Grants de `anon` en tablas | ✅ 0 |
| Funciones app ejecutables por `anon` | ✅ 0 (solo 12 funciones `*_dist` de extensiones, benignas) |
| Default ACL | ✅ Ya endurecido: funciones nuevas nacen sin EXECUTE para PUBLIC/anon/authenticated |
| SECURITY DEFINER sin `search_path` | ✅ 0 |
| Vista `actor_money_balances` | ✅ `security_invoker=true` |
| Touch triggers `updated_at` | ✅ 100% de tablas con `updated_at` tienen trigger BEFORE UPDATE |

Los problemas reales son de **segundo orden**: índices FK faltantes en hot paths, 30
funciones helper con `search_path` mutable, 20 tipos de actividad emitidos pero no
catalogados, columnas de auditoría faltantes en tablas hijas, RPCs legacy/overloads sin
registro de deprecación, y deuda de mantenibilidad en la cadena de migrations (drift
live↔disco ya conocido, ver shim `r9_g`).

---

## 2. Mapa completo de tablas (69 base + 1 vista)

Leyenda — **Estado**: ✅ viva/canónica · ⚠️ viva con observación · 🟡 vacía/aún sin uso ·
**Riesgo de tocar**: A(lto)/M(edio)/B(ajo). "iOS" = consumida directamente vía PostgREST
o indirectamente vía RPC/descriptor.

### Nivel 1 — Identity

| Tabla | Propósito | Estado | Riesgo | Recomendación |
|---|---|---|---|---|
| `actors` | Primitiva universal (person/collective/legal_entity/system; `is_context` derivado por trigger; placeholders + claim) | ✅ | A | No tocar shape. Es el corazón del modelo. |
| `person_profiles` | Perfil 1:1 con `auth.users` (`auth_user_id`) y 1:1 con actor persona | ✅ | A | OK. `user_id` solo aquí (correcto: auth directa). |
| `actor_capabilities_catalog` / `actor_type_capabilities` | Qué puede hacer cada tipo de actor (can_have_members, can_hold_money…) | ✅ | B | OK. |

### Nivel 2 — Social graph

| Tabla | Propósito | Estado | Riesgo | Recomendación |
|---|---|---|---|---|
| `actor_memberships` | Participación actor↔contexto (`membership_status/type`) | ✅ | A | OK. |
| `actor_relationships` | Grafo tipado (contains, owns, trustee_of…; guard anti-ciclos por trigger) | ✅ | M | OK. Jerarquía de contextos vive aquí (`parent_context_actor_id` derivado). |
| `roles` / `role_permissions` / `role_assignments` | Roles por contexto + permisos del `permission_catalog` | ✅ | M | OK. 1,170 filas en role_permissions: crece O(contextos×roles×permisos); a futuro considerar plantillas de rol compartidas (Fase 3). |
| `permission_catalog` | 30 permisos canónicos `dominio.verbo` | ✅ | M | Completo para el producto actual. Sin `created_at`→cosmético. |
| `context_invites` | Invitaciones por código (max_uses/expiración/estado) | ✅ | M | Convive con `invite_member` (invitación dirigida con placeholder): **complementarios, no duplicados** — documentado en §4. |
| `actor_context_preferences` | Favoritos + last_visited por actor/contexto | ✅ | B | Sin timestamps base (tiene favorited_at/last_visited_at); aceptable. |
| `trust_edges` | Red de confianza (self-write con RLS) | ✅ | B | OK. |
| `subscriptions` | Suscripciones polimórficas (5 columnas target_* + uniques parciales) | ✅ | M | Patrón distinto al `subject_type/subject_id` de activity. Documentado como inconsistencia tolerada (§6); índices por target añadidos en `audit_2`. |
| `context_section_catalog` / `context_subtype_sections` / `context_subtype_widgets` / `context_dashboard_widgets` | UI server-driven por subtipo de contexto | ✅ | B | OK. |

### Nivel 3 — Resources

| Tabla | Propósito | Estado | Riesgo | Recomendación |
|---|---|---|---|---|
| `resources` | Primitiva central; typing en 3 niveles: `resource_type` (legacy-compat, FK a catalog) + `resource_class_key` + `resource_subtype_key` (canónicos R5A, derivados por trigger) | ✅ | A | Declarar `resource_type` como **legacy de lectura** y class/subtype como canónicos (ya es así de facto; falta documentarlo en el contrato). |
| `resource_rights` | Derechos OWN/USE/MANAGE/VIEW… con %, scope, vigencia; unique parcial por derecho activo | ✅ | A | OK. `canonical_owner_actor_id` en resources es caché sincronizada por trigger — correcto. |
| `resource_type_catalog` (16) / `resource_classes` (17) / `resource_subtypes` (45) | Taxonomía | ⚠️ | M | Ver §5: subtipos clase `obligation` (iou/fine/loan/dues/contribution) y clase `event` podrían permitir "recursos-obligación/evento" paralelos a las primitivas. Decisión de producto pendiente. |
| `resource_capabilities_catalog` (42) + `resource_type_capabilities` + `resource_subtype_capabilities` + `resource_capability_overrides` | Capacidades efectivas por tipo/subtipo/instancia | ✅ | M | OK (zombie capabilities ya saneadas en `r5a_fix`). |
| `resource_action_catalog` (90) / `resource_action_forms` / `resource_action_dispatch` | Intent-first F.2X: acciones + forms + dispatch | ✅ | M | OK. Fuente del `available_actions[]`. |
| `resource_relation_types` / `resource_relations` | Grafo recurso↔recurso | 🟡 | B | Viva pero sin filas; iOS aún no la consume (RPCs `set/remove/list_resource_relations` sin consumo). Mantener. |
| `resource_section_catalog` / `resource_subtype_sections` / `resource_subtype_widgets` / `resource_dashboard_widgets` | UI server-driven de detalle | ✅ | B | OK. |
| `resource_conflict_types` / `resource_conflicts` | Conflictos unificados (R5B) — **nació por drift MCP, reconstruida en disco vía shim r9_g** | ⚠️ | M | Precedente de drift a vigilar; la fuente única debe ser el disco. |
| `documents` | Documentos + bucket privado `documents` (2 policies storage) | ✅ | M | OK. |

### Nivel 4 — Operations

| Tabla | Propósito | Estado | Riesgo | Recomendación |
|---|---|---|---|---|
| `calendar_events` | Eventos (series acotadas, host rotation, virtual, idempotencia client_id) | ✅ | A | OK. |
| `event_participants` | RSVP/check-in/cancel + plus_count en metadata | ⚠️ | M | **Sin created_at/updated_at** pese a ser mutable → corregido en `audit_3`. |
| `event_guests` | Invitados externos (count_share, linked_actor) | ✅ | B | OK. |
| `resource_reservations` | Reservas con exclusion constraint GiST anti-overlap | ✅ | A | OK (excelente uso de `tstzrange` + estado). |
| `reservation_conflicts` | Conflictos de reserva (espejados a resource_conflicts por trigger) | ✅ | M | OK. |

### Nivel 5 — Money

| Tabla | Propósito | Estado | Riesgo | Recomendación |
|---|---|---|---|---|
| `obligations` | Qué debe quién; doble taxonomía: `obligation_kind` (money/action/…) × `obligation_type` (iou/fine/expense_share/…) | ⚠️ | A | Funciona, pero `obligation_type` solo aplica a kind=money → documentar semántica (§6); no renombrar sin compat. |
| `money_transactions` | Transacciones posted/voided, 7 tipos, client_id idempotente | ✅ | A | OK. `voided` existe pero no hay RPC de reversa consumida → Fase 2. |
| `money_splits` | Partes por transacción (emite ledger por trigger) | ⚠️ | A | Sin `created_at` → corregido en `audit_3`. |
| `ledger_entries` + vista `actor_money_balances` | Ledger derivado append-like (R4C/R9D), vista security_invoker | ✅ | M | Diseño suficiente para MVP; ver §7 para el camino a ledger doble-partida. |
| `settlement_batches` / `settlement_items` | Neteo min-cashflow + handshake 2 vías (pending→pending_confirmation→paid/disputed) | ⚠️ | A | `settlement_items` sin created_at/updated_at pese a estado mutable → corregido en `audit_3`. |
| `pool_accounts` / `pool_basis_entries` | Pools R8 (actor pool + basis + resolución) | 🟡 | M | Recién shippeado, 0 filas en prod. OK. |

### Nivel 6 — Governance

| Tabla | Propósito | Estado | Riesgo | Recomendación |
|---|---|---|---|---|
| `decisions` / `decision_options` / `decision_votes` | Decisiones con opciones, voting_model, templates | ✅ | A | `decision_options.status` mutable sin updated_at; `decision_votes` upsert sin updated_at → corregido en `audit_3`. |
| `vote_delegations` | Delegación de voto (peso en trigger) | 🟡 | B | OK. |
| `decision_templates_catalog` (12) | Plantillas ejecutables R4B | ✅ | M | OK. |
| `governance_action_catalog` (15) / `governance_actions` / `governance_policies` | Orquestación R7 (modelo PULL): catálogo + requests + policies por contexto | ✅ | A | `governance_actions` tiene `idempotency_key` **y** `client_id` — documentar semántica (server vs cliente). Bypass conocido: `remove_member(p_force)` — verificar que el gate por policy lo cubra (Fase 2, smoke dedicado). |

### Nivel 7 — Rules

| Tabla | Propósito | Estado | Riesgo | Recomendación |
|---|---|---|---|---|
| `rules` | DSL cerrado (condition_tree validado por trigger), targeting, severidad | ✅ | A | **Sin versionado**: `update_rule` muta in-place; la “memoria institucional” depende del payload de `rule.updated` en activity. Fase 3: snapshot de versión en payload o tabla `rule_versions`. |
| `rule_evaluations` | Evaluaciones idempotentes (dedup R9H consciente del origen) | ✅ | M | OK. |
| `rule_attention_items` | Consecuencia `attention` (sink R6A) | ✅ | M | OK. |

### Nivel 8 — Activity / Notifications

| Tabla | Propósito | Estado | Riesgo | Recomendación |
|---|---|---|---|---|
| `activity_events` | Append-only (trigger anti UPDATE/DELETE), 1,112 filas, dispatcher del motor de reglas | ✅ | A | Índices por resource/decision/obligation/subject añadidos en `audit_2`. |
| `activity_event_catalog` (79) | Catálogo de tipos | ⚠️ | B | **20 tipos emitidos en prod no estaban catalogados** (context.child.*, governance.approved/executed, obligation.overdue, event.updated, …) → cerrado en `audit_4`. |
| `notifications` / `notification_deliveries` | Inbox R4D | 🟡 | B | Tablas y RPCs (`mark_notification_*`, `emit_notification`) listas; iOS aún no consume. Mantener, no es duplicado de activity (concern distinto). |

### Nivel 9 — System

| Objeto | Estado | Nota |
|---|---|---|
| Extensiones `btree_gist`, `pg_trgm` **en schema public** | ⚠️ | Advisor WARN. Moverlas es riesgoso (operadores GiST de reservas, `similarity()` del motor R2V las usan sin calificar). Decisión: **aceptar y documentar como excepción**; para proyectos nuevos, instalarlas en `extensions`. |
| `pg_cron`: 4 jobs R6 (overdue obligations 15m, expiring documents 1h, starting-soon reservations 30m, expiring rights 1h) | ✅ | OK. |
| Storage: bucket `documents` privado, 2 policies | ✅ | OK. |
| Auth: **leaked password protection deshabilitado** | ⚠️ | Habilitar en Dashboard → Auth → Passwords (no es SQL-able). |
| Enums Postgres | — | 0 enums: todo es `text + CHECK` (77 CHECKs). Decisión correcta para iterar rápido; documentada como convención. |

---

## 3. RLS — detalle

- 71 policies, todas PERMISSIVE; 67 de SELECT, 4 de write (insert/update self en
  `subscriptions` y `trust_edges`).
- 6 policies declaran rol `{public}` en vez de `{authenticated}`
  (`actor_context_preferences`, `decision_options`, `event_guests`, `pool_accounts`,
  `pool_basis_entries`, `rule_attention_items`). **No es fuga** (anon no tiene grant de
  tabla y los quals exigen actor propio), pero es higiene: normalizar a `TO authenticated`
  en Fase 2 para que la intención sea explícita.
- `service_role` aparece explícito solo en 5 policies; el resto se apoya en que
  service_role bypassa RLS. Consistente.

## 4. Duplicidades buscadas (checklist del founder)

| Sospecha | Veredicto |
|---|---|
| groups vs contexts vs spaces | **No existe**: un solo modelo (`actors` con `is_context`). |
| group_resources vs resources | **No existe** (muerto en reset MVP2). |
| events vs calendar_events vs resources tipo event | `calendar_events` es la única primitiva. ⚠️ Riesgo latente: subtipos `dinner/meeting/...` bajo clase `event` en la taxonomía de recursos (§5). |
| payments vs settlements vs transactions | **Capas, no duplicados**: obligations (deuda) → money_transactions+splits (hecho) → ledger_entries (derivado) → settlement_* (neteo). Correcto. |
| rules vs group_rules | Una sola `rules`. |
| permissions duplicados | Tres planos distintos y complementarios: `permission_catalog` (membresía), `resource_rights` (derechos sobre recurso), capabilities (qué permite el tipo). No es duplicación; documentado en TargetArchitecture §4. |
| invitations duplicadas | `context_invites` (por código) + placeholder flow (`invite_member`/`create_placeholder_person`/`claim`) — complementarios. |
| activity logs duplicados | `activity_events` único; `notifications` es delivery, no log. |
| RPC twins | ⚠️ Sí hay: `request_governed_action` vs `request_governance_action`; `governance_policy` vs `list_governance_policies`; `set_event_participant_plus_one` (superseded por `plus_count`); `current_person_actor_id` vs `current_actor_id`. Registro de deprecación en MigrationPlan §Fase 2. |

## 5. Hallazgo conceptual: taxonomía de recursos vs primitivas

`resource_subtypes` contiene subtipos cuya clase colisiona con primitivas dedicadas:
`iou/fine/loan/contribution/dues → obligation`, `recurring_event/meeting/dinner/community_event → event`.
Hoy **ningún recurso vivo usa esas clases** (clases en uso: vehicle=1, real_estate=16,
space=1, financial=6), pero el picker de subtipos podría permitir crear un "recurso-iou"
paralelo a `obligations`. Opciones (decisión de producto, Fase 2):
1. Marcar esos subtipos como `non_creatable` en el picker (flag en catálogo), o
2. Mapearlos como intents que crean la primitiva correcta (crear obligación/evento).

## 6. Inconsistencias de naming (toleradas vs corregibles)

Canónico vigente y correcto: `actor_id` social, `context_actor_id` para contexto,
`*_actor_id` con prefijo de rol (holder/debtor/creditor/host/subscriber…), `user_id`
solo en `person_profiles.auth_user_id`, RPCs `verbo_objeto`. Desviaciones:

| Caso | Veredicto |
|---|---|
| `money_splits.transaction_id` vs `pool_basis_entries.money_transaction_id` | Inconsistente. No renombrar (iOS decodifica); documentar y unificar a `money_transaction_id` solo si algún día se reescribe la tabla. |
| `removed_at` / `revoked_at` / `cancelled_at` / `archived_at` / `left_at` | Taxonomía semántica intencional (soft-states por dominio). Se documenta como convención en TargetArchitecture §3. |
| `decision_votes.voted_at` sin `created_at` | `voted_at` ES el created_at semántico; se añade `updated_at` (upsert de re-voto) en `audit_3`. |
| `obligations.obligation_type` (taxonomía money) vs `obligation_kind` (naturaleza) | Confuso pero estable; CHECK solo permite types money-like. Documentado; renombrar a `money_subtype` requeriría compat-view → Fase 3 opcional. |
| `governance_actions.idempotency_key` + `client_id` | Coexisten: `client_id` = idempotencia del cliente; `idempotency_key` = dedupe interno del orquestador. Documentar en contrato. |
| `_r5a_b1_*`, `_r5b_*` helpers con nombre de release | Cosmético; renombrar no paga el riesgo. |

## 7. Money model — suficiencia

Cubre: gastos compartidos (record_expense + split_basis + weighted R9C), multas
(record_fine), aportaciones/pools (R8), deudas de juego, settlement con handshake 2 vías y
apelación, neteo vivo por novación (R2N), idempotencia (client_id + locks R9B), ledger
derivado y balances por vista invoker.

Faltantes (no bloqueantes hoy, diseñar antes de escalar):
1. **Multi-moneda**: columnas `currency` en todas las tablas ✓ pero solo MXN en uso, sin
   tabla de monedas ni FX, y el neteo asume moneda única por batch (correcto). Fase 3:
   `currency_catalog` + CHECK ISO-4217.
2. **Reversa/void**: `money_transactions.status='voided'` existe sin RPC expuesta ni
   entradas de ledger compensatorias. Fase 2: `void_transaction` que emita ledger inverso.
3. **Disputes de transacción**: existe `disputed` en settlement_items; no hay primitiva de
   disputa general. Futuro.
4. **Ledger doble-partida estricta**: `ledger_entries` es derivado por triggers, no fuente
   de verdad. Suficiente para MVP; si Ruul se vuelve custodial, migrar a asientos
   balanceados con invariante sum=0 por transacción (documentado en TargetArchitecture §6).

## 8. RPCs — superficie y deuda

- 473 funciones app en `public` (excl. `_smoke_*`; +~210 de extensiones). iOS consume 143;
  0 RPCs consumidas faltan en la DB.
- **Overloads dobles** (6): `context_available_actions`, `event_available_actions`,
  `resource_available_actions` (1-arg vs 2-arg con `p_actor_id`), `create_rule` (sin/with
  targeting), `record_game_result` (batch jsonb vs winner/loser), `resolve_reservation_conflict`
  (2-arg vs 4-arg con modelo). PostgREST los resuelve por nombre de parámetro, pero son
  trampa de mantenimiento → plan de drop en Fase 2 (verificando call-sites internos).
- **Candidatas a deprecación** (no consumidas por iOS; verificar callers internos antes de
  drop): `set_event_participant_plus_one`, `request_governed_action`, `governance_policy`,
  `update_governance_policy`*, `actor_inbox_items`, `decision_results`,
  `current_person_actor_id`, `*_available_actions` por entidad (suplantadas por
  descriptors), `evaluate_rules_for_event` (conservar: entrada manual del motor),
  `mark_notification_*`/`emit_notification` (conservar: R4D pendiente de frontend).
  *`update_governance_policy` probablemente la use el flujo de policies — confirmar.
- Helpers de autoridad (`has_actor_authority`, `actor_can`, `is_context_member`, …)
  ejecutables por authenticated: aceptable (solo lectura de verdad), documentado.

## 9. Performance

- **77 FKs sin índice** (advisor INFO). Hot paths corregidos en `audit_2` (~24 índices:
  activity por subject/resource/decision/obligation, money by from/to/event/obligation,
  splits por actor, obligations por 4 sources y (status,due_at) para el detector overdue,
  settlement por actor, votes por votante, documents/subscriptions por target, etc.).
  El resto son catálogos fríos — no indexar por ahora.
- **19 unused indexes** (advisor): datos aún chicos, stats no significativas. Re-evaluar
  con tráfico real (Fase 3); no dropear hoy.
- Exclusion constraint GiST en reservas + uniques parciales por client_id: bien diseñado.

## 10. Migrations — estado de la cadena

- 231 archivos en disco; el ledger live tiene además ~250 entradas pre-MVP2 (muertas, las
  tablas no existen) — cosmético, no tocar.
- **Drift live↔disco documentado** y parcheado vía shims (`r9_g`): `resource_conflicts`
  nació por MCP sin archivo; firmas evolucionadas. Riesgo recurrente del workflow
  MCP-first → mitigación: todo `apply_migration` debe aterrizar el mismo SQL en disco en
  el mismo PR (regla ya implícita; ahora explícita en MigrationPlan §0).
- Muchos micro-fixes (`*_fix_*`): aceptable como historia; para onboarding/CI lento,
  opción de baseline squash en Fase 3 (nunca destructiva: snapshot `pg_dump --schema-only`
  como `baseline_v1` + cadena nueva, manteniendo la actual archivada).

## 11. Riesgos priorizados

| # | Riesgo | Severidad | Mitigación |
|---|---|---|---|
| 1 | 30 funciones con search_path mutable (helpers/triggers, varios SECURITY INVOKER llamados desde DEFINER) | Media | `audit_1` las pinea; smoke `_smoke_mvp2_audit_baseline` lo vuelve invariante de CI |
| 2 | Activity catalog incompleto (20 tipos) — rompe la promesa de catálogo como contrato | Media | `audit_4` + assert en smoke |
| 3 | FKs sin índice en hot paths (activity, money, settlement) | Media (crece con datos) | `audit_2` |
| 4 | Tablas hijas mutables sin created_at/updated_at (event_participants, settlement_items, decision_options/votes, money_splits) | Media | `audit_3` (los valores backfilled = fecha de migración; documentado) |
| 5 | Drift MCP live↔disco | Media | Regla §0 del MigrationPlan + replay CI existente |
| 6 | Subtipos obligation/event creables como recursos | Baja hoy | Decisión producto Fase 2 |
| 7 | Leaked password protection off | Baja | Toggle en Dashboard |
| 8 | Overloads + RPCs twins sin registro de deprecación | Baja | Registro en MigrationPlan Fase 2 |
| 9 | Sin versionado de reglas | Baja | Fase 3 |
| 10 | Multi-moneda/reversas/disputas sin diseño | Baja hoy | Fase 3 (documentado en TargetArchitecture) |

## 12. Qué NO se encontró (y se buscó)

- Tablas huérfanas/obsoletas en live (0); tablas sin RLS (0); policies que filtren datos a
  anon (0); funciones SECURITY DEFINER sin search_path (0); políticas con `auth.uid()`
  sin wrap (0); enums zombie (0 enums); FKs rotas o sin `ON DELETE` coherente (spot-check
  limpio); vistas SECURITY DEFINER (la única vista es invoker).
