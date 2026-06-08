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

- **2026-06-07:** DRAFT inicial. Track B paralelo a Track A (R.5V.3+V.4+V.5).
- **Founder firma:** ⏳ pendiente.
- **Bloquea:** R.6.A schema migration (no se aplica hasta Q1-6 firmados).
- **No bloquea:** R.5V.3+V.4+V.5 — Track A puede avanzar sabiendo que los slots de R.6 están reservados en §8.
