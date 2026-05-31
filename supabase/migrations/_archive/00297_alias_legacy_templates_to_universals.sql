-- 00297 — Alias 14 legacy templates to the 3 universals + demote 7 more.
--
-- Source: Plans/Active/UniversalRuleTemplates.md §14.1 (mapping table).
-- After mig 00296 seeded the 3 universal Beta-1 templates, this migration
-- reclassifies the existing 21 vertical-looking templates so the iOS
-- Gallery only surfaces the 3 universals while the engine keeps resolving
-- existing rule_versions (FK to the legacy template_id remains valid;
-- `status` stays 'active' for them).
--
-- Two buckets:
--
--   A. ALIAS to a universal (14)        — Gallery hides via alias_of IS NULL filter
--      missed_obligation_consequence (8): late_arrival_fine, no_show_fine,
--          same_day_cancel_fine, no_rsvp_fine, host_no_menu_fine,
--          cancellation_fee, not_returned_fine, space_cancellation_late_fine
--      approval_required (5): expense_threshold_vote, damage_approval_required,
--          transfer_large_vote, space_long_booking_vote,
--          space_damage_temporary_closure_vote
--      deadline_enforcement (1): right_expiration_warning
--
--   B. DEMOTE to beta_status='post_beta' (7) — no good universal home in
--      Beta 1; reabstract in Wave 1 when shape pieces exist.
--        expense_threshold_warning          → Wave 1 `monitoring_alert`
--        maintenance_overdue_lock           → Wave 1 `spending_lock`/`lock_capability`
--        damage_logged_warning              → Wave 1 `monitoring_alert`
--        space_capacity_overflow_waitlist   → Wave 1 `waitlist_flow`
--        space_no_check_in_release          → Wave 1 `unused_capacity_release`
--        space_outside_allowed_hours_deny   → Post-Beta `denyAction` family
--        space_founder_priority_bump        → Wave 1 `priority_allocation`
--
-- Engine impact: zero. rule_versions FK by template_id; status='active' kept;
-- alias_of is read by iOS Gallery only.
--
-- Rollback: _rollbacks/00297_rollback.sql unsets alias_of and resets
-- beta_status to default ('post_beta'). Note rollback does NOT restore
-- beta1 for these (they were never beta1 in the contract sense — the
-- vertical templates pre-mig-00295 had no beta_status column at all).

-- =============================================================================
-- A. Alias to universals
-- =============================================================================

update public.rule_templates
   set alias_of    = 'missed_obligation_consequence',
       beta_status = 'post_beta'
 where id in (
   'late_arrival_fine',
   'no_show_fine',
   'same_day_cancel_fine',
   'no_rsvp_fine',
   'host_no_menu_fine',
   'cancellation_fee',
   'not_returned_fine',
   'space_cancellation_late_fine'
 );

update public.rule_templates
   set alias_of    = 'approval_required',
       beta_status = 'post_beta'
 where id in (
   'expense_threshold_vote',
   'damage_approval_required',
   'transfer_large_vote',
   'space_long_booking_vote',
   'space_damage_temporary_closure_vote'
 );

update public.rule_templates
   set alias_of    = 'deadline_enforcement',
       beta_status = 'post_beta'
 where id = 'right_expiration_warning';

-- =============================================================================
-- B. Demote to post_beta (no alias — pending Wave 1 universals)
-- =============================================================================

update public.rule_templates
   set beta_status = 'post_beta'
 where id in (
   'expense_threshold_warning',
   'maintenance_overdue_lock',
   'damage_logged_warning',
   'space_capacity_overflow_waitlist',
   'space_no_check_in_release',
   'space_outside_allowed_hours_deny',
   'space_founder_priority_bump'
 );

-- =============================================================================
-- Sanity check (logged only)
-- =============================================================================
-- Expect after this migration:
--   Gallery-visible (alias_of IS NULL AND beta_status='beta1' AND status='active'): 3
--   Aliased to universals: 14
--   Demoted (no alias, post_beta): 7
--   Total: 24
do $$
declare
  v_visible int;
  v_aliased int;
  v_demoted int;
begin
  select count(*) into v_visible
    from public.rule_templates
   where alias_of is null and beta_status = 'beta1' and status = 'active';
  select count(*) into v_aliased
    from public.rule_templates where alias_of is not null;
  select count(*) into v_demoted
    from public.rule_templates
   where alias_of is null and beta_status = 'post_beta';
  if v_visible <> 3 then
    raise warning 'mig 00297: expected 3 visible templates, got %', v_visible;
  end if;
  if v_aliased <> 14 then
    raise warning 'mig 00297: expected 14 aliased templates, got %', v_aliased;
  end if;
  raise notice 'mig 00297: visible=%, aliased=%, demoted_only=%', v_visible, v_aliased, v_demoted;
end$$;
