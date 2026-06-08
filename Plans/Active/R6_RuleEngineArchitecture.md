# R.6.0 — Rule Engine 2.0 · Architecture (Track B documental)

**Fecha:** 2026-06-07
**Status:** 🟡 DRAFT — founder firma pendiente (Track B documental, no toca código)
**Companion:** `Plans/Active/PreR6_Roadmap.md` (slice 15) · `Plans/Active/R5V_UXDoctrine.md` (§0 anclas + §6 attention kinds extensibles)
**Antecedente:** `Plans/Archive/RuleEngineDoctrine.md` (MVP1 — `rule_evaluations`, atom guards, server-only). MVP2 hereda los 9 principios cardinales (server-only / deterministic / pure / idempotent / replayable / append-only audit / read-only projections / closed DSL / versioned snapshots).

---

## §0 — Por qué este doc existe ahora

Founder firmó 2026-06-07:

> *"Una vez que congeles Home, Context Detail, Resource Detail, ya tendrás definidos los lugares donde el Rule Engine va a manifestarse visualmente (attention, violations, automations, reminders, conflicts, obligations), y eso evita retrabajo cuando empiece R.6."*

R.6.0 NO implementa código. Congela **el vocabulario, los shapes y los puntos de aterrizaje** del engine para que R.5V.3–V.5 dejen los slots correctos plantados antes de que R.6 los rellene.

**Track B paralelo a Track A (R.5V.3 + V.4 + V.5).** R.6 backend implementación viene después.

---

## §1 — Modelo conceptual

Una **rule** en Ruul = `WHEN <event> AND <conditions> THEN <consequences>`.

```
Event           — qué pasó (catálogo cerrado, append-only en activity_events)
Conditions      — filtros sobre el event payload + state actual (DSL cerrado)
Consequences    — qué hacer (catálogo cerrado, idempotente)
Priority        — orden de evaluación dentro del mismo event (critical/high/normal/low)
Scope           — dónde aplica (global / context / context_subtree / resource / resource_subtype / capability)
Idempotency_key — sha1(rule_version_id || event_id || target_id || consequence_index)
```

**Reglas son objetos versionados** (`rules` + `rule_versions`). Toda evaluación deja una fila en `rule_evaluations` con `idempotency_key` UNIQUE → segundo run sobre el mismo evento es no-op.

---

## §2 — Catálogo de Eventos (founder spec 2026-06-07)

Source de truth: `activity_events.event_type` ya canónico hoy. R.6 NO inventa eventos nuevos — **suscribe a los existentes** y los que falten se agregan al catalog primero (no en R.6).

### 2.1 Eventos disponibles HOY (subscribibles desde el primer día de R.6)

| event_type | Emitido por | Payload mínimo |
|---|---|---|
| `resource.created` | `create_resource` RPC | `resource_id`, `context_actor_id`, `subtype_key`, `class_key` |
| `resource.updated` | `update_resource` RPC | `resource_id`, `changed_fields[]` |
| `resource.archived` | `archive_resource` RPC | `resource_id` |
| `resource.right_granted` | `grant_right` RPC | `resource_id`, `actor_id`, `right_key` |
| `resource.right_revoked` | `revoke_right` RPC | `resource_id`, `actor_id`, `right_key` |
| `reservation.requested` | `request_resource_reservation` | `reservation_id`, `resource_id`, `requester_actor_id`, `starts_at`, `ends_at` |
| `reservation.approved` | `approve_reservation` | `reservation_id` |
| `reservation.confirmed` | `confirm_reservation` | `reservation_id` |
| `reservation.cancelled` | `cancel_reservation` | `reservation_id`, `reason` |
| `obligation.created` | `record_fine` / `record_expense` (creates obligation split) | `obligation_id`, `from_actor_id`, `to_actor_id`, `amount`, `currency`, `due_at` |
| `obligation.paid` | `mark_settlement_paid` (cubre via batch) | `obligation_id`, `paid_at` |
| `decision.created` | `create_decision` | `decision_id`, `context_actor_id`, `kind` |
| `decision.vote_cast` | `vote_decision` | `decision_id`, `voter_actor_id`, `vote` |
| `decision.closed` | `close_decision` | `decision_id`, `outcome` |
| `decision.executed` | `execute_decision` | `decision_id`, `result` |
| `document.created` | `register_document` (R.5X.fix.C canonical) | `document_id`, `resource_id`, `document_type` |
| `event.created` | `create_calendar_event` | `event_id`, `context_actor_id` |
| `event.rsvp_changed` | `rsvp_event` | `event_id`, `actor_id`, `status` |
| `event.checked_in` | `check_in_participant` | `event_id`, `actor_id` |
| `event.cancelled` | `cancel_participation` / `close_event` | `event_id` |
| `member.joined` | `join_by_invite_code` / `accept_invitation` | `actor_id`, `context_actor_id`, `role` |
| `member.role_changed` | `assign_role` | `actor_id`, `context_actor_id`, `role` |
| `member.left` | `leave_context` / `remove_member` | `actor_id`, `context_actor_id` |
| `conflict.detected` | R.5B.1 / R.5B.2 trigger | `conflict_id`, `resource_id`, `conflict_type`, `severity` |
| `conflict.resolved` | `resolve_resource_conflict` | `conflict_id`, `resolution_kind` |

### 2.2 Eventos virtuales (cron-tick, no físicos)

Estos NO son rows en `activity_events` — son condiciones que el cron evalúa cada N minutos.

| virtual_event | Trigger del cron | Uso típico |
|---|---|---|
| `obligation.overdue` | `due_at < now() AND status='pending'` | Recordatorio + escalación |
| `document.expiring` | `metadata->>'expires_at' < now() + interval '30 days'` | Renovación |
| `reservation.starting_soon` | `starts_at < now() + interval '24 hours'` | Notificación pre-uso |
| `maintenance.due` | resource capability `maintainable` + last_maintenance_at | Mantenimiento preventivo |
| `right.expiring` | `valid_until < now() + interval '7 days'` | Renovación de USE/MANAGE |

**Doctrina cron-tick:** el cron genera un `activity_event` sintético del tipo `*.overdue` / `*.expiring` con `source='rule_engine'` para que pueda ser auditado igual que un event real.

### 2.3 Eventos futuros (post-MVP, sólo placeholder)

`policy.violated`, `proposal.created`, `audit.flagged` — fuera de scope MVP. No bloquea R.6.

---

## §3 — Catálogo de Condiciones (closed DSL — founder spec)

Una condición es `{ field: <variable>, op: <operator>, value: <literal_or_ref> }`. **Cero código arbitrario.** Builder UX genera shapes pre-validados.

### 3.1 Variables (lado izquierdo)

| Variable | Tipo | Ejemplo |
|---|---|---|
| `resource.subtype` | text | `primary_residence` (founder priority — depende de Subtype Picker shipped ✅) |
| `resource.class` | text | `real_estate` |
| `resource.capability` | text | `reservable`, `maintainable` |
| `resource.status` | enum | `active`, `archived` |
| `resource.estimated_value` | numeric | 1500000 |
| `resource.canonical_owner_actor_id` | uuid | `<actor>` |
| `membership.role` | enum | `member`, `admin`, `founder` |
| `membership.joined_at` | timestamptz | — |
| `event.type` | text | `family_dinner` |
| `event.participants_count` | int | — |
| `decision.kind` | text | `resolve_reservation_conflict` |
| `decision.outcome` | enum | `approved`, `rejected` |
| `obligation.amount` | numeric | — |
| `obligation.currency` | text | `MXN` |
| `obligation.days_until_due` | int (computed) | -3 (overdue) |
| `obligation.days_overdue` | int (computed) | 7 |
| `conflict.severity` | enum | `critical`, `warning`, `info` |
| `conflict.count_open` | int (projection) | — |
| `now` | timestamptz (snapshotted) | — |
| `context.member_count` | int (projection) | — |
| `context.subtype` | text | `family`, `business` |

### 3.2 Operadores

`==`, `!=`, `<`, `<=`, `>`, `>=`, `in`, `not_in`, `between`, `contains`, `is_null`, `is_not_null`.

### 3.3 Combinadores

`all_of: [cond, cond, ...]` (AND), `any_of: [cond, cond, ...]` (OR). Sin negación arbitraria — usar operadores invertidos.

### 3.4 Reglas del DSL

- No `Date.now()` — siempre `now` (snapshot del cron loop).
- No referencias a otras rules (anti-recursión).
- No HTTP / external calls.
- Las projections son read-only — `conflict.count_open` lee de `resource_conflicts` view sin mutar.
- Builder UX rechaza shapes con campos no enumerados.

---

## §4 — Catálogo de Consecuencias (founder spec)

Cada consequence: `{ type, params, target_resolution }`. Idempotente por construcción — `INSERT INTO rule_evaluations` antes de ejecutar.

| Consequence type | Qué hace | Target | RPC canónico |
|---|---|---|---|
| `emit_attention` | Crea row en `attention_inbox` (kind: `rule_violation` / `maintenance_due` / `document_expiring` / `policy_violation` / custom) | actor(es) específico(s) | `_r6_emit_attention` (nueva) |
| `emit_notification` | Push notification + email opcional | actor | `_r6_emit_notification` (R.7) |
| `create_obligation` | INSERT obligation (multa, recordatorio de pago) | from_actor → to_actor | `record_fine` |
| `open_decision` | INSERT decision con template_key | context_actor_id | `create_decision` |
| `flag_conflict` | INSERT row en `resource_conflicts` | resource_id | `_r5b_flag_conflict` (existente) |
| `resource_action` | UPDATE controlled (e.g. archive, lock_bookings) — via RPC canónico, NUNCA UPDATE directo | resource_id | `archive_resource` / `update_resource` |
| `membership_action` | UPDATE membership (suspender, escalar role) — via RPC | actor_id | `assign_role` |
| `schedule_followup` | Crea cron-tick virtual event futuro | — | `_r6_schedule_followup` |

**Anti-patterns prohibidos** (heredados de RuleEngineDoctrine §11):

- ❌ UPDATE directo a `resources` / `obligations` / `decisions` desde código del engine.
- ❌ Consequence que llame `fetch(externalUrl)`.
- ❌ Consequence sin INSERT en `rule_evaluations` primero.
- ❌ Consequence que mute `rule_evaluations` (audit corruption).
- ❌ Recursión: consequence que cree otra rule.

---

## §5 — Prioridades (founder spec §0.5 espejo)

| Priority | Tint UX (R.5V.1) | Cuándo usar | Comportamiento engine |
|---|---|---|---|
| `critical` | `Theme.Tint.critical` (red) | Violación grave, escalación inmediata, conflicto crítico | Procesar primero · push notification · attention top-pinned |
| `high` | `Theme.Tint.warning` (orange) | Vencimiento próximo, conflicto warning, mantenimiento pendiente | Procesar segundo · push si user opt-in · attention destacada |
| `normal` | `Theme.Tint.info` (blue) | Recordatorio, info, sugerencia | Procesar tercero · sólo attention card |
| `low` | `Theme.Text.tertiary` (gray) | Informativo, no-blocking, métrica | Procesar último · sólo en historial |

**Engine sort:** dentro del mismo event, rules se ordenan por `priority DESC, scope_specificity DESC, rule_id ASC`. Determinismo total.

---

## §6 — Idempotencia (founder spec — non-negotiable)

**Patrón heredado de MVP1** (RuleEngineDoctrine §4 + `rule_evaluations` table mig 00181):

```
idempotency_key = sha1(
    rule_version_id || '|' ||
    trigger_event_id || '|' ||
    target_id || '|' ||
    consequence_index
)
```

**Protocolo de evaluación:**

1. Cron / RPC procesa `activity_event`.
2. Engine determina rules aplicables (scope + event_type match).
3. Para cada rule, evalúa conditions sobre el payload.
4. Para cada consequence `i` de cada rule matched:
   - Compute `idempotency_key`.
   - `INSERT INTO rule_evaluations (...) ON CONFLICT (idempotency_key) DO NOTHING` (UNIQUE constraint).
   - Si rowsAffected = 0 → skip (ya ejecutado en run previo).
   - Si rowsAffected = 1 → execute consequence sink.
5. Marca `activity_events.rule_processed_at = now()`.

**Garantías:**

- Retry del mismo event NUNCA dispara consequence 2x.
- Replay de events viejos contra rule_versions actuales reproduce el mismo resultado.
- Cron crash mid-batch → próximo tick reprocesa events sin `rule_processed_at`, idempotency_key short-circuits dupes.

---

## §7 — Scope + Precedencia

Una rule aplica a un scope. Precedencia (más específico gana cuando dos rules conflictan en el mismo trigger):

```
resource > resource_subtype > resource_class > capability > context > context_subtree > global
```

Ejemplo: rule "casa Mizrahi requiere 7 días de antelación para reservar" (scope=`resource:casa_valle`) gana sobre rule global "reservaciones requieren 3 días" (scope=`global`).

**Conflict types:**

- **Precedencia natural** — mismo trigger en scopes distintos → engine elige más específico. No user-visible.
- **Conflict real** — dos rules en MISMO scope con MISMO trigger y consequences contradictorias → bloqueado a tiempo de publish (validación en `publish_rule_version` RPC).

---

## §8 — Cómo se manifiesta visualmente (puntos de aterrizaje V.3–V.5)

**Esta sección es la razón por la que R.6.0 sale ANTES de V.3.** Cada migración Apple-native debe dejar el slot correcto para R.6.

### 8.1 HomeView (V.3)

- `attention_inbox` ya consume kinds `rule_violation`, `maintenance_due`, `document_expiring` (R.5Y.A2 extensible). V.3 NO toca nada — sólo asegurar que `RuulAttentionCard` los renderice con priority correcto.
- **Slot R.6:** ninguno nuevo. R.6 emite attention → ya cae en la card existente.

### 8.2 ContextDetailViewV2 Overview (V.4)

- Sección "Reglas activas" (futuro R.6): chip count + tap → push `RulesListView` filtrado por contexto. V.4 deja el slot **vacío y oculto** (`rules.count == 0`).
- Conflicts widget (R.5B ya shipped) absorbe `flag_conflict` consequences sin cambios.
- **Slot R.6:** Section "Reglas" entre Money y More (placeholder oculto si no hay rules).

### 8.3 ResourceDetailViewV2 (V.5)

- Capability chips: V.5 los muestra con explanations (P3 shipped). R.6 añadirá `rules_count` por capability (futuro).
- Widget "Próximas obligaciones" / "Mantenimiento próximo": R.6 los puebla via `emit_attention` → ya capturado en attention.
- Sección "Reglas que aplican" (futuro R.6): list de rules at any scope que afecte ESTE resource. V.5 deja **slot oculto** hasta R.6.
- **Slot R.6:** Section "Reglas" después de Conflicts, antes de Actividad.

### 8.4 RulesListView + RuleDetailView (existentes — MVP1 leftover)

- Ya existen en `Features/Rules/`. R.6 los usará como entry point del builder UX.
- V.3–V.5 NO los tocan. R.6 los refactor.

---

## §9 — Implementación R.6 (slices propuestos, post Track A)

**NO comprometidos — sólo orden tentativo:**

| Slice | Scope | Bloquea |
|---|---|---|
| R.6.A | Schema: `rules` v2 + `rule_versions` v2 + `rule_evaluations` (reutiliza mig MVP1) + RLS | R.6.B |
| R.6.B | DSL parser + validador (closed grammar) + tests | R.6.C |
| R.6.C | Engine evaluator core (event subscribe + condition eval + consequence dispatch) + idempotency | R.6.D |
| R.6.D | Consequence sinks: `emit_attention` (primero — cierra loop con Attention Center) | R.6.E |
| R.6.E | Builder UX iOS (intent → trigger → conditions → consequences → publish) | R.6.F |
| R.6.F | Resto de sinks: `create_obligation`, `open_decision`, `flag_conflict`, `resource_action`, `membership_action`, `schedule_followup` | R.6.G |
| R.6.G | Cron-tick virtual events (`obligation.overdue`, `document.expiring`, etc.) | R.6.H |
| R.6.H | Smoke device + founder firma | CLOSE |

---

## §10 — Cierre R.6 (founder firma) — 8 puntos heredados de PreR6_Roadmap §15

1. ✅ Schema applied + RLS verificado
2. ✅ DSL parser cierra (closed grammar, tests pasan)
3. ✅ Engine evaluator idempotente (replay test verde)
4. ✅ `emit_attention` sink shipped — cierra loop con AttentionDispatcher (R.5Y.A2)
5. ✅ Builder UX iOS shipped — founder puede crear una rule sin escribir SQL
6. ✅ Al menos 3 rules ejemplo seedeadas (founder firma cuáles)
7. ✅ Smoke device: emit attention al violar rule → tap → destino correcto
8. ✅ Founder cita: "Ruul ya tiene reglas que funcionan, no es teatro"

---

## §11 — Founder firmas pendientes

| Q | Decisión esperada |
|---|---|
| 1. ¿Catálogo de eventos §2.1 cubre los flows que tienes en mente? | ⏳ |
| 2. ¿Variables del DSL §3.1 cubren los casos comunes (subtype/class/capability/role/days_until_due/conflict_count)? | ⏳ |
| 3. ¿Las 8 consequence types §4 cubren los outputs que esperas? | ⏳ |
| 4. ¿Slot "Reglas" en ContextDetail + ResourceDetail está OK como oculto en V.4/V.5? | ⏳ |
| 5. ¿Orden de slices §9 (A→H) es el correcto? | ⏳ |
| 6. ¿`emit_attention` primero antes que otros sinks (cierra loop con R.5Y) es la prioridad correcta? | ⏳ |

---

## §12 — Status del doc

- **2026-06-07 (draft):** Track B paralelo a Track A (R.5V.3+V.4+V.5).
- **2026-06-07 (post-audit):** §13 agregado — backend audit reveló que **mucho ya está shipped en MVP2**. Plan R.6.A reframed (no se construye desde cero, se extiende).
- **Founder firma:** ⏳ pendiente.
- **Bloquea:** R.6.A migration (no se aplica hasta Q1-6 firmados + Q7 nueva).
- **No bloquea:** R.5V.3+V.4+V.5 — Track A puede avanzar (ya shipped 2026-06-07).

---

## §13 — Estado actual MVP2 (audit 2026-06-07 post-V.5)

**Hallazgo:** el rule engine v1 ya existe parcialmente en producción. R.6 NO se construye desde cero — se EXTIENDE.

### 13.1 Lo que YA existe en MVP2

| Componente | Estado | Notas |
|---|---|---|
| `rules` table | ✅ shipped | `context_actor_id`, `title`, `body`, `rule_type`, `severity`, `status`, `trigger_event_type`, `condition_tree jsonb`, `consequences jsonb`, `target_scope`, `target_filter jsonb`, `created_by_actor_id`, `archived_at` |
| `rule_evaluations` table | ✅ shipped | `rule_id`, `context_actor_id`, `triggering_event_type/object_type/object_id`, `outcome`, `consequences_emitted jsonb`, `evaluated_at`, `metadata jsonb`. **Falta `idempotency_key`.** |
| `create_rule` / `update_rule` RPCs | ✅ shipped | Funcionan |
| `evaluate_rules_for_event(context_actor_id, trigger_event_type, subject_actor_id, payload, source_event_id)` | ✅ shipped | Selecciona rules activas por context + trigger + target_filter; evalúa `_eval_condition(condition_tree, payload)`; INSERT en `rule_evaluations`; ejecuta sinks. |
| `_rule_target_matches(target_filter, payload)` helper | ✅ shipped | Maneja scope precedence |
| `_eval_condition(condition_tree, payload)` helper | ✅ shipped | DSL condition evaluator |
| Sink: `fine` + `create_obligation` | ✅ shipped | Crea row en `obligations` + emite `obligation.created` / `fine.created` activity |
| Activity emit: `rule.evaluated` | ✅ shipped | Cada evaluación lo emite |
| RulesListView + RuleDetailView + CreateRuleWizard + EditRuleView iOS | ✅ shipped | MVP2 ya tiene builder UX (calidad por validar) |
| Trigger automático: check-in + cancel calendar events | ✅ shipped | `check_in_participant` / `cancel_participation` invocan `evaluate_rules_for_event` |
| Smokes existentes | ✅ shipped | `_smoke_mvp2_r2e_rules_dod`, `_smoke_mvp2_r2s_rule_targeting`, `_smoke_mvp2_m8_rules` |

### 13.2 Lo que FALTA para R.6 doctrine completa

| Gap | Severidad | Mig propuesta |
|---|---|---|
| 1. `idempotency_key text UNIQUE` en `rule_evaluations` | **Crítico** | R.6.A |
| 2. Sink `emit_attention` (cierra loop con R.5Y AttentionDispatcher) | **Crítico** — desbloquea el use case más visible | R.6.A |
| 3. Sinks adicionales: `flag_conflict`, `open_decision`, `resource_action`, `membership_action`, `emit_notification`, `schedule_followup` | Medio | R.6.B (incremental) |
| 4. Triggers automáticos para event types nuevos (resource.created, obligation.created, member.joined, document.created, etc.) | Medio — sin ellos las rules sólo disparan en eventos calendario | R.6.B/C |
| 5. Cron-tick virtual events (`obligation.overdue`, `document.expiring`, `reservation.starting_soon`, `maintenance.due`, `right.expiring`) | Medio | R.6.C |
| 6. DSL closed-grammar validador (§3 R.6.0 doc — operadores/variables tipados) | Bajo — el actual acepta jsonb libre | R.6.D |
| 7. Builder UX iOS audit + refactor Apple-native (`CreateRuleWizard` + `RuleDetailView` con List+Section §V.5 pattern) | Bajo | R.6.E |
| 8. Seeds: 3 rules ejemplo founder firma | Bajo | R.6.F |

### 13.3 Plan R.6 reframed (slices)

| Slice | Scope | Tamaño |
|---|---|---|
| **R.6.A** | **Mig**: `rule_evaluations.idempotency_key` + UNIQUE + helper `_r6_compute_idempotency_key`. Refactor `evaluate_rules_for_event` para usar idempotency. **Sink nuevo**: `emit_attention` (consequence type=`emit_attention` → crea row en `attention_inbox` consumida por R.5Y.A2 dispatcher → kind `rule_violation` / custom). Smoke nuevo. | Pequeño (~150 LOC SQL) |
| **R.6.B** | **Mig**: Triggers automáticos en RPCs faltantes (resource.created, obligation.created, member.joined, document.created, decision.executed, etc) — cada uno invoca `evaluate_rules_for_event`. Smoke por trigger. | Medio |
| **R.6.C** | **Mig**: Cron-tick edge function `r6-virtual-events-tick.ts` (Supabase edge) que emite virtual events cada N min: `obligation.overdue`, `document.expiring`, `reservation.starting_soon`, `maintenance.due`, `right.expiring`. Schedule via pg_cron o Supabase scheduled functions. | Medio |
| **R.6.D** | **Mig opcional**: DSL closed-grammar validator en `create_rule` / `update_rule` (rechaza shapes no enumerados). Builder UX ya constrains; backend lock. | Pequeño |
| **R.6.E** | **iOS**: RulesListView + CreateRuleWizard + RuleDetailView refactor Apple-native (List+Section §V.5 pattern). Wire emit_attention preview. | Medio (paralelizable con R.6.A/B/C) |
| **R.6.F** | **Seeds**: 3 rules ejemplo seedeadas (founder firma cuáles — sugerencia: "casa Mizrahi requiere 7 días antelación", "obligación pagada antes de vencer = thumbs up", "reservación cancelada con menos de 24h emite multa"). | Pequeño |
| **R.6.G** | **Smoke device**: founder valida 3 rules end-to-end (crear → trigger → emit_attention → tap → destino). | Founder |
| **R.6.H** | **CLOSE** + founder firma "Ruul ya tiene reglas que funcionan, no es teatro". | — |

### 13.4 Quick win priority orden firmado

**R.6.A es el más alto valor** porque cierra loop con R.5Y.A2 (Attention Center ya shipped + visible). Con sólo R.6.A:
- Cualquier rule emite `emit_attention` consequence → row en `attention_inbox` → R.5Y.A2 dispatcher lo lleva al destino correcto
- Builder UX iOS existente puede usarse para crear rules con consequence type=`emit_attention`
- Idempotency cierra el bug F5 heredado de MVP1 (consequences duplicadas en retry)
- Cero break: sinks existentes (`fine`/`create_obligation`) siguen funcionando

R.6.B y R.6.C son iterables después de que founder pruebe R.6.A.

### 13.5 Q7 nueva — founder firma

| Q | Decisión esperada |
|---|---|
| 7. ¿R.6.A reframed (idempotency_key + emit_attention sink en una mig) es el quick win correcto antes de R.6.B/C/D/E? | ⏳ — quiebra la promesa de "no aplicar mig hasta Q1-6 firmadas"; pide que founder firme orden ahora |

**Sugerencia agente:** firmar Q7 y aplicar R.6.A inmediatamente porque cierra el loop más visible con cero break. Q1-6 pueden firmarse en paralelo (no bloquean R.6.A).
