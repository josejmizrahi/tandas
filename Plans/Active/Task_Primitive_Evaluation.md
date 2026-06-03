# R.2P — Task / Commitment: Evaluación de Primitiva

**Status:** Análisis doctrinal (2026-06-03). NO implementa. NO toca schema. NO crea RPCs.
**Pregunta única:** ¿Task/Commitment es una nueva primitiva universal de Ruul, o es una
especialización de `Obligation`?

---

## 0. TL;DR — Respuesta

**Task/Commitment ES una primitiva nueva.** No es una especialización de `Obligation`.

`Obligation` modela **una deuda** (algo *que se debe* — dirigido `debtor → creditor`,
fungible, con monto, resuelto por **transferencia de valor** y neteo). `Task` modela
**un compromiso de hacer** (algo *que alguien debe hacer* — un solo responsable, no
fungible, sin monto, resuelto por **desempeño** y verificación).

La prueba decisiva es el **Caso 7** (*tarea incumplida genera multa*): una tarea no es
una multa; una tarea *produce* una multa cuando se incumple. Un objeto que **genera** una
obligación no puede *ser* esa obligación. Eso los separa ontológicamente.

Recomendación operativa: **declarar `Task` como primitiva en la doctrina, pero diferir su
implementación** (no en este corte). Mantenerla delgada y resistir el sobre-modelado de
gestor de proyectos.

---

## 1. Estado actual del schema (base del análisis)

`obligations` (migración `mvp2_008_rules_and_obligations`) es el candidato a reutilizar:

| Campo | Forma actual |
|---|---|
| `debtor_actor_id` | **NOT NULL** — quién debe |
| `creditor_actor_id` | **NOT NULL** — a quién |
| `obligation_type` | `iou · fine · sanction · expense_share · loan · contribution · dues · trip_share · game_debt · reservation_fee · other` |
| `amount` / `currency` | nullable, pero todo el dominio asume dinero |
| `status` | `open · settled · forgiven · disputed · cancelled` |
| `due_at` | timestamptz nullable |
| `source_*` | `decision_id · event_id · reservation_id · rule_id` |

Hechos relevantes del comportamiento existente:

1. **Toda obligación nace `open` y solo se cierra a `settled` vía `mark_settlement_paid`**,
   que es **neteo monetario FIFO** (`generate_settlement_batch` + transacciones). No hay
   forma de "completar" una obligación por desempeño no-monetario.
2. **Doble parte obligatoria.** `debtor` y `creditor` son ambos `NOT NULL`. Una obligación
   es por definición un vínculo de dos actores con dirección.
3. **El motor de reglas ya emite obligaciones** (`evaluate_rules_for_event` →
   consequence `fine`/`create_obligation`). Es decir, en Ruul una obligación es típicamente
   **una consecuencia**, no un compromiso primario.
4. **No existe** ningún concepto de `assignee`, `in_progress`, `completed`, `expired`,
   recurrencia de compromisos, ni verificación/aprobación de cumplimiento.
5. `calendar_events` tiene `event_type='deadline'` y `host_actor_id`, y
   `event_participants` tiene `status` (incl. `attended`/`no_show`) — lo más cercano hoy a
   "responsabilidad temporal", pero por evento, no por entregable.

---

## 2. Argumentos a favor de modelar como `Obligation` (Hipótesis A)

1. **Doctrina minimalista.** La doctrina MVP 2.0 lista 10 primitivas y **no** incluye Task.
   Cada primitiva nueva debe superar una barra alta; reutilizar evita inflación conceptual.
2. **Solape de campos.** `Obligation` ya tiene `debtor_actor_id` (≈ responsable),
   `due_at` (≈ fecha límite), `status`, `context_actor_id`, y los `source_*` (event,
   decision, reservation, rule). Cubre el ~60% de la forma de una tarea sin tabla nueva.
3. **Costo de schema cero.** Solo añadir valores al CHECK de `obligation_type`
   (`commitment`, `deliverable`, `action_item`) y reusar índices, RLS y activity log.
4. **Continuidad de dominio.** "Quién le debe qué al contexto" ya es el lenguaje de
   `obligations`; un compromiso es "le debes una acción al contexto".
5. **Caso 7 sin puente.** Si tarea y multa viven en la misma tabla, "incumplimiento genera
   multa" es solo cambiar/derivar una fila — no hay que enlazar dos primitivas.

---

## 3. Argumentos a favor de `Task` como primitiva (Hipótesis B)

1. **Lifecycle ajeno.** El ciclo de una tarea
   (`open → accepted → in_progress → completed | cancelled | expired`) **no es** el de una
   obligación (`open → settled | forgiven | disputed | cancelled`). `settled`,
   `forgiven`, `disputed` son verbos de **dinero/deuda**; no hay equivalente honesto de
   `accepted`/`in_progress`/`completed` en `Obligation`. Forzarlos contamina el enum
   monetario y rompe la semántica de `mark_settlement_paid`.
2. **Cardinalidad distinta.** Tarea = **un responsable** (`assignee`). Obligación = **par
   dirigido** (`debtor → creditor`, ambos NOT NULL). Una tarea no tiene "acreedor": "David
   lleva vino" no le debe el vino *a* nadie en particular; lo debe *al contexto/al plan*.
   Hacer `creditor = context` siempre es un hack que no significa lo que dice.
3. **No-fungibilidad / no-neteo.** Las obligaciones se **netean** (min-cashflow): 3 deudas
   se colapsan en 1 pago. Las tareas **no se netean**: "lleva vino" + "lleva postre" no se
   compensan entre sí. Aplicar el motor de settlement a tareas es un sin-sentido.
4. **Resolución por desempeño, no por pago.** Una tarea se cierra **haciendo** (y a veces
   **verificando**, Caso 8). Una obligación se cierra **pagando**. Son dos máquinas de
   estado con motores distintos (`record_*`/`settle` vs. `accept`/`complete`/`verify`).
5. **Es la primitiva-verbo que falta.** Ruul tiene Event (qué ocurre), Decision (cómo se
   aprueba), Obligation/Money (qué se debe/paga). Falta el **"qué hay que hacer"**. Task se
   ubica *entre* la intención (Event/Decision) y la consecuencia (Obligation/Money).
6. **Composición, no duplicación.** Task **enlaza** a las demás primitivas en vez de
   replicarlas: `Task ← Event` (compromiso de una cena), `Task → Resource` (entregable),
   `Task ← Decision` (aprobada), `Task → Obligation` (multa por incumplir). Una primitiva
   que sirve de nodo de unión justifica su existencia.
7. **Universalidad.** Aparece en **todos** los tipos de contexto del founder (cena, viaje,
   negocio, familia, trust). Eso es exactamente el criterio de "primitiva universal".

---

## 4. Smoke conceptual — los 8 casos

Leyenda: ✅ resuelve bien · 🟡 resuelve con fricción/hack · ❌ no resuelve.

| # | Caso | `Obligation` (A) | `Task` (B) |
|---|---|---|---|
| 1 | David lleva vino | 🟡 `commitment`, `amount=NULL`, `creditor=context` (acreedor ficticio; no hay "completar") | ✅ assignee=David, status completable |
| 2 | José reserva hotel | 🟡 igual; además querría enlazar el `Resource` reserva | ✅ assignee + `resource_id` del booking |
| 3 | David entrega presupuesto | 🟡 entregable = documento; `Obligation` no liga a `Resource` documento | ✅ `Task → Resource(document)` nativo |
| 4 | Banco entrega reporte trust | 🟡 debtor=legal_entity ok, pero es deadline recurrente, no deuda | ✅ assignee=actor `legal_entity`, recurrente |
| 5 | Tarea recurrente semanal | ❌ `obligations` no tiene `recurrence_rule` | ✅ recurrencia (heredada de Event o propia) |
| 6 | Tarea delegada | 🟡 reasignar `debtor` = *cesión de deuda* (novación) — semántica equivocada | ✅ reasignar `assignee` es natural |
| 7 | Incumplida genera multa | ❌ la obligación *sería* la multa; conflаciona disparador y consecuencia | ✅ `Task(expired) → evaluate_rules → Obligation(fine)` |
| 8 | Aprobada por otro actor | ❌ no hay paso de verificación/aprobación de cumplimiento | ✅ `completed_by` + `verified_by` distintos |

### 4.1 Casos que `Obligation` resuelve **bien**
- Ninguno de forma limpia. En el mejor caso (1, 2) lo resuelve **con hack**: monto nulo +
  acreedor = contexto. Funciona como *almacenamiento*, no como *modelo*.

### 4.2 Casos que `Obligation` resuelve **mal**
- **Caso 5 (recurrencia):** no existe `recurrence_rule` en `obligations`. ❌
- **Caso 6 (delegación):** mover `debtor` significa transferir una deuda, no reasignar
  trabajo. Semánticamente falso. 🟡→❌
- **Caso 7 (multa por incumplimiento):** colapsa el disparador (compromiso roto) y la
  consecuencia (deuda) en la misma fila. Pierdes la trazabilidad "esta multa vino de esta
  tarea". ❌
- **Caso 8 (aprobación de cumplimiento):** no hay máquina de verificación; `disputed` es de
  disputa de deuda, no de "no lo hizo bien". ❌

### 4.3 Casos que `Task` resuelve **bien**
- **Los 8.** En particular brilla en 5–8, donde `Obligation` falla:
  - 5: recurrencia propia o generada desde el `Event` recurrente.
  - 6: `assignee` reasignable sin cambiar la naturaleza del objeto.
  - 7: el motor de reglas existente (`evaluate_rules_for_event`) ya sabe emitir
    `Obligation(fine)` — solo hay que dispararlo con `trigger = task.expired`. La separación
    de primitivas hace este flujo **explícito y auditable**.
  - 8: `assignee` ≠ `verified_by` modela aprobación por tercero (consistente con cómo
    `Decision` ya separa proponente de votantes).

---

## 5. Matriz de decisión

| Criterio | Hipótesis A (`Obligation`) | Hipótesis B (`Task`) |
|---|---|---|
| **Complejidad** | Baja al inicio (solo enum), **alta después**: sobrecargas el enum, ramificas RPCs de money con `if amount IS NULL`, y `mark_settlement_paid` debe excluir tipos no-monetarios | Media constante: una tabla delgada + lifecycle propio, sin tocar money |
| **Reutilización** | Aparente. Reusa tabla pero **no** la lógica (settlement, neteo, balances no aplican) | Reusa por **composición**: enlaza Event, Resource, Decision, Obligation sin duplicarlos |
| **Impacto schema** | +3 valores de enum hoy; deuda técnica creciente en money | +1 tabla `tasks` + 1 enum de status; aislado del dominio de dinero |
| **Claridad conceptual** | Baja: "obligación con monto nulo y acreedor ficticio" miente sobre lo que es | Alta: un compromiso es un compromiso |
| **Riesgo de sobre-modelado** | Bajo *ahora*, pero contamina la primitiva más sensible (dinero) | Existe: tentación de construir un gestor de proyectos. **Mitigable** manteniéndola delgada |

**Lectura:** A minimiza el costo *hoy* a cambio de corromper la semántica de `Obligation`
(la primitiva donde un error es más caro: toca dinero, settlement y balances). B paga una
tabla a cambio de mantener cada primitiva honesta.

---

## 6. Recomendación final

### 6.1 Doctrina
**`Task` (o `Commitment`) ES una primitiva nueva y universal**, par de `Obligation`, no su
subtipo. Definición propuesta para la doctrina:

```
Task / Commitment = qué debe HACER alguien
  (un responsable, una fecha límite, un estado de desempeño,
   y posible incumplimiento que dispara reglas)

vs.

Obligation = qué DEBE alguien (deuda dirigida, fungible, neteable, settleable)
```

Regla de oro que las separa:
> Si se resuelve **pagando/neteando** → `Obligation`.
> Si se resuelve **haciendo/verificando** → `Task`.
> Una `Task` incumplida **puede generar** una `Obligation`; jamás al revés.

### 6.2 Pragmática (importante)
Ser primitiva en la **doctrina** no obliga a implementarla en este corte. Recomiendo:

1. **Diferir la implementación.** No hay tabla, RPC ni migración en R.2P (cumple la
   restricción). Añadir `Task` al mapa doctrinal como primitiva *prevista*.
2. **Cuando se implemente, mantenerla delgada** — anti-sobre-modelado:
   - Campos núcleo: `context_actor_id`, `assignee_actor_id`, `creator_actor_id`,
     `title`, `due_at`, `status`, `source_event_id?`, `source_decision_id?`,
     `resource_id?` (entregable), `verified_by_actor_id?`, `recurrence_rule?`, `metadata`.
   - Status mínimo viable: `open · in_progress · completed · cancelled · expired`
     (`accepted` y `verified` son opcionales según necesidad real, no especulativa).
   - **Prohibido**: subtareas, dependencias entre tareas, prioridades, estimaciones,
     tableros. Eso es producto de gestión de proyectos, no una primitiva de Ruul.
3. **Reusar lo que ya existe**, en vez de duplicar:
   - **Incumplimiento → multa:** disparar `evaluate_rules_for_event` con
     `trigger_event_type = 'task.expired'`. El motor de reglas y `Obligation` ya hacen el
     resto. (Caso 7 resuelto por composición, sin lógica nueva de dinero.)
   - **Recurrencia:** preferir que una `Task` recurrente derive de un `Event` recurrente
     antes que duplicar el motor de recurrencia.
   - **Aprobación:** si la verificación es colectiva, usar `Decision`; si es de un actor,
     basta `verified_by_actor_id`.

### 6.3 Lo que **NO** se debe hacer
- ❌ Añadir `commitment`/`deliverable`/`action_item` a `obligation_type`. Contamina la
  primitiva de dinero y empuja la deuda técnica al lugar más caro del sistema.
- ❌ Modelar tareas como `event_participants` con metadata (no hay lifecycle de desempeño
  ni entregable, y excluye las tareas sin evento — Casos 3 y 4).

---

## 7. Conclusión

> **¿Task/Commitment es una nueva primitiva universal de Ruul o una especialización de
> Obligation?**

Es una **primitiva universal nueva**. Comparte *forma* superficial con `Obligation`
(responsable, fecha, estado) pero difiere en lo esencial: **cardinalidad** (un responsable
vs. par debtor→creditor), **fungibilidad** (no neteable vs. neteable), **motor de
resolución** (desempeño/verificación vs. pago/settlement) y **rol sistémico** (es el
*disparador* de obligaciones, no una de ellas).

`Obligation` responde *"qué debe quién"*. `Task` responde *"qué debe hacer quién"*. Son
ejes distintos del mismo sistema, y conflarlos corrompería la primitiva más sensible de
Ruul (el dinero). Se recomienda **adoptarla en la doctrina y diferir su implementación**,
manteniéndola deliberadamente delgada.
