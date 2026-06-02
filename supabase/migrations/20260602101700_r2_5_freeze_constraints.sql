-- ============================================================================
-- R.2-5 — FREEZE CONSTRAINTS (review founder #2): los 3 gaps reales
-- ============================================================================
-- Del review de 7 issues: 1, 2, 3, 4 ya existían en la DB (verificado con
-- pg_constraint/pg_indexes). Este migration aplica los 3 reales:
--
--   Issue 5: CHECK de tiempo en calendar_events (reservations ya lo tenía)
--   Issue 6: FK obligations.source_rule_id → rules(id)
--   Issue 7: FKs source_decision_id → decisions(id) en resource_reservations
--            y reservation_conflicts
--
-- FKs con ON DELETE SET NULL: la obligación/reservación sobrevive si su regla
-- o decisión de origen se borra (pierde provenance, no integridad).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- Issue 5 — calendar_events: time check
-- ────────────────────────────────────────────────────────────────────────────
-- Sanear residuo de smokes (si existiera) antes de agregar el constraint
update public.calendar_events
   set ends_at = starts_at + interval '2 hours'
 where ends_at is not null and starts_at is not null and ends_at <= starts_at;

alter table public.calendar_events
  add constraint calendar_events_time_check
  check (ends_at is null or starts_at is null or ends_at > starts_at);

-- ────────────────────────────────────────────────────────────────────────────
-- Issue 6 — obligations.source_rule_id → rules(id)
-- ────────────────────────────────────────────────────────────────────────────
-- Sanear huérfanos (rules borradas por cleanups de smokes)
update public.obligations set source_rule_id = null
 where source_rule_id is not null
   and not exists (select 1 from public.rules r where r.id = source_rule_id);

alter table public.obligations
  add constraint obligations_source_rule_fk
  foreign key (source_rule_id) references public.rules(id) on delete set null;

-- ────────────────────────────────────────────────────────────────────────────
-- Issue 7 — source_decision_id → decisions(id)
-- ────────────────────────────────────────────────────────────────────────────
update public.resource_reservations set source_decision_id = null
 where source_decision_id is not null
   and not exists (select 1 from public.decisions d where d.id = source_decision_id);

alter table public.resource_reservations
  add constraint reservations_source_decision_fk
  foreign key (source_decision_id) references public.decisions(id) on delete set null;

update public.reservation_conflicts set source_decision_id = null
 where source_decision_id is not null
   and not exists (select 1 from public.decisions d where d.id = source_decision_id);

alter table public.reservation_conflicts
  add constraint conflicts_source_decision_fk
  foreign key (source_decision_id) references public.decisions(id) on delete set null;

-- ────────────────────────────────────────────────────────────────────────────
-- Verificación inline: los 7 issues del review deben quedar resueltos
-- ────────────────────────────────────────────────────────────────────────────
do $$
begin
  -- 1. activity_events FKs (≥5)
  if (select count(*) from pg_constraint
      where conrelid = 'public.activity_events'::regclass and contype = 'f') < 5 then
    raise exception 'freeze check 1: faltan FKs en activity_events';
  end if;
  -- 2. exactly-one check
  if not exists (select 1 from pg_constraint
      where conrelid = 'public.actor_relationships'::regclass and contype = 'c'
        and pg_get_constraintdef(oid) like '%object_actor_id%') then
    raise exception 'freeze check 2: falta CHECK exactly-one';
  end if;
  -- 3. los 6 UNIQUE
  if (select count(*) from pg_constraint where contype = 'u' and conrelid in (
      'public.actor_memberships'::regclass, 'public.roles'::regclass,
      'public.role_permissions'::regclass, 'public.role_assignments'::regclass,
      'public.event_participants'::regclass, 'public.decision_votes'::regclass)) < 6 then
    raise exception 'freeze check 3: faltan UNIQUE constraints';
  end if;
  -- 4. unique active right
  if not exists (select 1 from pg_indexes where indexname = 'idx_rights_unique_active') then
    raise exception 'freeze check 4: falta unique active right';
  end if;
  -- 5. time checks
  if not exists (select 1 from pg_constraint
      where conrelid = 'public.calendar_events'::regclass and conname = 'calendar_events_time_check') then
    raise exception 'freeze check 5: falta time check en calendar_events';
  end if;
  -- 6. source_rule_id FK
  if not exists (select 1 from pg_constraint
      where conrelid = 'public.obligations'::regclass and conname = 'obligations_source_rule_fk') then
    raise exception 'freeze check 6: falta FK source_rule_id';
  end if;
  -- 7. source_decision_id FKs
  if not exists (select 1 from pg_constraint where conname = 'reservations_source_decision_fk')
     or not exists (select 1 from pg_constraint where conname = 'conflicts_source_decision_fk') then
    raise exception 'freeze check 7: faltan FKs source_decision_id';
  end if;

  raise notice 'FREEZE CHECKS: los 7 issues del review resueltos — schema listo para congelar';
end $$;
