# Ruul — Talmudic Governance (Doctrina operacional)

**Status:** Canónico desde 2026-05-18. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (los 12 artículos + §13 filtro ontológico — el QUÉ), `Plans/Active/AtomProjection.md` (regla append-only — el CÓMO mecánico), `Plans/Active/HierarchyReference.md` (tabla de capas), `Plans/Active/Vision.md` (estrategia / posicionamiento).
**Source:** Founder prompt 2026-05-18 — "Talmudic Governance" — calibración filosófica.

Constitution.md §18 menciona el Talmud como "inspiración estructural" sin desarrollarlo. Este documento es ese desarrollo: el **cómo pensar** cuando diseñas, no las reglas concretas (esas viven en los 12 artículos). Es la lente que cualquier sesión humana o IA aplica al evaluar una nueva feature, capability, rule o resource antes de tocar código.

> Ruul **NO** es un CRUD. **NO** es Notion. **NO** es Airtable. **NO** es un ERP. Ruul es una **ontología viva de coordinación humana** — una capa jurídica digital sobre la realidad social, modelada con la lógica estructural del Talmud y los sistemas jurídicos reales (halajá, derecho romano, common law, sistemas notariales, contabilidad append-only).

---

## §1 — Principio central

En el Talmud, el orden de existencia es:

1. Primero existen las **entidades reales** del mundo (subjects, objects)
2. Luego las **relaciones** entre ellas
3. Luego los **actos** (acciones realizadas)
4. Luego las **consecuencias** (derivadas de actos + reglas)
5. Luego las **interpretaciones** (reglas que median)
6. Luego las **excepciones** (overrides explícitos)
7. Luego la **jurisprudencia acumulada** (memoria, precedente)

Ruul debe modelarse en este orden. NUNCA al revés. NUNCA "pantallas primero, modelo después". NUNCA "feature primero, ontología después".

La pregunta de diseño no es "qué pantalla necesitamos" sino **"qué realidad estamos modelando, y qué actos legítimos puede emitir el grupo sobre ella"**.

---

## §2 — La pirámide canónica

```
        WORLD       (subjects + objects que existen — Layer 0 + 3)
          ↓
       RELATIONS    (links polimórficos — Layer 3.5)
          ↓
        ACTS        (atoms append-only — Layer 10)
          ↓
    PROJECTIONS     (estado derivado — Layer 12)
          ↓
        RULES       (precedencia + interpretación — Layer 8)
          ↓
       EXCEPTIONS   (overrides explícitos — Layer 7 relations)
          ↓
       MEMORY       (jurisprudencia acumulada — Layer 13)
```

Cualquier feature nueva sube por esta pirámide en orden. Si necesita inventar una capa nueva, está mal pensada.

---

## §3 — Filosofía

El sistema debe sentirse como:

- una **constitución viva** (gobernable, enmendable, con jurisprudencia)
- una **guemará operacional** (debate, precedente, casos, excepciones registradas)
- una **capa semántica encima de la vida real** (no reemplaza la vida — la formaliza)
- un **motor universal de coordinación humana** (mismo core para palco / familia / coworking / hospital)

Reglas no negociables:

- Cada acción deja **evidencia** (atom)
- Cada decisión tiene **contexto** (resource_id, member_id, occurred_at, payload, actor)
- Cada regla tiene **precedencia** (occurrence > resource > series > resource_type > group > global)
- Cada excepción tiene **motivo** (relation override con razón explícita)
- Cada consecuencia **nace de un acto** (atom → engine → consequence atom)
- **Nada aparece mágicamente** (no auto-magic; siempre rastreable a un atom origen)

---

## §4 — Las 8 principios cardinales

Aplicar en cada PR. Si una propuesta viola cualquiera, está mal diseñada.

### A. Acto > Estado

**NO guardar:**

- `is_paid = true`
- `is_holder = true`
- `attended = true`
- `is_booked = true`
- `is_full = true`
- `current_occupancy = 5`

**Guardar:**

- `paymentRecorded` atom
- `custodyAssigned` atom
- `checkInRecorded` atom
- `bookingCreated` atom
- `spaceCapacityReached` atom

**El estado se deriva.** Una projection lo calcula on-demand desde los atoms; si necesitas un cache para UI, ese cache vive en `metadata` y siempre se escribe junto al atom (atom es la verdad, metadata es display).

### B. Más específico gana (precedencia halájica)

```
occurrence > resource > series > resource_type > group > global
```

Igual que en la halajá: la regla particular vence a la general. Una regla en una occurrence específica de la cena del jueves derrota la regla en el resource (la serie de cenas), que derrota la del resource_type (`event`), que derrota la del group, que derrota la global.

El rule engine evalúa de más específico a más general; primer match decide.

### C. Excepción explícita

**NO hardcodear** "David está excluido de la rotativa" en código de cliente.

Las excepciones existen como **entidades reales**:

- una `member_capability_overrides` row (futuro), o
- una `rules` scoped row con condición específica, o
- un `right` con `holder=David` y atributos específicos

Cada excepción debe:
- existir como entidad consultable
- dejar evidencia (atom de creación)
- tener motivo (payload con `reason`)
- ser auditable y revertible

Caso paradigmático: "el invitado de Jose puede entrar aunque no sea miembro" — eso es un `right` (entitlement) que `grants_access_to` el space, NO un boolean `allow_guests` en `resources.metadata`.

### D. Capabilities ≠ Resources

**Resources = qué existe.**
**Capabilities = qué puede hacerse sobre lo que existe.**

- Space NO es booking. Space ES un lugar; PUEDE TENER la capability `booking`.
- Fund NO es contribution. Fund ES un pool; PUEDE TENER la capability `ledger`.
- Asset NO es maintenance. Asset ES un objeto; PUEDE TENER la capability `maintenance`.

Confundirlas crea resources falsos (`reservation`, `payment`, `repair`) que son atoms o capabilities disfrazadas.

### E. Capability ≠ Surface

Una capability NO implica:
- una tab
- una pantalla
- una sección
- una navegación
- un botón fijo

La UI es **derivada**. La capability declara la semántica (`booking` = se puede reservar); la UI decide cómo renderizarla (sección inline, modal, lista, sticky CTA, accordion, etc.).

Test práctico: si una capability tiene un atributo `tab_position: 3` o `section_color: blue`, está conflando capability con surface. Lo correcto es un view layer que LEE qué capabilities están activas y decide cómo renderizar.

### F. Rules ≠ Capabilities

**Capability:** "se puede reservar" (la posibilidad existe en el resource).
**Rule:** "si está lleno, ofrece waitlist" (qué pasa cuando).

Capability declara qué actos son legales. Rule declara qué consecuencias siguen a esos actos. Una capability sin reglas funciona (booking abierto sin gates); una rule sin capability es código muerto.

### G. Consentimiento explícito

NO hacer automatizaciones silenciosas que decidan por el usuario.

**Incorrecto:**
- booking falla por capacidad → sistema mete automáticamente a waitlist sin avisar

**Correcto:**
- booking falla por capacidad → server rechaza con error claro
- UI captura el error → muestra "Aforo lleno. ¿Quieres unirte a la lista de espera?"
- Usuario acepta explícitamente → UI llama `join_waitlist` → atom nuevo

El usuario es el sujeto jurídico. Cada acto que registra el sistema debe ser un acto del usuario (o de un cron documentado, o de un admin con razón explícita). NUNCA acto sin consentimiento auditable.

Caso real (Space slice 2026-05-18): `book_space` rechaza con `capacityReached` error en vez de auto-routear a waitlist — UI orquesta la fallback con consentimiento explícito del usuario.

### H. Reutilizar conceptos universales

NO crear:
- `access_control` cuando ya existe `access`
- `space_permissions` cuando ya existe `access` + rules
- `venue_booking` cuando ya existe `booking`
- `seat_management` cuando ya existe `slot` + `capacity`
- `palco_*`, `cancha_*`, `parking_*` (vertical-specific)

Si el concepto semántico es el mismo, **usar la misma capability**. Como el Talmud: un mismo principio (negligencia, custodia, propiedad, usufructo) aplica a vacas, ánforas, depósitos, esclavos liberados, viñas, mujeres divorciadas — la abstracción es el principio, no el caso.

Caso real (Space slice 2026-05-18): `access_control` rechazado por founder; se reusó la capability existente `access` que ya cubría asset + space + right.

---

## §5 — Inspiración legal (no copia)

El sistema debe parecerse estructuralmente más a:

- **Derecho romano** — distinción subject/object, ownership/possession/usufruct, persona/cosa
- **Halajá talmúdica** — actos canónicos, precedencia jerárquica, excepciones registradas, jurisprudencia
- **Common law** — precedente, stare decisis, casos análogos, interpretación contextual
- **Constituciones modernas** — enmendabilidad gobernada, layers de norma (constitución > ley > reglamento)
- **Sistemas notariales** — actos formales que generan derecho, custodia de evidencia
- **Contabilidad append-only** — ledgers inmutables, balances derivados, auditabilidad total

NO debe parecerse a:

- Trello / Monday / Asana (tareas mutables, sin doctrina)
- Notion / Airtable (CRUD genérico)
- ERP legacy (campos por feature, ontología accidental)
- Calendarios sociales (eventos como entidad central pobre)

---

## §6 — Shapes + Lego: usuario como legislador, no como programador

El usuario NO programa. El usuario:

- selecciona **patrones válidos** (rule shapes) de un catálogo finito
- llena **parámetros** declarativos (monto, plazo, miembros)
- ve **lenguaje humano** ("cuando alguien llegue tarde, multa de $200")

Como el legislador medieval — escoge fórmulas jurídicas pre-validadas, no escribe el bytecode del juez.

El catálogo de shapes (`rule_shapes` table) es el corpus iuris cerrado. Cada shape:
- es declarativo (params jsonb, no código)
- tiene un evaluator server-side en el engine
- compone con otros shapes (trigger + condition + consequence)
- tiene una traducción humana ES/EN

---

## §7 — UX: humana, semántica, jurídica

La UI debe sentirse:

- humana — escrita como hablaría un abogado bilingüe, no como un README técnico
- visual — chrome, badges, sections que comunican estado sin párrafos
- semántica — "Aforo lleno", no "capacity reached event triggered"
- estructural — secciones que reflejan capas reales (INFORMACIÓN, AFORO, RESERVAS, REGLAS, HISTORIA)
- entretenida — el sistema invita a explorar, no a sufrir
- poderosa — el usuario siente que puede modelar cualquier coordinación real
- clara — cero ambigüedad sobre qué hace cada acción

El usuario nunca debe ver:
- JSON
- AST
- "trigger", "projection", "mutation", "cron" en copy
- IDs sin nombre
- estados internos (`status='_pending_validation'`)

Debe ver:
- "cuando alguien llegue tarde…"
- "si no hay cupo…"
- "si el gasto supera $5,000…"
- "el palco está reservado por Maria hasta las 22:00"
- "tienes 3 personas en lista de espera"

---

## §8 — El sistema debe soportar (sin cambiar primitives)

Con los 6 resource types + capabilities universales + rules + atoms + projections, el sistema debe modelar:

- familias
- palcos
- comunidades religiosas
- equipos de fútbol
- roommates
- viajes / grupos de viaje
- startups / cap tables
- fondos / kitties / tandas
- clubes / membresías
- coworkings
- asociaciones civiles
- bodas
- gaming guilds
- pequeños gobiernos vecinales
- coordinación legal real (asociaciones, copropiedades, herencias)
- hoteles / hospitality
- hospitales / quirófanos
- parking lots
- marinas / yates
- escuelas / aulas

Sin **inventar** un nuevo resource_type, capability, o atom por vertical. Si una vertical requiere primitives nuevas, primero pasa el filtro ontológico §13 de Constitution.md.

---

## §9 — Regla de oro (test de admisión)

Una feature está mal diseñada si:

1. **Duplica semántica** — crea otro nombre para algo que ya existe (`access_control` vs `access`).
2. **Crea otro nombre para lo mismo** — `venue_booking` vs `booking`, `palco_reservation` vs `space + booking`.
3. **Rompe append-only** — `UPDATE bookings SET cancelled=true` en vez de emitir `bookingCancelled` atom.
4. **Introduce estado mutable innecesario** — `current_occupancy: int` en metadata que se incrementa/decrementa.
5. **Agrega un resource innecesario** — `Reservation` resource_type cuando booking es atom.
6. **Mezcla capability con surface** — capability con `default_tab_index` o `section_template`.
7. **Mezcla ownership con occupancy** — usar `asset` cuando el caso real es booking/access (o viceversa).
8. **Mezcla acto con estado** — `Fine.status = 'paid'` cuando lo correcto es `fine + ledger_entries(fine_paid)` y derivar el estado.

Si la propuesta viola cualquiera: la propuesta cambia, no la ontología.

---

## §10 — Meta final

Ruul debe convertirse en:

- un **sistema universal de coordinación humana** (mismo core, múltiples verticales)
- una **ontología operacional** (cada concepto del mundo real tiene su primitive correcto)
- una **capa jurídica digital** (formaliza relaciones que hoy viven en WhatsApp + memoria + Excel)
- una **constitución viva** (enmendable, con jurisprudencia y precedente)
- una **guemará moderna** para grupos humanos (debate registrado, excepciones razonadas, decisiones contextuales)

NO un simple software. NO una "app de eventos para grupos". NO un competidor de Splitwise o Notion.

> Si una propuesta no encaja en este modelo: la propuesta cambia, no la ontología. (Constitution.md, última palabra.)

---

## §11 — Cómo aplicar esta doctrina en cada PR

1. Antes de abrir el editor: leer §4 (los 8 principios).
2. Articular qué realidad del mundo se modela. ¿Es subject? ¿Object? ¿Acto? ¿Relación? ¿Regla? ¿Excepción?
3. Pasar el filtro ontológico §13 de Constitution.md.
4. Identificar qué primitives existentes cubren el caso. ¿Atom existente? ¿Capability existente? ¿Resource type existente?
5. Si TODO está cubierto: implementar componiendo (sin inventar). Esto es el 90% de los casos.
6. Si NO está cubierto: documentar primero (spec canónico) en `Plans/Active/<Concept>.md`, citar precedentes (Asset.md / Space.md / EventResource.md), justificar la primitive nueva contra los 13 puntos del filtro §13.
7. Implementar en vertical slices (doc → atoms → RPCs → projections → UI → tests).
8. Cada commit prueba la regla de oro §9 sobre sí mismo.

---

## §12 — Referencias canónicas

- `Plans/Active/Constitution.md` — los 12 artículos + filtro ontológico (§13) + cleanup queue (§14) + separaciones inviolables (§15) + lo que nunca se acepta (§16).
- `Plans/Active/AtomProjection.md` — regla append-only + marker protocols Swift.
- `Plans/Active/HierarchyReference.md` — tabla maestra de 17 capas.
- `Plans/Active/Vision.md` — estrategia, posicionamiento, GTM.
- `Plans/Active/EventResource.md` / `Asset.md` / `Space.md` — specs canónicos por resource type.
- `Plans/Active/Governance.md` — Rule Builder UX + workflows de governance.

---

**Última palabra:**

> El Talmud no es un manual de reglas. Es la documentación viva del proceso por el cual una comunidad descubre, debate, formaliza y aplica reglas sobre sí misma — preservando cada paso, cada caso, cada excepción y cada razonamiento.
>
> Ruul es esa misma cosa, instanciada por software, para cualquier grupo humano.
