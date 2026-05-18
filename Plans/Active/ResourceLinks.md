# Ruul — Resource Links (Fase 2)

**Status:** Draft 2026-05-17. Founder directive.
**Companion of:** `Plans/Active/CapabilityTiers.md` (Fase 1 — universalidad), `Plans/Active/AtomProjection.md` (atoms doctrine), `Plans/Active/Constitution.md` (Artículos 2 y 11).
**Supersedes:** `Plans/Archive/ResourceMesh-superseded-2026-05-17.md` (frame anterior; cambió al cerrar la doctrina de Tier 0/0.5).
**Scope:** Lleva Ruul de "objetos inteligentes" a "estructura relacional viva". El grafo polimórfico entre resources se vuelve primitiva de primera clase, modelado como atoms (no como filas mutables).

> Hasta hoy, cada resource es un nodo aislado con capabilities propias. Fase 2 introduce el tejido. La diferencia entre Ruul y Notion/Airtable/Odoo no son los nodos — son las **relaciones tipadas, históricas y semánticas** que los conectan. Sin esto, Ruul es un CRUD bonito. Con esto, es ontología operativa.

---

## §1 — Principio cardinal

> **Las relaciones son tan importantes como los resources.** Ambos son verdad estructural, ambos son históricos, ambos son atomizables. Un grafo de Ruul es `(resources, links)` con `links` siendo ciudadanos de primera, no metadata de algún resource.

Corolario: **un link es un atom** (append-only), no una fila mutable con `active bool`. Quién creó el vínculo, cuándo, por qué — todo importa. Cambiar un vínculo es **crear un atom nuevo**, no editar el viejo.

---

## §2 — Cuatro niveles ortogonales

Fase 2 se compone de 4 niveles. Cada uno depende del anterior pero produce valor por sí mismo.

```
Nivel 1 — Link ontology (catálogo cerrado de relation_types)
Nivel 2 — Link atoms (resource_link_created / removed)
Nivel 3 — Current graph projection (resource_links_view)
Nivel 4 — Universal UI ("Vinculado con…" en todo detail)
```

---

## §3 — Nivel 1: Link ontology

### Catálogo cerrado, no free text

`relation_type` es un **enum cerrado** sancionado en código + SQL. Nuevos tipos requieren edit a este doc + migración explícita. No se permite `relation_type = "whatever"`.

**Razón**: free text mata la ontología. Sin catálogo, dos founders podrían tipar la misma relación como `"finances"` y `"funds"` y el grafo se vuelve ilegible. El catálogo es la columna vertebral semántica.

### Reglas del catálogo

1. **Cada relation_type declara `(from_type[], to_type[])`** — la matriz de qué types pueden estar a cada lado del vínculo. Server-side validation.
2. **Dirección semántica importante**: `fund funds asset` es distinto de `asset funded_by fund`. Elegimos UNA dirección canónica; el reverse se infiere por query.
3. **Cardinalidad**: cada relation declara si es `1:1`, `1:N`, `N:N`. Default `N:N` (cualquier resource puede vincularse a varios).
4. **Lifecycle del link**: cada relation puede declarar si es `permanent` (no se rompe), `mutable` (típico), o `expirable` (con timestamp).

### Catálogo V1 propuesto

Basado en tu lista, ajustado para descartar lo que no mapea limpio (ver §8 — open questions):

| relation_type | from_type | to_type | cardinalidad | semántica |
|---|---|---|---|---|
| `uses` | event, fund | asset, space, slot, fund | N:N | "X consume/depende de Y para operar" |
| `funds` | fund | asset, event, space | N:N | "este fondo financia esto" |
| `governs` | right | fund, asset, space, slot | N:N | "este derecho controla esto" |
| `located_in` | asset, slot | space | N:1 | "vive físicamente acá" |
| `scheduled_in` | event, slot | space | N:1 | "ocurre acá" |
| `reserves` | slot | space, asset | N:1 | "este slot reserva esto" |
| `grants_access_to` | right | asset, space, slot | N:N | "este right da acceso a esto" |

7 relations V1. Lo justo para abrir el grafo sin sobrediseñar.

**Lo que NO está en V1** (ver §8 para razones):
- `owns` — semántica ambigua a nivel resource-to-resource (member→resource lo cubre `right`)
- `belongs_to_series` — ya existe como `resources.series_id` FK
- `fulfills` — payment no es resource type
- `derives_from` — projection lineage es server-side, no actor-creado

---

## §4 — Nivel 2: Link atoms

### Schema

Dos atom types nuevos en el whitelist `is_known_system_event_type`:

```
resource_link_created
resource_link_removed
```

Tabla append-only `resource_link_events` (o reutilizar `system_events` con payload tipado):

```sql
-- Opción A: usar system_events (preferida — atoms ya viven ahí)
INSERT INTO system_events (group_id, event_type, payload, member_id, occurred_at)
VALUES (
  '...', 'resource_link_created',
  jsonb_build_object(
    'from_resource_id', '...',
    'from_resource_type', 'fund',
    'to_resource_id', '...',
    'to_resource_type', 'asset',
    'relation_type', 'funds'
  ),
  '...',  -- actor
  now()
);
```

Ventaja Opción A: integra con el rule engine + history feed automáticamente.

### Operaciones

- `link_resources(from, to, kind)` → INSERT atom `resource_link_created`
- `unlink_resources(from, to, kind)` → INSERT atom `resource_link_removed`
- **Nunca UPDATE/DELETE** sobre atoms anteriores.

### Migración de `resource_links` actual

La tabla `resource_links` actual tiene `unlinked_at` (mutable). Decisión:

- **Opción 1 (limpia)**: deprecar `resource_links` como fuente. Volver projection-only sobre los atoms.
- **Opción 2 (transicional)**: mantener `resource_links` como projection cacheada actualizada por trigger sobre los atoms.

Recomendación: Opción 2 para Fase 2 (cambio mínimo, performance estable). Opción 1 en Phase 1.1 cleanup si la proyección dinámica resulta lenta.

---

## §5 — Nivel 3: Current graph projection

### Vista

```sql
CREATE VIEW resource_links_view AS
WITH latest AS (
  SELECT
    payload->>'from_resource_id' AS from_id,
    payload->>'to_resource_id'   AS to_id,
    payload->>'relation_type'    AS relation_type,
    event_type,
    occurred_at,
    member_id AS actor,
    ROW_NUMBER() OVER (
      PARTITION BY payload->>'from_resource_id',
                   payload->>'to_resource_id',
                   payload->>'relation_type'
      ORDER BY occurred_at DESC
    ) AS rn
  FROM system_events
  WHERE event_type IN ('resource_link_created', 'resource_link_removed')
)
SELECT
  from_id::uuid AS from_resource_id,
  to_id::uuid   AS to_resource_id,
  relation_type,
  actor,
  occurred_at AS established_at
FROM latest
WHERE rn = 1 AND event_type = 'resource_link_created';
```

"Última operación gana" — si el más reciente atom es `_created`, el link está activo; si es `_removed`, no.

### Read patterns

Cuestiones que la projection debe responder rápido:

```text
"¿qué resources gobiernan este asset?"
  → SELECT * FROM resource_links_view WHERE to_resource_id = $1 AND relation_type = 'governs'

"¿qué fondos financian este evento?"
  → SELECT from_resource_id FROM resource_links_view WHERE to_resource_id = $event AND relation_type = 'funds'

"¿qué derechos dan acceso a este espacio?"
  → SELECT from_resource_id FROM resource_links_view WHERE to_resource_id = $space AND relation_type = 'grants_access_to'
```

Index sugerido: `(to_resource_id, relation_type)`, `(from_resource_id, relation_type)`.

---

## §6 — Nivel 4: Universal UI

### Sección "Vinculado con…"

Renderizada por **cualquier** resource detail, gateada por `caps.contains("links")` (nuevo Tier 0 cap — ver §8).

Layout:

```
VINCULADO CON
├── USA              (out-edges, relation IN [uses, reserves, located_in])
│   ├── chip → resource_type icon + name → tap navega
│   └── …
├── FINANCIADO POR   (in-edges, relation = funds)
│   └── …
├── GOBERNADO POR    (in-edges, relation = governs)
│   └── …
└── + Vincular nuevo
```

Sub-secciones agrupan por relation_type. La etiqueta humana sale de un mapping (in Spanish/EN) en código.

### Botón "+ Vincular"

Abre un picker que:
1. Filtra resources del grupo por las (from_type, to_type) válidas según el catálogo
2. Permite elegir `relation_type` cuando hay ambigüedad
3. Llama `link_resources(from, to, kind)` → emit atom

### Permission gate

Por ahora: `viewerIsAdmin` puede crear/romper links. En Phase 3+ se moverá a `resolve_governance(action='resource.link')` para permitir policies más finas.

---

## §7 — Lo que Fase 2 NO incluye

Per directiva founder: **hacer visible primero, automático después**.

- ❌ Money flows automáticos entre resources vinculados (ej: "expense en evento debita fund linked")
- ❌ Rules que disparen efectos cross-resource
- ❌ Multi-currency cross-resource auto-conversión
- ❌ Validación cycle-detection en el grafo (ej: `A uses B, B uses A` permitido salvo que el catálogo lo prohíba)

Esto es Fase 3+.

---

## §8 — Open questions (necesito confirmación antes de migración)

### Q1 — Catálogo V1: ¿7 relations o subset?

Tu lista tenía 11. Mi propuesta V1 tiene 7 (descartados los 4 que no mapean limpio). ¿Aprobás el subset o querés incluir/modificar algunos?

**Descartados con razón**:
- `owns` — ambiguo entre resources. Member→resource es lo cubre `right.holder_member_id`. ¿Quisiste decir "fund owns asset" como "el fondo es legalmente dueño del activo que compró"? Si sí, es una relation legítima y la agrego con `(fund, [asset, space])`.
- `belongs_to_series` — ya está como `resources.series_id` FK. ¿Querés duplicar como link para uniformidad de query, o lo mantenemos como FK optimizada?
- `fulfills` — payment no es resource type; es atom (`ledger_entry`). Si querés vincular pagos a eventos/fondos, esa relación ya vive en `ledger_entries.resource_id`. ¿Otra cosa en mente?
- `derives_from` — projection lineage es server-side computed (vistas materializadas). No suelen ser actor-creados. ¿O pensabas exponer linkage entre, ej, `event → projection_of_event`?

### Q2 — Capability `links` como Tier 0

Para que la sección "Vinculado con…" aparezca universalmente, necesito una cap `links`. ¿La promovemos a Tier 0 (los 6 types) o la dejamos opt-in?

Mi recomendación: **Tier 0**. Cualquier resource puede participar del grafo; la cap declara que SÍ tiene la surface "vinculado con". Sin esta cap, el resource sigue siendo nodo del grafo (los links son atoms separados), pero no muestra la UI.

### Q3 — `unlink` requires permission?

Hoy el RPC `unlink_resource_from_event` no chequea quién creó el link. ¿Cualquier admin puede romper cualquier link, o sólo quien lo creó / founder?

Mi recomendación: admin del grupo puede romper cualquier link. Refinable en Phase 3 vía `resolve_governance(action='resource.unlink')`.

### Q4 — Migración del data actual (cero rows hoy)

`resource_links` tiene 0 filas en prod. Migración es trivial. Pero la decisión es **cómo coexisten los 2 patrones**:

- Mantener `resource_links` como projection cacheada (Opción 2 en §4) — recomendación.
- Borrar `resource_links` y proyectar dinámicamente desde atoms.

Mi recomendación: Opción 2 — preserva los RPCs existentes (`link_resource_to_event`) como wrappers que ahora también emiten atom + actualizan projection. Backward-compat sin esfuerzo.

---

## §9 — Plan de ejecución (después de confirmar §8)

Sólo cuando las 4 preguntas estén respondidas. NO antes.

### Slice 1 — Schema + RPC base
- Catálogo `relation_type` en código (Swift + SQL CHECK constraint)
- Whitelist atom types en `is_known_system_event_type`
- RPC `link_resources(from, to, kind)` + `unlink_resources(from, to, kind)`
- Mig: actualizar `resource_links` table to projection-only role + trigger desde atoms

### Slice 2 — Vista + indices
- `resource_links_view` (last-write-wins projection)
- Indices `(to_resource_id, relation_type)` y `(from_resource_id, relation_type)`

### Slice 3 — UI universal
- `ResourceLinksSectionView` polimórfica
- Picker para "+ Vincular"
- Backfill cap `links` para todos los resources existentes

### Slice 4 — Atoms en history feed
- `system_events` ya rendea automáticamente — verificar que el copy es claro ("Bros vinculó Fondo Bbva → Auto 2018 (funds)")
- Filtros básicos en feed

### Slice 5 — Tests + docs
- Tests del catálogo (server-side rejection de tuplas inválidas)
- Test de projection (último atom gana)
- Doc actualizado

Estimación total: ~1.5 semanas.

---

## §10 — Doctrina post-Fase 2

> *"Cada resource es nodo del grafo. Cada relación entre dos resources es un atom histórico tipado por el catálogo. La pregunta '¿qué cosas se relacionan con esta?' siempre tiene respuesta server-side y se renderea en todos los detalles. Las relaciones son tan canónicas como los nodos."*

Eso es **tejido**. No CRUD.
