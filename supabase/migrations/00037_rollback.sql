-- 00037 rollback — Remove presentation + defaultCategory from templates.config.
--
-- Strips the two new keys from each of the 4 template rows. iOS Swift
-- decoders treat both keys as optional, so post-rollback the app falls
-- back to top-level `Template.name`/`icon`/`description` and category
-- `.socialRecurring`.

update public.templates
set config = (config - 'presentation' - 'defaultCategory')
where id in ('recurring_dinner', 'shared_resource', 'rotating_savings', 'custom');
