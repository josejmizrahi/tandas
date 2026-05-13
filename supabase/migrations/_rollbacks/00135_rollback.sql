-- Rollback 00135 — restore the empty provided_rules_def on
-- slot_assignment. Existing rule rows previously seeded by 00135
-- (post-deploy) stay — they're real group state.

update public.modules
   set provided_rules_def = '[]'::jsonb
 where id = 'slot_assignment';
