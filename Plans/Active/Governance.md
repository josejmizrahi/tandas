# Ruul — Governance & Rule Builder (Especificación canónica)

**Status:** Draft 3 — 2026-05-14. Hybrid-doctrine pass (preserva runtime-declarative `rule_shapes` table + agrega capa de Templates curados arriba). Founder spec.
**Companion of:** `Vision.md` (estrategia), `Constitution.md` (artículos), `HierarchyReference.md` (capa 8).
**Scope:** Diseño completo del sistema de governance, gramática de reglas, rule shapes, engine, UI/UX, datos y roadmap.
**Tono:** Opinionado y crítico. Marca explícita de "Beta 1", "Post-Beta", "No construir".

> **Epígrafe (la frase que ata todo):**
> **User-configurable parameters, not user-programmable logic.**
> El usuario nunca escribe lógica. Sólo elige Legos pre-validados y rellena huecos.

---

## 0. Lectura ejecutiva en 60 segundos

1. **Governance** es la capa 8 del Hierarchy: el conjunto de **reglas + políticas + permisos + workflows** que dicen *qué está permitido, requerido o prohibido* sobre **capabilities** de **resources** dentro de un **group**.
2. **Una regla nunca muta estado.** Una regla **decide** un veredicto y **emite atoms** o **arranca workflows**. El engine es server-only, determinístico, idempotente, versionado, replayable.
3. **El usuario nunca escribe código.** El usuario elige un **Rule Template** curado (receta pre-compuesta de shape pieces), llena 2–4 parámetros visuales, ve el preview en lenguaje humano, publica. Per-piece builder existe pero queda oculto/admin-only en Beta 1.
4. **5 niveles de precedencia, "más específico gana":** `occurrence > resource > series > group > global_default`.
5. **AI propone, nunca publica.** AI genera draft de rule shape + parámetros; humano confirma; engine ejecuta.
6. **Beta 1 (anclado al catálogo real de `public.rule_shapes`):** 5 rule templates curados, todos *attendance + fine* variants — compone solo shape pieces existentes (zero engine code nuevo): `late_arrival_fine`, `no_show_fine`, `same_day_cancel_fine`, `no_rsvp_fine`, `host_no_menu_fine`. UI = Template Gallery + Param Form (sin per-piece visible), sin simulación, sin AI, sin votación de reglas. Admin publica. Templates con `assignParticipantRole`/`approval`/`amountAbove` (first_n_starters, rotating_host, expense_requires_approval) → Post-Beta, requieren evaluadores nuevos en `ruleEngine.ts`.

---

## 0.5 Doctrina corregida 2026-05-14 (Híbrido — preserva 2026-05-10)

Draft 1-2 dijeron *"shape registry is executable code, not user data"*. **Eso era incorrecto** — colisiona con el founder principle 2026-05-10 declarado en `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/RuleShape.swift:6-11` y con `public.rule_shapes` + `list_rule_shapes` RPC + `LiveRuleShapeRepository` ya consolidados pre-Beta. **Draft 3 reinstala el modelo híbrido correcto.**

### 0.5.1 Modelo conceptual corregido

```
┌─────────────────────────────────────────────────────────────────┐
│  SHAPE PIECES (runtime catalog — public.rule_shapes)            │
│  Atomic Legos: 1 trigger | 1 condition | 1 consequence each     │
│  Loaded at boot via list_rule_shapes RPC                        │
│  Executable semantics owned by server-side TS code              │
│  Adding a piece = INSERT + new evaluator (no client release)    │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ composed by
                              │
┌─────────────────────────────────────────────────────────────────┐
│  TEMPLATES (curated UX recipes — code-canonical, table mirror)  │
│  Each template = pre-composed recipe of pieces + scope + params │
│  Beta 1 ships 5 templates; per-piece builder hidden Post-Beta   │
│  User chooses template → fills params → preview → publish       │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ instantiated as
                              │
┌─────────────────────────────────────────────────────────────────┐
│  RULES (instancia publicada — public.rules)                     │
│  Existing table preserved (trigger/conditions/consequences jsonb)│
│  Carries slug + scope columns (resource_id/series_id/…)         │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ snapshot of
                              │
┌─────────────────────────────────────────────────────────────────┐
│  RULE_VERSIONS (compiled snapshots — append-only, NEW)          │
│  Frozen `compiled` jsonb per publish; replay/audit reproducible │
└─────────────────────────────────────────────────────────────────┘
```

### 0.5.2 Traducción de vocabulario

| Vocabulario Draft 2 (incorrecto) | Vocabulario Draft 3 (correcto) |
|---|---|
| "5 rule shapes Beta 1" | **"5 rule templates Beta 1"** (recetas curadas) |
| "Shape registry is executable code" | "Executable semantics owned by server-side code; runtime catalog (`rule_shapes`) exposes building blocks; templates are curated recipes" |
| "Shape = bundled Lego (trigger+conditions+consequences)" | "**Shape = pieza atómica** (1 trigger \| 1 condition \| 1 consequence). **Template = receta** que pre-compone piezas." |
| "Shape contract" (incluía conditions+consequences) | "**Template contract** declara composición de piezas; **Shape contract** preserva su forma actual en `rule_shapes`" |
| "Custom Lego Builder = Post-Beta" | "Per-piece builder ya existe (`EditRulesView`) pero queda **oculto / admin-only en Beta 1**; UI pública es Template-driven" |

### 0.5.3 Regla doctrinal corregida (reemplaza principio 21 de §21.2)

> **Rule shapes are runtime-declarative building blocks. Rule templates are curated product-level recipes. The engine only executes compiled rule versions. The client may render from runtime shape/template catalogs, but the server validates and compiles everything before publish.**

### 0.5.4 Implicaciones operativas

- **NO se dropea ni modifica** `public.rule_shapes`, `list_rule_shapes`, `LiveRuleShapeRepository`, `RuleShape.swift`.
- **SE AGREGA** `public.rule_templates` (mirror; canonical en TS) + `list_rule_templates` RPC + `RuleTemplate.swift` + `LiveRuleTemplateRepository`.
- **SE AGREGA** `rule_versions` append-only snapshot por cada publish.
- **SE AGREGA** `rule_evaluations`, `rule_conflicts`, `member_capability_overrides` (no existen aún).
- **El UI per-piece existente** (`EditRulesView`, `EditRuleSheet`) queda visible solo en modo admin/dev. UI pública Beta 1 = Template Gallery → Param Form → Preview → Publish.

> **El resto del documento debe leerse aplicando la traducción de §0.5.2**: donde dice "shape" en sentido de Lego bundled, sustituye por "template". Las menciones a `rule_shapes` table (piezas atómicas) se conservan tal cual.

---

## 1. Filosofía de governance en Ruul

### 1.1 Qué es governance (y qué NO es)

Governance en Ruul es la **constitución viva del grupo**. Define cómo se decide, quién decide, qué cuesta romper acuerdos, y qué evidencia queda. Vive en la capa 8 del Hierarchy y controla **behavior + permisos + workflows + obligations** sobre **resources, capabilities, relations y workflows**.

**Lo que governance SÍ controla:**
- **Permisos** (capa 2/3): quién puede ejercer una capability.
- **Reglas de comportamiento** (capa 5/9): qué pasa cuando un trigger ocurre, sobre qué resource, con qué consecuencia.
- **Políticas estructurales** (capa 8): cómo se cambian las reglas (meta-rules).
- **Workflows** (capa 9): procesos abiertos (voto, apelación, aprobación).
- **Obligations** (proyecciones derivadas): qué debe un actor.

**Lo que governance NO controla (límite duro):**
- Projections (son derivadas; no son configurables).
- Notification internals (delivery queue, retries, APNs tokens).
- Cron/queue infrastructure.
- Cachés, sync, system config.
- Storage backends, índices, RLS implementations.

> **Regla constitucional:** *Governance controla behavior visible al usuario; no controla infraestructura interna.* Si alguien quiere "hacer una rule que limpie el cache de notificaciones", la respuesta es **no** — eso no es governance.

### 1.2 Vocabulario técnico (interno, NO se expone al usuario)

| Concepto | Definición | Mutabilidad | Vive en |
|---|---|---|---|
| **Capability** | Comportamiento *posible* sobre un resource (RSVP, booking, ledger…). | Mutable | `resource_capabilities` |
| **Permission** | Quién puede ejercer una capability. | Mutable | `group_policies`, `roles` (jsonb) |
| **Rule** | Constraint condicional: `WHEN X / IF Y / THEN Z`. | Versionada | `rules` + `rule_versions` |
| **Policy** | Meta-rule estructural: "cambiar una rule requiere voto". | Versionada | `group_policies` (jsonb) |
| **Workflow** | Proceso abierto que necesita resolución (voto, aprobación, apelación). | Mutable hasta cierre | `votes`, `pending_changes`, `fine_review_periods` |
| **Atom** | Acto ocurrido, append-only, inmutable. | Inmutable | `system_events`, `ledger_entries`, `rsvp_actions`, `check_in_actions`, `vote_casts` |
| **Projection** | Estado derivado, recomputable desde atoms. | Rebuild | `*_view` |
| **Obligation** | Proyección de "este miembro debe X" (multa pendiente, RSVP requerido). | Rebuild | derivada |
| **Relation override** | Excepción puntual al grafo de membresía (miembro excluido de rotativa, guest con permiso especial). | Versionada | `member_capability_overrides` (futuro) |

> **Distinción cardinal:** *capabilities habilitan posibilidades; rules modifican comportamiento*. Capabilities responden "¿se puede?"; rules responden "¿bajo qué condiciones, y con qué consecuencia?". Memorias previas lo enuncian así y se mantiene.

### 1.3 Por qué una regla NO debe mutar estado directo

Si la regla escribe estado (ej. `UPDATE members SET prio = 0 WHERE …`), perdemos:

- **Auditabilidad** — no queda atom que diga "esto se hizo porque la regla R v3 disparó condición C".
- **Replayability** — no podemos re-simular el pasado bajo otra versión de la regla.
- **Reversibilidad** — un override administrativo no puede rollback limpiamente.
- **Idempotencia** — un retry duplica el efecto.
- **Composabilidad** — dos reglas pisándose generan race conditions.

**Por eso:** una regla emite **atoms** (que son la fuente de verdad) y/o **arranca workflows** (que cierran como atoms). Todo lo demás se **deriva** vía projection.

### 1.4 Cómo se evalúa (resumen, detalle en §9)

```
trigger atom emitted
   ↓
engine loads applicable rules (scope match)
   ↓
sorted by precedence (occurrence > resource > series > group > global)
   ↓
conditions evaluated against atoms + projections
   ↓
exceptions checked
   ↓
consequences emitted as atoms / workflows
   ↓
rule_evaluation row written (audit)
   ↓
projections rebuilt (lazy or eager)
   ↓
notifications enqueued
```

### 1.5 Versionado, audit, desactivación

- Una regla **nunca se sobrescribe**. Cada cambio crea `rule_version` nuevo con `effective_from`, `created_by`, `change_reason`, `previous_version_id`.
- Desactivar = nueva versión con `status='inactive'`, NO `DELETE`.
- Cada evaluación deja `rule_evaluations(rule_version_id, trigger_atom_id, verdict, consequences_emitted)`.

### 1.6 Conflictos y prioridad

**Precedencia (orden completo, "más específico gana"):**

```
occurrence > resource > series > resource_type > capability > group > global_default
```

- `occurrence` = una instancia (este partido del 8 de mayo).
- `resource` = un resource específico (cancha del Olivar).
- `series` = serie/recurrencia (todas las cenas de los jueves).
- `resource_type` = todo lo de tipo `event` / `fund` / `asset` / `space` / `slot` / `right`.
- `capability` = scope sobre la capability misma (ej. "todo `booking` en este grupo").
- `group` = todo el grupo.
- `global_default` = default de plataforma (raro).

> **Caveat de `capability` scope:** *capability scope siempre se interpreta como group-level a menos que vaya pareado con un resource o resource_type específico*. Ej. `scope = capability:booking` significa "todas las bookings del grupo"; `scope = capability:booking + resource_type:space` significa "bookings sobre spaces del grupo". Sin esa precisión, capability scope es ambiguo y el publish lo bloquea.

**Tipos de "conflicto":**

1. **Precedencia natural (no es conflicto, es jerarquía):** una regla de scope `occurrence` gana sobre la de `group`. La más específica gana automáticamente. Esto **se resuelve en el engine, sin warning**.
2. **Conflicto real:** dos reglas al **mismo scope, mismo trigger, consecuencias contradictorias** (ej. una emite `issue_fine` y otra `emit_warning` para el mismo actor sobre el mismo atom). Esto se detecta en publish-time y bloquea.

> Beta 1 sólo detecta conflictos del tipo 2 (más `consequence_missing_capability` y `impossible_condition`). Loops, deadlocks de aprobación, ambigüedades de prioridad cruzada se manejan post-Beta.

---

## 2. Gramática universal de reglas

### 2.1 Forma canónica

```
WHEN     <trigger>
IF       <conditions...>     (AND/OR; AND por defecto)
THEN     <consequences...>   (ejecución idempotente)
TARGET   <whom/what>         (a quién/qué afecta la consequence: actor, resource, group, role, member-set)
UNLESS   <exceptions...>     (cortocircuito: si exception aplica, NO se emiten consequences)
LIMIT    <thresholds>        (rate, quota, cooldown)
SCOPE    <where>             (group | resource | resource_type | capability | series | occurrence)
PRIORITY <int|auto>          (default: derivado del scope)
```

> **SCOPE vs TARGET (distinción crítica):**
> - `SCOPE` = **dónde** aplica/evalúa la regla. "Esta regla vive sobre el partido X."
> - `TARGET` = **a quién/qué** afecta la consequence. "Le pone bench al miembro que hizo check-in."
> Una regla puede tener scope `resource(event)` y target `actor` (el que disparó el trigger), o scope `group` y target `role:treasurer`. Sin esta separación el JSON se vuelve ambiguo cuando trigger.actor ≠ a quién se le aplica la consecuencia (ej. un host hace check-in y la consequence afecta a otro miembro).

> **UX:** el usuario nunca ve esta forma. Ve "Cuando alguien hace check-in, los primeros 11 son titulares…". Esta es la forma **interna** que ven el engine y el JSON.

### 2.2 Variables del DSL

Las variables son **referencias tipadas** a estados conocidos. No hay expresiones aritméticas libres, no hay strings de código.

| Familia | Variables | Tipos | Resuelve en |
|---|---|---|---|
| **Actor** | `actor`, `actor.role`, `actor.relation`, `actor.is_admin`, `actor.has_role(x)`, `actor.is_member`, `actor.is_guest` | enum / bool | runtime |
| **Resource** | `resource`, `resource.type`, `resource.capabilities`, `resource.owner`, `resource.custodian` | typed ref | runtime |
| **Event/atom** | `trigger.type`, `trigger.actor`, `trigger.resource`, `trigger.timestamp`, `trigger.payload.<field>` | typed | atom payload |
| **Time** | `now`, `before(<ref>, <duration>)`, `after(<ref>, <duration>)`, `within(<duration>)`, `weekday`, `cycle` | timestamp/duration | runtime |
| **Quantity** | `count(<projection>)`, `rank(<actor>, <projection>)`, `capacity(<resource>)`, `position(<actor>, <ordered_projection>)` | int | projection read |
| **Money** | `amount`, `balance(<scope>)`, `unpaid_total(<actor>)` | decimal | projection read |
| **State** | `projection.<name>`, `obligation.<name>`, `status.<workflow>` | typed | projection read |
| **History** | `history.count(<event_type>, <window>)`, `history.last(<event_type>, <actor>)`, `streak.<projection>` | int/timestamp | atoms scan |
| **Target** | `$trigger.actor`, `$resource.owner`, `$resource.custodian`, `role:<role_id>`, `member_set:<filter>` | ref/set | resolved at consequence emit |

**Reglas duras:**
- Toda variable tiene tipo cerrado.
- No hay coerción implícita.
- No hay funciones definidas por el usuario.
- Comparaciones permitidas: `==`, `!=`, `<`, `<=`, `>`, `>=`, `in`, `not in`, `between`.
- Sin operadores aritméticos a nivel rule (los cálculos ya viven en projections; la rule sólo compara).

### 2.3 Forma JSON interna (no expuesta)

```json
{
  "rule_id": "...",
  "version": 3,
  "scope": { "type": "resource", "id": "<resource_uuid>" },
  "trigger": "check_in.created",
  "conditions": {
    "all_of": [
      { "var": "rank(actor, projection.check_in_order)", "op": "<=", "value": 11 },
      { "var": "actor.is_eligible", "op": "==", "value": true }
    ]
  },
  "target": { "type": "ref", "value": "$trigger.actor" },
  "consequences": [
    { "type": "assign_participant_role", "role": "starter", "target": "$target" }
  ],
  "exceptions": [
    { "all_of": [ { "var": "actor.has_role", "value": "captain_override_target" } ] }
  ],
  "priority": "auto",
  "status": "active",
  "effective_from": "2026-05-14T00:00:00Z",
  "shape_id": "first_come_first_served",
  "shape_params": { "limit": 11, "winner_role": "starter", "loser_role": "bench" }
}
```

> El builder produce **shape + params**. El servidor materializa **conditions/consequences** desde el shape registrado. Esto es el guardrail clave: el usuario no puede escribir condiciones arbitrarias — sólo parametrizar shapes auditados.

---

## 3. Catálogo de triggers

> **Convención:** los triggers son **referencias a tipos de atoms emitidos**. Si no hay atom, no hay trigger. Esto fuerza disciplina: cualquier cosa "rule-able" tiene que dejar evidencia.

### 3.1 Triggers reales (= atom types existentes hoy o V1)

| Trigger | Atom source | Beta 1? |
|---|---|---|
| `member.joined` | `system_events` | ✅ |
| `member.left` | `system_events` | ✅ |
| `member.role_changed` | `system_events` | ✅ |
| `resource.created` | `system_events` | ✅ |
| `resource.archived` | `system_events` | ✅ |
| `capability.enabled` / `capability.disabled` | `system_events` | ✅ |
| `event.created` / `event.updated` / `event.cancelled` | `system_events` | ✅ |
| `event.started` / `event.ended` | `system_events` (cron-emitted) | ✅ |
| `event.deadline_passed` | `system_events` (cron-emitted) | ✅ |
| `rsvp.created` / `rsvp.changed` | `rsvp_actions` | ✅ |
| `rsvp.deadline_missed` | `system_events` (cron-emitted) | ✅ |
| `check_in.created` | `check_in_actions` | ✅ |
| `check_in.window_closed` | `system_events` (cron-emitted) | ✅ |
| `check_in.missed` | derived from `event.ended` + no `check_in_action` | ✅ |
| `vote.started` / `vote.cast` / `vote.closed` | `vote_casts` + `system_events` | ✅ |
| `ledger_entry.created` | `ledger_entries` | ✅ |
| `fine.issued` / `fine.paid` / `fine.voided` | `ledger_entries` + `system_events` | ✅ |
| `appeal.started` / `appeal.resolved` | workflow events | Post-Beta |
| `booking.requested` / `booking.created` / `booking.cancelled` | `system_events` | Post-Beta |
| `booking.overlap_detected` | engine-synthetic | Post-Beta |
| `task.created` / `task.completed` / `task.overdue` | `task_events` | Post-Beta |
| `document.uploaded` / `document.acknowledged` | `document_versions` + `system_events` | Post-Beta |
| `obligation.created` | engine-synthetic | Post-Beta |
| `projection.changed` | engine-synthetic (debounced) | ❌ |

### 3.2 Synthetic / internal triggers

- **Cron-emitted:** `event.started`, `event.ended`, `deadline_passed`, `check_in.window_closed` los emite el cron `process-system-events` consultando atoms + tiempo. No vienen de acción de usuario. Son atoms reales en `system_events`.
- **Engine-derived:** `check_in.missed`, `booking.overlap_detected` los deriva el engine al evaluar otra rule. Se materializan como `system_events` para mantener auditabilidad.
- **NO trigger:** `projection.changed` y `rule.evaluated` están **prohibidos como triggers** en Beta 1. Permitirlos abre la puerta a loops infinitos. Si una regla necesita reaccionar a "cambió balance", reacciona al atom que cambió el balance (`ledger_entry.created`), no a la proyección.

> **Guardrail:** sólo triggers en este catálogo son seleccionables. El builder no permite triggers libres.

---

## 4. Catálogo de conditions

> **Toda condition es:** `(variable, operador, valor)` o `(variable, operador, otra_variable)`. Sin AST libre.

| Nombre humano (UI) | Variable interna | Lee de | Tipos | Beta 1? |
|---|---|---|---|---|
| "Es miembro" | `actor.is_member` | relation | bool | ✅ |
| "Es admin" / "Tiene rol X" | `actor.has_role(x)` | relation | bool | ✅ |
| "Es invitado" | `actor.is_guest` | relation | bool | ✅ |
| "Es elegible (no excluido)" | `actor.is_eligible_for(<capability>)` | relation override | bool | ✅ |
| "Está entre los primeros N en …" | `rank(actor, <projection>) <= N` | projection | int | ✅ |
| "Cupo lleno" | `count(<projection>) >= capacity(<resource>)` | projection | int | ✅ |
| "Antes del deadline" | `now < <trigger.resource>.deadline` | trigger + resource | timestamp | ✅ |
| "Después del deadline" | inverso | trigger + resource | timestamp | ✅ |
| "Dentro de la ventana de check-in" | `between(now, window_open, window_close)` | resource | timestamp | ✅ |
| "Monto mayor a X" | `trigger.amount > X` | atom payload | money | ✅ |
| "Balance negativo / bajo X" | `balance(<scope>) < X` | projection | money | ✅ |
| "Tiene multas sin pagar" | `unpaid_total(actor) > 0` | projection | money | ✅ |
| "Faltó a las últimas N veces" | `history.count('check_in.missed', actor, last_N) >= K` | atoms scan | int | ✅ |
| "Ya usó su cuota" | `usage_count(actor, <capability>, <period>) >= quota` | projection | int | ✅ |
| "Voto tiene quórum" | `count(vote_casts) / count(eligible) >= quorum` | projection | float | ✅ |
| "Reserva se empalma" | `booking.overlap_detected = true` | engine | bool | Post-Beta |
| "Documento no aceptado" | `document.acknowledged(actor, <doc>) = false` | projection | bool | Post-Beta |
| "Tarea vencida" | `task.due_at < now AND task.completed = false` | projection | bool | Post-Beta |
| "Es custodio del asset" | `actor == resource.custodian` | resource | ref | Post-Beta |

**Para cada condition, el builder declara:**
- `name_human` (UI)
- `var_template` (cómo se compila al JSON interno)
- `required_capabilities` (la regla sólo se puede usar si el resource tiene esas capabilities habilitadas)
- `accepts_param` (qué parámetros pide al usuario: N, monto, días, etc.)
- `reads_from`: `atoms` | `projections` | `relations` | `trigger_payload`

> **Distinción crítica:** las conditions que leen de **atoms scan** (history) son caras. El engine las cachea por `(actor, event_type, window)`. Las que leen de **projections** son baratas. Las que leen de **trigger_payload** son gratis. Esto guía qué shapes elegir primero.

---

## 5. Catálogo de consequences

> **Lista cerrada.** No hay consecuencias arbitrarias. Cada una es un emisor de **atom** o **workflow** (que cierra como atom).

> **Principio constitucional:** **en Beta 1 todas las reglas son post-atom.** El trigger ya ocurrió y fue escrito; la rule reacciona. **No hay `deny_action` ni `allow_action` en Beta 1.** Cuando una acción excede capacidad/elegibilidad, no se rechaza el atom original — se *etiqueta* la consecuencia (waitlist, violation, warning, review, approval). Pre-write deny es Post-Beta cuando el engine soporte rollback transaccional.

> **Principio constitucional:** **workflows no son verdad final.** Un workflow (vote, approval, appeal) coordina la resolución, pero su outcome SIEMPRE debe materializarse como un **atom** propio para entrar a la cadena de verdad. Ej.: `pending_changes.status='approved'` ayuda al workflow; la consecuencia real (booking confirmada) escribe `system_events(booking_confirmed)`.

### 5.1 Beta 1 — consequences seguras (post-atom)

| Consecuencia | Qué hace | Emite atom | Inicia workflow | Requiere capability | Reversible |
|---|---|---|---|---|---|
| `assign_participant_role` | Asigna rol **contextual** al target en el resource (titular, banca, host_for_event). NO es rol persistente del grupo. | `system_events(role_assigned)` | — | — | Sí (nuevo atom) |
| `assign_to_waitlist` | Variante de `assign_participant_role` con semántica explícita de cola. La projection respeta order. | `system_events(role_assigned, role=waitlist, position=N)` | — | — | Sí |
| `mark_violation` | Anota incumplimiento (no avisó, no asistió, llegó tarde). No emite dinero por sí solo. Alimenta projections de reputación/elegibilidad. | `system_events(violation_marked)` | — | — | Sí (con `correction` atom) |
| `emit_warning` | Aviso explícito al target. Visible en su inbox + history. No tiene costo monetario. | `system_events(warning_emitted)` | — | — | Sí |
| `require_review` | Anota que un humano (admin) debe revisar. Más ligero que approval — no bloquea nada, sólo deja pendiente. | `system_events(review_requested)` + `user_actions` | review workflow | — | Sí (resolve) |
| `start_approval` | Abre approval por rol(es) configurado(s). Bloquea ejecución posterior de otra rule encadenada hasta cierre. | `system_events(approval_requested)` + `pending_changes` | approval workflow | — | Sí (cancel) |
| `start_vote` | Abre votación con quórum/mayoría configurada. | `system_events(vote_started)` + `vote_casts` (al cierre) | voting workflow | `voting` | Sí (cancel) |
| `record_ledger_entry` | Escribe ledger (contribución, gasto, reembolso). | `ledger_entries` | — | `ledger` | Vía correction entry |
| `issue_fine` | Multa monetaria + obligation projection seed. | `ledger_entries(fine)` + `system_events(fine_issued)` | (opcional) appeal workflow | `fines` | Vía `void_fine` |
| `send_notification` | Encola push/email al target. | queue row | — | `notifications` | No |

### 5.2 Post-Beta — consequences diferidas

| Consecuencia | Razón del diferimiento |
|---|---|
| `deny_action` | Requiere pre-write engine + rollback transaccional. Complejidad alta. |
| `allow_action` | Redundante con default. Sólo útil para overriding de otras rules, lo cual implica pre-write. |
| `assign_relation_role` | Asignar rol **persistente** del grupo (treasurer, captain) desde rule automática es peligroso. Debe pasar por workflow/admin. En Beta 1, rule emite `require_review` o `start_approval` y un admin asigna. |
| `adjust_priority` | Requiere capability `priority` (no en Beta 1) + projection de priority score. |
| `apply_quota_usage` | Requiere capability `quota`. |
| `create_task` | Requiere capability `tasks`. |
| `request_acknowledgement` | Requiere capability `documents`. |
| `lock_capability` / `unlock_capability` | Cambio estructural de configuración. Sólo manual en Beta 1. |
| `archive_resource` | Cambio estructural. Sólo manual. |
| `trigger_reminder` | Necesita cron de recordatorios; no en Beta 1. |
| `escalate_to_admin` | Variante de `start_approval`; redundante hasta tener routing por severidad. |

### 5.3 Guardrails de consequences

- Toda consequence con dinero (`record_ledger_entry`, `issue_fine`) escribe `idempotency_key` derivado de `sha1(rule_version_id || trigger_event_id || target_id || consequence_index)` para evitar duplicados en retry. UNIQUE constraint a nivel DB.
- `assign_participant_role` es **siempre** scoped al resource (titular **de este partido**, host **de esta cena**). Nunca afecta `group_members.role`.
- `assign_to_waitlist` debe escribir `position` derivada al momento del atom, no diferida.
- `mark_violation` y `emit_warning` son atoms inmutables; corregir = emitir `correction_atom` (post-Beta) o `void` via admin manual.
- `start_approval` / `start_vote` deben validar al publish-time que el rol/poll de votantes exista; si no, conflict `consequence_missing_capability`.
- Workflows abiertos al cerrarse SIEMPRE emiten un atom de cierre (`approval_granted`, `vote_closed`, `appeal_resolved`) — no basta con `status='resolved'`.
- `target` es obligatorio para toda consequence; el shape registry lo declara y lo valida al compilar.

---

## 6. Rule shapes (Catálogo Lego)

> **Estos son los "Legos".** Un shape es una plantilla pre-validada: trigger fijo, conditions parametrizables, consequences fijas, capabilities requeridas. El usuario sólo elige el shape y rellena 2–4 parámetros.

> **Doctrina (la frase que vale más que el catálogo):** *user-configurable parameters, not user-programmable logic.* El shape es código auditado; los params son datos. Si algo no encaja en un shape existente, **no se publica como rule** — se pide nuevo shape al founder o se usa el AI assistant (post-Beta) para sugerir promoción.

### 6.1 Catálogo Beta 1 (5 shapes, post-recorte)

#### 1. `first_come_first_served`
- **Frase humana:** "Los primeros N que hagan {acción} reciben {rol A}; el resto recibe {rol B}."
- **Trigger:** `check_in.created` | `rsvp.created` (param).
- **Scopes soportados:** `resource(event)`, `series`, `resource_type=event`.
- **Params:** `limit` (int), `winner_role` (string), `loser_role` (string, default=`bench`).
- **Target:** `$trigger.actor`.
- **Conditions:** `actor.is_eligible == true`, `rank(actor, <projection>) <= limit`.
- **Consequences:** `assign_participant_role(winner_role)` si rank≤limit; `assign_to_waitlist` o `assign_participant_role(loser_role)` si no.
- **Capabilities requeridas:** `check_in` o `rsvp`, `eligibility`.
- **Projection dependencies:** `check_in_order_view` o `rsvp_order_view`.
- **Conflict signature:** `(scope, trigger, target=actor)` — otro `first_come_first_served` o `assign_participant_role` automático en mismo scope = conflict.
- **Usos:** equipo de fútbol titulares/banca; mesas en cena; primeras N reservas.

#### 2. `deadline_enforcement`
- **Frase humana:** "Si no haces {acción} antes de {tiempo}, pasa {consecuencia}."
- **Trigger:** `event.deadline_passed`.
- **Scopes soportados:** `resource(event)`, `series`, `resource_type=event`, `group`.
- **Params:** `required_action` (`rsvp_yes` | `check_in` | `ledger_contribution`), `consequence_kind` (`fine` | `warning` | `violation` | `review`).
- **Target:** `member_set:owes_required_action` (resuelto en eval-time: miembros que no emitieron el atom requerido).
- **Conditions:** ausencia de atom requerido por target dentro de la ventana.
- **Consequences:** según `consequence_kind`: `issue_fine` | `emit_warning` | `mark_violation` | `require_review`.
- **Capabilities requeridas:** depende del consequence_kind.
- **Projection dependencies:** `rsvp_view` | `check_in_view` | `ledger_view` por resource.
- **Conflict signature:** `(scope, trigger=deadline, action_kind)`.

#### 3. `monetary_penalty`
- **Frase humana:** "Si {trigger}, se cobra una multa de {monto}."
- **Trigger:** cualquier atom del whitelist.
- **Scopes soportados:** todos.
- **Params:** `amount` (money), `currency` (group default), `appeal_window_hours` (int, default 0).
- **Target:** `$trigger.actor`.
- **Conditions:** opcionales (filtros por rol/relation/exclusión).
- **Consequences:** `issue_fine`; opcional `start_approval(appeal)` si `appeal_window>0`.
- **Capabilities requeridas:** `fines`, opcional `appeals`.
- **Projection dependencies:** `unpaid_fines_view`.
- **Conflict signature:** `(scope, trigger, target=actor, consequence=fine)`.
- **Guardrail:** **nunca pre-marcado por default**, sólo si el template lo marca como strict (per memoria `feedback_create_flow_defaults`).

#### 4. `approval_threshold`
- **Frase humana:** "Si el monto/cantidad supera {umbral}, requiere {aprobación | voto}."
- **Trigger:** `ledger_entry.created` | (post-Beta: `booking.requested`).
- **Scopes soportados:** `group`, `resource(fund)`, `resource_type=fund`.
- **Params:** `threshold_field` (path JSON), `threshold_op`, `threshold_value`, `decision_mode` (`approval_by_role` | `vote_simple_majority` | `vote_quorum_X`), `approver_role` o `voter_pool`.
- **Target:** `$trigger.resource` o `$trigger.atom_id` (lo que se va a aprobar).
- **Conditions:** `trigger.<field> <op> <value>`.
- **Consequences:** `start_approval` o `start_vote`. Si se aprueba, workflow emite atom de cierre que confirma el efecto.
- **Capabilities requeridas:** `approvals` o `voting`.
- **Projection dependencies:** `pending_changes_view`, `vote_counts_view`.
- **Conflict signature:** `(scope, trigger, threshold_field)` con threshold ranges solapados.

#### 5. `rotating_assignment`
- **Frase humana:** "El siguiente miembro elegible es {rol} para el próximo {resource}."
- **Trigger:** `event.created` (o `resource.created` con `resource_type=event`).
- **Scopes soportados:** `series`, `resource_type=event`.
- **Params:** `role` (`host` | `server` | `cleaner` | custom string), `pool` (`all_members` | `eligible_for_capability:<cap>` | `role:<role>`).
- **Target:** miembro siguiente en cola (resuelto vía projection `next_host_view`).
- **Conditions:** miembro está en pool y no tiene override `excluded` activo.
- **Consequences:** `assign_participant_role(role)` sobre el resource recién creado.
- **Capabilities requeridas:** `rotating_host`, `eligibility`.
- **Projection dependencies:** `rotation_state_view`, `next_host_view`.
- **Conflict signature:** `(scope, role)` — dos rules de rotación al mismo role+scope = conflict.

### 6.2 Shapes Post-Beta (orden de prioridad)

1. `capacity_limit` — recortado de Beta 1 porque abre waitlist/pre-write/period resets.
2. `quota_per_period` — recortado de Beta 1 por usage counters + capability `quota` no existe aún.
3. `priority_allocation` (socios fundadores entran primero).
4. `exclusion` (David fuera de rotativa) — Beta 1 lo cubre con `member_capability_overrides`, sin rule explícita.
5. `guest_limit` (4 invitados por miembro).
6. `booking_conflict` (no permitir empalmes) — requiere pre-write.
7. `acknowledgement_gate` (debe aceptar reglas antes de participar).
8. `manual_override` (capitán puede mover de banca a titular, con audit).
9. `reputation_adjustment` (faltas bajan prioridad).
10. `recurrence_rule` (repetir esto semanal/mensual).
11. `freeze_capability` (congelar booking si pasa X).
12. `document_requirement` (requiere doc subido).
13. `escalation_rule` (no resuelto en 24h → admin).
14. `custody_liability` (custodio responde si daño).

> **Razón del recorte a 5 (no 7):** `capacity_limit` y `quota_per_period` parecen simples pero abren waitlist, pre-write deny, period resets, usage counters y disputas de fairness. `first_come_first_served` ya cubre el caso "fútbol titulares" sin necesidad de capacity formal. Empezar con 5 minimiza la matriz de conflicts y permite shipear sin AI ni simulación.

### 6.3 Rule Shape Contract (qué debe declarar todo shape)

Todo shape registrado debe declarar, en TypeScript (server) y Swift (cliente mirror):

```ts
interface RuleShapeContract {
  shape_id: string;                          // "first_come_first_served"
  version: number;                           // bump when semantics change
  display_name: { es: string; en: string };
  supported_scopes: ScopeType[];             // ['resource(event)', 'series', 'resource_type=event']
  allowed_triggers: TriggerType[];
  required_capabilities: Capability[];       // engine bloquea publish si faltan
  params_schema: ParamSpec[];                // JSON schema-like, typed
  target_resolver: TargetResolverRef;        // función que resuelve target desde context
  compiled_conditions: ConditionTemplate[];  // se instancian con params al publicar
  compiled_consequences: ConsequenceTemplate[];
  projection_dependencies: ProjectionRef[];  // qué projections lee
  conflict_signature: ConflictSig;           // fingerprint para detección de overlap
  explanation_templates: {                   // .strings refs por locale
    short: string; detailed: string;
    member_facing: string; audit: string;
    edge_cases: string[]; not_included: string[];
  };
  test_fixtures: ShapeFixture[];             // mínimo 5 por shape; CI bloquea release sin ellos
  migration_policy: 'frozen' | 'backwards_compatible' | 'breaking';
}
```

**Reglas:**
- Sin `test_fixtures` ≥5 (incluyendo edge cases declarados), el shape NO entra a producción.
- Si `migration_policy='breaking'`, todas las `rule_versions` con ese `shape_id` deben re-compilarse o marcarse `inactive` antes del release.
- `conflict_signature` es un tuple-fingerprint server-side, no expresable en UI.
- Cambiar un shape = release de código. El catálogo NO se edita en runtime.

### 6.4 Custom Lego Builder

**Decisión:** **NO construir en Beta 1.** Razones:

- 5 shapes cubren ≥85% de casos verticales validados (cenas, fútbol, palco, fund roommates, rotación).
- Custom builder multiplica superficie de bugs y casos de conflict 5–10x.
- AI assistant (post-Beta) reemplaza al Custom builder para casos exóticos: el usuario describe, AI propone un shape existente o escala como feature request.
- Cualquier shape "exótico" que aparezca dos veces se promueve a shape oficial. Esa es la cadencia.

---

## 7. Data model

> **Doctrina:** lo mínimo en tablas; lo demás JSONB **controlado por shape registry server-side**. El shape registry vive en código (TypeScript en edge functions + Swift en cliente), no en DB. Las tablas son el archivo histórico, no el motor.

### 7.1 Tablas (qué SÍ)

```sql
-- Identidad de la regla (estable). Mutable sólo en campos no-versionados.
create table rules (
  id            uuid primary key default gen_random_uuid(),
  group_id      uuid not null references groups(id),
  scope_type    text not null check (scope_type in
                  ('group','resource','resource_type','capability','series','occurrence')),
  scope_id      uuid,                       -- nullable si scope_type='group' o 'capability'
  scope_extra   jsonb default '{}',         -- ej. {capability:'booking', series_id:'…'}
  shape_id      text not null,              -- referencia al shape registry server-side
  title         text not null,              -- "Multa por no avisar"
  status        text not null default 'active' check (status in ('active','inactive','draft')),
  current_version int not null default 1,
  created_by    uuid not null references profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on rules (group_id, scope_type, scope_id) where status='active';

-- Append-only. Una fila por cambio de la regla.
create table rule_versions (
  id                 uuid primary key default gen_random_uuid(),
  rule_id            uuid not null references rules(id) on delete restrict,
  version            int  not null,
  shape_id           text not null,
  shape_params       jsonb not null,        -- los parámetros que llenó el usuario
  compiled           jsonb not null,        -- el JSON canónico (trigger/conditions/consequences)
                                            -- recomputado desde shape + params al publicar
  status             text not null check (status in ('active','inactive','superseded','draft')),
  effective_from     timestamptz not null,
  effective_until    timestamptz,
  previous_version_id uuid references rule_versions(id),
  created_by         uuid not null references profiles(id),
  change_reason      text,
  created_at         timestamptz not null default now(),
  unique (rule_id, version)
);
create index on rule_versions (rule_id, version desc);
create index on rule_versions (effective_from, effective_until);

-- Cada evaluación deja huella. Append-only.
create table rule_evaluations (
  id                  uuid primary key default gen_random_uuid(),
  rule_id             uuid not null references rules(id),
  rule_version_id     uuid not null references rule_versions(id),
  trigger_event_id    uuid not null,        -- referencia al atom desencadenante (system_events.id u otra)
  trigger_event_table text not null,        -- 'system_events' | 'rsvp_actions' | …
  group_id            uuid not null,
  actor_id            uuid,
  verdict             text not null check (verdict in ('matched_consequences','matched_no_action','exception_short_circuit','no_match','error')),
  consequences        jsonb not null default '[]', -- lista de atoms/workflows emitidos (refs)
  conflicts_detected  jsonb default '[]',
  evaluated_at        timestamptz not null default now(),
  idempotency_key     text not null,
  unique (idempotency_key)
);
create index on rule_evaluations (rule_id, evaluated_at desc);
create index on rule_evaluations (group_id, evaluated_at desc);
create index on rule_evaluations (trigger_event_id);

-- Conflictos detectados en publish-time. Mutable mientras se resuelven.
create table rule_conflicts (
  id                  uuid primary key default gen_random_uuid(),
  group_id            uuid not null,
  rule_a_version_id   uuid not null references rule_versions(id),
  rule_b_version_id   uuid not null references rule_versions(id),
  conflict_type       text not null check (conflict_type in
                        ('contradictory_consequences','same_scope_overlapping','impossible_condition','priority_ambiguity')),
  severity            text not null check (severity in ('blocking','warning')),
  detected_at         timestamptz not null default now(),
  resolved_at         timestamptz,
  resolution          text
);
create index on rule_conflicts (group_id) where resolved_at is null;

-- Overrides por miembro (excepciones puntuales, ej. David fuera de rotativa).
-- POST-BETA: generalizar a `relation_capability_overrides` cuando aparezcan casos
-- para guest/role/ownership/custodian/team-subgroup. Beta 1: member es suficiente.
create table member_capability_overrides (
  id            uuid primary key default gen_random_uuid(),
  group_id      uuid not null,
  member_id     uuid not null references group_members(id),
  capability    text not null,                  -- 'rotating_host' | …
  override      text not null check (override in
                  ('excluded','allowed','priority_high','priority_low','exempt')),
  effective_from timestamptz not null default now(),
  effective_until timestamptz,
  reason        text,
  created_by    uuid not null,
  created_at    timestamptz not null default now()
);
create index on member_capability_overrides (group_id, member_id, capability) where effective_until is null;
```

### 7.2 Lo que NO es tabla (JSONB en `rule_versions.compiled` y `shape_params`)

- `rule_conditions` → conditions como tabla **no**. Son lista en `compiled.conditions`. El shape registry server-side las validó al publicar; no se mutan.
- `rule_consequences` → idem. Lista en `compiled.consequences`.
- `rule_exceptions` → idem.
- `rule_simulations` → **no** persistir en DB. Son ejecuciones efímeras del engine en modo dry-run (post-Beta). Si se vuelve recurrente, persistir como `rule_simulations(rule_version_id, fixture_set_id, results_jsonb)` y nada más.
- `rule_shapes` → **NO va en DB**. El shape registry vive en código TypeScript en `_shared/ruleShapes.ts` + tipos Swift en `RuulCore`. Cambiar un shape = release. Esto es deliberado: shapes son código, no datos de usuario.
- `capability_overrides` (no-member-scoped) → no en Beta 1; cuando se necesite, JSONB en `resource_capabilities`.
- `relation_overrides` → `member_capability_overrides` ya cubre el caso. Más allá de eso, no.

### 7.3 RLS y permisos

- `rules`: read si miembro del grupo; insert/update sólo si tiene permission `rules.author` (jsonb en `groups.roles`).
- `rule_versions`: read si miembro; **insert solamente desde edge function vía service role** (para forzar compilación server-side y conflict detection).
- `rule_evaluations`: read si admin del grupo; engine escribe vía service role.
- `rule_conflicts`: read si admin; engine escribe.
- `member_capability_overrides`: read si miembro; insert/update si admin o si auto-override (member auto-excluyéndose).

### 7.4 Idempotencia, replay, effective context

- Toda evaluación tiene `idempotency_key = sha1(rule_version_id || trigger_event_id || target_id || consequence_index)`. UNIQUE constraint impide doble ejecución.
- Replay (post-Beta): el engine puede correrse sobre un rango de atoms históricos con `rule_version_id` específico para producir un `rule_simulations` snapshot. Útil para "qué hubiera pasado si esta regla hubiera estado activa la semana pasada".

**Effective context (frozen-at-eval-time):**

Para que replay y audit sean reproducibles, toda evaluación debe correrse con un **contexto congelado**:

| Dimensión | Cómo se congela | Beta 1 |
|---|---|---|
| `rule_version` | Se evalúa contra `rule_versions.compiled` específico, no contra `rules` mutable. | ✅ |
| `actor relation` | Snapshot de `group_members` (rol, status) **al momento del trigger atom**, no al evaluar. | Documentar; Beta 1 lee actual (acceptable porque atoms están fresh). |
| `resource metadata` | Snapshot relevante de `resources.metadata` al momento del trigger. | Documentar; Beta 1 lee actual. |
| `group policy` | Versión de `groups.governance` activa al momento del trigger. | Documentar; Beta 1 lee actual. |
| `projection snapshot` | Estado de projection leída con `as_of = trigger.created_at`. | Documentar; Beta 1 lee actual (sin replay aún). |

> **Beta 1:** las dimensiones de actor/resource/group/projection se leen "actuales" porque el lag entre trigger y eval es <1min. Acceptable. **Post-Beta:** todas se congelan en `rule_evaluations.context_snapshot` (jsonb) para replay reproducible.

---

## 8. Execution engine

### 8.1 Ubicación

**Server-only.** Edge function `_shared/ruleEngine.ts` (ya existe parcialmente en el repo). El cliente iOS **nunca evalúa reglas para decidir** — solamente para **mostrar preview** (compila shape+params a frase humana, sin tocar atoms).

> Memoria: "Engine server-only" — esto está enraizado y se respeta.

### 8.2 Flujo de evaluación (detallado)

```
1. Atom emitted  (e.g. rsvp_actions row inserted)
   ↓
2. process-system-events cron tick (cada 30s) o trigger-on-write (post-Beta)
   ↓
3. Engine.load(group_id):
     - active rules where scope matches (occurrence, resource, series, resource_type, capability, group)
     - sorted by precedence DESC:
         occurrence > resource > series > resource_type > capability > group > global_default
     - capability scope: only evaluated paired with resource/resource_type; bare-capability-group-level is allowed but explicit
     - within same scope: by created_at DESC (newer wins; explicit ties surface as conflict)
     - resolve `target` per rule from registry (e.g. `$trigger.actor`, `$resource.custodian`, `member_set:...`)
   ↓
4. For each applicable rule:
     a. Resolve trigger.payload variables
     b. Resolve projection reads (cached per evaluation tick)
     c. Resolve history scans (cached per (actor, event_type, window))
     d. Evaluate conditions in ConjunctiveNormal form (validated at publish)
     e. Evaluate exceptions; if any matches → short-circuit, verdict=exception
     f. Resolve consequences; build atom payload(s) and workflow seed(s)
   ↓
5. Deduplicate consequences:
     - same (consequence_type, target_resource, target_actor, amount) within same eval → dedup
     - same idempotency_key across replays → no-op (UNIQUE constraint)
   ↓
6. Write atoms / workflows via SECURITY DEFINER RPCs
     (record_system_event, issue_fine, start_vote, …)
   ↓
7. Write rule_evaluations row
   ↓
8. Trigger projection rebuild (lazy: invalidate view cache)
   ↓
9. Enqueue notifications (dispatch-notifications cron picks up)
```

### 8.3 Idempotencia, retries, ordering

- **Idempotency:** `idempotency_key` en `rule_evaluations` + en cada atom de consequence (ej. `ledger_entries.idempotency_key`).
- **Retries:** cron puede correr varias veces sobre el mismo atom; UNIQUE constraint absorbe.
- **Ordering:** atoms procesados por `created_at ASC`. Dentro de un mismo tick, batch ordenado.
- **Async:** todo es async. Cliente nunca espera evaluación; recibe push cuando hay consecuencia que mostrar.
- **Failure handling:** error en una rule no aborta el batch; `verdict='error'` se persiste y se loggea. Admin del grupo recibe notification de regla rota.

### 8.4 Replay y backfill

- **Beta 1:** no hay replay público. Una rule nueva sólo aplica a atoms futuros (`effective_from = now`).
- **Post-Beta:** admin puede pedir "aplicar a partir de fecha pasada" → engine corre sobre rango histórico, **produce dry-run report** (NO escribe consequences automáticamente). Admin revisa el report y confirma. Esto es la base de la simulación.

### 8.5 Cuándo evalúa pre-write vs post-write

- **Post-write (default):** la mayoría de triggers son `*.created/*.changed`. El atom ya se escribió. Las consequences son emitir más atoms (fine, role assignment, notification).
- **Pre-write (solo para `*.requested`):** triggers como `booking.requested`, `member_invited` → engine evalúa **antes** de confirmar la escritura. Si `deny_action`, la escritura se cancela vía RPC que devuelve error al cliente. **No usar este modo en Beta 1**; en Beta 1 todo es post-write con compensaciones (ej. RSVP que excede cupo se acepta, pero se marca con `participant_role=waitlist`).

> **Razón:** pre-write es complejo, no idempotente, fuerza sincronía. Diferir a post-Beta cuando haya un caso real que lo necesite.

---

## 9. SwiftUI architecture

### 9.1 Estructura de carpetas

```
ios/Packages/
├── RuulCore/Sources/RuulCore/
│   ├── PlatformModels/
│   │   ├── Rule.swift                       // domain model
│   │   ├── RuleVersion.swift
│   │   ├── RuleShape.swift                  // shape registry mirror (codegen'd from server)
│   │   ├── RuleDraft.swift                  // builder-state, never persisted
│   │   ├── RuleBlock.swift                  // chip-level unit in builder UI
│   │   ├── RuleConflict.swift
│   │   └── MemberCapabilityOverride.swift
│   ├── PlatformModules/
│   │   └── RuleShapeRegistry.swift          // canonical 5 Beta-1 shapes (mirror of server)
│   ├── Repositories/
│   │   ├── RulesRepository.swift            // protocol
│   │   ├── LiveRulesRepository.swift
│   │   ├── MockRulesRepository.swift
│   │   └── RuleConflictRepository.swift
│   └── Services/
│       ├── RulePreviewGenerator.swift       // shape+params → human sentence
│       └── RulePublishService.swift         // calls RPC publish_rule_version
└── RuulFeatures/Sources/RuulFeatures/Features/Rules/
    ├── Views/
    │   ├── RulesListView.swift
    │   ├── RuleDetailView.swift
    │   ├── RuleBuilderView.swift            // master container
    │   ├── RuleScopePickerView.swift
    │   ├── RuleShapeGalleryView.swift
    │   ├── RuleParamFormView.swift          // dynamic form from shape.params spec
    │   ├── RuleSentencePreviewView.swift
    │   ├── RuleConflictWarningsView.swift
    │   ├── RuleVersionHistoryView.swift
    │   └── RulePublishSheet.swift
    ├── Components/
    │   ├── LegoBlockView.swift              // colored chip with icon
    │   ├── BlockPaletteView.swift           // post-Beta (Custom Builder)
    │   ├── RuleSummaryCard.swift
    │   └── RuleStatusBadge.swift
    └── Coordinators/
        └── RuleBuilderCoordinator.swift
```

### 9.2 Modelos clave (Swift)

```swift
// RuulCore/PlatformModels/Rule.swift
public struct Rule: Identifiable, Sendable, Equatable {
  public let id: UUID
  public let groupId: UUID
  public let scope: RuleScope
  public let shapeId: RuleShape.ID
  public let title: String
  public let status: RuleStatus
  public let currentVersion: Int
  public let createdBy: UUID
  public let createdAt: Date
}

public enum RuleScope: Sendable, Equatable {
  case group
  case resource(UUID)
  case resourceType(ResourceType)
  case capability(Capability)
  case series(UUID)
  case occurrence(UUID)
}

public enum RuleStatus: String, Sendable { case active, inactive, draft }

// RuulCore/PlatformModels/RuleShape.swift
public struct RuleShape: Identifiable, Sendable, Equatable {
  public let id: String                                    // "first_come_first_served"
  public let displayName: String
  public let humanSentenceTemplate: String                 // "Los primeros {limit}…"
  public let trigger: TriggerType
  public let paramSpec: [RuleShapeParam]
  public let requiredCapabilities: Set<Capability>
  public let sentenceGenerator: @Sendable (RuleShapeParams) -> AttributedString
}

public struct RuleShapeParam: Sendable, Equatable {
  public let key: String
  public let label: String
  public let kind: ParamKind   // int, money, duration, enum(options), roleRef, member, …
  public let validation: ParamValidation
  public let defaultValue: ParamValue?
}

// RuulCore/PlatformModels/RuleDraft.swift
public struct RuleDraft: Sendable, Equatable {
  public var scope: RuleScope?
  public var shape: RuleShape?
  public var params: [String: ParamValue] = [:]
  public var title: String = ""
  public var changeReason: String = ""
}
```

### 9.3 ViewModel (Observable, no Combine)

```swift
@Observable
@MainActor
public final class RuleBuilderStore {
  public private(set) var draft = RuleDraft()
  public private(set) var preview: AttributedString = ""
  public private(set) var conflicts: [RuleConflict] = []
  public private(set) var publishState: PublishState = .idle

  private let rules: RulesRepository
  private let registry: RuleShapeRegistry
  private let preview: RulePreviewGenerator

  public func selectScope(_ scope: RuleScope) { … }
  public func selectShape(_ shape: RuleShape) { … }
  public func setParam(_ key: String, _ value: ParamValue) { … updatePreview() }
  public func validate() async -> [ValidationError] { … }
  public func publish() async throws { … }   // calls publish_rule_version RPC

  private func updatePreview() {
    guard let shape = draft.shape else { return }
    preview = shape.sentenceGenerator(.init(values: draft.params))
  }
}
```

### 9.4 Layered access

```
RuleBuilderView (SwiftUI)
   ↓ binds to
RuleBuilderStore (@Observable)
   ↓ calls
RulesRepository (protocol)
   ↓ Live or Mock
LiveRulesRepository
   ↓ uses
SupabaseClient.rpc("publish_rule_version", …)
   ↓
edge function `publish-rule-version`:
   - validates shape + params against server registry
   - compiles to canonical JSON
   - detects conflicts
   - inserts rule_versions row
   - returns RuleVersion + conflicts
```

**Nada de calls directos a Supabase desde Views.** Repository pattern ya enraizado en CLAUDE.md.

### 9.5 Mock + tests

- `MockRulesRepository` con 5 reglas seed (una por cada shape Beta 1).
- Swift Testing en `RuulCoreTests` para `RulePreviewGenerator` (verifica que shape+params → frase esperada en es-MX).
- Snapshot tests en `RuulFeaturesTests` para `RuleSentencePreviewView` en 3 shapes representativos.

---

## 10. UI/UX — Lego Rule Builder

### 10.1 Principios visuales

- **Mobile-first vertical scroll**, sin drag&drop libre. Drag&drop libre se siente "Excel" y rompe con el principio "Lego seguro".
- **Bloques de colores** según función: trigger (azul), condición (amarillo), consecuencia (verde si positiva, rojo si negativa), excepción (gris).
- **Iconos consistentes** del set Apple SF Symbols + materiales `.glassEffect()` nativos iOS 26.
- **Frase humana siempre visible** en sticky footer. La frase es la verdad — los bloques son el armado.
- **Progressive disclosure:** scope picker → shape gallery → param form → preview → publish. Una pantalla por paso, todas en push stack o sheet.
- **Haptic light** en cada selección de chip; haptic success en publish.
- **NUNCA exponer palabras "trigger", "condition", "consequence", "scope", "JSON"** al usuario. Internamente sí; en UI: "Cuándo", "Si", "Entonces", "Excepto", "Dónde aplica". (Per memoria.)

### 10.2 Flujo — 3 fases visibles para el usuario, 8 stages internos

El usuario percibe **tres pasos**: **Elige Lego → Llena huecos → Activa.** Cada fase agrupa stages internos vía progressive disclosure (sheets, push interno, modales) para no sentirse "wizard de 8 pantallas".

```
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  1. ELIGE LEGO   │ →  │  2. LLENA HUECOS │ →  │   3. ACTIVA      │
│  scope + shape   │    │ params (+ excep) │    │ preview+publish  │
└──────────────────┘    └──────────────────┘    └──────────────────┘
   stages 1-2             stages 3-4             stages 5-8
```

**Fase 1 — Elige Lego** *(una pantalla, dos secciones)*
- *Sección Scope:* cards visuales ("Todo el grupo", "Este recurso", "Todos los eventos", "Esta serie", "Sólo este evento"). Preselect inteligente si el builder se abre desde un resource detail.
- *Sección Shape gallery:* tras seleccionar scope, mismas pantallas debajo se renderizan cards filtradas por `shape.supported_scopes`. Cards muestran emoji + frase con placeholders ("Los primeros [N] que lleguen…"). Tap = continúa a fase 2.

**Fase 2 — Llena huecos** *(una pantalla con form + frase sticky)*
- Form dinámico desde `shape.paramSpec`:
  - Int → stepper/slider con bounds visibles.
  - Money → campo numérico + moneda del grupo.
  - Duration → "X días/horas/minutos".
  - Enum → segmented control.
  - RoleRef → lista de roles existentes + "crear nuevo".
  - Member/MemberSet → multi-select.
- Frase humana actualizándose **en vivo** en sticky bottom.
- Sub-sheet *Excepciones (opcional, collapsable)* — en Beta 1 sólo "Excepto admins" como toggle único.
- Botón "Revisar y activar" → fase 3.

**Fase 3 — Activa** *(sheets en serie sobre la misma vista de revisión)*
- *Preview review:* frase completa formateada, chips clickables que regresan a fase 2 al param exacto.
- *Conflict sheet (sólo si los hubo):* banner rojo con opciones (reemplazar/editar/cancelar). Sin conflictos, se salta.
- *Publish sheet:* campo opcional "¿Por qué este cambio?" + switch "Notificar al grupo" (ON por default) + botón final "Publicar regla" con haptic success.
- *Resultado:* toast "Regla activa desde ahora" + push a `RuleDetailView`. La lista de reglas marca la nueva con badge.

**Stages internos (referencia para implementación, no visibles como pasos al usuario):**

| Stage | Vive en fase | Componente |
|---|---|---|
| 1. Scope pick | 1 | `RuleScopePickerView` |
| 2. Shape pick | 1 | `RuleShapeGalleryView` |
| 3. Params fill | 2 | `RuleParamFormView` |
| 4. Exceptions | 2 (collapsable) | `RuleExceptionsSection` |
| 5. Preview | 3 | `RuleSentencePreviewView` |
| 6. Conflicts | 3 (conditional) | `RuleConflictWarningsView` |
| 7. Publish confirm | 3 | `RulePublishSheet` |
| 8. Result | 3 | toast + push |

> **Razón del reframe:** ocho pantallas seguidas se sienten "Excel/Salesforce". Tres fases con disclosure se sienten "iOS native — armar Legos". Internamente el state machine es el mismo; el chrome cambia.

### 10.3 Componentes SwiftUI

**LegoBlockView**
```swift
struct LegoBlockView: View {
  let kind: BlockKind        // trigger | condition | consequence | exception
  let icon: Image
  let title: String
  let subtitle: String?
  let isInteractive: Bool

  var body: some View {
    HStack(spacing: 12) {
      icon.font(.system(size: 22, weight: .semibold))
        .foregroundStyle(kind.iconColor)
        .frame(width: 36, height: 36)
        .background(kind.iconBackground, in: .circle)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(.subheadline, weight: .semibold))
        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
      }
      Spacer()
    }
    .padding(14)
    .glassEffect(in: .rect(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(kind.borderColor, lineWidth: 1))
  }
}
```

**RuleSentencePreviewView**
- Sticky bottom con frase humana en `AttributedString`
- Highlight de cada parámetro como chip clickable que vuelve al paso correspondiente
- Animación cross-fade al cambiar params

**RuleConflictWarningsView**
- Banner rojo con icono `exclamationmark.triangle.fill`
- Lista de conflictos con CTA por conflicto
- Botón inferior "Resolver y continuar"

### 10.4 Copy de ejemplo (es-MX)

| Surface | Copy |
|---|---|
| Scope picker | "¿Dónde quieres que aplique esta regla?" |
| Shape gallery | "Elige el tipo de regla que mejor describe lo que quieres" |
| Param form | "Llena los huecos para personalizar" |
| Preview sticky | "Así se va a aplicar:" |
| Conflict | "Esta regla choca con otra que ya tienes" |
| Publish | "Listo. ¿Quieres activarla?" |
| Empty state | "Aún no hay reglas. Las reglas le dan estructura al grupo sin tener que recordarlas en cada evento." |

### 10.5 Lo que NO se construye en Beta 1

- Drag & drop de bloques (custom builder)
- Edición avanzada de excepciones más allá de "excepto admins"
- Visualización de árbol de reglas con dependencias
- Editor de roles/permissions desde dentro del rule builder (se hace en Settings aparte)
- Themes / colores personalizables de bloques

---

## 11. Natural language preview

### 11.1 Arquitectura

`RulePreviewGenerator` es un servicio puro:

```swift
public protocol RulePreviewGenerator: Sendable {
  func shortSummary(_ draft: RuleDraft) -> AttributedString
  func detailedExplanation(_ draft: RuleDraft) -> AttributedString
  func edgeCases(_ draft: RuleDraft) -> [String]
  func notIncluded(_ draft: RuleDraft) -> [String]
  func memberFacingExplanation(_ draft: RuleDraft, locale: Locale) -> AttributedString
  func auditExplanation(_ evaluation: RuleEvaluation) -> AttributedString
}
```

### 11.2 Generación

- Cada `RuleShape` declara plantillas localizadas (`.strings` files):
  - `short`: "Los primeros {limit} {action} {role}."
  - `detailed`: párrafo completo.
  - `member_facing`: tú/usted, sin jargon.
  - `audit`: tercera persona, con fechas y refs.
- Interpolación tipada (`AttributedString` con runs de `chip` para parámetros).
- Edge cases hardcoded por shape ("¿Qué pasa si llegan al mismo segundo? El de menor `created_at` gana.").
- "Not included" hardcoded por shape ("Esta regla **no** asigna posición en cancha, solo titular/banca.").

### 11.3 Auditoría

Cada `rule_evaluation` puede generar:
> "Hoy a las 19:42, Jose hizo check-in al partido del jueves. La regla 'Primeros 11 titulares' (v3) lo evaluó: rank=4 → asignado como titular."

Se muestra en el History feed con link al detail.

---

## 12. Simulation / dry run

**Decisión: NO en Beta 1.** Razones:
- Costo de implementación alto (replay engine + storage de fixtures).
- Casi nadie lo va a usar al principio.
- Empuja al usuario a "ya publica" en lugar de "qué tal si".

**Post-Beta (cuando 3+ grupos lo pidan):**

### 12.1 Inputs
- `rule_draft`
- ventana histórica (`from`, `to`)
- subset de atoms reales del grupo

### 12.2 Engine
- Mismo engine, pero `dry_run=true` flag.
- Atoms de consequence NO se escriben; se acumulan en memoria.
- Output: `RuleSimulationResult { evaluations: [...], hypothetical_atoms: [...] }`

### 12.3 UI
- Pantalla "Pruébala en tus últimos 10 partidos"
- Tabla: "Si hubiera estado activa, esto habría pasado…"
- Markers de "Esta multa NO se emitió porque era simulación"
- Cierra con "Publicar" o "Volver a ajustar"

### 12.4 Fixtures
- Edge cases por shape: empate de rank, capacity 0, deadline igual al `now`, actor sin role, etc.
- Tests automáticos contra estos fixtures bloquean release del shape registry.

---

## 13. Conflict detection

### 13.1 Tipos

| Tipo | Severidad | Beta 1? | Cuándo detectar |
|---|---|---|---|
| `contradictory_consequences` | Blocking | ✅ | Publish-time: dos rules mismo scope, mismo trigger, una `allow` otra `deny`. |
| `same_scope_overlapping` | Warning | ✅ | Publish-time: dos rules mismo `(scope, shape_id)` con params parcialmente solapados. |
| `impossible_condition` | Blocking | ✅ | Publish-time: condition que nunca puede ser true (ej. `rank <= -1`). |
| `priority_ambiguity` | Warning | Post-Beta | Dos rules mismo scope sin tiebreaker. |
| `loop_detected` | Blocking | Post-Beta | Rule A emite atom que dispara Rule B que emite atom que dispara Rule A. |
| `approval_deadlock` | Blocking | Post-Beta | Rule requiere aprobación de rol que está vacío. |
| `consequence_missing_capability` | Blocking | ✅ | Rule emite `start_vote` pero resource no tiene capability `voting`. |
| `quota_overlap` | Warning | Post-Beta | Dos reglas de cuota se contradicen. |

### 13.2 UI

- En el builder, después de "Publicar" → si conflictos:
  - Blocking: sheet rojo, no se puede continuar.
  - Warning: banner amarillo, se puede continuar con confirmación explícita ("Sé que choca pero publicar igual").
- En `RulesListView`: badge rojo en reglas con conflictos no resueltos.
- En `Settings → Governance`: vista global de conflictos pendientes.

### 13.3 Resolución

- Edit one of the conflicting rules.
- Or mark "supersede" → publishing this rule disables the other automatically.
- Conflict is logged in `rule_conflicts` table; resolved when one side changes status.

---

## 14. Permissions — quién puede tocar reglas

### 14.1 Roles base

| Rol | Crear rule | Editar rule | Desactivar | Aprobar voto sobre rule | Override manual | Ver simulation |
|---|---|---|---|---|---|---|
| admin | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| treasurer | money rules only | money rules only | ❌ | money votes | ❌ | money rules |
| captain | roster rules only | roster rules only | ❌ | roster votes | ✅ (lineup) | roster rules |
| member | propose only | ❌ | ❌ | vote | ❌ | ❌ |
| guest | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

### 14.2 Permission resolution

- `has_permission(actor_id, group_id, capability_or_action)` ya existe (RPC, mig 00063).
- Para Beta 1, sólo admins crean reglas. Treasurer/captain/member-propose es post-Beta.
- Permissions viven en `groups.roles` (jsonb) — versionado vía group history, NO append-only por ahora.

### 14.3 Proposal workflow (Post-Beta)

- Member propone → crea `rule_versions` con `status='draft'`.
- Admins reciben notification.
- Admin `approve` → status → `active`, `effective_from = now`.
- Admin `reject` → status → `inactive`, propuesta archivada.
- Opcional: grupo configura "cambios de regla requieren voto" → trigger `start_vote(simple_majority)` en lugar de admin direct.

### 14.4 Meta-rules

Política de governance sobre governance:
- "Cambiar una rule de tipo X requiere voto" → vive en `groups.governance` (jsonb).
- `governance.rules.change_policy = "admin_only" | "admin_with_notification" | "vote_simple_majority" | "vote_supermajority"`.
- Default: `admin_only` (Beta 1). El grupo puede subir a `vote_simple_majority` desde Settings (post-Beta).

---

## 15. Versioning & audit

### 15.1 Reglas

- **Nunca UPDATE de `rule_versions`.** Cada cambio → nueva row con `version = max + 1`.
- `previous_version_id` enlaza la cadena.
- `effective_from = now`, `effective_until = null` hasta que la siguiente versión la supere (`UPDATE prev SET effective_until = new.effective_from`).
- `rules.current_version` se actualiza al publicar.

### 15.2 Audit feed — distinción entre audit técnico y user activity

**Principio constitucional:** `rule_evaluations` es **audit técnico**, no actividad de usuario. Una rule que se evaluó 1,000 veces hoy NO debe ensuciar el History feed con 1,000 entradas.

**Tabla de routing:**

| Evento | Va a `system_events` (user-visible) | Va sólo a `rule_evaluations` (technical audit) |
|---|---|---|
| `rule.created` (v1) | ✅ | — |
| `rule.version_created` (v2+) | ✅ | — |
| `rule.activated` / `rule.deactivated` | ✅ | — |
| `rule.conflict_detected` (publish-time) | ✅ (admins only) | — |
| `rule.evaluated` con verdict=`matched_consequences` | ❌ — pero las **consequences** emitidas SÍ (ej. `fine_issued`, `role_assigned`) | ✅ |
| `rule.evaluated` con verdict=`no_match` / `exception_short_circuit` | ❌ | ✅ |
| `rule.evaluated` con verdict=`error` | ✅ (admin notification) | ✅ |

La regla operacional: **el feed del usuario muestra qué pasó (atom de consecuencia), no qué se evaluó.** El admin puede entrar a `RuleDetailView → Activity` para ver `rule_evaluations` cruda; eso es la vista técnica.

Aparece en History feed con filtro "Reglas" sólo los eventos marcados ✅ arriba.

### 15.3 UI version history

`RuleVersionHistoryView`:
- Timeline vertical
- Por cada versión: número, fecha, autor, cambio_razón, diff de params (semántico, "Limit cambió de 10 a 11")
- Tap → ver versión completa, opción "Revertir a esta versión" (crea nueva versión con mismos params)

---

## 16. AI Assistant para reglas

**Decisión: NO en Beta 1.** Post-Beta.

### 16.1 Principios

- **AI propone, nunca publica.** (Per Vision canonical.)
- AI sólo puede sugerir shapes del registry. Si el usuario describe algo que no calza, AI dice "No tengo un Lego para eso. Lo paso a tu founder para revisión" y crea un `feature_request`.
- AI valida capabilities requeridas. Si faltan, AI propone activarlas como parte del draft.
- AI muestra el preview en lenguaje humano antes de cualquier acción.

### 16.2 Flujo

```
User: "Quiero que si alguien falta 3 veces seguidas, pierda prioridad."

LLM (con system prompt que incluye registry de shapes):
  → identifica intent: reputation_adjustment + condition history.count
  → en Beta 1 no existe shape; AI dice:
     "Aún no tenemos un Lego para 'perder prioridad por faltas'.
      Lo más cercano es 'multa por inasistencia' o 'warning'.
      ¿Quieres alguno de esos, o lo mandamos como sugerencia para crear?"

Post-Beta cuando exista shape `reputation_adjustment`:
LLM:
  → propone draft con shape=reputation_adjustment,
     params={trigger_count: 3, window: '4_events', adjustment: -1}
  → muestra preview
  → pide confirmación
  → cliente llama publish_rule_version exactamente como si lo hubiera armado el humano
```

### 16.3 Guardrails

- LLM no recibe DB access. Sólo:
  - registry de shapes (JSON)
  - lista de capabilities del grupo
  - lista de roles del grupo
  - 5 reglas recientes para contexto
- Output del LLM es JSON estructurado validado por schema en cliente antes de pasar al builder.
- Toda sugerencia AI deja audit row `ai_suggestions(rule_draft_id, prompt, model, accepted)`.
- AI nunca llama publish directamente. Siempre pasa por el builder con preview obligatorio.

---

## 17. Examples completos por vertical

> Para cada ejemplo: copy UI, JSON interno, atoms emitidos, projection afectada, posible conflict.

### 17.1 Equipo de fútbol — Primeros 11 titulares

**UI:**
> "Cuando alguien haga check-in al partido, si está entre los primeros 11 elegibles, queda titular. Si ya hay 11, va a banca."

**JSON interno (compiled):**
```json
{
  "shape_id": "first_come_first_served",
  "trigger": "check_in.created",
  "scope": { "type": "resource_type", "value": "event" },
  "target": { "type": "ref", "value": "$trigger.actor" },
  "shape_params": { "limit": 11, "winner_role": "starter", "loser_role": "bench" },
  "conditions_winner": [
    { "var": "actor.is_eligible", "op": "==", "value": true },
    { "var": "rank(actor, projection.check_in_order)", "op": "<=", "value": 11 }
  ],
  "consequences_winner": [
    { "type": "assign_participant_role", "role": "starter", "target": "$target" }
  ],
  "consequences_loser": [
    { "type": "assign_participant_role", "role": "bench", "target": "$target" }
  ]
}
```

**Atoms emitidos:** `system_events(role_assigned)` por cada check-in. **Nota:** `participant.assigned_role` es **atom**; `event_lineup_view` es **projection** derivada. Si el capitán hace override (post-Beta), emite `system_events(role_override_applied)` — NUNCA `UPDATE lineup`.

**Projection:** `event_lineup_view` lee `system_events(role_assigned)` y produce starters/bench.

**Conflicto potencial:** otra regla "los 5 mejores rankeados son titulares automáticos" → conflict `contradictory_consequences` → blocking.

### 17.2 Cena — Multa por no avisar

**UI:**
> "Si no avisas si vas a la cena antes del jueves a mediodía, se cobra $100. Tienes 24h para apelar."

**JSON:**
```json
{
  "shape_id": "deadline_enforcement",
  "trigger": "event.deadline_passed",
  "scope": { "type": "series", "value": "<cenas_series_id>" },
  "shape_params": {
    "required_action": "rsvp_yes_or_no",
    "consequence": "fine",
    "amount": 100,
    "appeal_window_hours": 24
  }
}
```

**Atoms:** `ledger_entries(fine)` + `system_events(fine_issued)` + (si appeal) `pending_changes(appeal)`.

### 17.3 Palco — Reserva con aprobación si es final

**UI:**
> "Si un socio reserva el palco para un partido de fase final, requiere aprobación del consejo."

**JSON:**
```json
{
  "shape_id": "approval_threshold",
  "trigger": "booking.requested",
  "scope": { "type": "resource", "value": "<palco_id>" },
  "shape_params": {
    "threshold_field": "event.metadata.stage",
    "threshold_op": "in",
    "threshold_value": ["semifinal","final"],
    "decision_mode": "approval_by_role",
    "approver_role": "consejo"
  }
}
```

**Atoms:** `pending_changes(approval)` + `system_events(approval_requested)`.

### 17.4 Roommates — Gasto grande requiere voto

**UI:**
> "Si alguien registra un gasto mayor a $2,000, abre votación de todos para aprobar."

**JSON:**
```json
{
  "shape_id": "approval_threshold",
  "trigger": "ledger_entry.created",
  "scope": { "type": "group" },
  "shape_params": {
    "threshold_field": "trigger.amount",
    "threshold_op": ">",
    "threshold_value": 2000,
    "decision_mode": "vote_simple_majority",
    "voter_pool": "all_members"
  }
}
```

### 17.5 Fund — Aporte mensual obligatorio

**UI:**
> "Cada mes, todos los miembros deben aportar $500 al fondo antes del día 5."

**JSON:**
```json
{
  "shape_id": "deadline_enforcement",
  "trigger": "event.deadline_passed",   // synthetic monthly deadline event
  "scope": { "type": "resource", "value": "<fund_id>" },
  "shape_params": {
    "required_action": "ledger_contribution",
    "amount": 500,
    "consequence": "warning"
  }
}
```

> Nota: este caso requiere `recurrence_rule` para generar deadlines mensuales sintéticos. Post-Beta. En Beta 1, admin crea el deadline event manualmente cada mes.

### 17.6 Space — Sin empalmes

**UI:**
> "No se permite reservar la cancha si ya hay otra reserva en el mismo horario."

**JSON (post-Beta, requiere `booking_conflict` shape):**
```json
{
  "shape_id": "booking_conflict",
  "trigger": "booking.requested",
  "scope": { "type": "resource", "value": "<cancha_id>" },
  "shape_params": { "overlap_behavior": "deny", "grace_minutes": 0 }
}
```

### 17.7 Community — Nuevos miembros requieren voto

**UI:**
> "Si alguien quiere unirse al grupo, abre votación. Si la mayoría aprueba, entra."

**JSON:**
```json
{
  "shape_id": "approval_threshold",
  "trigger": "member.invited",
  "scope": { "type": "group" },
  "shape_params": {
    "threshold_field": null,
    "decision_mode": "vote_simple_majority",
    "voter_pool": "all_members"
  }
}
```

> Nota: `member.invited` no escribe `group_members` hasta resolución del voto. Esto es pre-write (riesgoso, post-Beta). En Beta 1, el miembro entra y un admin puede `remove_member` si vota fallido.

---

## 18. Guardrails (qué bloquear vs advertir)

### 18.1 Bloqueos duros (no se puede publish)

- Shape no existe en registry server-side.
- Param requerido faltante o fuera de rango.
- Capability requerida no está habilitada en el resource.
- Conflict tipo `contradictory_consequences` con regla activa.
- Condition imposible.
- Consequence `start_vote` sin votantes elegibles.
- `effective_from` retroactivo (no soportado en Beta 1).
- Permission insuficiente (`groups.roles.rules.author` no incluye al actor).

### 18.2 Advertencias (se puede publish con confirmación)

- `same_scope_overlapping` (warning).
- Consecuencia monetaria sin appeal window configurado (recomienda).
- Rule sin `change_reason`.
- Rule muy compleja (>3 conditions) — sugerir simplificar.

### 18.3 Prohibiciones de sistema (no negociables)

- No client-side enforcement of consequences (cliente jamás escribe atoms; siempre vía RPC).
- No arbitrary code execution.
- No loops (engine detecta `rule_evaluations` con misma `(rule_id, actor_id)` >10 en <1s y aborta).
- No double-fine (idempotency_key garantiza).
- No silent rule execution (todo deja `rule_evaluations`).
- No AI auto-publish.
- No edit sin nueva versión.

---

## 19. Implementation roadmap

### 19.1 Beta 1 (~4 semanas)

**Semana 1 — Foundations**
- Migraciones DB: `rules`, `rule_versions`, `rule_evaluations`, `rule_conflicts`, `member_capability_overrides`.
- RPC `publish_rule_version(group_id, draft jsonb)` con validación + conflict detection.
- RPC `deactivate_rule(rule_id, reason)`.
- Edge function `_shared/ruleShapes.ts` con los 5 shapes Beta 1.
- Edge function `_shared/ruleEngine.ts` actualizado para usar shape registry.

**Semana 2 — Engine**
- Engine evalúa los 5 shapes contra atoms reales.
- Idempotency, retries, ordering.
- Atom-side wiring: `record_system_event` + RPCs especializados para consequences.
- Tests: fixtures por shape + edge cases.

**Semana 3 — iOS**
- `RuulCore`: domain models + shape registry mirror + repositories (Mock + Live).
- `RuulFeatures/Rules`: builder views (scope, gallery, params, preview, publish).
- `RulePreviewGenerator` con `.strings` localización es-MX.
- Snapshot tests + Swift Testing.

**Semana 4 — Polish**
- `RulesListView` por grupo.
- `RuleDetailView` con version history.
- Conflict warnings UI.
- Integration con `Settings → Governance`.
- Beta testing en cenas + 1 grupo de fútbol amigo.

### 19.2 Post-Beta (orden de prioridad)

1. Member propose + admin approve workflow.
2. Conflict detection extendido (loops, deadlocks).
3. Simulation / dry run.
4. Shapes 8–19 (priority_allocation, guest_limit, booking_conflict, …).
5. AI assistant.
6. Recurrence rules.
7. Custom Lego Builder (último — solo si datos lo justifican).

### 19.3 NO construir

- Custom Lego Builder en Beta 1.
- AI auto-publish (jamás).
- Pre-write engine (a menos que un caso real lo exija).
- Editor visual de árbol de reglas con drag&drop.
- Multi-tenant rule sharing entre grupos ("usa la regla de los X").
- DSL textual expuesto al usuario.
- Rule marketplace.

---

## 20. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| **Shape registry crece sin control** | Alta | Alto | Política: nuevo shape requiere 2+ casos reales documentados antes de añadirse. |
| **Conflictos no detectados en publish-time** | Media | Alto | Tests por shape pair en CI + audit periódico de `rule_evaluations` con verdict='error'. |
| **Users frustrados porque "no se puede" hacer X** | Alta (en Beta 1) | Medio | "Pedirle a tu founder" CTA visible; track de feature requests en backlog. |
| **Engine se ahoga si muchos atoms** | Media | Alto | Cron batch + queue por grupo; engine corre por grupo, no global. |
| **Reglas viejas confunden después de cambios** | Media | Medio | `effective_until` muestra "esta regla aplicó hasta…"; UI siempre marca versión. |
| **AI sugiere shapes que no calzan** | Media | Bajo | AI sólo propone; preview obligatorio; humano confirma. |
| **Idempotency key colisiona** | Baja | Crítico | `idempotency_key = sha1(rule_version_id || trigger_event_id || actor_id || consequence_index)`. UNIQUE constraint absorbe. |
| **Replay rompe estado** | Baja | Crítico | Replay siempre dry-run; nunca escribe. |
| **Rule no-author members rage-publish vía proposal** | Baja | Medio | Admin approval required (default); rate-limit propose por miembro. |
| **Performance de history scans** | Media | Medio | Index sobre `system_events (group_id, event_type, actor_id, created_at)`; cache LRU en engine por evaluación. |
| **Migración de datos pre-rule** | Alta | Bajo | No retroactivo. `effective_from = now`. Atoms previos se quedan sin reglas evaluadas. |

---

## 21. Final architecture summary

### 21.1 Two-line summary

> **Governance en Ruul = capa 8 declarativa.** Resources son qué existe; capabilities qué se puede; rules qué se permite/requiere/prohíbe **bajo condiciones**, expresado como **shapes pre-validados con parámetros**, ejecutado **server-only** emitiendo **atoms inmutables**, derivado a **projections** recomputables, **versionado** para audit y **descrito en lenguaje humano** para usuarios que no saben programar.

### 21.2 Cardinal rules (no negociables)

**Capa ontológica (heredada de Vision.md):**

1. Resources define what exists.
2. Capabilities define what can happen.
3. **Rules define what is allowed, required, or forbidden — vía shapes parametrizados.**
4. Atoms record what actually happened.
5. Projections derive current reality.
6. **El usuario nunca escribe código.**
7. **Engine es server-only.**
8. **Una rule jamás muta estado directo. Emite atoms.**
9. **Toda rule está versionada.**
10. **AI propone, humano publica.**
11. **JSONB controlado por shape registry. No mesas innecesarias.**
12. **No expongas jargon. Habla humano.**

**Capa governance-específica (constitución del Rule Builder, post-review):**

13. **Rules govern behavior, not arbitrary state.** Governance controla user-facing behavior, permisos, consequences, workflows y obligations. Nunca infraestructura (caches, queues, sync, config).
14. **In Beta 1, all rules are post-atom.** El trigger ya escribió su atom; la rule reacciona. No hay pre-write deny.
15. **No `deny_action` in Beta 1.** Etiquetar consequence (waitlist, violation, warning, review, approval) > rechazar atom original.
16. **Consequences emit atoms or workflows only.** No mutations directas, no escrituras laterales.
17. **Workflow state is not final truth; outcomes must emit atoms.** `pending_changes.status='approved'` coordina; `system_events(booking_confirmed)` es verdad.
18. **`rule_evaluations` are technical audit, not user activity.** User feed muestra qué pasó (atom de consequence), no qué se evaluó.
19. **Scope is where a rule applies; target is what a consequence affects.** Separar estos dos campos en el JSON.
20. **Persistent role changes require workflow/admin approval.** `assign_participant_role` (contextual al resource) = OK automático. `assign_relation_role` (treasurer/captain del grupo) = nunca automático; pasa por approval.
21. **(Corregido 2026-05-14 / Draft 3 — ver §0.5)** *Rule shapes are runtime-declarative building blocks. Rule templates are curated product-level recipes. The engine only executes compiled rule versions. The client may render from runtime shape/template catalogs, but the server validates and compiles everything before publish.* Shape pieces viven en `public.rule_shapes` (data observable, runtime-declarative, preserva founder principle 2026-05-10). Templates viven canonical en TS code + mirror en `public.rule_templates`. Evaluadores (ejecución) viven en TS server-side. Capabilities catalog vive como data.
22. **Every shape requires fixtures and conflict signature.** Mínimo 5 fixtures (incluyendo edge cases) + `conflict_signature` fingerprint server-side. Sin esto, el shape no entra a producción.

**Y la frase que ata todo (epígrafe del documento):**

> **User-configurable parameters, not user-programmable logic.**

### 21.3 Diagrama mental

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            GROUP (capa 1)                               │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                       RESOURCES (capa 3-4)                      │   │
│  │  ┌──────────┐ ┌──────┐ ┌──────┐ ┌───────┐ ┌──────┐ ┌──────┐    │   │
│  │  │  event   │ │ fund │ │asset │ │ space │ │ slot │ │right │    │   │
│  │  └──────────┘ └──────┘ └──────┘ └───────┘ └──────┘ └──────┘    │   │
│  │                                                                 │   │
│  │            CAPABILITIES (capa 5) — qué se puede hacer           │   │
│  │   [scheduling][rsvp][check_in][booking][ledger][voting][…]      │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                            │                                            │
│                            ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │              GOVERNANCE LAYER (capa 8)                          │   │
│  │                                                                 │   │
│  │   ┌────────────┐  ┌────────────┐  ┌────────────┐               │   │
│  │   │   RULES    │  │  POLICIES  │  │ PERMISSIONS│               │   │
│  │   │  (shapes)  │  │ (meta-rules│  │  (roles)   │               │   │
│  │   └─────┬──────┘  └────────────┘  └────────────┘               │   │
│  └─────────┼───────────────────────────────────────────────────────┘   │
│            │                                                            │
│            │ triggered by atom                                          │
│            ▼                                                            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                  RULE ENGINE (server-only)                      │   │
│  │  load → sort precedence → eval conditions → exceptions →        │   │
│  │  emit consequences → write atoms/workflows →                    │   │
│  │  record rule_evaluations → invalidate projections               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│            │                                                            │
│            ├──→ ATOMS (system_events, ledger_entries, …)               │
│            ├──→ WORKFLOWS (votes, pending_changes, …)                  │
│            └──→ NOTIFICATIONS (outbox → APNs)                          │
│                                                                         │
│                            ▼                                            │
│            PROJECTIONS recompute (balance, attendance, lineup…)        │
└─────────────────────────────────────────────────────────────────────────┘
```

### 21.4 Beta 1 entregable mínimo

- **5 rule templates** curados operativos end-to-end, todos *attendance + fine* (DB seed mig 00171 → publish RPC → engine reusa evaluadores existentes → iOS UI). Templates Beta 1: `late_arrival_fine`, `no_show_fine`, `same_day_cancel_fine`, `no_rsvp_fine`, `host_no_menu_fine`. **Cada uno compone shape pieces YA existentes en `public.rule_shapes` — zero engine code nuevo.** Templates exóticos (rotating_host, first_n_starters, expense_requires_approval) → Post-Beta, requieren nuevos evaluadores TS.
- **Preservación de lo consolidado:** `public.rule_shapes`, `list_rule_shapes`, `LiveRuleShapeRepository`, `EditRulesView` (admin-only en Beta 1). Cero rip.
- **Builder de 3 fases visibles** (Elige Template → Llena huecos → Activa) con 8 stages internos vía progressive disclosure.
- **Consequences post-atom seguras:** `assign_participant_role`, `assign_to_waitlist`, `mark_violation`, `emit_warning`, `require_review`, `start_approval`, `start_vote`, `record_ledger_entry`, `issue_fine`, `send_notification`. **NO** `deny_action` ni `assign_relation_role` automático.
- **Shape Contract enforcement:** todo shape registrado declara fixtures ≥5, conflict signature, supported_scopes, projection_dependencies. CI bloquea release sin estos.
- **Versionado completo** + history view + scope/target separation en JSON.
- **Conflict detection básico:** contradictory_consequences, same_scope_overlapping, impossible_condition, consequence_missing_capability.
- **Permission gating:** admin-only crear/editar/desactivar. Treasurer/captain/member-propose: Post-Beta.
- **Audit routing correcto:** consequences emitidas van a History feed; `rule_evaluations` queda como audit técnico accesible sólo desde `RuleDetailView → Activity`.
- **Effective context documentado** (snapshot policy declarada aunque no implementada al 100% en Beta 1).
- `member_capability_overrides` (no `relation_capability_overrides` aún) para casos tipo "David fuera de rotativa".

Punto.

### 21.5 Postura final

Este sistema es **deliberadamente conservador en superficie** y **opinionado en arquitectura**:

- Shape registry como código (no datos de usuario) es la decisión más importante. Es lo que hace que "armar Legos" se sienta seguro: el usuario no puede construir piezas inválidas porque las piezas son código auditado.
- JSONB controlado > tablas: 90% de lo que otros equipos modelan como tablas (conditions, consequences, exceptions, simulations) aquí vive como JSONB validado por el shape registry. Eso recorta la superficie 5x sin perder auditabilidad.
- Engine server-only y append-only de versions garantizan que la fuente de verdad es siempre reproducible. Replay, dry-run, AI assistant — todo se construye encima sin reescribir el core.
- El UX se obsesiona con la frase humana. La frase **es** la regla; el JSON es trivia interna. Si la frase está rota, la regla está rota.

Si todo lo demás falla y solo construimos los 5 shapes Beta 1 con builder + engine + versioning + history feed: **Ruul ya tiene governance real**, mejor que cualquier herramienta de coordinación grupal en el mercado. Recordatorio cardinal: **user-configurable parameters, not user-programmable logic.**

---

## 22. Límites conocidos del Rule Composer (post-2026-05-17)

> Status: documentado 2026-05-17 después del aterrizaje del composer
> libre (mig 00245-00246, commits 5a2d7b9 … 89519d2). Estos son los
> gaps que el composer NO cubre todavía. Cada uno está alineado con la
> doctrina (§9 scope, §18 estructura halájica) pero requiere trabajo
> incremental. El orden de implementación es **demand-pull**: se ataca
> el que aparezca primero con un grupo beta real, no el que parezca
> arquitectónicamente más bonito.

### 22.1 Edit-in-place sin perder `rule_id` (severidad: **alta**)

Hoy `publish_rule_composition` siempre crea una nueva fila en `rules`
con un `rule_id` distinto. Eso significa que **editar el monto de una
multa** (caso 1 de cualquier beta tester) rompe la continuidad de
atoms históricos: las fines emitidas referenciarán el `rule_id` viejo
+ las nuevas el `rule_id` nuevo. El `slug` ayuda a deduplicar
analíticamente, pero no es lo mismo.

Falta: RPC `bump_rule_version(p_rule_id, p_new_composition, p_change_reason)`
que:

- Verifica `has_permission('modifyRules')` + ownership del rule por el
  grupo del caller.
- Marca el `rule_versions` actual como `superseded`.
- Inserta nuevo `rule_versions` con `version+1`, mismo `rule_id`,
  `previous_version_id` apuntando al anterior.
- Actualiza `rules.trigger/conditions/consequences/updated_at` con la
  nueva composición.
- Re-validate compatibility (trigger ↔ scope ↔ resource_type) y
  conflict detection.

UI: el composer abre con `RuleDraft.from(rule:)` cuando se invoca con
un `editing: rule` en vez de scope vacío. Botón "Publicar" llama
`bump_rule_version` en vez de `publish_rule_composition`.

### 22.2 Exceptions evaluables por el engine (severidad: **media**)

El JSON compilado ya carga `exceptions: []` (mig 00245). El engine
nunca lo lee. Talmud sin excepciones es solo medio Talmud — "todos
pagan EXCEPTO si tienen circunstancia X" es estructura fundamental.

Falta:

- Schema decision: ¿exceptions como lista de conditions invertidas
  (lo más simple, AND NOT), o como predicate tree separado?
- Engine: extender `ruleEngineConditions.ts` o introducir
  `ruleEngineExceptions.ts` que se ejecuta DESPUÉS de conditions, y
  si alguna pasa, skipea la consequence.
- UI composer: tercera sección entre conditions y consequences,
  "Excepto si…" con su propio `+`.
- Sentencia natural: "Cuando X, si Y, **excepto** si Z, entonces W."

### 22.3 Multi-target / subject distinto al actor (severidad: **media-baja**)

`compiled.target = "$trigger.actor"` está hardcoded. No se puede armar
"cuando alguien transfiere $X de un activo, **notifica al tesorero**".

Falta:

- Schema: `compiled.target` acepta más opciones: `$trigger.actor`,
  `$role.<role_id>` (todos los holders de un rol), `$member.<uuid>`
  (explícito), `$resource.host` (member en metadata).
- Engine: trigger evaluators emiten targets según resolución del
  selector, no hardcoded al actor.
- UI composer: picker "a quién aplica esta consecuencia" entre cons
  shape y sus params.

Caso clásico anti-tirania: notifica al treasurer cuando alguien
intenta retirar > $X. Hoy no es expresable como regla — hay que
hardcodearlo via permission gate del RPC.

### 22.4 Conditions con árbol (AND/OR/NOT) (severidad: **media**)

Hoy `conditions[]` es lista AND plana. Para "fine si [late AND no
excuse] OR [no-show]" hay que publicar 2 reglas separadas y aceptar
que aparezcan duplicadas en analytics.

Falta:

- Schema: `conditions` pasa de `[c1, c2]` a `{op: 'and', children:
  [c1, c2]}` con `op` ∈ `{and, or, not}`. Backward compat: el array
  plano se interpreta como `{op: 'and', children: array}`.
- Engine: condition evaluator recursivo.
- UI: el composer actual asume lista plana. Editor de árbol es UX
  fork — probable que se difiera hasta que aparezca un grupo que
  pida la 3a o 4a regla compuesta.

### 22.5 Scope `membership` + `module` en el picker (severidad: **baja**)

Schema ya soporta `rules.membership_id` (mig 00078) y `rules.module_key`
(mig 00074). UI composer solo expone resource / series / group. Faltan:

- Membership: picker de miembro al elegir scope. Util para "esta regla
  aplica solo a Isaac (que está fuera de rotativa)".
- Module: picker de módulo activo al elegir scope. Útil para
  consolidar rules con el módulo que las introduce.

Demand-pull bajo: los pocos casos hoy se cubren con scope=resource o
scope=group + miembro-condition.

### 22.6 Otros límites menores (severidad: **baja**)

| Área | Limitación | Workaround |
|---|---|---|
| Sentencia natural | "multa (cantidad: $200)" rough; falta plantilla de frase per-shape | Aceptable para Beta 1; añadir `rule_shapes.sentence_template_es` cuando UX feedback lo demande |
| Consequence ordering | Lista ordenada pero UI no permite reorder ni "stop on failure" | Drag-reorder + flag al menú del row cuando aparezca caso real |
| AI suggest drafts | Constitution §16 lo permite ("AI propone, nunca aplica"). Composer no integra. | Phase Projections (§16 sección dedicada existe pero engine ausente) |
| Trigger metadata stringly-typed | Cada trigger evaluator accede `context.resource.metadata.host_id` etc. sin schema | Add JSON Schema per resource_type cuando Phase 2 expanda más tipos |

### 22.7 Lo que NO es límite (frontera explícita por diseño)

- **Nuevo trigger/condition/consequence = release**, no INSERT data only.
  Constitution §0.5 lo declara: shape registry expone building blocks
  pero **semántica vive en código TS auditable**. Esto es feature, no
  bug — es lo que hace seguro componer (no se pueden armar piezas
  inválidas porque las piezas son código auditado).
- **Resource types frozen a 6** (Constitution §2). Añadir un tipo
  nuevo es decisión arquitectónica con filtro ontológico §13.
- **AI no muta estado directo** (Constitution §16). Cualquier propose
  pasa por workflow humano verificable.

### 22.8 Orden de ataque sugerido

1. **22.1 Edit-in-place** — caso #1 que aparece en beta. RPC + iOS
   integration es ~3 commits.
2. **22.2 Exceptions** — doctrinal, "regla y excepción" es estructura
   halájica fundamental.
3. **22.3 Multi-target** — anti-tirania pattern. Útil para grupos
   formales (asociaciones, comunidades religiosas).
4. **22.4 Tree conditions** — el más invasivo (engine + UI), se queda
   al final.
5. **22.5+22.6** — picotear cuando UX feedback lo demande.

No construir las 4 a ciegas. Esperar a que un grupo beta haga
explícitamente la petición → atacar esa, instrumentar, repetir.
