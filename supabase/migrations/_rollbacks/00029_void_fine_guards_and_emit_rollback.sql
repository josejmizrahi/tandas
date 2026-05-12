-- 00029 rollback — restore 00016 void_fine body (no guards, no emissions).
create or replace function public.void_fine(p_fine_id uuid, p_reason text default null)
returns public.fines
language plpgsql security definer set search_path = public as $$
declare
  f public.fines;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select * into f from public.fines where id = p_fine_id;
  if f.id is null then raise exception 'fine not found'; end if;
  if not public.is_group_admin(f.group_id, uid) then
    raise exception 'only admins can void fines';
  end if;

  update public.fines
     set status = 'voided',
         waived = true,
         waived_at = now(),
         waived_reason = p_reason
   where id = p_fine_id
   returning * into f;

  return f;
end;
$$;
revoke execute on function public.void_fine(uuid, text) from public, anon;
grant  execute on function public.void_fine(uuid, text) to authenticated;
