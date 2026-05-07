# `system_events` Archival Plan

> Audit doc § 5.1 #5 (cerrar F0) — documentación papel ahora,
> implementación pre-Fase 4 cuando el volumen lo demande.
>
> Versión 2026-05-07.

---

## 0. Estado actual (verificado vía MCP 2026-05-07)

```
total_size:   128 kB
row_count:    82
unprocessed:  0
oldest:       2026-05-04 08:18:07 UTC
newest:       2026-05-07 07:59:34 UTC
```

3 días de operación con 1 grupo activo: ~27 rows/día. Ratio dominante: `rsvpSubmitted` (63), `rsvpChangedSameDay` (9), `fineOfficialized` (4).

## 1. Por qué importa

`system_events` es append-only y crece sin techo. La query del cron `process-system-events` usa idx parcial sobre `processed_at IS NULL`, así que **el procesamiento no degrada con tamaño**. Pero:

- Queries de `GroupHistoryView` (lecturas filtradas por `group_id` + `event_type` + rango fecha) se vuelven lentas a > 1M rows.
- Costo Supabase escala lineal con storage.
- Backups + replication slot WAL crecen.
- Reglas de mensajería (e.g., reasignar miembros) requieren scan completo si no están particionadas.

## 2. Proyección de volumen

Asunciones conservadoras:

| Eje | Valor |
|---|---|
| Eventos por grupo activo por mes | ~800 |
| Grupos activos pre-Fase 1 launch | 30-50 |
| Grupos activos pre-Fase 2 (post-launch) | 200-500 |
| Grupos activos pre-Fase 4 | 5,000-15,000 |

```
Pre-Fase 1:   30 grupos × 800 = 24k rows/mes
Pre-Fase 2:  300 grupos × 800 = 240k rows/mes
Pre-Fase 4: 10k grupos × 800 = 8M rows/mes
```

A ~150 bytes por row promedio, eso es:
- Pre-Fase 1: ~3.6 MB/mes (cero problema)
- Pre-Fase 2: ~36 MB/mes (irrelevante)
- Pre-Fase 4: ~1.2 GB/mes (empieza a importar)

**Trigger de implementación**: cuando `system_events` supere los 5M rows total OR la query p99 de `GroupHistoryView` supere los 200ms. Lo que llegue primero. Estimado: 6-12 meses post-launch de Fase 1, depende de tracción.

## 3. Estrategia de partitioning (cuando se implemente)

### 3.1 PARTITION BY RANGE (occurred_at) MONTHLY

Postgres native partitioning. Cada mes es su propia tabla física: `system_events_2026_05`, `system_events_2026_06`, etc.

**Mecánica**:
1. Convertir `system_events` → particionada por `occurred_at` rango mensual (vía `pg_partman` extension).
2. Crear partition antes del primer evento de cada mes (cron job o trigger).
3. Drop partitions > 90 días después de copiarlas a cold storage.

**Beneficios**:
- Queries con `occurred_at >= now() - interval '30 days'` solo scanean particiones recientes (typical history view).
- Drop de particiones viejas es instantáneo (no reclaim por row).
- Backup eficiente: solo particiones recientes en hot path.

### 3.2 Cold storage destino

Tres opciones, en orden de preferencia para V1:

**Opción A — Supabase Storage bucket (recomendada V1)**
- Export mensual: `pg_dump --table system_events_<YYYY_MM> | gzip | upload to `archive/system_events/<YYYY_MM>.sql.gz``
- Cuesta el storage (negligible para esta volumetría)
- Re-import vía `pg_restore` para auditorías retroactivas (raras)
- Sin search a través de cold data — aceptable porque "history > 90 días" es 1% del use case

**Opción B — S3/R2 con Parquet**
- Convert SQL → Parquet via DuckDB pipeline
- Permite query con DuckDB sin re-import
- Más infra, requiere pipeline mantenido
- V2/V3 si volume justifica

**Opción C — Postgres FDW a otra DB**
- Foreign tables a un cluster de archivo
- Mismo SQL surface
- Requiere segundo cluster (costo)
- V3 si necesidad real

V1 = **Opción A**.

### 3.3 Política de retención

| Edad | Donde vive | Acceso |
|---|---|---|
| 0–30 días | Partition activa (hot) | Indexed, fast |
| 31–90 días | Partition reciente (cold tier en mismo cluster) | Indexed, slower |
| 91+ días | Supabase Storage (archivo) | Re-import on demand |

90 días cubre el 99% de las queries de history. Más allá es forensics.

**Excepción**: events de tipo `fineOfficialized`, `appealResolved`, `voteResolved` se preservan en hot indefinidamente (es lo que respalda disputas). Esto se logra con partial index + manual exclusion del archive job para esos tipos.

## 4. Implementación — pasos cuando llegue el momento

### 4.1 Migration `00033_system_events_partitioned.sql`

```sql
-- 1. Habilitar pg_partman
create extension if not exists pg_partman schema partman;

-- 2. Renombrar tabla actual a temp
alter table public.system_events rename to system_events_legacy;

-- 3. Crear nueva tabla particionada por occurred_at
create table public.system_events (
  -- mismos columns que legacy
  ...
) partition by range (occurred_at);

-- 4. Crear particiones mensuales con pg_partman
select partman.create_parent(
  p_parent_table => 'public.system_events',
  p_control => 'occurred_at',
  p_type => 'native',
  p_interval => 'monthly',
  p_premake => 3   -- pre-create 3 months ahead
);

-- 5. Migrar data desde legacy en chunks
-- (script aparte, paginado, durante low-traffic window)

-- 6. Re-create indexes en master + propagate a particiones nuevas
create index system_events_unprocessed_idx
  on public.system_events(occurred_at)
  where processed_at is null;
-- ... resto de indexes ...

-- 7. Validar paridad row count + spot-check queries
-- 8. Drop legacy table
```

Migration script grande. Plan dedicado pre-Fase 4.

### 4.2 Cron job de archivo

Edge function `archive-old-events`:
- Schedule: diario a las 03:00 UTC
- Para cada partition con `occurred_at` final > 90 días atrás:
  - Export a `archive/system_events/<YYYY_MM>.sql.gz` en Supabase Storage
  - Verificar upload (size + checksum)
  - DROP PARTITION
- Excluir tipos preservados (fineOfficialized, etc.) — re-INSERT de esos rows a la partition activa antes del drop

### 4.3 Restore on-demand

Procedimiento manual documentado en `Plans/Runbooks/SystemEventsRestore.md` (TBD pre-implementación):
1. Identificar mes(es) requeridos
2. Download desde Supabase Storage
3. `psql -f` a cluster temp
4. Query desde temp
5. Drop temp

V2 — UI admin para self-service restore.

## 5. Riesgos

| Riesgo | Severidad | Mitigación |
|---|---|---|
| Migration de partitioning bloquea tabla > minutos | Alta | Hacer durante maintenance window pre-anunciado. Test en staging primero. |
| pg_partman no disponible en Supabase tier | Media | Verificar antes de planear. Alt: manual partition management. |
| Eventos perdidos durante migration | Crítica | Doble-write durante cutover (legacy + nueva), reconcile, drop legacy |
| Cold storage corruption | Media | Checksum + re-verify mensual. Backup del bucket. |
| Queries cross-partition lentas | Media | EXPLAIN ANALYZE pre-implementación. Indexes propagation correcta. |
| Restore from cold storage > 1h | Baja | Documentar SLA. Es forensic, no real-time. |

## 6. Checkpoint de revisión

Re-evaluar este plan **cuando** se cumpla cualquiera de:

- `system_events.row_count > 1,000,000`
- p99 de `GroupHistoryView` query > 100ms
- Storage cost de la tabla > $5/mes
- Backup time > 30s

Hasta entonces, no se implementa nada — la tabla es eficiente al volumen actual.

## 7. Estado al 2026-05-07

- ✅ Plan documentado (este archivo)
- ⏸️ Implementación diferida (fuera de F0; pre-Fase 4 según métricas)
- 🔍 Métricas a monitorear: row_count, query p99, storage size

---

## Apéndice — comandos útiles para monitoreo

```sql
-- Tamaño y conteo
select
  pg_size_pretty(pg_total_relation_size('public.system_events')) as total_size,
  (select count(*) from public.system_events) as row_count,
  (select min(occurred_at) from public.system_events) as oldest;

-- Distribución por type (¿qué eventos dominan el volumen?)
select event_type, count(*) as cnt
from public.system_events
group by event_type
order by cnt desc;

-- Distribución temporal (¿el volumen es estable o explosivo?)
select date_trunc('day', occurred_at) as day, count(*) as cnt
from public.system_events
where occurred_at > now() - interval '30 days'
group by 1
order by 1 desc;

-- Hot vs cold ratio (¿cuánto del volumen es < 90 días?)
select
  count(*) filter (where occurred_at > now() - interval '30 days') as hot_30d,
  count(*) filter (where occurred_at > now() - interval '90 days') as warm_90d,
  count(*) as total
from public.system_events;
```

Correr trimestralmente para tracking.
