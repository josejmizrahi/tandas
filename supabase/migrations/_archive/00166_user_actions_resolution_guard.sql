-- 00166 — user_actions resolution-only guard (Constitution audit Gap 4).
--
-- Why
-- ===
-- Constitution Article 8 listed `user_actions inbox` as a projection,
-- but the live table is mutable: triggers INSERT rows (when a fine
-- lands, when a vote opens, when a host is assigned…), and a flip
-- of `resolved_at: null → ts` happens when the user taps through or
-- a cascade trigger resolves the row. That's not a pure projection —
-- it's the same "Atom-ish" pattern already documented in
-- `Plans/Active/AtomProjection.md` for `events.closed_at`,
-- `group_members.active`, and `invites.used_at`: a one-way terminal
-- transition that nothing should be able to undo.
--
-- The doctrinal cleanup is twofold:
--
--   1. Reclassify user_actions as Atom-ish (handled in the companion
--      doc commit: AtomProjection.md table row + Constitution Article 8
--      example list).
--   2. Enforce the terminal transition at the DB level (this migration)
--      so no future trigger or RPC can mutate a business column or
--      reset a resolved row back to NULL.
--
-- Audit (2026-05-14)
-- ==================
-- All 7 SQL function paths that UPDATE user_actions do the same
-- thing: `set resolved_at = now()` (occasionally with extra WHERE
-- filters). None touch title/body/priority/action_type/reference_id.
-- The single DELETE path (none) doesn't exist either — orphans get
-- cleaned by cascade triggers that flip resolved_at, not by DELETE.
--
-- Functions audited:
--   on_fine_atom_inserted
--   on_resource_event_cancelled
--   on_rsvp_action_inserted
--   resolve_rule_change_apply_pending
--   resolve_stale_fine_voided
--   resolve_user_action_on_vote_cast
--   resolve_vote_actions_on_close
--   (void_fine inserts only, no update)
--
-- Cost
-- ====
-- One per-row check on each UPDATE / DELETE. INSERT untouched.
-- Mirror of mig 00162 (system_events) — same approach, different
-- column name.

create or replace function public.user_actions_resolution_only_guard()
returns trigger
language plpgsql
as $$
declare
  v_old jsonb;
  v_new jsonb;
begin
  if tg_op = 'DELETE' then
    raise exception
      'user_actions row is atom-ish; DELETE rejected (id=%)',
      old.id
      using errcode = 'check_violation';
  end if;

  if tg_op = 'UPDATE' then
    -- The only legitimate mutation is the terminal resolution flip.
    if old.resolved_at is not null then
      raise exception
        'user_actions.resolved_at is set-once; UPDATE rejected (id=%)',
        new.id
        using errcode = 'check_violation';
    end if;

    -- Strip resolved_at + updated_at from both rows and compare. If
    -- anything else differs, the UPDATE is touching business state.
    -- updated_at is included in the strip because triggers like
    -- `set_updated_at` legitimately tick it forward on resolution.
    v_old := (to_jsonb(old) - 'resolved_at') - 'updated_at';
    v_new := (to_jsonb(new) - 'resolved_at') - 'updated_at';
    if v_old is distinct from v_new then
      raise exception
        'user_actions is atom-ish; only resolved_at may transition (id=%)',
        new.id
        using errcode = 'check_violation';
    end if;
  end if;

  return new;
end$$;

comment on function public.user_actions_resolution_only_guard() is
  'Atom-ish enforcement for user_actions: rejects DELETE; allows UPDATE only when the single one-way `resolved_at: null → timestamp` transition is the sole business mutation. Mirrors mig 00162 system_events guard pattern. Constitution Article 8 reclassification (2026-05-14).';

drop trigger if exists user_actions_resolution_guard on public.user_actions;
create trigger user_actions_resolution_guard
  before update or delete on public.user_actions
  for each row execute function public.user_actions_resolution_only_guard();
