-- 00147 — Constitution §14 Step 1 + Step 2: freeze ResourceType, decouple modules.
--
-- Context
-- =======
-- Constitución Ruul §1 artículo 2 (Resource es el objeto coordinado) fija
-- el enum `resource_type` a 6 valores canónicos:
--     event, fund, asset, space, slot, right
--
-- Cualquier subtype nuevo pasa el filtro ontológico (§13). Eliminados:
--     settlement   → ledger_entry type
--     contribution → ledger_entry type
--     proposal     → vote (subject_type='general')
--     assignment   → FK / atom relation
--     rotation     → rule pattern scoped a series
--     guestPass    → rsvp especial o ledger right
--     booking      → atom append-only (bookings table Phase 2)
--     position     → role en group_members.roles (o Resource sólo si cumple
--                    criterios estrictos: mandato, sucesión, elecciones, etc.)
--
-- Constitución §1 artículo 6 (Modules son bundles activables): los modules
-- referencian capabilities + provee rules semilla + provee system_event types.
-- NO declaran resource_types. Resource types son del platform.
--
-- Estado pre-migración (audit 2026-05-13)
-- ========================================
-- resources.resource_type: 3 valores vivos (event:11, asset:1, fund:1).
--                          0 filas con tipos a eliminar.
-- resource_series:         0 filas.
-- group_policies.target_resource_type: todos NULL.
-- rule_shapes.valid_resource_types:    sólo ['event'] o vacío.
-- modules.provided_resource_types:     2 filas contaminadas
--     rotating_position: [position, assignment, rotation]
--     slot_assignment:   [slot, booking, asset]
-- Estas 2 filas se limpian de raíz al droppear la columna.
--
-- Cambios
-- =======
-- 1. DROP COLUMN modules.provided_resource_types (mata la columna que
--    permite a un module declarar types — violación de §1 artículo 6).
-- 2. ADD CHECK resources.resource_type IN (canonical 6).
-- 3. ADD CHECK resource_series.resource_type IN (canonical 6).
-- 4. ADD CHECK group_policies.target_resource_type IN (canonical 6) OR NULL.
-- 5. ADD CHECK rule_shapes.valid_resource_types <@ (canonical 6).
-- 6. COMMENT en resources.resource_type apuntando a la Constitución.
--
-- Reversión
-- =========
-- Para revertir: DROP CONSTRAINT *_canonical en cada tabla; ALTER TABLE
-- modules ADD COLUMN provided_resource_types text[] DEFAULT '{}'. La
-- data en los 2 modules contaminados NO se restaura (eran legacy).
--
-- Companion: Plans/Active/Constitution.md §14 Step 1+2.

BEGIN;

-- ---------------------------------------------------------------------------
-- Part 1 — Decouple modules from resource_types (§14 Step 2)
-- ---------------------------------------------------------------------------

ALTER TABLE modules
    DROP COLUMN provided_resource_types;

COMMENT ON TABLE modules IS
    'Bundles activables (basic_fines, rotating_host, rsvp, check_in, '
    'appeal_voting, slot_assignment, …). Cada module provee: '
    'capabilities + rules semilla + system_event types. '
    'NO declara resource_types — los types son del platform (Constitución §1 art. 6).';

-- ---------------------------------------------------------------------------
-- Part 2 — Freeze resource_type to canonical 6 (§14 Step 1)
-- ---------------------------------------------------------------------------

ALTER TABLE resources
    ADD CONSTRAINT resources_resource_type_canonical
    CHECK (resource_type IN ('event', 'fund', 'asset', 'space', 'slot', 'right'));

COMMENT ON COLUMN resources.resource_type IS
    'Canonical 6: event, fund, asset, space, slot, right. '
    'Nuevos types pasan el filtro ontológico de Constitución §13 antes de añadirse aquí.';

ALTER TABLE resource_series
    ADD CONSTRAINT resource_series_resource_type_canonical
    CHECK (resource_type IN ('event', 'fund', 'asset', 'space', 'slot', 'right'));

ALTER TABLE group_policies
    ADD CONSTRAINT group_policies_target_resource_type_canonical
    CHECK (
        target_resource_type IS NULL
        OR target_resource_type IN ('event', 'fund', 'asset', 'space', 'slot', 'right')
    );

ALTER TABLE rule_shapes
    ADD CONSTRAINT rule_shapes_valid_resource_types_canonical
    CHECK (
        valid_resource_types <@ ARRAY['event', 'fund', 'asset', 'space', 'slot', 'right']::text[]
    );

COMMIT;
