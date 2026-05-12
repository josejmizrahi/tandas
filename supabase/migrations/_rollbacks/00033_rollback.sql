-- 00033 rollback — Restaurar NOT NULL en legacy columns de rules.
--
-- ATENCIÓN: si entre apply y rollback alguna row se inserta con NULL
-- en estas columnas, el rollback fallará con el SET NOT NULL. En ese
-- caso, identificar las rows ofensivas y backfilling antes de rollback:
--
--   update public.rules set
--     title = coalesce(title, name, 'Untitled'),
--     trigger = coalesce(trigger, '{}'::jsonb),
--     action = coalesce(action, '{"type":"fine"}'::jsonb),
--     enabled = coalesce(enabled, is_active),
--     status = coalesce(status, case when is_active then 'active' else 'inactive' end)
--   where title is null or trigger is null or action is null
--      or enabled is null or status is null;

alter table public.rules
  alter column code         set not null,    -- code era nullable original; ajustar si lo era
  alter column title        set not null,
  alter column trigger      set not null,
  alter column action       set not null,
  alter column enabled      set not null,
  alter column status       set not null;

-- Restaurar comentarios pre-deprecation (los originales no tenían
-- comentarios estructurados; el rollback los limpia).
comment on column public.rules.code         is null;
comment on column public.rules.title        is null;
comment on column public.rules.description  is null;
comment on column public.rules.trigger      is null;
comment on column public.rules.action       is null;
comment on column public.rules.enabled      is null;
comment on column public.rules.status       is null;
