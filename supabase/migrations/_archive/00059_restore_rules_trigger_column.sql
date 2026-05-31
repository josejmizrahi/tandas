-- 00059 — Restore the platform `trigger` column dropped accidentally
-- by 00058.
--
-- The original 00058 dropped `trigger jsonb` along with the legacy
-- columns, but `trigger` is the platform WHEN field
-- (jsonb { eventType, config }) read by `_shared/ruleEngine.ts`
-- line 384 (`r.trigger.eventType === event.event_type`). Both
-- legacy and platform writers had been writing into the same column
-- with different shapes; the platform engine has been reading the
-- platform shape since 00018.
--
-- Backfill mapping covers all slugs present in prod at apply time:
--   - canonical 00015 slugs (dinner_late_arrival, dinner_no_response,
--     dinner_same_day_cancel, dinner_no_show, dinner_host_no_menu)
--   - alt-shape slugs from an earlier seed variant
--     (dinner_late_rsvp → eventClosed,
--      dinner_rsvp_change → rsvpChangedSameDay)
--
-- Post-backfill the column is NOT NULL — every existing row has a
-- known platform trigger and `create_initial_rule` /
-- `seed_dinner_template_rules` always write it on insert.

alter table public.rules
  add column if not exists trigger jsonb;

update public.rules
set trigger = case slug
  when 'dinner_late_arrival'    then jsonb_build_object('eventType', 'checkInRecorded',    'config', '{}'::jsonb)
  when 'dinner_no_response'     then jsonb_build_object('eventType', 'eventClosed',        'config', '{}'::jsonb)
  when 'dinner_same_day_cancel' then jsonb_build_object('eventType', 'rsvpChangedSameDay', 'config', '{}'::jsonb)
  when 'dinner_no_show'         then jsonb_build_object('eventType', 'eventClosed',        'config', '{}'::jsonb)
  when 'dinner_host_no_menu'    then jsonb_build_object('eventType', 'hoursBeforeEvent',   'config', jsonb_build_object('hours', 24))
  when 'dinner_late_rsvp'       then jsonb_build_object('eventType', 'eventClosed',        'config', '{}'::jsonb)
  when 'dinner_rsvp_change'     then jsonb_build_object('eventType', 'rsvpChangedSameDay', 'config', '{}'::jsonb)
end
where trigger is null
  and slug in (
    'dinner_late_arrival',
    'dinner_no_response',
    'dinner_same_day_cancel',
    'dinner_no_show',
    'dinner_host_no_menu',
    'dinner_late_rsvp',
    'dinner_rsvp_change'
  );

alter table public.rules
  alter column trigger set not null;

comment on column public.rules.trigger is
  'Platform WHEN: { eventType: SystemEventType, config: jsonb }. Read by the rule engine in _shared/ruleEngine.ts. Restored in 00059 after 00058 dropped it accidentally.';
