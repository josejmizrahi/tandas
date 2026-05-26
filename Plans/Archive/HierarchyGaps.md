# Ruul — Análisis de huecos en la jerarquía

**Status:** Open analysis (no canonizado todavía). Founder review 2026-05-14.
**Companion:** `Plans/Active/HierarchyReference.md` (tabla maestra), `Plans/Active/Constitution.md` (12 artículos).

Este doc lista los huecos detectados al revisar la tabla maestra. **No** propone nuevos `resource_type`. Sí propone capabilities + refinamientos de layer que conviene formalizar.

---

## §1 — Veredicto sobre resource_types

**No falta otro `resource_type`.** El enum congelado cubre los casos límite:

| Caso | ¿Ya cabe? | Dónde |
|---|---|---|
| Membership externa | Sí | `right` |
| Licencia / permiso | Sí | `right` |
| Cuenta compartida | Sí | `fund` o `right` |
| Inventario | Sí | `asset` + inventory capability |
| Documento importante | No como core | `document_versions` |
| Proyecto largo | Futuro | `project`, dormido |
| Relación de custodia | No resource | relation / capability |
| Cargo / posición | No inicialmente | role / relation |
| Contrato / acuerdo | No resource | document + rule / policy |
| Obligación | No resource | projection |
| Reserva | No resource | atom / projection |
| Tarea | No resource | task layer |

**Regla:** si algo parece faltar como resource, probablemente es **capability** o **relation**, no resource.

---

## §2 — Capabilities candidatas (10)

Estas no existen aún en el catálogo V1 de `public.capabilities` (28 capabilities) pero llenan huecos reales de comportamiento. Muchas pueden ser `rule_shapes` reusables más que capabilities con DB nueva.

### 1. `eligibility` ⭐ PRIORITARIA

Quién puede participar en una mecánica según criterio algorítmico (no permission directo).

Ejemplos:
- Quién puede ser host
- Quién puede votar
- Quién entra a rotativa
- Quién puede reservar
- Quién está exento

**Por qué urgente:** resuelve elegantemente "David no entra en la rotativa" sin crear nuevo resource, sin tabla vertical, sin excepción fea. Tier 5 rotation cerró 2026-05-14 con este caso explícitamente fuera de scope ([[tier5-rotation-scope]]). Eligibility lo destrabaría.

### 2. `allocation`

Repartir recursos escasos según regla. No es booking puro (booking = "reservar"); allocation = "repartir según regla".

Ejemplos:
- Asignar turnos
- Asignar fechas de palco
- Repartir presupuesto
- Distribuir invitados
- Repartir tareas

### 3. `priority`

Orden de preferencia en colas/asignaciones.

Ejemplos:
- Socios fundadores tienen prioridad
- Host anterior va al final
- Quien no usó el palco tiene prioridad
- Prioridad por aportación

Puede vivir como rule/capability híbrida.

### 4. `quota`

Límites cuantitativos. Puede ser rule, pero conviene como capability/shape reusable.

Ejemplos:
- Máximo 4 invitados
- Máximo 2 reservas por mes
- Máximo $5,000 sin aprobación
- Máximo 3 faltas

### 5. `delegation`

Alguien actúa por otro.

Ejemplos:
- Jose reserva por David
- Admin paga por el grupo
- Tesorero aprueba por comité
- Padre responde por hijo

Muy real en grupos humanos.

### 6. `custodianship`

No es ownership. Es responsabilidad sobre un asset/fund sin ser dueño.

Ejemplos:
- Alguien cuida un asset
- Alguien tiene la llave
- Alguien administra el fondo
- Alguien responde por daños

Puede ser relation + capability.

### 7. `dispute_resolution`

Generalización del `appeals` actual (que está scoped a fines).

Ejemplos:
- Apelar multa
- Disputar gasto
- Reportar daño
- Impugnar reserva
- Resolver desacuerdo

### 8. `acknowledgement` (compliance_acknowledgement)

Aceptar reglas explícitamente. Importante para governance auditable.

Ejemplos:
- Acepto reglas del grupo
- Acepto reglamento del palco
- Acepto pagar cuota
- Acepto términos del viaje

### 9. `audit_export`

Exportar historial inmutable a formato externo. Crítico para clubes, asociaciones y palcos formales.

Ejemplos:
- Exportar historial
- Exportar ledger
- Exportar votos
- Exportar documentos

### 10. `recurrence`

Implícita en `resource_series` hoy. Reconocerla formalmente como capability.

Ejemplos:
- Cenas semanales
- Cuotas mensuales
- Turnos rotativos
- Eventos recurrentes

---

## §3 — Layers que podrían faltar

### 3.1 Relation overrides table

Para no acumular metadata random eterna en `group_members`. Shape propuesto:

```sql
member_capability_overrides (
  id uuid pk,
  group_id uuid,
  member_id uuid,
  capability text,
  effect text, -- allow | deny | exempt | priority
  scope_type text,
  scope_id uuid,
  reason text,
  created_at timestamptz
)
```

**No crear ahora salvo que la rotativa lo pida.** Si `eligibility` capability llega, esta tabla probablemente se vuelve necesaria como su backing store.

### 3.2 Rights / Relations distinción

Si `right` es resource_type, necesitamos distinguir explícitamente:

- **Resource:** "Costco Membership" = `right`
- **Relation:** "David can use Costco Membership"

Hoy esto puede mezclarse. Convendría regla de uso o policy explícita.

### 3.3 Obligation projection

No tabla primaria, pero sí vista clara: `obligations_view` derivada de `rules + atoms + ledger + workflows`. Generaliza `fines_view` para obligaciones no monetarias (promesas, commitments).

---

## §4 — Acción recomendada

Orden sugerido (priorización del founder):

1. **Eligibility capability** — diseñar shape + decidir si vive en `rule_shapes` o como capability propia. Demand-pull confirmado por Tier 5 rotation exclusion case.
2. **Allocation + priority + quota** — formalizar como `rule_shapes` reusables antes que como capabilities standalone (probablemente).
3. **Recurrence** — promote de implícito a explícito en catálogo `public.capabilities`.
4. **Delegation + custodianship** — diseño cuando un Resource lo pida (ej. palco con llaves, fondo con tesorero formal).
5. **Dispute_resolution + acknowledgement + audit_export** — Phase futura cuando llegue demand-pull (clubes formales, asociaciones, compliance).

**No crear `member_capability_overrides` hasta que eligibility tenga shape definido.**

---

## §5 — Lo que NO se cambia

- Resource type enum sigue congelado (6 valores).
- Constitution.md art. 5 sigue siendo la ley.
- Atom guards y mutabilidad rules intocadas.
- Project sigue diferido.
