-- Mig 00194: expense_threshold_vote — second money template (vote variant).
--
-- Extends mig 00193 pilot. Same trigger (ledgerEntryCreated) + same
-- condition (amountAbove) but a heavier consequence: opens a `ledger_review`
-- vote so the group can ratify or challenge the expense.
--
-- Phase 1 (this mig): vote is INFORMATIONAL. Outcome doesn't auto-void the
-- ledger entry. Phase 2 (deferred) wires `finalize_vote` to refund on fail.
-- Shipping the open-vote half first to validate UX + voter quorum settings
-- against real groups before committing to refund semantics.
--
-- Adds:
--   1. `ledger_review` to is_known_vote_type whitelist.
--   2. `startVote` shape piece in public.rule_shapes.
--   3. expense_threshold_vote template in public.rule_templates.

-- =============================================================================
-- 1. Whitelist ledger_review vote_type
-- =============================================================================

create or replace function public.is_known_vote_type(p_vote_type text)
returns boolean
language sql
immutable parallel safe
set search_path = public
as $function$
  -- Keep in sync with
  -- ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Vote.swift's
  -- `VoteType` enum. A new case in Swift requires a follow-up migration
  -- to update this function.
  select p_vote_type = any (array[
    'fine_appeal',
    'rule_change',
    'rule_repeal',
    'member_removal',
    'fund_withdrawal',
    'role_assignment',
    'general_proposal',
    'slot_dispute',
    -- mig 00194: expense_threshold_vote consequence
    'ledger_review'
  ]);
$function$;

-- =============================================================================
-- 2. startVote shape piece (Builder catalog)
-- =============================================================================

insert into public.rule_shapes (id, kind, label_es, summary_es, icon, valid_scopes, valid_resource_types, sort_order)
values (
  'startVote',
  'consequence',
  'Abrir una votación',
  'Inicia una votación en el grupo para que los miembros decidan. La regla queda registrada como el origen; el voto aparece en la sección de Decisiones.',
  'hand.raised',
  array[]::text[],
  array[]::text[],
  30
);

-- =============================================================================
-- 3. expense_threshold_vote template (Builder gallery)
-- =============================================================================

insert into public.rule_templates (id, display_name_es, description_es, category, template_kind, required_capabilities, default_params, composition, status, sort_order)
values (
  'expense_threshold_vote',
  'Voto por gasto grande',
  'Cuando alguien registre un movimiento de dinero mayor a X pesos, se abre automáticamente una votación para que el grupo lo ratifique o lo cuestione. (Fase 1: el voto es informativo; el gasto NO se reversa si pierde la votación — Fase 2 agrega esa lógica.)',
  'money',
  'governance',
  array['ledger','voting']::text[],
  jsonb_build_object('threshold_cents', 500000),
  jsonb_build_object(
    'trigger_shape_id',      'ledgerEntryCreated',
    'condition_shape_ids',   jsonb_build_array('amountAbove'),
    'consequence_shape_ids', jsonb_build_array('startVote'),
    'scope_hint',            'group'
  ),
  'active',
  70
);
