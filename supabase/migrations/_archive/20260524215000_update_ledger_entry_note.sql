-- 00372 — update_ledger_entry_note: in-place edit of the note field.
--
-- Why
-- ===
-- Most "edit" intent on a ledger entry is correcting a typo in the
-- note — a descriptive field that doesn't affect any projection math.
-- The atom log enforces immutability on amount/from/to/type via reverse
-- + replay (mig 00368). But notes are pure metadata text — promoting
-- them to first-class mutable fields keeps the immutability around the
-- math (where it matters) without forcing reverse + replay for every
-- typo fix.
--
-- This RPC updates BOTH:
--   1. ledger_entries.metadata.note (the source of truth)
--   2. system_events.payload.note where event_type='ledgerEntryCreated'
--      and payload.entry_id = p_entry_id (so the iOS activity feed
--      reflects the edit on next refresh without needing a separate
--      "edit" event)
--
-- The second update is a pragmatic departure from strict append-only
-- on system_events. Acceptable because the note is descriptive — the
-- atomic event itself (the money movement) is untouched. Math edits
-- still require reverse + replay.
--
-- Authorization
-- =============
-- Caller must be the original `recorded_by`. Admin override deferred —
-- same posture as `reverse_ledger_entry` (mig 00368).

create or replace function public.update_ledger_entry_note(
  p_entry_id uuid,
  p_note     text
) returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_uid     uuid := auth.uid();
  v_entry   public.ledger_entries;
  v_trimmed text;
begin
  if v_uid is null then
    raise exception 'update_ledger_entry_note: auth required' using errcode = '42501';
  end if;
  if p_entry_id is null then
    raise exception 'update_ledger_entry_note: p_entry_id required' using errcode = '22023';
  end if;

  select * into v_entry
    from public.ledger_entries
   where id = p_entry_id
   for update;
  if v_entry.id is null then
    raise exception 'update_ledger_entry_note: entry % not found', p_entry_id using errcode = 'check_violation';
  end if;
  if v_entry.recorded_by is distinct from v_uid then
    raise exception 'update_ledger_entry_note: only the original recorder can edit this entry'
      using errcode = '42501';
  end if;

  v_trimmed := nullif(trim(coalesce(p_note, '')), '');

  if v_trimmed is null then
    update public.ledger_entries
       set metadata = metadata - 'note'
     where id = p_entry_id
     returning * into v_entry;
  else
    update public.ledger_entries
       set metadata = metadata || jsonb_build_object('note', v_trimmed)
     where id = p_entry_id
     returning * into v_entry;
  end if;

  if v_trimmed is null then
    update public.system_events
       set payload = payload - 'note'
     where event_type = 'ledgerEntryCreated'
       and (payload->>'entry_id')::uuid = p_entry_id;
  else
    update public.system_events
       set payload = payload || jsonb_build_object('note', v_trimmed)
     where event_type = 'ledgerEntryCreated'
       and (payload->>'entry_id')::uuid = p_entry_id;
  end if;

  return v_entry;
end;
$$;

revoke execute on function public.update_ledger_entry_note(uuid, text) from public, anon;
grant  execute on function public.update_ledger_entry_note(uuid, text) to authenticated;

comment on function public.update_ledger_entry_note(uuid, text) is
  'v1 (mig 00372): lightweight in-place edit of a ledger entry note. Updates both ledger_entries.metadata.note and system_events.payload.note. Math edits still require reverse + replay via reverse_ledger_entry (mig 00368).';
