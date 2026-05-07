# Ruul — Social Primitives and Product Logic

> Documento estratégico-operativo para explicar qué es Ruul, qué tipo de grupos modela, cuáles son sus primitivas sociales, cómo esas primitivas aterrizan en producto, y qué implicaciones tienen para la arquitectura y el roadmap.
>
> Este documento complementa:
>
> - `Docs/Vision.md` — north star del proyecto, si existe en el repo/local.
> - `Plans/Audit-2026-05-06.md` — estado estructural y próximos pasos técnicos.
> - `Plans/Roadmap.md` — fases de implementación, si existe en el repo/local.
> - `Plans/Phase1.md` — histórico de Fase 1.
>
> No reemplaza el Audit. El Audit manda sobre prioridades técnicas inmediatas. Este documento explica la lógica de producto detrás de esas decisiones.

---

## 1. Tesis central

Ruul existe porque muchos grupos humanos funcionan con reglas, rituales, confianza, dinero, turnos, acceso, obligaciones y reputación, pero casi todos los manejan de forma informal.

Ejemplos:

- amigos que hacen cenas recurrentes;
- grupos que comparten un palco;
- tandas de ahorro;
- grupos de poker;
- grupos de viaje;
- clubes privados;
- familias empresarias;
- grupos religiosos;
- comunidades de inversión;
- grupos de gastos compartidos;
- comunidades digitales.

Todos estos grupos tienen una misma estructura de fondo:

```text
personas + recurrencia + reglas + confianza + coordinación + memoria
```

Ruul convierte esa estructura informal en software.

La tesis corta:

```text
Ruul es infraestructura para grupos recurrentes que necesitan reglas claras, decisiones compartidas, coordinación, obligaciones y memoria.
```

La tesis de producto:

```text
Ruul convierte grupos informales en comunidades gobernables.
```

La tesis técnica:

```text
Ruul modela grupos como contenedores sociales compuestos por recursos gobernables, reglas, votos, multas, roles, eventos y memoria histórica.
```

---

## 2. Qué tienen en común estos grupos

Un grupo de amigos que hace cenas recurrentes y un grupo que comparte un palco parecen casos distintos, pero comparten primitivas profundas.

Ambos tienen:

| Primitiva | Cena recurrente | Palco compartido |
|---|---|---|
| Identidad | “Nuestro grupo de cenas” | “Nuestro palco” |
| Frontera | Quién pertenece | Quién tiene derecho de acceso |
| Recurrencia | Cena semanal/mensual | Partidos/eventos de temporada |
| Ritual | Cena, anfitrión, llegada, confirmación | Partido, invitados, convivencia |
| Reglas | Confirmar, llegar a tiempo, llevar algo | Uso, invitados, pagos, calendario |
| Obligaciones | Asistir, confirmar, pagar multa | Pagar cuota, reservar, respetar turnos |
| Beneficios | Convivencia, pertenencia | Acceso, estatus, entretenimiento |
| Gobernanza | Decidir reglas, expulsiones, cambios | Decidir uso, cuotas, invitados |
| Reputación | Cumplido/incumplido | Buen/mal socio del palco |
| Memoria | Historial de cenas y decisiones | Historial de uso, pagos y conflictos |

La diferencia no está en si tienen o no estructura. La diferencia está en qué primitivas dominan.

En una cena domina:

```text
ritual + asistencia + reglas sociales
```

En un palco domina:

```text
asset compartido + acceso + turnos + pagos
```

En una tanda domina:

```text
rotación + obligación + payout + confianza
```

En un poker pot domina:

```text
tesorería + contribución + reglas de reparto
```

En un grupo de inversión domina:

```text
capital + gobernanza + riesgo + distribución
```

Por eso Ruul no debe ser una app rígida de “tipos de grupo”. Debe ser una plataforma de primitivas configurables.

---

## 3. Las primitivas sociales de Ruul

Estas son las primitivas que aparecen una y otra vez en grupos recurrentes.

| Primitiva | Pregunta que responde | Producto |
|---|---|---|
| Identity | ¿Quiénes somos? | Nombre, template, símbolos, narrativa |
| Boundary | ¿Quién pertenece? | Membresía, invitaciones, roles |
| Recurrence | ¿Cada cuándo ocurre? | Eventos, ciclos, temporadas |
| Ritual | ¿Qué hacemos repetidamente? | Cena, partido, tanda, poker, viaje |
| Rule | ¿Qué se permite/prohíbe? | Reglas configurables |
| Obligation | ¿Qué debe hacer cada quien? | Confirmar, pagar, asistir, aportar |
| Contribution | ¿Qué aporta cada miembro? | Dinero, tiempo, lugar, host, tarea |
| Benefit | ¿Qué recibe cada miembro? | Acceso, payout, turno, estatus |
| Resource | ¿Qué se gobierna? | Evento, fondo, slot, asset, regla, multa |
| Vote | ¿Cómo decidimos? | Votaciones, quórum, threshold |
| Fine | ¿Qué pasa si alguien incumple? | Multas automáticas o manuales |
| Appeal | ¿Cómo se corrige una injusticia? | Apelaciones y revisión |
| Role | ¿Quién puede hacer qué? | Admin, host, treasurer, arbiter |
| Reputation | ¿Quién cumple? | Historial de conducta |
| Memory | ¿Qué pasó antes? | History, system events, snapshots |

Estas primitivas no son features aisladas. Son bloques que se combinan para crear templates.

Ejemplo:

```text
Dinner recurring =
Group + Members + Event + RSVP + Rule + Fine + Vote + History
```

```text
Tanda =
Group + Members + Cycle + Rotation + Contribution + Payout + Rule + Fine + History
```

```text
Shared box / palco =
Group + Members + Asset + Calendar + Slot + Guest + Payment + Rule + Vote + History
```

```text
Poker pot =
Group + Members + Fund + Contribution + Event + Settlement + Rule + History
```

---

## 4. Tipos de grupos que Ruul puede modelar

Ruul debe empezar con pocos templates, pero la arquitectura debe permitir muchos casos.

### 4.1 Grupos sociales recurrentes

Ejemplos:

- cenas recurrentes;
- grupos de amigos;
- grupos de viaje;
- cumpleaños recurrentes;
- asados;
- reuniones familiares.

Primitivas dominantes:

```text
recurrence + ritual + attendance + rules + fines + memory
```

Caso inicial recomendado:

```text
dinner_recurring
```

Razón:

- es emocionalmente entendible;
- tiene fricción real;
- no requiere fintech compleja;
- permite validar reglas, votos, multas y notificaciones;
- funciona como laboratorio social para Ruul.

### 4.2 Grupos financieros rotativos

Ejemplos:

- tandas;
- vaquitas;
- savings circles;
- rotating credit associations.

Primitivas dominantes:

```text
rotation + contribution + payout + trust + enforcement
```

Requiere:

- cycles;
- positions;
- assignments;
- payment tracking;
- payout tracking;
- fines for late payment;
- rule snapshots.

Esta línea no debe implementarse como “una app de tandas” separada. Debe implementarse como una configuración de primitivas universales.

### 4.3 Grupos de asset compartido

Ejemplos:

- palco;
- casa de fin de semana;
- yate;
- coche compartido;
- mesa en club;
- membresía compartida.

Primitivas dominantes:

```text
asset + access + slot + calendar + guest permissions + payment
```

Requiere:

- resource type: asset;
- resource type: slot;
- booking rules;
- guest rules;
- payment obligations;
- conflict/dispute handling.

El palco es especialmente importante porque demuestra que Ruul no es solo para dinero o cenas. Ruul también gobierna acceso a recursos escasos.

### 4.4 Grupos de tesorería compartida

Ejemplos:

- poker pot;
- fondo de viaje;
- fondo comunitario;
- caja chica de amigos;
- fondo de emergencias;
- fondo religioso/comunitario.

Primitivas dominantes:

```text
fund + contribution + withdrawal + approval + audit trail
```

Requiere:

- fund;
- contribution;
- withdrawal request;
- approval vote;
- treasurer role;
- audit history.

Esta línea se vuelve fuerte cuando Ruul agregue `Fund`, `Contribution` y `Cycle`.

### 4.5 Grupos de gobernanza comunitaria

Ejemplos:

- comunidades religiosas;
- clubes privados;
- alumni groups;
- fraternidades;
- DAOs;
- grupos vecinales;
- network states tempranos.

Primitivas dominantes:

```text
identity + rules + roles + proposals + votes + legitimacy + memory
```

Requiere:

- proposals;
- comments;
- configurable roles;
- governance rules;
- constitution/rulebook;
- long-term history.

Esta es la visión grande, pero no debe ser el primer producto comercial. Primero hay que ganar con grupos pequeños y recurrentes.

---

## 5. Implicación clave: Templates, no GroupType

Ruul no debe depender de un enum rígido tipo `GroupType`.

La lógica correcta es:

```text
Group usa Template.
Template define primitivas, presentación, reglas default, módulos y governance default.
```

Por eso la dirección del Audit es correcta:

```text
Eliminar GroupType
Expandir Template
Mover defaults a data
```

Estructura conceptual:

```swift
Template {
  id: String
  category: String
  presentation: {
    displayName: String
    symbolName: String
    description: String
    bullets: [String]
    defaultEventLabel: String
  }
  defaultSettings: {...}
  defaultGovernance: {...}
  defaultModules: [...]
  defaultRules: [...]
}
```

Esto permite que Ruul crezca sin modificar código cada vez que aparece un nuevo tipo de grupo.

Ejemplos:

```text
recurring_dinner
shared_box
rotating_savings
poker_pot
shared_trip
investment_club
family_council
religious_study_group
```

Todos son templates. No son modelos de app separados.

---

## 6. Implicación clave: Resource es la primitiva técnica central

El grupo es el contenedor social, pero lo que Ruul gobierna son recursos.

Un recurso puede ser:

- evento;
- cena;
- slot;
- turno;
- posición;
- fondo;
- multa;
- regla;
- propuesta;
- asset;
- pago;
- invitación;
- payout;
- ciclo.

Por eso la arquitectura correcta es:

```text
Group
  → Template
  → Resource
  → Rule
  → Vote
  → Fine
  → SystemEvent
  → History
```

Esto también explica por qué el Audit marca como críticos estos puntos:

1. `fines.resource_id` polimórfico.
2. Dual-write a `resources`.
3. Convergencia de `ResourceProtocol`.
4. `events_view` como transición, no estado final.
5. Rule engine evaluando contra resource context.

Si las multas siguen amarradas a `event_id`, Ruul queda atrapado en cenas/eventos. Si las multas apuntan a `resource_id`, Ruul puede multar sobre:

- no asistir a una cena;
- no pagar una tanda;
- no respetar un slot de palco;
- no contribuir a un fondo;
- no cumplir un turno;
- no ejecutar una responsabilidad.

La lógica correcta es:

```text
Fine should attach to Resource, not only Event.
```

---

## 7. Implicación clave: Rules necesitan IDs estables

Una regla no puede identificarse por su texto visible.

Incorrecto:

```text
"Llegada tardía"
"No confirmó a tiempo"
"No-show"
```

Correcto:

```text
late_arrival
missed_rsvp_deadline
no_show
host_no_menu
late_payment
slot_no_show
unauthorized_guest
```

El texto cambia. El ID no.

Razones:

- localización;
- cambio de copy;
- analytics;
- rule snapshots;
- templates serializables;
- compatibilidad histórica;
- votaciones sobre reglas;
- apelaciones;
- auditoría.

Por eso el Audit tiene razón al marcar `rule_id` estable como pre-Fase 2.

---

## 8. Implicación clave: Governance debe ser gradual

No todos los grupos quieren sentirse como una DAO o como un gobierno.

Ruul debe tener gobernanza real, pero con UX simple.

Usuario final no necesariamente debe ver:

```text
quorum
threshold
proposal
governance model
resource policy
```

Puede ver:

```text
¿Quién puede cambiar esta regla?
¿Todos votan o solo admins?
¿Cuántos votos se necesitan?
¿Cuánto tiempo dura la votación?
```

Internamente:

```text
GovernanceService
Vote
VoteCast
GovernanceRules
PermissionLevel
```

Externamente:

```text
Decisiones claras para el grupo.
```

La palabra “autogobierno” es correcta para la visión, pero puede ser demasiado pesada para onboarding.

Mejor lenguaje de producto:

- reglas claras;
- decisiones en grupo;
- acuerdos automáticos;
- consecuencias justas;
- memoria compartida;
- menos pleitos en el chat.

---

## 9. El lugar correcto de Beta 1

Beta 1 no debe intentar validar los 130 casos de uso ni toda la visión.

Beta 1 debe validar una pregunta:

```text
¿Un grupo real acepta que una app convierta reglas sociales informales en reglas explícitas, recordatorios, votos y consecuencias?
```

Para eso, `dinner_recurring` es el mejor primer template.

Durante Beta 1 se debe observar:

- ¿El grupo entiende para qué sirve Ruul?
- ¿Les da pena poner reglas?
- ¿Les da pena multar?
- ¿Prefieren multas reales o simbólicas?
- ¿Votan o esperan que el admin decida?
- ¿Se reduce fricción en WhatsApp?
- ¿Las notificaciones ayudan o molestan?
- ¿Qué reglas aparecen naturalmente?
- ¿Qué conflictos no habíamos previsto?
- ¿El grupo siente que Ruul ayuda o que lo hace más pesado?

Beta 1 debe producir aprendizajes para decidir si Fase 2 prioriza:

```text
Rotation
Slot
Asset
Fund
```

Pero antes de Fase 2 hay que cerrar deuda estructural pre-Fase 2.

---

## 10. Roadmap conceptual

### Fase 0 / F0

Objetivo:

```text
Base técnica sólida para grupos recurrentes.
```

Debe incluir:

- auth;
- groups;
- members;
- events;
- RSVP;
- rules;
- votes;
- fines;
- history;
- notifications;
- governance base.

Según el Audit, varias piezas de F0 ya están shipped o parcialmente cerradas. El documento de verdad para estado actual es `Plans/Audit-2026-05-06.md`.

### Pre-Fase 2

Objetivo:

```text
Quitar deuda estructural que bloquea recursos no-evento.
```

Prioridad:

1. `fines.resource_id` + `fine_review_periods.resource_id`.
2. `rule_id` estable.
3. Activar dual-write a `resources`.
4. Reconciliar parity de `defaultRules`.
5. Eliminar `GroupType`, expandir `Template`.

Esta etapa es más importante que construir features nuevas.

Sin esto, Fase 2 se construye sobre una base inconsistente.

### Fase 2 — Universal Assignment / Rotation

Objetivo:

```text
Modelar turnos, posiciones, asignaciones, responsabilidades y beneficios rotativos.
```

Primitivas nuevas:

- Rotation;
- Position;
- Assignment;
- Cycle;
- Turn;
- Obligation;
- Benefit.

Casos que desbloquea:

- tandas;
- anfitrión rotativo;
- turnos de palco;
- quién lleva qué;
- responsabilidades recurrentes;
- asignaciones de mesa/lugar;
- rotación de beneficios.

La tesis de Fase 2:

```text
Ruul pasa de coordinar eventos a coordinar responsabilidades y beneficios rotativos dentro de un grupo.
```

### Fase 3 — Asset / Slot / Access

Objetivo:

```text
Gobernar recursos escasos compartidos.
```

Casos:

- palco;
- casa compartida;
- membresía;
- reservas;
- invitados;
- acceso por temporada;
- conflictos de uso.

Primitivas:

- Asset;
- Slot;
- Booking;
- GuestPass;
- AccessRule;
- Dispute.

### Fase 4 — Fund / Contribution / Cycle

Objetivo:

```text
Gobernar dinero compartido.
```

Casos:

- poker pot;
- fondo de viaje;
- caja comunitaria;
- tanda más robusta;
- pagos recurrentes;
- retiros aprobados.

Primitivas:

- Fund;
- Contribution;
- Withdrawal;
- Approval;
- Treasurer;
- Ledger.

### Fase 5 — Proposal / Comment / Roles configurables

Objetivo:

```text
Convertir Ruul en una capa de gobernanza comunitaria flexible.
```

Casos:

- clubes;
- comunidades;
- familias empresarias;
- consejos;
- asociaciones;
- network communities.

Primitivas:

- Proposal;
- Comment;
- CustomRole;
- Permission;
- Constitution;
- GovernanceLog.

---

## 11. Cómo pensar cualquier nueva feature

Antes de construir una feature, preguntar:

### 11.1 ¿Qué primitiva representa?

Ejemplo:

```text
“Que alguien pueda reservar el palco”
```

No es solo una pantalla de calendario.

Es:

```text
Asset + Slot + Booking + AccessRule + GuestPermission
```

### 11.2 ¿Es específica de un template o universal?

Si solo sirve para cenas, cuidado.

Idealmente:

```text
host rotation para cenas
```

también debe poder servir para:

```text
turno de tanda
turno de palco
turno de llevar botellas
turno de organizar viaje
```

### 11.3 ¿Debe ser código o data?

Regla general:

```text
Si el founder o el grupo debería poder configurarlo algún día, debe tender a data.
```

Ejemplos que deben tender a data:

- templates;
- default rules;
- governance;
- roles;
- fines;
- copy de presentación;
- thresholds;
- modules.

### 11.4 ¿Genera memoria?

Si una acción cambia confianza, dinero, acceso, reglas o reputación, debe dejar rastro.

Debe crear:

```text
SystemEvent
HistoryItem
RuleSnapshot cuando aplique
```

### 11.5 ¿Puede aplicar a non-event resources?

Si una feature solo funciona con `event_id`, preguntar si debería funcionar con `resource_id`.

Ejemplo:

```text
fine.event_id
```

limita Ruul.

```text
fine.resource_id
```

abre Ruul.

---

## 12. Riesgos de lógica de producto

### 12.1 Riesgo: parecer una app de castigos

Ruul no debe sentirse como “la app que multa a tus amigos”.

Debe sentirse como:

```text
la app que evita malentendidos porque todos acordaron las reglas antes.
```

El framing correcto:

- acuerdos antes que castigos;
- transparencia antes que pleito;
- recordatorios antes que multa;
- apelación antes que injusticia;
- amnistía antes que rigidez.

### 12.2 Riesgo: sobre-gobernar grupos simples

No todos los grupos quieren votar todo.

Ruul debe permitir niveles:

```text
light mode: admin decide casi todo
balanced mode: reglas importantes se votan
governance mode: comunidad más formal
```

Dinner recurring debe empezar simple.

### 12.3 Riesgo: demasiadas categorías visibles

Aunque Ruul pueda modelar muchos tipos de grupo, el onboarding no debe mostrar 20 opciones.

MVP recomendado:

```text
Cena recurrente
Tanda
Palco / recurso compartido
Poker pot
Gastos compartidos
Custom
```

Pero internamente todos son templates.

### 12.4 Riesgo: construir Phase 2 antes de aprender de Beta 1

Fase 2 debe tomar aprendizajes reales de Beta 1.

Pero la deuda estructural pre-Fase 2 sí debe resolverse antes, porque no depende del aprendizaje de usuario. Es arquitectura base.

### 12.5 Riesgo: confundir visión con producto inicial

La visión puede ser:

```text
operating system for self-governed groups
```

El producto inicial debe ser más concreto:

```text
reglas, eventos, votos y multas para grupos recurrentes de amigos.
```

---

## 13. Lenguaje recomendado

### Interno

- social primitives;
- self-governed groups;
- resource-governance;
- templates-as-data;
- event sourcing;
- rule engine;
- legitimacy;
- enforcement.

### Usuario final

- reglas claras;
- acuerdos del grupo;
- decisiones en grupo;
- recordatorios automáticos;
- multas justas;
- apelaciones;
- historial;
- menos caos en WhatsApp.

### One-liners posibles

```text
Ruul helps friend groups run on clear rules.
```

```text
Ruul turns informal groups into organized communities.
```

```text
Ruul is the operating system for recurring groups.
```

```text
Ruul gives groups rules, memory and coordination.
```

En español:

```text
Ruul ayuda a grupos de amigos a organizarse con reglas claras.
```

```text
Ruul convierte acuerdos informales en reglas compartidas.
```

```text
Ruul es el sistema operativo para grupos recurrentes.
```

---

## 14. Decisiones recomendadas

### 14.1 Mantener Camino B multi-vertical

Ruul no debe casarse solo con `dinner_recurring`. Dinner es el primer template, no la empresa completa.

Decisión:

```text
Mantener multi-vertical basado en templates.
```

### 14.2 Priorizar templates como data

Decisión:

```text
Todo template futuro debe vivir lo más posible en data/config, no como hardcode Swift.
```

### 14.3 Hacer Resource la base del modelo

Decisión:

```text
Toda primitiva gobernable debe tender a Resource.
```

### 14.4 Hacer Beta 1 con cenas reales

Decisión:

```text
Usar 4-6 cenas reales para validar fricción social antes de escribir Phase2.md final.
```

### 14.5 No escribir Phase2 final antes de Beta 1

Sí se puede crear un draft de `Plans/Phase2.md`, pero debe marcarse como:

```text
Draft — pending Beta 1 learnings.
```

---

## 15. Próximo paso recomendado

Antes de crear `Plans/Phase2.md`, hacer estos trabajos pre-Fase 2:

1. `fines.resource_id` polimórfico.
2. `rule_id` estable.
3. dual-write a `resources`.
4. parity de `defaultRules`.
5. eliminar `GroupType`, expandir `Template`.

Después:

1. correr Beta 1 con 4-6 cenas reales;
2. documentar fricciones;
3. decidir si Fase 2 prioriza Rotation, Slot o Asset;
4. crear `Plans/Phase2.md`.

---

## 16. Resumen final

Ruul no es una app de tandas.

Ruul tampoco es solo una app de cenas.

Ruul es una plataforma para grupos recurrentes que necesitan transformar acuerdos informales en reglas compartidas, decisiones, obligaciones, consecuencias y memoria.

La arquitectura correcta no es:

```text
GroupType → hardcoded behavior
```

La arquitectura correcta es:

```text
Template → Resources → Rules → Votes → Fines → History
```

La visión grande es autogobierno de grupos.

El producto inicial debe ser simple:

```text
reglas claras para grupos reales.
```
