-- Doctrine fix: group_resource_transactions.resource_id debe ser NULL-able.
-- Razones:
--   * Un gasto sin fondo dedicado cae al pool implícito (doctrine_shared_money.md).
--   * record_settlement ya escribe NULL cuando ninguna obligación cerrada
--     tiene source_resource_id.
--   * Mantener NOT NULL forzaría a crear un "default pool" auto-instanciado
--     por grupo, lo cual es trabajo separado de UX.

alter table public.group_resource_transactions
  alter column resource_id drop not null;

-- El FK on delete cascade pierde sentido si la columna puede ser null;
-- cambiamos a on delete set null para coherencia con el resto del schema.

alter table public.group_resource_transactions
  drop constraint group_resource_transactions_resource_id_fkey;

alter table public.group_resource_transactions
  add constraint group_resource_transactions_resource_id_fkey
  foreign key (resource_id) references public.group_resources(id) on delete set null;

-- El composite same-group FK (resource_id, group_id) sigue válido — Postgres
-- permite null en el lado child sin que el FK se rompa (match simple default).
