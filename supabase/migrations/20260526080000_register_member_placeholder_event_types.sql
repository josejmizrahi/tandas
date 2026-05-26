-- Register the three member.* atom types in known_event_types so the
-- whitelist rebuilds from migrations alone (no manual dashboard inserts).
--
-- These types are emitted by mig 00315 (finalize_placeholder_member),
-- mig 00316 (merge_group_members), and mig 00317 (claim_placeholder)
-- but were never explicitly registered — they pre-dated mig 00293's
-- table-backed catalog. After the 2026-05-26 data wipe the known_event_types
-- table was reseeded only from mig 00293's literal seed, dropping these
-- three and breaking the "Agregar pendiente" + claim/merge flows.
--
-- Idempotent (ON CONFLICT DO NOTHING). Safe to re-run.

select public.register_event_type(
  'member.placeholder_created',
  'mig_00315',
  'Placeholder member finalized — emitted by finalize_placeholder_member RPC'
);

select public.register_event_type(
  'member.claimed',
  'mig_00317',
  'Placeholder claimed by a real user via claim_placeholder RPC'
);

select public.register_event_type(
  'member.merge_declined',
  'mig_00316',
  'Member merge proposal declined'
);
