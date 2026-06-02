-- ============================================================================
-- R.2-6 — FIX: cleanup robusto + tie-break determinista del canonical owner
-- ============================================================================
-- Bug encontrado por CI (e2e + db en DB fresca):
--
-- Cuando dos OWN rights tienen el mismo percent y el mismo created_at (misma
-- transacción → now() congelado), el ORDER BY del canonical sync era
-- no-determinista → en la live DB ganaba el contexto, en CI ganaba la persona →
-- _r2_cleanup_context no encontraba los rights del contexto → FK violation.
--
-- Fixes:
--   1. _sync_canonical_owner: tie-break determinista (percent desc, created_at
--      desc, id desc) — mismo input, mismo resultado en cualquier DB.
--   2. _r2_cleanup_context: borra rights por holder Y por resource sin asumir
--      quién quedó como canonical owner.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Tie-break determinista en el canonical sync
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._sync_canonical_owner()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_resource_id uuid := coalesce(new.resource_id, old.resource_id);
  v_owner uuid;
begin
  if coalesce(new.right_kind, old.right_kind) = 'OWN' then
    select holder_actor_id into v_owner
      from public.resource_rights
     where resource_id = v_resource_id and right_kind = 'OWN'
       and revoked_at is null and expired_at is null
       and (ends_at is null or ends_at > now())
     -- R.2-6: id como tie-break final → determinista
     order by coalesce(percent, 0) desc, created_at desc, id desc
     limit 1;
    if v_owner is not null then
      update public.resources set canonical_owner_actor_id = v_owner
       where id = v_resource_id and canonical_owner_actor_id is distinct from v_owner;
    end if;
  end if;
  return coalesce(new, old);
end; $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Cleanup helper robusto (no asume canonical owner)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._r2_cleanup_context(p_ctx uuid, p_actors uuid[], p_auths uuid[])
returns void
language plpgsql security definer set search_path = public, auth
as $$
begin
  delete from public.settlement_items where settlement_batch_id in
    (select id from public.settlement_batches where context_actor_id = p_ctx);
  delete from public.settlement_batches where context_actor_id = p_ctx;
  delete from public.money_splits where transaction_id in
    (select id from public.money_transactions where context_actor_id = p_ctx);
  delete from public.money_transactions where context_actor_id = p_ctx;
  delete from public.rule_evaluations where context_actor_id = p_ctx;
  delete from public.obligations where context_actor_id = p_ctx;
  delete from public.rules where context_actor_id = p_ctx;
  delete from public.event_participants where event_id in
    (select id from public.calendar_events where context_actor_id = p_ctx);
  delete from public.calendar_events where context_actor_id = p_ctx;

  -- R.2-6: rights y resources sin asumir canonical — por holder (ctx o personas),
  -- por canonical (ctx o personas), o por creador (ctx o personas)
  delete from public.reservation_conflicts where resource_id in
    (select id from public.resources
      where canonical_owner_actor_id = p_ctx or canonical_owner_actor_id = any(p_actors)
         or created_by_actor_id = p_ctx or created_by_actor_id = any(p_actors));
  delete from public.resource_reservations where context_actor_id = p_ctx;
  delete from public.decision_votes where decision_id in
    (select id from public.decisions where context_actor_id = p_ctx);
  delete from public.decisions where context_actor_id = p_ctx;
  delete from public.documents where context_actor_id = p_ctx;

  delete from public.resource_rights
   where holder_actor_id = p_ctx or holder_actor_id = any(p_actors)
      or resource_id in (
        select id from public.resources
         where canonical_owner_actor_id = p_ctx or canonical_owner_actor_id = any(p_actors)
            or created_by_actor_id = p_ctx or created_by_actor_id = any(p_actors));

  delete from public.resources
   where canonical_owner_actor_id = p_ctx or canonical_owner_actor_id = any(p_actors)
      or created_by_actor_id = p_ctx or created_by_actor_id = any(p_actors);

  delete from public.context_invites where context_actor_id = p_ctx;
  delete from public.role_assignments where context_actor_id = p_ctx;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = p_ctx;
  delete from public.roles where context_actor_id = p_ctx;
  delete from public.actor_memberships where context_actor_id = p_ctx;
  delete from public.actors where id = p_ctx;
  delete from public.person_profiles where actor_id = any(p_actors);
  delete from public.actors where id = any(p_actors);
  delete from auth.users where id = any(p_auths);
end; $$;

revoke all on function public._r2_cleanup_context(uuid, uuid[], uuid[]) from public, anon, authenticated;
