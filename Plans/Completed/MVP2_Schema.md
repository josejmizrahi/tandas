# MVP 2.0 — Ruul Schema Final: Plan de Implementación

**Status:** ✅ **SHIPPED 2026-06-02** — firmado por founder e implementado completo (ver §10 Journal).
**Fecha:** 2026-06-02.
**Schema fuente:** "Ruul MVP Schema Final" (founder, 2026-06-02) — 22 tablas + RPCs core.
**Decisiones ya firmadas:**

| Decisión | Firmado |
|---|---|
| Estrategia | **Reset en el proyecto actual** (`wyvkqveienzixinonhum`) — `drop schema public cascade` estilo canonical_reset |
| Datos | **Empezar vacío** — los 154 profiles / 78 groups / 127 resources actuales NO se migran |
| Modo | **Plan firmado primero** — este documento; implementación solo después de firma |

---

## 1. Doctrina (locked)

```
Actor        = quién existe
Contexto     = desde dónde opero
Resource     = qué cosa existe
Right        = qué derecho tiene un actor sobre un recurso
Membership   = quién participa en un contexto
Relationship = cómo se conectan actores/recursos
Event        = qué ocurre en el tiempo
Rule         = qué debe pasar automáticamente
Decision     = cómo se aprueba/cambia algo
Obligation   = qué debe quién
Money        = cómo se registra y liquida
Activity     = qué pasó
```

Cambio doctrinal clave vs R.0/R.1: **ya no hay tablas group-céntricas.** El "grupo" es
solo un actor `collective` y TODO (memberships, events, decisions, money, obligations)
referencia actores. Un "contexto" es cualquier actor desde el cual se opera (collective,
legal_entity, o la propia persona).

---

## 2. Inventario del schema (22 tablas, por dominio)

| Dominio | Tablas |
|---|---|
| Identidad | `actors`, `person_profiles` |
| Participación | `actor_memberships`, `roles`, `role_assignments`, `permission_catalog`, `role_permissions` |
| Recursos | `resources`, `resource_rights`, `actor_relationships`, `resource_type_catalog`*, `resource_capabilities_catalog`*, `resource_type_capabilities`* (*R.2M*) |
| Tiempo | `calendar_events`, `event_participants`, `resource_reservations`, `reservation_conflicts` |
| Reglas | `rules`, `rule_evaluations` |
| Governance | `decisions`, `decision_votes` |
| Dinero | `obligations`, `money_transactions`, `money_splits`, `settlement_batches`, `settlement_items` |
| Memoria | `documents`, `activity_events` |

El DDL canónico es el del documento del founder. Este plan agrega lo que el schema no
especifica: constraints, índices, RLS, semántica de RPCs, triggers y orden de ejecución.

---

## 3. Decisiones de diseño que requieren firma (D1–D12)

El schema del founder define las tablas. Estas 12 decisiones cubren lo que falta para que
sea implementable. Cada una tiene mi propuesta; tachar/corregir lo que no aplique.

### D1 — Mapping auth ↔ actor (la decisión más importante)

El schema desacopla `person_profiles.auth_user_id` de `actors.id` (en R.0/R.1 eran el
mismo UUID). Implicación: `auth.uid()` ya NO es el actor id.

**Propuesta:**
- Helper `current_actor_id() returns uuid`: `SELECT actor_id FROM person_profiles WHERE auth_user_id = auth.uid()` (STABLE, SECDEF). Toda RLS y todo RPC lo usan.
- Trigger AFTER INSERT en `auth.users` → crea `actors` (person) + `person_profiles` automáticamente.
- Índice único en `person_profiles.auth_user_id` (ya en el schema).

### D2 — Primitivas faltantes del MVP

El schema no incluye **invites/join codes** (cómo entra alguien a un contexto) ni
**notifications**. El MVP cubre "Comunidad" y "Cena semanal" — ambos necesitan onboarding.

**Propuesta:**
- AGREGAR tabla mínima `context_invites` (id, context_actor_id, code unique, created_by_actor_id, max_uses, used_count, expires_at, status, metadata) + RPCs `create_invite` / `join_by_invite_code`.
- DIFERIR notifications/push (sin tabla outbox, sin APNs) a post-MVP. La app consulta `activity_events` por pull.

### D3 — Whitelists (CHECK constraints)

Todos los campos text tipo enum llevan CHECK con whitelist explícita (actor_kind,
actor_subtype, right_kind, relationship_type, membership_status, event status/types,
reservation status, obligation_type, transaction_type, split_role, decision status, vote).
Los whitelists son los del documento del founder. `metadata jsonb` queda libre.

### D4 — Modelo RLS (context-scoped)

**Propuesta de patrón único para todas las tablas:**
- SELECT: miembro activo del `context_actor_id` (vía `actor_memberships` + `current_actor_id()`), o el actor referenciado directamente (holder/participant/debtor/creditor/owner).
- INSERT/UPDATE/DELETE: **solo vía RPCs SECURITY DEFINER** (cero write policies directas). PostgREST queda read-only para `authenticated`; `anon` sin acceso a nada.
- `permission_catalog`: read para authenticated (catálogo global).
- `activity_events`: append-only (trigger guard anti UPDATE/DELETE).

### D5 — Overlap de reservaciones

**Propuesta:** extensión `btree_gist` + EXCLUDE constraint sobre
`(resource_id WITH =, tstzrange(starts_at, ends_at) WITH &&)` solo para status
`approved/confirmed`. Las `requested` pueden traslaparse (el conflicto se detecta y se
registra en `reservation_conflicts` vía `detect_reservation_conflicts`).

### D6 — Rule engine MVP

**Propuesta:** evaluator pl/pgsql **síncrono** (sin cron, sin edge functions):
- `evaluate_rules_for_event(event_id)` se invoca desde los RPCs que cierran el ciclo (check_in, cancel_participation, record_expense).
- `condition_tree` jsonb: comparaciones simples (`{">": ["minutes_late", 15]}`).
- `consequences` jsonb: `[{type: "fine", amount: 100, currency: "MXN"}]` → crea `obligations`.
- Cada evaluación se registra en `rule_evaluations`.
- Host rotativo: regla con consequence `assign_next_host` que rota sobre miembros activos por `joined_at`.

### D7 — Settlement (split + liquidación optimizada)

**Propuesta:**
- `record_expense` crea `money_transactions` + `money_splits` (equal split por default, custom vía payload) + `obligations` netas por deudor.
- `generate_settlement_batch(context, currency)`: algoritmo greedy min-cashflow sobre el neto de `obligations` abiertas → `settlement_items` (mínimo número de transferencias).
- `mark_settlement_paid(item)`: crea `money_transactions` de settlement + cierra las obligations cubiertas.

### D8 — System actor + bootstrapping

**Propuesta:** seed de 1 actor `system` (`actor_kind='system'`, id fijo documentado) como
`created_by_actor_id` para acciones automáticas (rule engine, triggers). Las columnas
`created_by_actor_id NOT NULL` lo usan como fallback.

### D9 — Idempotencia

**Propuesta:** columna `client_id text` (nullable + unique parcial por contexto) en:
`calendar_events`, `resource_reservations`, `money_transactions`, `decisions`, `obligations`.
Los RPCs de creación aceptan `p_client_id` y devuelven el row existente si ya existe
(patrón de retry-safety para iOS).

### D10 — Edge functions actuales

Las 22 edge functions del repo están escritas contra el schema viejo y mueren con el reset.

**Propuesta:** mover `supabase/functions/*` (excepto `_shared` vacío) a
`supabase/functions/_archive_pre_mvp2/`. El MVP no usa edge functions (rule engine es SQL
síncrono, sin push). `send-otp`/`verify-otp`: verificar si iOS los usa para auth — si sí,
son las únicas dos que se conservan.

### D11 — Repo: archivo de la cadena vieja

**Propuesta:** mover las 326 migrations actuales a `supabase/migrations/_archive_pre_mvp2/`
y arrancar cadena nueva `mvp2_*`. CI (`supabase start`) replayará solo la cadena nueva
(~15 migrations limpias en lugar de 326).

### D12 — Migration history en la live DB

El reset (`drop schema public cascade`) no toca `supabase_migrations.schema_migrations`.
Las 331 entradas viejas quedan como histórico huérfano (no afectan operación ni CI).
**Propuesta:** dejarlas (auditoría de que existió la era anterior). Alternativa: limpiar la
tabla en la migration de reset.

---

## 4. Plan de slices

Cada slice = 1-2 migrations (vía MCP `apply_migration` + archivo en repo) + smoke + commit.
Orden estricto, sin saltar.

| Slice | Contenido | Depende de |
|---|---|---|
| **M.0 — Reset + Foundation** | `drop schema public cascade` + grants + extensiones (`pgcrypto`, `btree_gist`) + helper `touch_updated_at()` + archivo de migrations/functions viejas en repo (D10, D11) | firma |
| **M.1 — Identity** | `actors` + `person_profiles` + system actor seed (D8) + trigger auth.users → person actor (D1) + `current_actor_id()` + RLS | M.0 |
| **M.2 — Participación** | `actor_memberships` + `roles` + `role_assignments` + `permission_catalog` (seed de keys) + `role_permissions` + `has_actor_authority(context, member, permission)` + RLS | M.1 |
| **M.3 — Contexts & Invites** | `context_invites` (D2) + RPCs `create_context` (actor collective + founder membership + roles seed) / `create_invite` / `join_by_invite_code` + `context_candidates()` / `context_summary()` | M.2 |
| **M.4 — Resources & Rights** | `resources` + `resource_rights` + `actor_relationships` + trigger auto-OWN al canonical owner (heredado de R.1) + RPCs `create_resource` / `grant_right` / `revoke_right` / `list_context_resources` / `resource_detail` + RLS | M.2 |
| **M.5 — Calendar** | `calendar_events` + `event_participants` + RPCs `create_calendar_event` (con recurrencia) / `rsvp_event` / `check_in_participant` / `cancel_participation` + RLS | M.2 |
| **M.6 — Reservations** | `resource_reservations` + `reservation_conflicts` + EXCLUDE constraint (D5) + RPCs `request_resource_reservation` / `detect_reservation_conflicts` / `resolve_reservation_conflict` + RLS | M.4 |
| **M.7 — Rules** | `rules` + `rule_evaluations` + evaluator (D6) + RPCs `create_rule` / `evaluate_rules_for_event` + RLS | M.5 |
| **M.8 — Decisions** | `decisions` + `decision_votes` + RPCs `create_decision` / `vote_decision` / `execute_decision` (quorum mayoría simple MVP) + RLS | M.2 |
| **M.9 — Money** | `obligations` + `money_transactions` + `money_splits` + `settlement_batches` + `settlement_items` + RPCs `record_expense` / `record_fine` / `record_game_result` / `generate_settlement_batch` / `mark_settlement_paid` (D7) + RLS | M.5, M.7, M.8 |
| **M.10 — Memoria** | `documents` + `activity_events` (append-only) + emisión de activity desde todos los RPCs anteriores + RLS | M.1–M.9 |
| **M.11 — Contract smoke** | `_smoke_mvp2_contract()`: cena semanal end-to-end (crear contexto → invitar → evento recurrente → RSVP → check-in tarde → regla multa → obligation → expense → settlement) + casa reservable con conflicto + juego con deudas | todo |

**Estimación:** ~16-20 migrations, 11 smokes.

---

## 5. Trazabilidad: escenarios MVP → schema

| Escenario | Primitivas que lo cubren |
|---|---|
| Cena semanal recurrente | `calendar_events.recurrence_rule` + `event_participants` |
| Host rotativo | `rules` (consequence `assign_next_host`) + `calendar_events.host_actor_id` |
| Check-in / multas por tarde / por cancelar | `event_participants.checked_in_at` + `rules` → `obligations` (fine) |
| Juegos de mesa | `calendar_events` (game_night) + `record_game_result` → `obligations` (game_debt) |
| Split automático + settlement optimizado | `money_transactions` + `money_splits` + `settlement_batches/items` |
| Viajes con subgrupo | actor `collective` subtype `trip` + `actor_relationships.contains` |
| Casa familiar reservable + conflictos | `resources` + `resource_reservations` + `reservation_conflicts` |
| Negocio con amigo | actor `legal_entity` subtype `company` + `resource_rights` + `actor_relationships.shareholder_of` |
| Comunidad | actor `collective` subtype `community` + invites |
| Trust básico | actor `legal_entity` subtype `trust` + `trustee_of`/`beneficiary_of` |
| Documentos básicos | `documents` + Supabase Storage |

---

## 6. Qué rompe el reset (aceptado al firmar)

1. **iOS app actual: rota al 100%.** Todos los RPCs/tablas que consume desaparecen
   (`my_world_summary`, `create_group_resource`, `list_my_groups`, auth profiles, …).
   El contrato nuevo es el de §4 — iOS se reescribe contra él (fuera de scope backend).
2. **Edge functions: rotas al 100%** (archivadas, D10). Sin push notifications en MVP.
3. **Datos de producción: borrados** (firmado — empezar vacío). Los 154 usuarios tendrán
   que volver a registrarse (auth.users sobrevive el reset de `public`, pero sus profiles no;
   el trigger D1 recrea person actors en el siguiente login).
4. **R.0/R.1: superseded.** Los docs (`R1_Backend_Hardening_Wiring.md`, audits) pasan a
   `Plans/Archive/`. Lo que sobrevive conceptualmente: doctrina actor/right/relationship,
   patrón auto-OWN, patrón authority, patrón smoke.

> Nota: `auth.users` (154 usuarios reales con phone OTP) NO se borra — vive en schema `auth`.
> Solo se borra `public`. Quien vuelva a abrir la app (cuando el iOS nuevo exista) entra con
> su mismo teléfono y el trigger D1 le crea su person actor nuevo.

---

## 7. Riesgos

| # | Riesgo | Mitigación |
|---|---|---|
| R1 | Reset irreversible en proyecto con datos reales | Backup automático de Supabase (PITR) + dump manual de `public` antes del reset (lo tomo en M.0) |
| R2 | iOS queda muerto un periodo largo | Aceptado al firmar; el contrato nuevo queda documentado y con smokes desde M.3 para que iOS pueda desarrollar contra él |
| R3 | auth↔actor decoupling introduce bugs sutiles en RLS | `current_actor_id()` único punto de mapping + smoke específico de RLS en cada slice |
| R4 | Rule engine síncrono insuficiente para recurrencia (generar la próxima cena) | MVP: la siguiente instancia del evento se genera al cerrar la anterior (`close_event` → crea la siguiente); sin cron |
| R5 | CI verde dependiente del toolchain iOS roto (pre-existente) | Los checks de DB (`supabase start` + db tests) replayarán la cadena mvp2 limpia; los checks iOS siguen rotos hasta la sesión iOS |

---

## 8. Fuera de scope (firmado por founder)

Canonical registry · dedupe global · marketplace · compra/venta real · fideicomiso
compliant legal completo · ERP/Odoo sync · AI document extraction · search global avanzada ·
tokenización · push notifications (D2) · edge functions/cron (D6, D10).

---

## 9. DoD global del MVP backend

- [ ] Las 22 tablas (+`context_invites`) existen con CHECKs, índices y RLS
- [ ] Los ~25 RPCs core existen, son SECURITY DEFINER, gated por `has_actor_authority`, y `anon` no ejecuta ninguno
- [ ] `current_actor_id()` es el único punto de mapping auth↔actor
- [ ] Todos los escenarios MVP (§5) tienen smoke verde end-to-end
- [ ] Cadena de migrations replicable desde cero (`supabase start` verde en CI)
- [ ] `activity_events` registra todas las mutaciones
- [ ] Cero referencias al schema viejo en `supabase/` activo (todo archivado)
- [ ] Docs: contrato iOS (`Plans/Active/MVP2_iOS_Contract.md`) + journal por slice en este doc

---

## 10. Journal de implementación

### Journal — Implementación SHIPPED 2026-06-02

**Las 12 slices ejecutadas, todas con smoke verde en la live DB `wyvkqveienzixinonhum`:**

| Slice | Migration | Smoke |
|---|---|---|
| M.0 Reset + Foundation | `mvp2_000_reset_and_foundation` | (preflight inline) |
| M.1 Identity | `mvp2_001_identity` | 6 casos ✅ |
| M.2 Participación | `mvp2_002_participation` | 8 casos ✅ |
| M.3 Contexts & Invites (+activity_events) | `mvp2_003_contexts_and_invites` | 9 casos ✅ |
| M.4 Resources & Rights | `mvp2_004_resources_and_rights` | 8 casos ✅ |
| M.5 Calendar | `mvp2_005_calendar` | 7 casos ✅ |
| M.6 Reservations | `mvp2_006_reservations` | 6 casos ✅ |
| M.7 Decisions (reordenada antes de Rules) | `mvp2_007_decisions` | 6 casos ✅ |
| M.8 Rules + Obligations | `mvp2_008_rules_and_obligations` | 5 casos ✅ |
| M.9 Money | `mvp2_009_money` | 5 casos ✅ |
| M.10 Documents + Summary v2 + M.11 Contract | `mvp2_010_documents_summary_and_contract` | contrato e2e ✅ |
| M.11 Fix settlement temp table | `mvp2_011_fix_settlement_temp_table` | (re-run all ✅) |

**Estado final DB:** 26 tablas · ~35 RPCs · RLS deny-by-default en todo · anon sin acceso a nada.

**Desviaciones del plan (documentadas):**
1. `activity_events` se adelantó a M.3 (todos los RPCs emiten actividad desde el inicio). Sin FKs (append-only audit).
2. Decisions (M.7) se ejecutó antes que Rules (M.8) — obligations referencia decisions.
3. `obligations` se creó en M.8 junto con rules (es el target de las consecuencias).
4. M.10 y M.11 se combinaron en una migración.

**Bugs encontrados por smokes (y corregidos):**
1. `ALTER DEFAULT PRIVILEGES IN SCHEMA` no remueve el default global de EXECUTE a PUBLIC → fix global en M.2.
2. `generate_settlement_batch` temp table collision en llamadas múltiples por transacción → fix en M.11.

**Escenarios MVP verificados end-to-end (contract smoke):**
contexto → invite → join → regla multa → cena recurrente → check-in tarde → multa automática $100 → gasto $600 split 50/50 → cierre con host rotation → settlement neteado ($400) → pago → obligations cerradas → context_summary completo.

**Pendiente post-MVP backend:** iOS rewrite contra este contrato (`Plans/Active/MVP2_iOS_Contract.md` por escribir) · push notifications · cron para recurrencia sin cierre manual.

