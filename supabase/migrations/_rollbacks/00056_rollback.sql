-- Rollback for 00056_drop_dormant_settings_fines_enabled.sql
--
-- Restores the dormant `finesEnabled` key in `groups.settings` jsonb
-- from the canonical `groups.fines_enabled` column. Safe because the
-- slice 1 trigger (mig 00049) keeps `fines_enabled` aligned with
-- `'basic_fines' = ANY(active_modules)` — the restored value is
-- guaranteed consistent with the canonical SoT.

update public.groups
   set settings = coalesce(settings, '{}'::jsonb)
                  || jsonb_build_object('finesEnabled', fines_enabled),
       updated_at = now()
 where not (coalesce(settings, '{}'::jsonb) ? 'finesEnabled');
