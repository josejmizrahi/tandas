# Ruul — Constitución arquitectónica

**Status:** Canónico desde 2026-05-13. Founder directive.
**Reemplaza/consolida:** `Primitives.md` (la fórmula), `Taxonomy_Resources_and_Capabilities.md` (Resources × Capabilities), `AtomProjection.md` (atoms/projections), `L1_Audit_2026-05-10.md` (deuda L1).
**Companion:** `Roadmap.md` (ejecución), `OpenPlatform_Phase0_2026-05-10.md` (phasing), `Beta1Consolidation.md` (vertical actual).

> **Ruul es un Human Coordination Operating System.**
> No es una app de eventos, ni un calendario social, ni un splitwise, ni una colección de verticales. Es la infraestructura para que grupos humanos persistentes coordinen recursos, reglas, actos y memoria de manera auditable y extensible.

Cualquier sesión (humana o IA) que toque arquitectura lee este documento antes de abrir una tabla, un enum value o una primitive nueva.

---

## Los 12 artículos

1. **Group es el dominio social.** Único sujeto colectivo de coordinación. Persistente, gobernable, propietario de todo lo demás.

2. **Resource es el objeto coordinado.** Único primitive‑objeto top‑level. Polimórfico vía `resource_type`. Enum congelado: `event`, `fund`, `asset`, `space`, `slot`, `right`. Cualquier subtype nuevo pasa el filtro ontológico (§13).

3. **Project es futuro y excepcional.** Sólo cuando Resource + capabilities no alcanzan para coordinar un objetivo multi‑mes con milestones reales. Hoy: no existe.

4. **User es subject, pero opera vía Membership.** Cadena operacional de Beta: `User → Membership → Group → Resource`. Cross‑group obligations User↔User directas son horizonte, no presente.

5. **Capabilities son primitivas de comportamiento.** Universales, platform‑level, ~15‑20 unidades atómicas: `scheduling, rsvp, voting, ledger, booking, approvals, obligations, tasks, documents, reminders, notifications, activity, maintenance, valuation, availability, capacity, location, host_actions, check_in, rotation, rules`. Catálogo fijo; modules las componen, no las redefinen.

6. **Modules son bundles activables.** `basic_fines`, `rotating_host`, `rsvp`, `check_in`, `appeal_voting`. Cada module **referencia** capabilities + provee rules semilla + provee system_event types. Un module nunca declara un resource_type nuevo. Resource types son del platform.

7. **Atoms son la única verdad histórica.** Append‑only, sin UPDATE/DELETE, protegidos por trigger `*_atom_guard`. Atoms canónicos: `system_events`, `ledger_entries`, `rsvp_actions`, `vote_casts`. Futuros: `bookings` (Phase 2), `document_versions` (Phase futuro), `task_events` (Phase futuro).

8. **Projections son estado derivado.** Nunca persisten verdad independiente. Recomputables a partir de atoms + workflows + relaciones. Ejemplos: `attendance_view`, `balance_view`, `fines_view`, `vote_counts`, `event_resources_view`, `user_actions` inbox.

9. **Rules gobiernan acciones, no son objetos.** Estructura `WHEN trigger → IF conditions → THEN consequences`. Evaluadas por engine determinístico server‑only sobre `system_events`. Scope resolution jerárquico: `occurrence > resource > series > module > group`. Behavior rules ≠ governance policies (artículo separado).

10. **Obligations se derivan de rules + actions + relations.** No hay tabla `obligations` genérica. `fines_view` proyecta obligaciones monetarias sobre (ledger_entries + votes + review_periods). Cualquier obligación futura (no monetaria, promesa, commitment) entra como projection sobre el mismo patrón. **Nunca tabla nueva mutable de "obligations".**

11. **Ledger es la única verdad financiera.** Tabla canónica `ledger_entries` (atom append‑only). Tipos: `payment`, `contribution`, `reimbursement`, `transfer`, `expense`, `fine_issued`, `fine_paid`, `fine_voided`, `settlement`, `payout`, `fundDeposit`. Toda projection monetaria (balances, who‑owes‑whom, budget vs actual, estado de multa) deriva de aquí. Las tablas legacy `expenses`, `expense_shares`, `pots`, `pot_entries` están programadas para extinción.

12. **Ningún resource_type, atom type, capability ni primitive nueva sin pasar el filtro ontológico** del §13.

---

## §13 — Filtro ontológico (test de admisión)

Para CADA entidad propuesta (tabla, columna, enum value, atom, capability, module), preguntar en orden:

1. ¿Es subject?
2. ¿Es objeto persistente con lifecycle e identidad propia?
3. ¿Es relación entre subjects/objects?
4. ¿Es acción (atom append‑only)?
5. ¿Es obligación derivable de rules + acts + relations?
6. ¿Es regla o policy declarativa?
7. ¿Es workflow en curso (decisión transitoria)?
8. ¿Es projection derivada?
9. ¿Es evidencia / documento?
10. ¿Es capability transversal?
11. ¿Es configuración / metadata?
12. ¿Puede derivarse de algo que ya existe?
13. ¿Duplica una verdad existente?

**Sólo si sobrevive como subject / object / evidence con historial propio → tabla persistente.** En cualquier otro caso: relation embedded / atom / projection / config / rule / capability. **Nunca** "primitive nueva paralela".

---

## §14 — Cleanup queue (orden ejecutivo)

Estos 6 pasos son la deuda concreta para alinear la base con la constitución. No se construye nada nuevo (documentos, tasks, obligations genéricas, projects) hasta que estos pasos cierren.

1. **Freeze `ResourceType` enum** a 6 valores. Drop: `settlement`, `contribution`, `proposal`, `assignment`, `rotation`, `guestPass`, `booking`, `position`. Auditar filas vivas con `SELECT DISTINCT resource_type FROM resources` antes.

2. **Split Capability ≠ Module.** Refactor: drop `modules.provided_resource_types`; modules declaran sólo `provided_capabilities` + `provided_rules` + `provided_system_event_types`. Capabilities forman catálogo platform fijo.

3. **Refactor `fines.status` a projection.** Crear `fines_view` derivada de `ledger_entries + votes + fine_review_periods`. Drop column `fines.status` y triggers `fines_after_status_change`, `fines_resolve_fine_pending`.

4. **Consolidar dinero en `ledger_entries`.** Migrar filas vivas de `expenses`, `expense_shares`, `pots`, `pot_entries` a `ledger_entries` con metadata adecuada. Drop tablas legacy.

5. **Consolidar events en `resources`.** Migrar lectores restantes de `events` / `event_attendance` a `resources WHERE resource_type='event'` / `rsvp_actions`. Drop trigger `events_sync_to_resources` y tablas legacy.

6. **Sólo después de 1‑5**, abrir cualquier construcción nueva. Candidatos en orden de prioridad cuando llegue su turno:
   - `documents` polimórficos (Phase 3, layer evidencia)
   - `tasks` polimórficos (Phase 3, layer acción)
   - `bookings` atom (Phase 2, parte de slot capability)
   - `projects` (Phase 4+, sólo si data lo justifica)
   - AI‑enriched projections (Phase 3+, **viven en Layer 9 Projections** — no son layer propia; ver §15)

---

## §15 — Separaciones inviolables

- **Resource ≠ Action.** Payment, vote, RSVP, booking, contribution, settlement son **actions**, no resources.
- **Rule ≠ Resource.** Una regla es constraint declarativa, no objeto.
- **Projection ≠ Truth.** El atom es la verdad. La projection es lectura.
- **Workflow ≠ Entity.** Un vote en curso es workflow; el resultado es projection.
- **Obligation ≠ Ledger entry.** El ledger entry es el atom; la obligation es la projection.
- **Capability ≠ Module.** Capability es unidad atómica; module es bundle.
- **Governance rule ≠ Behavior rule.** Policies gobiernan permisos; rules gobiernan side‑effects sobre system_events.
- **AI ≠ Layer propia.** AI vive en **Layer 9 (Projections)** como projection enriquecida con LLM. Sigue las mismas reglas que cualquier projection: derivada de atoms, recomputable, descartable, sin write directo a atoms. El valor de AI más alto es *latente* (forecast en balance, health score en members, pattern detection en historial), no *agente* (asistente con workflow propio).

---

## §16 — Lo que NUNCA se acepta

- CRUD thinking
- Screen‑first thinking
- Vertical‑specific modeling ("una tabla para cenas, otra para tandas")
- "Todo es un resource"
- Estados mutables que pueden derivarse
- Múltiples fuentes de verdad para la misma realidad
- Reglas mágicas implícitas en código de cliente
- Atoms con UPDATE/DELETE
- AI mutando estado directo (sólo propone vía votes / pending_changes / notifications)

---

## §17 — Universalidad asegurada

El enum de 6 tipos + capabilities + rules + templates cubre, sin tocar primitives:

familias, roommates, cenas, viajes, bodas, clubes, startups, comunidades religiosas, asociaciones, teams (sports), coworking, gaming guilds, palcos, voluntariado, parent groups, alumni, creators, masterminds.

Verticales emergen de combinación, no de schema nuevo.

---

## §18 — Inspiración estructural

Esta arquitectura toma estructura conceptual (no contenido) de:
- **Talmud**: separación sujetos / objetos / relaciones / actos / obligaciones / reglas / evidencia / tiempo.
- **Derecho civil y common law**: subject‑object distinction, propiedad, custodia, obligaciones derivadas.
- **Contabilidad append‑only**: ledgers inmutables, balances derivados.
- **Ontologías relacionales**: relaciones como ciudadanas de primera clase.
- **Event sourcing**: atoms como fuente de verdad, projections como lectura.

---

**Última palabra:**
> El sistema permite que grupos humanos acumulen memoria, coordinen recursos, operen bajo reglas, registren actos, generen obligaciones, mantengan historial auditable, y evolucionen sin romper la ontología base.
>
> Si una propuesta no encaja en los 12 artículos: la propuesta cambia, no la ontología.
