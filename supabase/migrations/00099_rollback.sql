-- Rollback for 00099. Strips the defaultCapabilities key from the
-- recurring_dinner template config. Other templates were not touched.

update public.templates
   set config = config - 'defaultCapabilities',
       updated_at = now()
 where id = 'recurring_dinner';
