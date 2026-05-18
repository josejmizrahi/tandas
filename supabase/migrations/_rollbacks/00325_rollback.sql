-- Rollback for 00325 — restore prior aliases + drop the 10 new universals.

update public.rule_templates set alias_of = 'missed_obligation_consequence' where id = 'cancellation_fee';
update public.rule_templates set alias_of = 'missed_obligation_consequence' where id = 'not_returned_fine';
update public.rule_templates set alias_of = 'missed_obligation_consequence' where id = 'host_no_menu_fine';
update public.rule_templates set alias_of = 'deadline_enforcement'           where id = 'right_expiration_warning';
update public.rule_templates set alias_of = 'missed_obligation_consequence' where id = 'space_cancellation_late_fine';
update public.rule_templates set alias_of = 'approval_required'              where id = 'damage_approval_required';
update public.rule_templates set alias_of = 'approval_required'              where id = 'space_damage_temporary_closure_vote';
update public.rule_templates set alias_of = 'approval_required'              where id = 'expense_threshold_vote';
update public.rule_templates set alias_of = 'approval_required'              where id = 'transfer_large_vote';
update public.rule_templates set alias_of = 'approval_required'              where id = 'space_long_booking_vote';

delete from public.rule_templates
 where id in (
   'cancellation_consequence','late_return_consequence','deadline_consequence',
   'expiration_warning','booking_cancellation_consequence',
   'damage_approval','damage_vote_required','vote_required',
   'transfer_vote_required','booking_vote_required'
 );
