-- 00090_rollback.sql
-- Strip the V1 backfilled policies. Preserves any group_policies row that
-- was authored after the backfill (priority != 100, or target_action outside
-- the V1 rule.* family).

delete from public.group_policies
 where priority      = 100
   and target_action in (
         'rule.toggle',
         'rule.update_amount',
         'rule.create',
         'rule.delete'
       );
