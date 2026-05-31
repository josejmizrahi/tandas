-- V3-D.20 FASE D — amplía CHECK de group_membership_events para 'paused'.
ALTER TABLE public.group_membership_events
  DROP CONSTRAINT IF EXISTS group_membership_events_event_type_check;
ALTER TABLE public.group_membership_events
  ADD  CONSTRAINT group_membership_events_event_type_check CHECK (
    event_type = ANY (ARRAY[
      'requested','invited','joined','provisional_started','confirmed',
      'paused','suspended','reactivated','left','removed','banned',
      'role_assigned','role_revoked','type_changed','other'
    ])
  );
