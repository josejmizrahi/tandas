-- R.RES.POLICY.A — seed reservation_policy en resource_subtypes.metadata
-- (same content as applied via apply_migration)

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'reservation_policy', jsonb_build_object(
       'granularity', 'day',
       'min_duration_units', 1,
       'max_duration_units', null,
       'advance_window_days', 180,
       'requires_approval', true
     )
   )
 where class_key = 'real_estate'
   and subtype_key in (
     'primary_residence', 'vacation_home', 'apartment',
     'rental_property', 'warehouse', 'office', 'industrial_property'
   );

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'reservation_policy', jsonb_build_object(
       'granularity', 'hour',
       'min_duration_units', 1,
       'max_duration_units', 24,
       'advance_window_days', 30,
       'requires_approval', false
     )
   )
 where class_key = 'vehicle'
   and subtype_key in ('car', 'truck', 'motorcycle', 'boat', 'aircraft');

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'reservation_policy', jsonb_build_object(
       'granularity', 'hour',
       'min_duration_units', 1,
       'max_duration_units', null,
       'advance_window_days', 60,
       'requires_approval', true
     )
   )
 where class_key = 'space'
   and subtype_key = 'generic_space';

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'reservation_policy', jsonb_build_object(
       'granularity', 'hour',
       'min_duration_units', 1,
       'max_duration_units', null,
       'advance_window_days', 14,
       'requires_approval', true
     )
   )
 where class_key = 'equipment'
   and subtype_key in ('machine', 'tool', 'generic_equipment');

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'reservation_policy', jsonb_build_object(
       'granularity', 'none',
       'min_duration_units', 0,
       'max_duration_units', null,
       'advance_window_days', null,
       'requires_approval', false
     )
   )
 where class_key = 'real_estate'
   and subtype_key = 'land';
