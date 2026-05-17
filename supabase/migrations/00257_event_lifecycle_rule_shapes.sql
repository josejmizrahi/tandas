-- Mig 00211: rule_shapes + cancellation_fee template for new event atoms
--
-- The new event lifecycle triggers shipped over the past sessions:
--   - eventCancelled (mig 00203/00215)
--   - eventStarted   (mig 00208/00214)
--   - eventUpdated   (mig 00210)
--
-- now have rule-engine evaluators (added today) but cannot be picked from
-- the iOS Rule Builder gallery: that view reads from public.rule_shapes,
-- which has no entries for the three triggers. This migration adds the
-- shape entries so authors can compose rules against them in the UI.
--
-- Also seeds ONE template — `cancellation_fee` — which composes
-- eventCancelled + alwaysTrue + fine. Mirrors the no_show_fine template
-- shape exactly so the existing Rule Builder card layout renders it for
-- free. Per spec §19 ("cancelled events do not produce no-show fines")
-- this is the legitimate way to charge a cancellation cost.
--
-- No template for eventStarted / eventUpdated yet — both want a
-- sendNotification consequence which isn't implemented end-to-end in V1.
-- Shapes are added so a future template (or hand-authored rule via
-- publish_rule_version) can consume them.

-- =========================================================
-- 1. rule_shapes — three new triggers
-- =========================================================

insert into public.rule_shapes (id, kind, label_es, summary_es, icon, valid_scopes, valid_resource_types, config_fields, sort_order)
values
  ('eventCancelled',
   'trigger',
   'Cuando se cancela el evento',
   'Se dispara cuando el host o un admin cancela el evento. Ideal para cobros de cancelación o avisos a confirmados.',
   'xmark.circle',
   array['resource','series','group'],
   array['event'],
   '[]'::jsonb,
   60),
  ('eventStarted',
   'trigger',
   'Al iniciar el evento',
   'Se dispara cuando llega la hora de inicio del evento (cron cada 5 min). Útil para recordatorios "ya empezó" o nudges a quien no llegó.',
   'play.circle',
   array['resource','series','group'],
   array['event'],
   '[]'::jsonb,
   70),
  ('eventUpdated',
   'trigger',
   'Al editar el evento',
   'Se dispara cuando se cambia algún dato del evento (hora, lugar, host, descripción). El payload trae las llaves que cambiaron.',
   'pencil.and.list.clipboard',
   array['resource','series','group'],
   array['event'],
   '[]'::jsonb,
   80)
on conflict (id) do nothing;

-- =========================================================
-- 2. rule_templates — cancellation_fee
-- =========================================================
--
-- Composes eventCancelled + alwaysTrue + fine. The target enumeration
-- (eventCancelled evaluator added today) emits one target per active
-- member, but the `is_host` flag in target.context lets a future
-- condition narrow this to the host only. For V1 the alwaysTrue
-- condition means every active member pays; admins can edit the rule
-- post-publish to add a `onlyIfHost` condition once that shape lands.

insert into public.rule_templates (id, display_name_es, description_es, category, template_kind, required_capabilities, default_params, composition, status, sort_order)
values
  ('cancellation_fee',
   'Multa por cancelar el evento',
   'Cobra una cantidad cuando el host o un admin cancela el evento. Útil para cubrir gastos no recuperables (reservas, comida, etc.).',
   'attendance',
   'penalty',
   array['fines'],
   jsonb_build_object('amount', 200),
   jsonb_build_object(
     'trigger_shape_id',      'eventCancelled',
     'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
     'consequence_shape_ids', jsonb_build_array('fine'),
     'scope_hint',            'series'
   ),
   'active',
   60)
on conflict (id) do nothing;

comment on table public.rule_shapes is
  'Catalog of building blocks the iOS Rule Builder composes. v2 (00211): added eventCancelled / eventStarted / eventUpdated trigger shapes for the new lifecycle atoms.';
