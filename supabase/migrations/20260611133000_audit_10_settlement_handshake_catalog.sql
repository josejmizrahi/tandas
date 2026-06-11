-- ============================================================================
-- AUDIT.10 — Catalogar los eventos del handshake de settlement (2026-06-11)
-- ============================================================================
-- _smoke_mvp2_audit_baseline (assert 7) cazó en live 'settlement.payment_claimed'
-- sin catalogar: el handshake 2-vías r5z (20260610220000/230000) emite 4 tipos
-- pero solo 'settlement.paid' y 'settlement.payment_appealed' estaban en el
-- catálogo. Se cierran los 2 restantes ('payment_rejected' aún no emitido en
-- prod, pero emitible por código → se cataloga preventivamente).
-- Nota: 'money.fine_recorded' (record_fine r9_b) NO se cataloga — _emit_activity
-- lo mapea al canónico 'fine.created' (verificado en prosrc).
-- ============================================================================

insert into public.activity_event_catalog
  (event_type, domain, description, expected_subject_type, is_system_generated)
values
  ('settlement.payment_claimed',  'settlement', 'El deudor marcó un pago de settlement como realizado (pendiente de confirmación)', 'settlement_item', false),
  ('settlement.payment_rejected', 'settlement', 'El acreedor rechazó el claim de pago de un settlement item',                       'settlement_item', false)
on conflict (event_type) do nothing;

-- Sin backfill del flag payload.uncatalogued en eventos ya emitidos:
-- activity_events es append-only (trg_activity_append_only) y la marca es
-- historia legítima de cuándo el catálogo iba atrás del código.
