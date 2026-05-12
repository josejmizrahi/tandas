-- Rollback for 00070: drop slot/booking/asset lifecycle RPCs.
--
-- Note: this drops the functions but leaves any resources rows
-- (assets/slots/bookings) intact. They become read-only without the
-- RPCs to mutate them — pragmatic since polymorphic resources don't
-- have FKs that force cascades.

drop function if exists public.request_slot_swap(uuid, uuid);
drop function if exists public.book_slot(uuid);
drop function if exists public.assign_slot(uuid, uuid);
drop function if exists public.create_slot(uuid, timestamptz, timestamptz);
drop function if exists public.create_asset(uuid, text, int);
