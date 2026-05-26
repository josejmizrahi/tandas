# Ruul — Rules vs Money Doctrine

**Status:** Canónico desde 2026-05-18. Founder directive.
**Companion of:** `Plans/Active/RuleEngineDoctrine.md` (engine es server-only, append-only, mutates nothing), `Plans/Active/AtomProjection.md` (atom = truth, projection = interpretation), `Plans/Active/ProjectionDoctrine.md` (declaración obligatoria de projections), `Plans/Active/OperationalCacheDoctrine.md` (Prohibición 2 — money state nunca es cache), `Plans/Active/UniversalRuleTemplates.md` (templates son patrones universales, no features verticales), `Plans/Active/Constitution.md` (Artículo 14 — fine projection sobre ledger), `Plans/Active/ConsistencyAudit_2026-05-17.md` (Axiom 8 — Fund ≠ Ledger; Axiom 14 — Rule ≠ Mutation).
**Sibling deliverables:** `Plans/Active/ObligationsProjectionDoctrine.md`, `Plans/Active/ConsequenceArchitecture.md`, `Plans/Active/RulesFinesAudit_2026-05-18.md`, `Plans/Active/RulesFinesRefactorPlan.md`.

> **Rules define WHEN consequences happen. Consequences may create obligations. Ledger entries are the economic truth. Balances and fines are projections.**
>
> **Governance is not accounting. Accounting is not governance. Rules coordinate behavior. Ledger records economic reality.**

> **El error doctrinal en Ruul al 2026-05-18:** UI, modelos Swift y copy de templates siguen tratando "rule = fine = money" como una sola cosa. `GroupRule.amountMXN` y `GroupRule.fineShape` leen una rule como si fuera una multa. `OnboardingRuleDraft.amountMXN` setter escribe directo al primer `fine` consequence. Templates antiguos (`late_arrival_fine`, `no_show_fine`) están aliased a universales pero el copy ("se le cobra"), las cards y la pestaña de Resource Detail llamada "Reglas" siguen acoplando los tres conceptos. Backend está sano (ledger_entries + fines_view + atoms) pero la doctrina cliente lo traiciona.

---

## §1 — Los 3 axiomas canónicos

### Axioma 1 — Rule ≠ Fine

Una rule define:

- 1 trigger (qué ocurre)
- 0..N conditions (cuándo aplica)
- 1..N consequences (qué se hace)

Una **fine** es exactamente UNA de las consequences posibles. Las demás familias canónicas viven en `Plans/Active/ConsequenceArchitecture.md`:

- **Economic** — `fine`, `refund`, `contributionRequired`
- **Coordination** — `releaseBooking`, `bumpPriority`, `requireApproval`, `lockBookings`
- **Access** — `suspendRight`, `revokeRight`
- **Social** — `emitWarning`, `denyAction`, `sendNotification`

**Implicaciones:**

- No existe la categoría "fine rule". Existe rule, y dentro la consequence puede ser fine.
- Ningún template universal puede asumir consequence=fine (`missed_obligation_consequence` se llama "consequence" precisamente para no encadenar el patrón al dinero).
- Ningún property/método sobre `GroupRule` o `RuleDraft` puede llamarse `amountMXN`, `fine*`, ni asumir que el primer consequence es siempre fine.

### Axioma 2 — Fine ≠ Ledger

Una **fine** es un instrumento con identidad (id, group, member, rule_id, resource_id, amount). Pero **no es economic truth**.

Economic truth = `ledger_entries` (Atom, Taxonomy §2.E).

Sobre `ledger_entries` viven los tipos canónicos:

```
contribution     — aportación a un fund/pot
expense          — gasto reportado por un miembro
payout           — pago del grupo a un miembro
fine_issued      — atom de issuance (== officialize de la multa)
fine_paid        — atom de payment
fine_voided      — atom de anulación
refund           — reverso de un pago
settlement       — cierre directo de IOU entre miembros
reimbursement    — devolución de gasto reportado
transfer         — movimiento neutro
```

**La fine "está pagada" = existe un `ledger_entries(type='fine_paid', metadata.fine_id=X)`. Punto.**

Toda mutable `paid` flag, `paid_at` column, `waived` column, `waived_at`, `waived_reason` sobre la tabla `fines` es **deuda doctrinal transitoria** (ver `RulesFinesAudit_2026-05-18.md` §3.B). El `fines_view` (mig 00149) ya proyecta los campos desde atoms; Constitution §14 Step 3c dropea las columnas storage después del audit close.

**Implicaciones:**

- Ninguna RPC nueva muta `fines.paid`, `fines.waived`, `fines.status`. Mutaciones van vía atoms (`pay_fine` / `void_fine` / `officialize_fine` que emiten ledger_entries).
- Ningún reader Swift puede confiar en `Fine.paid` o `Fine.status` como source-of-truth — debe leer de `fines_view` (que sí los deriva).
- Ningún campo `balance` mutable sobrevive. Balance = `member_balances_per_resource` view (mig 00136) o `fund_balance_view` (mig 00203).

### Axioma 3 — Obligation ≠ Rule

Una rule puede **emitir** un obligation atom. Pero el obligation no es la rule.

Ejemplos:

- "José debe $500 por una multa officialized" → projection sobre `ledger_entries(type='fine_issued', from_member_id=José)` no offset por `fine_paid` o `fine_voided`.
- "Daniel tiene un damage_reported sin resolver" → projection sobre `damageReported` atoms sin matching `damageResolved`.
- "Alan perdió prioridad de booking" → projection sobre `bumpPriority` consequence atoms restando del rank actual.

Las obligations son **derivables** desde atoms. No persisten verdad independiente. Detalle completo en `Plans/Active/ObligationsProjectionDoctrine.md`.

---

## §2 — Arquitectura objetivo (3 capas)

```
┌──────────────────────────────────────────────────────────────┐
│ RULES LAYER                                                  │
│   rules / rule_versions / rule_evaluations                   │
│   responsibilities: evaluación, timing, condiciones,         │
│                     emisión de consequence intent            │
│   forbidden: balance state, money totals, fine status truth  │
└────────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼ emits consequence intent
┌──────────────────────────────────────────────────────────────┐
│ CONSEQUENCE LAYER                                            │
│   ConsequenceType + ConsequenceSink (server-side)            │
│   responsibilities: normaliza intent en acciones canónicas;  │
│                     llama RPC canónico que emite atom        │
│   forbidden: UPDATE directo a state tables                   │
└────────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼ emits atom (record_system_event,
                                              ledger_entries INSERT,
                                              user_actions INSERT, …)
┌──────────────────────────────────────────────────────────────┐
│ LEDGER + ATOM LAYER                                          │
│   ledger_entries (money atom)                                │
│   system_events (general atom)                               │
│   bookings / rsvp_actions / check_in_actions (typed atoms)   │
│   responsibilities: ÚNICA verdad económica + de coordinación │
│   forbidden: mutable balance, mutable paid flag              │
└────────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼ feed projections
┌──────────────────────────────────────────────────────────────┐
│ PROJECTION LAYER                                             │
│   fund_balance_view / fines_view / member_balances_*         │
│   outstanding_fines_view / member_obligations_view (futura)  │
│   responsibilities: interpretación user-facing y             │
│                     engine-facing; recomputable desde atoms  │
│   forbidden: persiste verdad independiente                   │
└──────────────────────────────────────────────────────────────┘
```

**Cada capa es read-only sobre la capa de abajo.** Ninguna escribe atrás.

---

## §3 — Las 7 reglas de aislamiento

### Regla 1 — Rules no escriben money

El rule engine NUNCA hace:

```sql
UPDATE fines SET paid = true WHERE …;
UPDATE groups SET fund_balance = fund_balance + N;
UPDATE resources SET metadata = jsonb_set(metadata, '{balance}', …);
```

El engine SOLO emite consequence intents. La consequence sink llama el RPC canónico (`officialize_fine`, `pay_fine`, `void_fine`, `record_ledger_entry`) que internamente hace `INSERT INTO ledger_entries`. Esa es la única write path doctrinal.

### Regla 2 — Money no se lee como rule logic

El rule engine puede leer **projections** atom-derived (`fund_balance_view`, `member_balances_per_resource`) para evaluar `condition.amountAbove(2000)`. NUNCA lee de:

- `groups.fund_balance` (dropeado mig 00078, todavía referenciado por `pay_fine` antes del fix mig 00273)
- `resources.metadata.balance`
- Cualquier mutable balance field

### Regla 3 — Templates no nombran instrumentos

`template_id` describe el patrón social (`missed_obligation_consequence`), no el instrumento (`late_fee_rule`, `rsvp_fine`). Lista canónica en `UniversalRuleTemplates.md` §3.

`template.description_es` describe la coordinación, no el dinero. Reemplazar copy:

| Antes (heresy) | Después (doctrina) |
|---|---|
| "Si alguien llega tarde, se le cobra $200." | "Si alguien llega tarde, se aplica la consecuencia configurada." |
| "Cuando alguien no avisa, paga una multa." | "Cuando alguien no cumple la obligación, se ejecuta la consecuencia." |
| "Multa por no llegar" | "Consecuencia por no asistir" |

La instancia del grupo SÍ puede llamarse "Multa por llegar tarde" (`rules.label_es`) — el template subyacente queda universal.

### Regla 4 — Capabilities no son fines

NO existe:

- `fines_enabled` capability
- `fines` module (legacy `basic_fines` module sigue por compat, pero no se crean nuevos)
- "fine capability" o "penalty capability"

SÍ existen:

- `permissions`: `issueFine`, `markFinePaid`, `voidFine` (mig 00233) — son **acciones**, no capabilities. Permission gating de RPCs.
- Module → capabilities → rules → consequences es el pipeline. Una capability puede habilitar rules que en su consequence usan `fine`, pero la capability no se llama "fine".

### Regla 5 — UI separa rules, money y governance

Resource detail tabs (ver `UniversalResourceDetailView.swift:391-397` — `.overview`, `.activity`, `.rules`, `.connections`, `.governance`) deben evolucionar:

| Tab | Doctrina |
|---|---|
| `.rules` | SOLO definiciones de rules (trigger, conditions, consequences, scope, source). Cero balances. Cero deudas. |
| `.money` (nueva) | Ledger entries del resource, balances per miembro derivados, fines pendientes/pagadas/voided del resource. |
| `.obligations` (nueva, futura) | Projection consolidado de **obligations abiertas** que un miembro tiene relacionadas al resource (pending fines + unpaid contributions + unresolved damages). |

Copy humano en `.money`:

- "Pendientes" / "Saldo" / "Pagos recientes" / "Aportaciones"
- **NO:** "Reglas" / "Castigos" / "Multas del sistema"

Copy humano en `.rules`:

- "Cuándo se aplica" / "Qué se hace" / "Origen de la regla"
- **NO:** "Saldo pendiente" / "Multa actual" / "Cuánto debes"

### Regla 6 — Consequence sinks son normalizables

Cualquier `ConsequenceType` nuevo sigue el shape del Consequence Architecture doc:

```
{ type: <verb>, target: <selector>, params: <typed config> }
```

`type` es uno de la familia canónica (`fine`, `requireApproval`, `lockBookings`, `denyAction`, `bumpPriority`, `revokeRight`, `suspendRight`, `releaseBooking`, `emitWarning`, …). NO existe `fine_for_late_arrival` ni `fine_with_grace`. Diferencias se modelan vía `params`, no vía type explosion.

### Regla 7 — Projections declaran obligación de proveniencia atómica

Toda projection que muestre money, fines, balances u obligations cumple las **8 declaraciones** de `ProjectionDoctrine.md` §1, especialmente:

1. **Source atoms** declarados explícitamente — `ledger_entries`, `system_events`, `bookings`, `rsvp_actions`.
2. **Reduction logic** determinístico, sin `now()` dependant.
3. **Recomputable** — `DROP VIEW; CREATE VIEW` produce el mismo resultado.

`fines_view` (mig 00149) ya cumple. `outstanding_fines_view`, `member_obligations_view`, `penalties_view` son las próximas — viven en `ObligationsProjectionDoctrine.md`.

---

## §4 — Las 5 frases prohibidas en producto

Estas aparecen hoy en código, copy o specs y deben desaparecer:

| Frase | Por qué prohibida | Reemplazo |
|---|---|---|
| "Rule has amount" | Asume consequence=fine como single source. | "Rule's first fine consequence has amount." |
| "Late fee rule" | Template name money-coupled. | "Deadline Enforcement template (consequence=fine)." |
| "Fine balance" | Confunde instrumento con economic truth. | "Outstanding fine total (projection over ledger_entries)." |
| "Mark rule as paid" | Rules no se pagan; obligations sí. | "Mark fine as paid → emits fine_paid ledger atom." |
| "Penalty governance" | Mezcla economic consequence con meta-rule layer. | "Penalty is a consequence; governance is the rule that emits it." |

---

## §5 — Convivencia con la deuda transitoria

Hasta que se ejecute `RulesFinesRefactorPlan.md` post audit-close, la doctrina **admite** los siguientes patrones como deuda documentada:

| Patrón | Por qué admitido | Cuándo se elimina |
|---|---|---|
| `GroupRule.amountMXN` extension property | UI composer fast-path; engine ya no lo usa. | Refactor Phase 2 — renombrar a `fineConsequenceAmount` + doc comment. |
| `Fine.paid` / `Fine.paidAt` / `Fine.waived` mutable fields | Storage columns que `fines_view` ya proyecta; los lectores reales del status leen view. | Constitution §14 Step 3c — drop columns, Fine struct lee desde `fines_view` exclusively. |
| `basic_fines` module nombrado por dinero | Legacy module schema; usa rules universales por debajo. | No se borra; no se crean módulos nuevos money-coupled. |
| Permission slugs `issueFine`/`voidFine`/`markFinePaid` | Son acciones humanas, no capabilities ni reglas. | No se eliminan — están bien nombrados (acción permitida ≠ rule consequence). |
| Tab "Reglas" + sección "Money" mezcladas en overview | UI legacy; backend ya separado. | Refactor Phase 3 — separar `.money` tab + (futura) `.obligations` tab. |

Cualquier deuda **nueva** que viole los 3 axiomas requiere rechazo en code review. La deuda existente se cataloga en `RulesFinesAudit_2026-05-18.md` con plan de migración.

---

## §6 — Tests doctrinales (CI gates)

Antes de cerrar el refactor (post audit-close):

| Test | Cubre |
|---|---|
| `test_rules_table_has_no_amount_column` | Axioma 1 — money no vive en rules table. |
| `test_rule_engine_does_not_update_fines_table` | Axioma 2 — engine no muta money. Scan TS source. |
| `test_fines_view_recomputes_from_ledger_entries` | Axioma 2 — projection completa desde atoms. |
| `test_pay_fine_emits_only_ledger_entries_insert` | Regla 1 — write path canónico. |
| `test_no_template_id_contains_money_word` | Regla 3 — grep `late_fee\|fine_\|penalty_` en seeded templates. |
| `test_no_capability_id_contains_fine_or_penalty` | Regla 4 — grep capability registry. |
| `test_resource_detail_money_tab_renders_no_rule_definitions` | Regla 5 — UI separation. |
| `test_consequence_type_enum_is_normalizable` | Regla 6 — cada case carga params via typed config, no via subclassing. |
| `test_outstanding_fines_view_is_projection_over_ledger_entries` | Regla 7 — obligation projection compliant. |

---

## §7 — Doctrina final

> **Rules define when consequences happen.**
> **Consequences may create obligations.**
> **Ledger entries are the economic truth.**
> **Balances and fines are projections.**
>
> **Governance is not accounting.**
> **Accounting is not governance.**
> **Rules coordinate behavior.**
> **Ledger records economic reality.**

Cuando hay duda sobre dónde poner un dato:

- ¿Cambia cómo se decide algo? → **Rule**.
- ¿Es plata que se movió? → **Ledger entry**.
- ¿Es un dato derivado de ambos? → **Projection**.
- ¿Es un cache mutable? → **Lee `OperationalCacheDoctrine.md` §1 (5 puertas) o no lo escribas**.
