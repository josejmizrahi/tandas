-- Rollback for 00321 — restore prior alias + drop new universal.

update public.rule_templates
   set alias_of = 'missed_obligation_consequence'
 where id = 'no_rsvp_fine';

delete from public.rule_templates where id = 'no_rsvp_consequence';
