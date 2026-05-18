-- Rollback for 00297 — unalias and reset beta_status.

update public.rule_templates
   set alias_of    = null,
       beta_status = 'post_beta'  -- default, can't reconstruct prior beta1 because column is new in 00295
 where id in (
   'late_arrival_fine','no_show_fine','same_day_cancel_fine','no_rsvp_fine',
   'host_no_menu_fine','cancellation_fee','not_returned_fine',
   'space_cancellation_late_fine','expense_threshold_vote',
   'damage_approval_required','transfer_large_vote','space_long_booking_vote',
   'space_damage_temporary_closure_vote','right_expiration_warning',
   'expense_threshold_warning','maintenance_overdue_lock','damage_logged_warning',
   'space_capacity_overflow_waitlist','space_no_check_in_release',
   'space_outside_allowed_hours_deny','space_founder_priority_bump'
 );
