-- 00034 rollback — Remove resourceTypes from existing templates.config.

update public.templates
set config = config - 'resourceTypes'
where id = 'recurring_dinner';
