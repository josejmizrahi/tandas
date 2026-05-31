-- 00066 — Populate `shared_resource` template config with
-- defaultModules + defaultRoles + defaultRules.
--
-- Phase 2 Slice 1: arquitectural test. Goal — ship a 2nd template
-- with **zero changes in Platform/** code. Only data updates +
-- enum cases (codegen).
--
-- The template was created in 00037 (id, displayName, presentation,
-- category, availableInVersion=2) but had no defaults, so picking it
-- in onboarding would seed an empty group. This migration completes
-- it.
--
-- defaultModules: rsvp + check_in (deps for basic_fines), basic_fines
--   + appeal_voting (governance), slot_assignment + slot_swap_request
--   (Phase 2 modules from mig 00065), rotating_position (rotating
--   axis, conflicts with rotating_host so the latter is excluded).
--
-- defaultRoles: 2 system roles + 3 custom (seat_owner / co_owner /
--   guest_holder) sized for the canonical "palco familiar" scenario.
--   max_holders limits number of seat_owners to 6 (typical palco
--   capacity); co_owner / guest_holder unlimited.
--
-- defaultRules: 2 platform-shape rules. Triggers + conditions point
--   at @codegen:enum cases that ship in this same wave (Phase 2
--   Slice 1 enums). Engine evaluators land in Phase 2 Slice 2; until
--   then the engine logs `unimplemented condition/consequence` and
--   skips. Rules still seed correctly via seed_template_rules
--   (mig 00062).

update public.templates
set config = config
  || jsonb_build_object(
    'defaultModules', jsonb_build_array(
      'rsvp', 'check_in', 'basic_fines', 'appeal_voting',
      'slot_assignment', 'slot_swap_request', 'rotating_position'
    ),
    'defaultRoles', jsonb_build_object(
      'founder', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array(
          'modifyGovernance','modifyRules','modifyMembers',
          'assignRoles','removeMember','voidFine',
          'closeAppeal','createVotes','assignSlot','approveSlotSwap'
        )
      ),
      'member', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array('createVotes','castVote','bookSlot')
      ),
      'seat_owner', jsonb_build_object(
        'label', 'Titular',
        'permissions', jsonb_build_array('assignSlot','approveSlotSwap','bookSlot'),
        'max_holders', 6
      ),
      'co_owner', jsonb_build_object(
        'label', 'Co-titular',
        'permissions', jsonb_build_array('bookSlot','approveSlotSwap')
      ),
      'guest_holder', jsonb_build_object(
        'label', 'Invitado con cupo',
        'permissions', jsonb_build_array('bookSlot')
      )
    ),
    'defaultRules', jsonb_build_array(
      jsonb_build_object(
        'slug',         'shared_no_show',
        'name',         'No usar el cupo asignado',
        'description',  'Multa cuando un cupo asignado expira sin que nadie lo use ni lo libere a tiempo.',
        'module',       'basic_fines',
        'isActive',     true,
        'trigger',      jsonb_build_object('eventType', 'slotExpired'),
        'conditions',   jsonb_build_array(
          jsonb_build_object('type', 'slotIsUnassigned', 'config', jsonb_build_object())
        ),
        'consequences', jsonb_build_array(
          jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
        )
      ),
      jsonb_build_object(
        'slug',         'shared_swap_warning',
        'name',         'Aviso 24h antes de un cupo libre',
        'description',  'Notifica al grupo cuando un cupo asignado pero no usado se acerca a su ventana.',
        'module',       'slot_assignment',
        'isActive',     false,
        'trigger',      jsonb_build_object(
          'eventType', 'slotExpiresInHours',
          'config',    jsonb_build_object('hours', 24)
        ),
        'conditions',   jsonb_build_array(
          jsonb_build_object('type', 'slotIsUnassigned', 'config', jsonb_build_object())
        ),
        'consequences', jsonb_build_array(
          jsonb_build_object('type', 'sendNotification', 'config', jsonb_build_object())
        )
      )
    )
  )
where id = 'shared_resource';
