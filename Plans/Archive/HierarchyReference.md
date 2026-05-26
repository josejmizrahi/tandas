# Ruul — Tabla maestra de jerarquía lógica

**Status:** Canónico desde 2026-05-14. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (12 artículos + §13 filtro ontológico).
**Source of truth de estrategia:** `Plans/Active/Vision.md`.

Este documento es la **referencia operativa** del Constitution.md: qué existe, dónde vive, qué gobierna qué, y qué NO debe convertirse en resource. Toda decisión de modelado consulta primero el Constitution (artículos + filtro), luego esta tabla para el detalle.

---

## §1 — Tabla maestra de capas

| Nivel | Capa | Pregunta que responde | Qué vive aquí | Tablas / estructuras | Ejemplo |
|---|---|---|---|---|---|
| 0 | Identity | ¿Quién es la persona? | Usuarios, perfiles, auth | `auth.users`, `profiles` | Jose como usuario |
| 1 | Subject / Domain | ¿Qué grupo existe? | Grupo como dominio social persistente | `groups` | "Cenas de los jueves" |
| 2 | Membership / Relation | ¿Quién pertenece y cómo? | Membresía, roles, estatus, relación con el grupo | `group_members` | Jose es miembro/admin |
| 3 | Resource / Object | ¿Qué cosa coordina el grupo? | Objetos persistentes coordinados | `resources` | Cena, fondo, palco, cancha |
| 4 | Resource Type | ¿Qué tipo de cosa es? | Subtipo cerrado del resource | `resources.resource_type` | `event`, `fund`, `asset`, `space`, `slot`, `right` |
| 5 | Capability | ¿Qué se puede hacer sobre eso? | Capacidades atómicas universales | `capabilities`, `resource_capabilities` | RSVP, booking, ledger |
| 6 | Module | ¿Qué bundle activamos? | Paquete de capabilities + reglas + UI | `modules` | `rotating_host`, `basic_fines` |
| 7 | Template | ¿Cómo nace configurado? | Seed inicial por caso de uso | `templates` | "Cena recurrente" |
| 8 | Governance / Rules | ¿Qué está permitido, requerido o prohibido? | Reglas, permisos, políticas | `rules`, `rule_shapes`, `group_policies` | "Si falta, multa" |
| 9 | Workflow | ¿Qué proceso está abierto? | Votos, apelaciones, aprobaciones, cambios pendientes | `votes`, `pending_changes`, `fine_review_periods` | Apelación de multa |
| 10 | Atom / Action | ¿Qué ocurrió realmente? | Actos inmutables append-only | `system_events`, `ledger_entries`, `rsvp_actions`, `check_in_actions`, `vote_casts` | Jose votó sí |
| 11 | Atom-ish | ¿Qué acción tiene cierre terminal? | Inbox/acciones resolubles one-way | `user_actions` | RSVP pendiente resuelto |
| 12 | Projection / View | ¿Cuál es el estado actual calculado? | Estado derivado, recomputable | `attendance_view`, `balance_view`, `fines_view`, `vote_counts_view` | Balance actual |
| 13 | Evidence / Memory | ¿Qué evidencia queda? | Documentos, recibos, archivos, versiones | `documents`, `document_versions` (futuro) | Recibo de pago |
| 14 | Task / Coordination | ¿Qué debe hacerse? | Tareas, pendientes, responsabilidades | `tasks`, `task_events` (futuro) | Reservar restaurante |
| 15 | Notification / Delivery | ¿A quién se le avisa? | Cola de notificaciones | `notifications_outbox`, tokens | Push de RSVP |
| 16 | AI / Generated | ¿Qué propone o resume AI? | Resúmenes, drafts, sugerencias | outputs derivados (futuro) | "Sugiero nueva regla" |
| 17 | Analytics | ¿Qué patrones se observan? | Métricas, health, insights | views futuras | Grupo con baja asistencia |

---

## §2 — Resource types (enum congelado)

| Resource type | Qué es | Ejemplos | Capabilities típicas | Qué NO es |
|---|---|---|---|---|
| `event` | Ocurrencia temporal coordinada | cena, viaje, boda, partido, junta | scheduling, RSVP, check-in, guests, ledger, rules | No es "Trip" separado |
| `fund` | Bolsa monetaria compartida | fondo común, kitty, mantenimiento | ledger, contributions, payouts, approvals, balance | No es payment |
| `asset` | Bien físico/digital persistente | coche, palco, equipo, IP, contenido | ownership, maintenance, valuation, access, ledger | No es booking |
| `space` | Lugar administrable/reservable | cancha, salón, casa, oficina | booking, availability, capacity, access | No es event |
| `slot` | Capacidad escasa temporal | turno, asiento, horario, mesa | booking, assignment, availability | No es "reservation" |
| `right` | Derecho de uso/acceso/beneficio | membresía externa, equity, derecho de voto, acceso | access, transfer, ownership, expiration | No es membership interna |

---

## §3 — Capabilities universales

| Capability | Qué permite | Puede vivir sobre | Genera atoms | Genera projections |
|---|---|---|---|---|
| scheduling | Coordinar fechas/horas | event, slot, space | `system_events` | calendario |
| rsvp | Confirmar asistencia | event | `rsvp_actions` | asistencia actual |
| check_in | Registrar presencia | event, space | `check_in_actions` | attendance/check-in state |
| ledger | Registrar dinero | group, fund, event, asset | `ledger_entries` | balance |
| voting | Tomar decisiones | group/resource/workflow | `vote_casts` | vote_counts |
| booking | Reservar uso/capacidad | space, slot, asset | `system_events` | availability |
| availability | Consultar disponibilidad | space, slot, event | ninguno directo | availability view |
| access_control | Controlar acceso | todos | `system_events` | permissions view |
| ownership | Registrar derechos/participaciones | asset, fund, right | `system_events` | ownership view |
| maintenance | Reportar/manejar mantenimiento | asset, space | `system_events` | open issues |
| valuation | Registrar valor | asset, fund, right | `system_events` | current value |
| guest_management | Manejar invitados | event, space, asset | `system_events` | guest list |
| rotating_host | Asignar anfitrión rotativo | event, resource_series | `system_events` | next host |
| fines | Emitir penalizaciones | event, group | `ledger_entries`, `system_events` | fines_view |
| appeals | Apelar una consecuencia | workflow | `vote_casts`, `system_events` | appeal status |
| approvals | Requerir autorización | todos | `system_events`, `vote_casts` | approval status |
| documents | Adjuntar evidencia | todos | `document_versions` | document list |
| tasks | Asignar pendientes | group/resource/project/event | `task_events` (futuro) | task status |
| notifications | Avisar a usuarios | todos | queue events | delivery status |
| activity | Ver historial | todos | `system_events` | activity feed |

---

## §4 — Reglas: sobre qué pueden gobernar

| Scope de regla | Qué gobierna | Ejemplo | Se guarda como |
|---|---|---|---|
| group | Comportamiento general del grupo | "Solo admins crean reglas" | `rules` / `group_policies` |
| resource | Comportamiento sobre un resource | "El palco requiere aprobación para reservar" | `rules.scope=resource` |
| resource_type | Todos los resources de cierto tipo | "Todo fund requiere tesorero" | `rules.scope=resource_type` |
| capability | Uso de una capability | "Solo hosts pueden usar check-in" | rule sobre capability |
| action | Permitir/rechazar/condicionar acción | "No RSVP después del deadline" | rule trigger |
| relation | Permisos según relación | "Guests no pueden invitar" | policy / rule |
| role | Permisos según rol | "Treasurer puede ver ledger" | `group_policies` |
| time | Ventanas / deadlines | "Reservas cierran 24h antes" | rule condition |
| threshold | Montos / límites | "Gastos > $5,000 requieren voto" | rule condition |
| workflow | Proceso requerido | "Alta de miembro requiere aprobación" | workflow rule |
| obligation | Consecuencia que debe cumplirse | "Falta genera multa" | rule consequence |
| visibility | Qué puede ver quién | "Guests no ven balances" | policy |
| transition | Cambios de estado permitidos | "Solo admin puede cancelar evento" | policy / rule |
| exception | Excepción para alguien/caso | "David no entra a rotativa" | relation override / scoped rule |

---

## §5 — Ejemplo: palco

| Capa | En el caso del palco | Tabla / estructura |
|---|---|---|
| Group | "Socios Palco Azteca" | `groups` |
| Members | Socios, invitados, admin | `group_members` |
| Resource | "Palco Azteca 204" | `resources` |
| Resource type | `asset` o `space` según modelado principal | `resources.resource_type` |
| Capabilities | booking, guest_management, ledger, access_control | `resource_capabilities` |
| Rules | invitados máx. 4, reservas requieren aprobación, prioridad socios | `rules` |
| Policies | admin puede editar reglas, treasurer ve ledger | `group_policies` |
| Workflows | aprobación de reserva, votación de gasto | `votes`, `pending_changes` |
| Atoms | reserva creada, invitado agregado, pago hecho | `system_events`, `ledger_entries` |
| Projections | disponibilidad, balance, próximas reservas | `*_view` |
| Documents | contrato, reglamento, recibos | `document_versions` |
| Tasks | pagar mantenimiento, limpiar palco | `tasks` |

---

## §6 — Ejemplo: excepción en rotativa

| Elemento | Qué es | Dónde vive |
|---|---|---|
| Cena semanal | Resource | `resources(type=event)` |
| Rotativa de host | Capability / module | `resource_capabilities`, `modules` |
| Miembro excluido | Relation override | metadata en `group_members` o `member_capability_overrides` (futuro) |
| Regla | "No incluir a X en eligible hosts" | `rules` |
| Asignación de host | Atom | `system_events(type=host_assigned)` |
| Host actual | Projection | `current_host_view` |
| Próximo host | Projection | `next_host_view` |

---

## §7 — Relation overrides

| Override | Qué significa | Ejemplo | Mejor ubicación |
|---|---|---|---|
| excluded_capabilities | Miembro no participa en cierta capability | David no puede ser host | `group_members.metadata` o `member_capability_overrides` |
| capability_allow=false | Bloqueo específico | Guest no puede reservar | override / policy |
| capability_allow=true | Permiso excepcional | Invitado especial puede reservar | override / policy |
| role_override | Rol temporal/contextual | Ana es host esta semana | relation metadata |
| eligibility_override | Elegibilidad para algoritmo | Isaac fuera de rotativa | override |
| visibility_override | Visibilidad especial | Contador ve ledger | policy |
| obligation_exemption | Exención de obligación | Nuevo miembro no paga multa 30 días | scoped rule / override |
| priority_override | Prioridad diferente | Socio fundador tiene prioridad | rule condition |
| quota_override | Límite distinto | Jose puede invitar 6 guests | rule exception |

---

## §8 — Qué NO debe ser resource

| Cosa | Clasificación correcta | Por qué no es resource |
|---|---|---|
| Payment | `ledger_entry` | Movimiento de dinero |
| Contribution | `ledger_entry` | Acto financiero |
| Settlement | `ledger_entry` | Liquidación |
| Expense | `ledger_entry` | Movimiento financiero |
| RSVP | `rsvp_action` | Acción |
| Check-in | `check_in_action` | Acción |
| Vote cast | `vote_cast` | Acción |
| Vote | workflow | Proceso de decisión |
| Proposal | workflow / `pending_change` | No tiene gravedad propia |
| Booking | capability / action | Es uso de un resource |
| Reservation | atom / projection | Acto y estado derivado |
| Rotation | rule / capability | Algoritmo de asignación |
| Assignment | relation / atom | Relación temporal |
| Guest pass | right / permission / action | Derecho o permiso, no primitive |
| Fine | obligation projection / ledger | Consecuencia derivada |
| Balance | projection | Cálculo |
| Attendance | projection | Cálculo |
| Notification | delivery queue | Infraestructura |
| Message | activity / comment | Comunicación |
| Rule | governance | Gobierna behavior |
| Document | evidence | Memoria/evidencia, no core object salvo futuro |

---

## §9 — Decisiones de modelado

| Pregunta | Si la respuesta es sí | Entonces |
|---|---|---|
| ¿Tiene identidad persistente? | Sí | Puede ser resource |
| ¿Dura meses/años? | Sí | Puede ser resource |
| ¿Es centro de coordinación? | Sí | Puede ser resource |
| ¿Es algo que ocurrió? | Sí | Es atom |
| ¿Mueve dinero? | Sí | Es `ledger_entry` |
| ¿Es estado calculado? | Sí | Es projection |
| ¿Es permiso/regla? | Sí | Es governance |
| ¿Es proceso pendiente? | Sí | Es workflow |
| ¿Es vínculo entre actor y objeto? | Sí | Es relation |
| ¿Es comportamiento posible? | Sí | Es capability |
| ¿Es evidencia? | Sí | Es `document_version` |
| ¿Es output AI? | Sí | Es generated / proposal |

---

## §10 — Mutabilidad técnica

| Tabla / capa | UPDATE permitido | DELETE permitido | Regla |
|---|---|---|---|
| `profiles` | Sí | Controlado | PII mutable |
| `groups` | Sí | Soft-delete | Dominio vivo |
| `group_members` | Sí | Mejor `status` | Relation viva |
| `resources` | Sí | Soft-delete | Object mutable controlado |
| `resource_capabilities` | Sí | Sí | Config mutable |
| `rules` | Mejor versionar | No ideal | Governance debe auditarse |
| `group_policies` | Mejor versionar | No ideal | Permisos auditables |
| `votes` | Sí | No ideal | Workflow mutable |
| `pending_changes` | Sí | No ideal | Workflow mutable |
| `system_events` | Solo `processed_at` | No | Atom parcial |
| `ledger_entries` | No | No | Atom full |
| `rsvp_actions` | No | No | Atom full |
| `check_in_actions` | No | No | Atom full |
| `vote_casts` | No | No | Atom full |
| `user_actions` | Solo `resolved_at` | No | Atom-ish |
| `*_views` | Rebuild | Rebuild | Projection |
| `document_versions` | No | No | Evidence append-only |

---

## Resumen constitucional

- **Group** = dominio social.
- **Resource** = cosa coordinada.
- **Capability** = comportamiento posible.
- **Rule** = constraint sobre comportamiento.
- **Workflow** = proceso abierto.
- **Atom** = acto ocurrido.
- **Projection** = estado derivado.
- **Document** = evidencia.
- **AI** = propuesta, nunca ejecución directa.

> Resources define what exists.
> Capabilities define what can happen.
> Rules define what is allowed, required, or forbidden.
> Atoms record what actually happened.
> Projections derive current reality.
