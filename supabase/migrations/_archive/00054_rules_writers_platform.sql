-- 00054 — Make rule-writing RPCs produce platform shape.
-- (Originally 00048; renamed in repo. Prod migration name remains
-- "00048_rules_writers_platform" — applied 2026-05-08 22:27 UTC.)
--
-- Audit § 5.2 item 6 (drop legacy rules columns) — pre-req work. The full
-- column drop is deferred to a follow-up sprint that requires a Swift
-- model refactor (GroupRule + OnboardingRule + RuleDraft + ~10 view
-- callsites that still read legacy field names). Tracked in
-- `Plans/Active/RulesPlatformOnly.md`.
--
-- This migration closes the ACTIVE bug: V1 founder onboarding creates
-- rules via `create_initial_rule` which writes only legacy columns. Both
-- live engines (`evaluate-event-rules`, `process-system-events`) match
-- rules by `trigger.eventType` + `conditions[]` + `consequences[]` — i.e.
-- platform shape. Legacy-only rows are silently skipped, so V1 onboarding
-- has been producing rules that NEVER fire fines.
--
-- Migration 00018 backfilled platform shape for groups created before the
-- platform rules were added, but post-00018 onboarding flows kept writing
-- only legacy. This migration:
--   1. Rewrites `create_initial_rule` to translate the iOS-side legacy
--      input (RuleDraft with code='late', trigger='{type:"late_arrival"}',
--      action='{type:"fine", amount_mxn:200}') into BOTH legacy columns
--      (kept for cohabitation) AND platform columns (so the engine fires).
--   2. Drops the broken `propose_rule` RPC (00003) which still calls the
--      pre-00020 `create_vote(...)` RPC that was dropped in 00020. It has
--      zero iOS callers and zero successful invocations on prod. Phase 4
--      reintroduces a proper "propose_rule_change" flow via start_vote.
--
-- =========================================================
-- 1. Drop the broken propose_rule
-- =========================================================
drop function if exists public.propose_rule(uuid, text, text, jsonb, jsonb, jsonb, boolean);

-- =========================================================
-- 2. Rewrite create_initial_rule with code → platform translation
-- =========================================================
create or replace function public.create_initial_rule(
  p_group_id    uuid,
  p_code        text,
  p_title       text,
  p_description text,
  p_trigger     jsonb,
  p_action      jsonb
) returns public.rules
language plpgsql security definer set search_path = public as $$
declare
  r              public.rules;
  v_slug         text;
  v_event_type   text;
  v_conditions   jsonb;
  v_consequences jsonb;
  v_platform_trigger jsonb;
  v_amount       int := coalesce((p_action ->> 'amount_mxn')::int, 200);
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can seed rules';
  end if;

  -- Translate iOS RuleDraft.code → canonical platform shape.
  -- The 5 dinner template codes are the only valid V1 inputs from
  -- FounderOnboardingCoordinator. Unknown codes fall through to a
  -- legacy-only row (Phase 4 custom rule editor will replace this path
  -- with a proper authoring UI that sends platform shape directly).
  case p_code
    when 'late' then
      v_slug         := 'dinner_late_arrival';
      v_event_type   := 'checkInRecorded';
      v_conditions   := jsonb_build_array(
        jsonb_build_object('type', 'checkInMinutesLate',
                           'config', jsonb_build_object('thresholdMinutes', 0))
      );
      v_consequences := jsonb_build_array(
        jsonb_build_object('type', 'fine',
                           'config', jsonb_build_object(
                             'baseAmount',  v_amount,
                             'stepAmount',  50,
                             'stepMinutes', 30))
      );
    when 'no_rsvp' then
      v_slug         := 'dinner_no_response';
      v_event_type   := 'eventClosed';
      v_conditions   := jsonb_build_array(
        jsonb_build_object('type', 'responseStatusIs',
                           'config', jsonb_build_object('status', 'pending'))
      );
      v_consequences := jsonb_build_array(
        jsonb_build_object('type', 'fine',
                           'config', jsonb_build_object('amount', v_amount))
      );
    when 'cancel_same_day' then
      v_slug         := 'dinner_same_day_cancel';
      v_event_type   := 'rsvpChangedSameDay';
      v_conditions   := jsonb_build_array(
        jsonb_build_object('type', 'alwaysTrue', 'config', '{}'::jsonb)
      );
      v_consequences := jsonb_build_array(
        jsonb_build_object('type', 'fine',
                           'config', jsonb_build_object('amount', v_amount))
      );
    when 'no_show' then
      v_slug         := 'dinner_no_show';
      v_event_type   := 'eventClosed';
      v_conditions   := jsonb_build_array(
        jsonb_build_object('type', 'responseStatusIs',
                           'config', jsonb_build_object('status', 'going')),
        jsonb_build_object('type', 'checkInExists',
                           'config', jsonb_build_object('exists', false))
      );
      v_consequences := jsonb_build_array(
        jsonb_build_object('type', 'fine',
                           'config', jsonb_build_object('amount', v_amount))
      );
    when 'host_no_menu' then
      v_slug         := 'dinner_host_no_menu';
      v_event_type   := 'hoursBeforeEvent';
      v_conditions   := jsonb_build_array(
        jsonb_build_object('type', 'eventDescriptionMissing', 'config', '{}'::jsonb)
      );
      v_consequences := jsonb_build_array(
        jsonb_build_object('type', 'fine',
                           'config', jsonb_build_object('amount', v_amount))
      );
    else
      -- Unknown code: store legacy-only. Engine won't match (no
      -- conditions/consequences), but the row exists for legacy compat.
      v_slug         := null;
      v_event_type   := null;
      v_conditions   := '[]'::jsonb;
      v_consequences := '[]'::jsonb;
  end case;

  -- Platform trigger is just `{eventType: ..., config: {}}`. Legacy
  -- trigger preserved for the cohabitation window.
  v_platform_trigger := case
    when v_event_type is null then p_trigger
    else jsonb_build_object('eventType', v_event_type, 'config', '{}'::jsonb)
  end;

  insert into public.rules (
    group_id, slug,
    -- legacy cohabitation
    code, title, description, trigger, action, status, enabled,
    -- platform
    name, is_active, conditions, consequences,
    proposed_by
  ) values (
    p_group_id, v_slug,
    p_code, p_title, p_description, v_platform_trigger, p_action, 'active', true,
    p_title, true, v_conditions, v_consequences,
    auth.uid()
  ) returning * into r;
  return r;
end;
$$;

revoke execute on function public.create_initial_rule(uuid, text, text, text, jsonb, jsonb) from public, anon;
grant  execute on function public.create_initial_rule(uuid, text, text, text, jsonb, jsonb) to authenticated;

comment on function public.create_initial_rule(uuid, text, text, text, jsonb, jsonb) is
  'Founder-onboarding seed for one rule. Accepts iOS RuleDraft legacy shape + translates p_code to canonical platform conditions/consequences. Writes BOTH legacy columns (for view back-compat during cohabitation) AND platform columns (so the rule engine fires). Phase 4 custom rule editor replaces this with a platform-native RPC.';
