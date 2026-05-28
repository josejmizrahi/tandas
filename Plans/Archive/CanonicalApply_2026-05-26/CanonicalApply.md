# CanonicalApply.md — Cómo aplicar el schema canónico

> Receta operativa para validar `00001_canonical_schema.sql` sin tocar prod.
> Una vez validado en un target limpio, A8 ejecuta la misma secuencia contra
> producción con backup previo.

---

## Files en este bundle

| Orden | Archivo | Líneas | Propósito |
|---|---|---:|---|
| 1 | `CanonicalReset.sql` | ~50 | `DROP SCHEMA public CASCADE` + re-grants Supabase. |
| 2 | `CanonicalSchema.sql` | ~870 | Tablas, triggers, helpers, seeds, RPC `create_group`. |
| 3 | `CanonicalRLS.sql` | ~640 | Policies por tabla + realtime publication. |
| 4 | `CanonicalRPCs.sql` | _pendiente_ | Bodies de las 50 RPCs (catálogo en `CanonicalSchema_RPCs.md`). |

Total apply hoy: ~1560 líneas. Tras escribir RPCs subirá a ~4000.

---

## Targets posibles

Pick uno. Los tres dan el mismo resultado funcional; difieren en setup y costo.

### Opción A — Local Supabase (`supabase start`) — recomendada

**Pros:** gratis, repetible, rápido, sin tocar prod ni infra.
**Cons:** requiere Docker corriendo.

```bash
# 1. Inicializar local stack (una vez por máquina)
cd /Users/jj/code/tandas/supabase
supabase start
# Anota la connection string que imprime (e.g. postgres://postgres:postgres@localhost:54322/postgres)

# 2. Aplicar bundle en orden
psql "<connection_string>" -f /Users/jj/code/tandas/Plans/Active/CanonicalReset.sql
psql "<connection_string>" -f /Users/jj/code/tandas/Plans/Active/CanonicalSchema.sql
psql "<connection_string>" -f /Users/jj/code/tandas/Plans/Active/CanonicalRLS.sql
# (cuando esté listo:)
# psql "<connection_string>" -f /Users/jj/code/tandas/Plans/Active/CanonicalRPCs.sql

# 3. Smoke test
psql "<connection_string>" -c "select count(*) from public.permissions;"   -- expect 44
psql "<connection_string>" -c "\dt public.*"                                -- expect ~43 tables
psql "<connection_string>" -c "select tgname from pg_trigger where tgrelid::regclass::text like 'public.group_%' order by 1;"
```

Si algo falla, corregir la SQL en el draft y re-aplicar (los archivos son idempotentes salvo el reset que ya dropea).

### Opción B — Nuevo Supabase project (free tier)

**Pros:** misma surface que prod (RLS, realtime, storage, edge functions), sin
gastar nada (free tier suficiente para 115 rows).
**Cons:** requiere setup manual en dashboard.

1. Founder crea project en https://supabase.com/dashboard (free tier).
2. Founder me pasa el `project_ref` (XXX en `https://XXX.supabase.co`).
3. Yo uso `mcp__supabase__apply_migration` apuntando a ese ref con cada archivo.
4. Smoke tests via `mcp__supabase__execute_sql`.

Cuando termine la validación, el project se deja vivo como dev permanente o se borra.

### Opción C — Branch sobre main project (NO recomendada)

Requiere `confirm_cost_id` que no tengo expuesto, hereda las 343 migraciones legacy con `MIGRATIONS_FAILED`, y cobra por hora. Solo válido si los otros caminos fallan.

---

## Aplicación al cutover de producción (A8)

La misma secuencia (Reset → Schema → RLS → RPCs) se aplica a prod en A8, **con
tres cambios obligatorios**:

1. **Backup completo previo:**
   ```bash
   pg_dump "postgres://postgres.<ref>:<pass>@<host>:5432/postgres" > backup_pre_canonical_$(date +%Y%m%d_%H%M).sql
   ```
2. **Ventana de mantenimiento corta** (5–15 min). iOS app quedará rota hasta B1.
3. **Import inmediato de data** ejecutando el script de migración (`CanonicalSchema_Migration.md`) antes de levantar tráfico.

Rollback: `psql ... < backup_pre_canonical_*.sql` restaura todo lo viejo.

---

## Estado actual del bundle

- [x] Reset SQL escrita.
- [x] Schema SQL escrita y revisada por founder.
- [x] RLS SQL escrita.
- [ ] RPCs SQL — pendiente. El catálogo está; faltan los bodies (~50 funciones).
- [ ] Migration TS script — pendiente (spec en `CanonicalSchema_Migration.md`).
- [ ] Edge functions — pendiente. Reescribir `ruleEngine.ts`, `dispatch-notifications`, `finalize-votes`, `record-system-event` contra el schema canónico.

---

## Próximo paso

Founder pick: **Opción A (local docker)** o **Opción B (nuevo dev project)**.

Si A: corre `supabase start` y compárteme la connection string; yo guío el apply.

Si B: crea el project en dashboard y compárteme `project_ref`; yo uso MCP para aplicar.

Cualquiera de las dos: una vez verde el smoke test, sigo con el RPCs.sql.
