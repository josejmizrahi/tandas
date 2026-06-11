-- ============================================================================
-- AUDIT.16 — PKs particionables en las tablas infinitas (2026-06-11)
-- ============================================================================
-- Recomendación §2 de la revisión de escalabilidad (2026-06-11): las únicas
-- tablas que crecen sin límite por diseño son activity_events (memoria
-- institucional append-only) y ledger_entries (proyección contable). El
-- particionado declarativo por rango de occurred_at exigirá que la clave de
-- partición forme parte de la PK; cambiarla hoy (1.1k filas) es gratis,
-- cambiarla con 100M de filas es una migración épica.
--
-- Verificado antes de tocar: CERO foreign keys referencian activity_events o
-- ledger_entries (pg_constraint), y occurred_at es NOT NULL en ambas.
-- id sigue siendo gen_random_uuid() (colisión práctica nula); la unicidad
-- compuesta (id, occurred_at) es suficiente y la PK sigue sirviendo lookups
-- por id (columna líder).
-- NOTA: esto NO particiona nada todavía — solo deja la fundación lista.
-- ============================================================================

alter table public.activity_events
  drop constraint if exists activity_events_pkey,
  add primary key (id, occurred_at);

alter table public.ledger_entries
  drop constraint if exists ledger_entries_pkey,
  add primary key (id, occurred_at);

comment on constraint activity_events_pkey on public.activity_events is
  'AUDIT.16: PK compuesta (id, occurred_at) para habilitar particionado por rango sin migración futura.';
comment on constraint ledger_entries_pkey on public.ledger_entries is
  'AUDIT.16: PK compuesta (id, occurred_at) para habilitar particionado por rango sin migración futura.';
