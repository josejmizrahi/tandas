-- 00031 — Outbox dispatcher RPCs.
--
-- Por qué: PostgREST schema cache no se refresca confiablemente con
-- `notify pgrst, 'reload schema'` después de un CREATE TABLE reciente
-- (observado durante el sprint APNs 2026-05-07: notifications_outbox
-- creado vía 00022 quedó visible para SQL pero PostgREST reportaba
-- columnas inexistentes por >5 min). El dispatcher no puede esperar.
--
-- Solución: las operaciones del dispatcher van por RPCs SECURITY DEFINER
-- en lugar de `.from('notifications_outbox')` calls. PostgREST resuelve
-- RPCs por nombre (no requiere reflection del schema), entonces los
-- llamadas son inmediatamente correctas tras el deploy.
--
-- Beneficio extra: claim_pending_outbox usa FOR UPDATE SKIP LOCKED, que
-- el JS client no expone via .update().select(). Atomicidad mejor que
-- el patrón row-level-lock implícito.

create or replace function public.claim_pending_outbox(p_limit int default 100)
returns table (
  id                  uuid,
  group_id            uuid,
  recipient_member_id uuid,
  notification_type   text,
  payload             jsonb,
  deep_link           text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  update public.notifications_outbox o
  set    dispatched_at = now()
  where  o.id in (
    select n.id
    from   public.notifications_outbox n
    where  n.dispatched_at is null
      and  n.scheduled_for <= now()
      and  n.dispatch_status = 'pending'
    order  by n.scheduled_for
    limit  p_limit
    for    update skip locked
  )
  returning
    o.id, o.group_id, o.recipient_member_id,
    o.notification_type, o.payload, o.deep_link;
end;
$$;

comment on function public.claim_pending_outbox is
  'Atomic claim de outbox rows pendientes. Marca dispatched_at=now() y devuelve las rows reclamadas. FOR UPDATE SKIP LOCKED previene double-claim entre invocaciones concurrentes del cron. Usado por dispatch-notifications edge function.';

revoke execute on function public.claim_pending_outbox(int) from public, anon;
grant  execute on function public.claim_pending_outbox(int) to service_role;

create or replace function public.mark_outbox_sent(p_outbox_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.notifications_outbox
  set    dispatch_status = 'sent'
  where  id = p_outbox_id;
$$;

create or replace function public.mark_outbox_failed(p_outbox_id uuid, p_error text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.notifications_outbox
  set    dispatch_status = 'failed',
         dispatch_error  = p_error
  where  id = p_outbox_id;
$$;

create or replace function public.mark_outbox_skipped(p_outbox_id uuid, p_reason text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.notifications_outbox
  set    dispatch_status = 'skipped',
         dispatch_error  = p_reason
  where  id = p_outbox_id;
$$;

revoke execute on function public.mark_outbox_sent(uuid)            from public, anon;
revoke execute on function public.mark_outbox_failed(uuid, text)    from public, anon;
revoke execute on function public.mark_outbox_skipped(uuid, text)   from public, anon;
grant  execute on function public.mark_outbox_sent(uuid)            to service_role;
grant  execute on function public.mark_outbox_failed(uuid, text)    to service_role;
grant  execute on function public.mark_outbox_skipped(uuid, text)   to service_role;
