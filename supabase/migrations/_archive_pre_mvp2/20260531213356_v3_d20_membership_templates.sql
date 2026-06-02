-- V3-D.20 FASE C-back 3/3
-- Templates membership extra. Reusan decision_type=membership +
-- reference_kind=membership (existentes).

INSERT INTO public.decision_templates_catalog (
  template_key, display_name, description,
  decision_type, reference_kind,
  default_method, default_legitimacy_source,
  default_threshold_pct, default_quorum_pct,
  execution_mode, metadata
) VALUES
  ('decision.membership_suspend',
   'Suspender miembro',
   'Decisión para suspender una membresía (sanción reversible).',
   'membership', 'membership',
   'majority', 'majority',
   50.01, 50.00,
   'manual',
   jsonb_build_object('target_state','suspended')),

  ('decision.membership_reinstate',
   'Reinstalar miembro',
   'Decisión para reactivar una membresía suspendida, pausada, removida o baneada.',
   'membership', 'membership',
   'majority', 'majority',
   50.01, 50.00,
   'manual',
   jsonb_build_object('target_state','active')),

  ('decision.membership_pause',
   'Pausar miembro',
   'Decisión para pausar voluntariamente una membresía (no punitiva).',
   'membership', 'membership',
   'majority', 'majority',
   50.01, NULL,
   'auto',
   jsonb_build_object('target_state','paused')),

  ('decision.membership_remove_reversible',
   'Remover miembro (reversible)',
   'Decisión para remover administrativamente sin baneo permanente.',
   'membership', 'membership',
   'majority', 'majority',
   50.01, 50.00,
   'manual',
   jsonb_build_object('target_state','removed'))
ON CONFLICT (template_key) DO UPDATE SET
  display_name              = EXCLUDED.display_name,
  description               = EXCLUDED.description,
  decision_type             = EXCLUDED.decision_type,
  reference_kind            = EXCLUDED.reference_kind,
  default_method            = EXCLUDED.default_method,
  default_legitimacy_source = EXCLUDED.default_legitimacy_source,
  default_threshold_pct     = EXCLUDED.default_threshold_pct,
  default_quorum_pct        = EXCLUDED.default_quorum_pct,
  execution_mode            = EXCLUDED.execution_mode,
  metadata                  = EXCLUDED.metadata;
