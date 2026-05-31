-- 00327_template_descriptions_consequence_agnostic.sql
--
-- Phase 1.1 of Plans/Active/RulesFinesRefactorPlan.md.
-- Doctrine: Plans/Active/RulesVsMoneyDoctrine.md §3 Regla 3 — templates
-- name social patterns, not money instruments. Today's active universals
-- (beta1, alias_of IS NULL) ship with display names like "Cobrar por X" and
-- descriptions like "se le cobra una multa" that embed the V1 consequence
-- (fine) into the template's identity. That violates the universality test
-- (UniversalRuleTemplates.md §2.1) — when Wave 2 ships additional
-- consequence shapes (warning, suspendRight, loseTurn, etc.), the SAME
-- template should re-compose with no name change.
--
-- Scope of this mig:
--   - 7 active universals get display_name_es + description_es rewritten as
--     consequence-agnostic. The consequence composition stays unchanged —
--     V1 still ships fine-only; the copy is honest about the rest as future
--     options.
--   - Aliased post_beta templates (alias_of IS NOT NULL) are skipped — they
--     are NOT surfaced in gallery (iOS filters alias_of=null), so their
--     legacy copy is invisible to users.
--   - Templates that are already consequence-agnostic (deadline_enforcement,
--     approval_required, expiration_warning, the *_vote_required family,
--     damage_approval, missed_obligation_consequence) are NOT touched.
--   - No schema change, no composition change, no test break. Pure UPDATE.
--
-- Idempotency: each UPDATE is keyed by id; re-running the mig is a no-op
-- if the new copy is already in place.

BEGIN;

-- ---------------------------------------------------------------------------
-- booking_cancellation_consequence  (Family C — Obligation, bookingCancelled)
-- ---------------------------------------------------------------------------

UPDATE public.rule_templates
   SET display_name_es = 'Consecuencia por cancelar reserva tarde',
       description_es  = $$Cuando alguien cancela una reserva con menos de N horas de anticipación, se aplica la consecuencia configurada por el grupo (multa, advertencia o pérdida de prioridad). Distinto de "Consecuencia por cancelar tarde" — ese aplica a RSVPs (asistencia); este a reservas (slot/space ocupado que no se libera a tiempo).$$
 WHERE id = 'booking_cancellation_consequence';

-- ---------------------------------------------------------------------------
-- cancellation_consequence  (Family C — Obligation, eventCancelled)
-- ---------------------------------------------------------------------------

UPDATE public.rule_templates
   SET display_name_es = 'Consecuencia por cancelar el evento',
       description_es  = $$Cuando el organizador cancela el evento completo (no solo una persona, sino el evento entero), se aplica la consecuencia configurada por el grupo a los miembros que confirmaron. Útil cuando hay costos hundidos: comida comprada, salón reservado, recurso ya apartado.$$
 WHERE id = 'cancellation_consequence';

-- ---------------------------------------------------------------------------
-- deadline_consequence  (Family C — Obligation, hoursBeforeEvent)
-- ---------------------------------------------------------------------------

UPDATE public.rule_templates
   SET display_name_es = 'Consecuencia por no cumplir a tiempo',
       description_es  = $$Cuando una obligación con deadline no se cumple a tiempo, se aplica la consecuencia configurada por el grupo. Variante con consecuencia ejecutiva de "Exigir algo antes de una fecha" — útil cuando un aviso no basta (subir documento, proponer menú, asignar host, pagar a tiempo).$$
 WHERE id = 'deadline_consequence';

-- ---------------------------------------------------------------------------
-- late_cancellation_consequence  (Family C — Obligation, rsvpChangedSameDay)
-- ---------------------------------------------------------------------------

UPDATE public.rule_templates
   SET display_name_es = 'Consecuencia por cancelar tarde',
       description_es  = $$Cuando un miembro cancela su asistencia con menos de N horas de anticipación, se aplica la consecuencia configurada por el grupo. Reconoce el costo logístico de cancelar a última hora: cupos perdidos, comida planeada, recursos asignados.$$
 WHERE id = 'late_cancellation_consequence';

-- ---------------------------------------------------------------------------
-- late_return_consequence  (Family F — Custody, checkoutOverdue)
-- ---------------------------------------------------------------------------

UPDATE public.rule_templates
   SET display_name_es = 'Consecuencia por no devolver a tiempo',
       description_es  = $$Cuando un miembro tiene un activo en custodia y no lo regresa en el plazo acordado, se aplica la consecuencia configurada por el grupo. Aplica a cualquier objeto que se presta o se entrega bajo custodia con compromiso de devolución.$$
 WHERE id = 'late_return_consequence';

-- ---------------------------------------------------------------------------
-- no_rsvp_consequence  (Family C — Obligation, rsvpDeadlinePassed)
-- ---------------------------------------------------------------------------

UPDATE public.rule_templates
   SET display_name_es = 'Consecuencia por no confirmar a tiempo',
       description_es  = $$Cuando vence la fecha límite para confirmar asistencia y un miembro nunca contestó (ni sí ni no), se aplica la consecuencia configurada por el grupo. Reconoce el costo de no saber con cuántos contar: comida planeada, recursos reservados, espacios apartados.$$
 WHERE id = 'no_rsvp_consequence';

-- ---------------------------------------------------------------------------
-- no_show_consequence  (Family C — Obligation, eventClosed)
-- ---------------------------------------------------------------------------

UPDATE public.rule_templates
   SET display_name_es = 'Consecuencia por no asistir',
       description_es  = $$Cuando el evento cierra y un miembro no hizo check-in (estuvo confirmado pero no apareció), se aplica la consecuencia configurada por el grupo. Aplica a cenas, partidos, palcos, salas reservadas, comidas familiares, reuniones.$$
 WHERE id = 'no_show_consequence';

-- ---------------------------------------------------------------------------
-- missed_obligation_consequence  (Family C — Obligation, checkInRecorded)
-- Already consequence-aware ("se le aplica una consecuencia configurada");
-- this UPDATE removes the "típicamente una multa" parenthetical that biased
-- towards money, keeping the copy fully consequence-neutral.
-- ---------------------------------------------------------------------------

UPDATE public.rule_templates
   SET description_es  = $$Cuando un miembro no cumple con una obligación (llegar a tiempo, asistir, devolver, pagar), se aplica la consecuencia configurada por el grupo. Aplica a cualquier obligación con check verificable.$$
 WHERE id = 'missed_obligation_consequence';

COMMIT;
