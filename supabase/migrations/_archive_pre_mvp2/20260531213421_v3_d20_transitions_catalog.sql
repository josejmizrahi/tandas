-- V3-D.20 FASE C.2 — membership_state_transitions_catalog.
-- Documentación canónica. NO se consume como motor de ejecución hoy.
-- set_membership_state sigue siendo la autoridad. Este catalog responde
-- "qué transiciones existen, quién las puede hacer, qué evento emiten".

CREATE TABLE IF NOT EXISTS public.membership_state_transitions_catalog (
  id                     bigserial PRIMARY KEY,
  from_state             text NOT NULL,
  to_state               text NOT NULL,
  required_permission    text,
  requires_decision      boolean NOT NULL DEFAULT false,
  event_type             text NOT NULL,
  reversible             boolean NOT NULL DEFAULT false,
  description            text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT membership_state_transitions_unique UNIQUE (from_state, to_state),
  CONSTRAINT membership_state_transitions_from_valid CHECK (
    from_state IN ('requested','invited','active','paused','suspended','removed','left','banned')
  ),
  CONSTRAINT membership_state_transitions_to_valid CHECK (
    to_state IN ('requested','invited','active','paused','suspended','removed','left','banned')
  )
);

ALTER TABLE public.membership_state_transitions_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS membership_transitions_read_all ON public.membership_state_transitions_catalog;
CREATE POLICY membership_transitions_read_all
  ON public.membership_state_transitions_catalog FOR SELECT
  USING (true);

-- Seed: las 14 transiciones canónicas que set_membership_state + accept_invite
-- + leave_group + request_membership pueden producir.
INSERT INTO public.membership_state_transitions_catalog (
  from_state, to_state, required_permission, requires_decision,
  event_type, reversible, description
) VALUES
  ('requested', 'active',    'members.invite', false, 'joined',      false, 'Solicitud aprobada por admin'),
  ('invited',   'active',    NULL,             false, 'joined',      false, 'Aceptar invitación (self, código)'),
  ('invited',   'left',      'members.invite', false, 'left',        false, 'Invitación revocada antes de aceptar'),
  ('active',    'paused',    'members.pause',  false, 'paused',      true,  'Pausa voluntaria/temporal (self o admin)'),
  ('paused',    'active',    'members.update', false, 'reactivated', true,  'Reanudar tras pausa'),
  ('active',    'suspended', 'members.suspend',false, 'suspended',   true,  'Suspensión administrativa/punitiva'),
  ('suspended', 'active',    'members.update', false, 'reactivated', true,  'Reactivar tras suspensión'),
  ('active',    'left',      NULL,             false, 'left',        true,  'Salida voluntaria (self) o forzada (admin)'),
  ('left',      'active',    'members.update', false, 'reactivated', true,  'Reingreso post-salida voluntaria'),
  ('active',    'removed',   'members.remove', false, 'removed',     true,  'Remoción administrativa reversible'),
  ('removed',   'active',    'members.update', false, 'reactivated', true,  'Reinstalar tras remoción'),
  ('active',    'banned',    'members.remove', false, 'banned',      false, 'Expulsión fuerte (administrativa o por decisión)'),
  ('suspended', 'banned',    'members.remove', false, 'banned',      false, 'Escalado de suspensión a expulsión'),
  ('banned',    'active',    'members.update', true,  'reactivated', true,  'Reinstalar baneado — REQUIERE decisión explícita (decision.membership_reinstate)')
ON CONFLICT (from_state, to_state) DO UPDATE SET
  required_permission = EXCLUDED.required_permission,
  requires_decision   = EXCLUDED.requires_decision,
  event_type          = EXCLUDED.event_type,
  reversible          = EXCLUDED.reversible,
  description         = EXCLUDED.description;

CREATE OR REPLACE FUNCTION public.list_membership_transitions()
RETURNS TABLE (
  from_state          text,
  to_state            text,
  required_permission text,
  requires_decision   boolean,
  event_type          text,
  reversible          boolean,
  description         text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
  SELECT
    t.from_state, t.to_state, t.required_permission,
    t.requires_decision, t.event_type, t.reversible, t.description
  FROM public.membership_state_transitions_catalog t
  ORDER BY t.from_state, t.to_state;
$$;

GRANT EXECUTE ON FUNCTION public.list_membership_transitions() TO authenticated;

COMMENT ON TABLE public.membership_state_transitions_catalog IS
  'V3-D.20 — documentación canónica de transiciones. set_membership_state sigue siendo la autoridad de runtime.';
