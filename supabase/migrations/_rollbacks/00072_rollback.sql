-- 00072 rollback — Reset modules.basic_fines.provided_rules_def to empty.
--
-- Idempotent. Re-running 00072 restores the data. Safe to apply only if
-- 00073+ have NOT yet been applied (they read from this column).

update public.modules
set provided_rules_def = '[]'::jsonb,
    updated_at = now()
where id = 'basic_fines';
