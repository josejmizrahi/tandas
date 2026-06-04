-- ============================================================================
-- R.3A.1 — Expand actor_relationships whitelist (additive)
-- ============================================================================
-- Doctrina: Ruul NO es red social. Los actores existen, las relaciones se
-- declaran. Estos tipos enriquecen el grafo para alimentar trust/feed/sugerencias
-- en R.3A+, NO otorgan permisos ni rights.
-- ============================================================================

alter table public.actor_relationships
  drop constraint if exists actor_relationships_relationship_type_check;

alter table public.actor_relationships
  add constraint actor_relationships_relationship_type_check
  check (relationship_type = any (array[
    -- Legacy / estructural (existían)
    'member_of',
    'contains',
    'affiliated_with',
    'controls',
    'shareholder_of',
    'trustee_of',
    'beneficiary_of',
    'partner_of',
    'creditor_of',
    'debtor_to',
    'related_to',
    -- R.3A nuevos (social/profesional/gobernanza)
    'friend_of',
    'family_of',
    'colleague_of',
    'advisor_of',
    'mentor_of',
    'student_of',
    'investor_of',
    'employee_of',
    'employer_of',
    'contractor_of',
    'client_of',
    'supplier_of',
    'board_member_of',
    'recommended_by',
    'reports_to',
    'manages'
  ]));

comment on constraint actor_relationships_relationship_type_check on public.actor_relationships is
'R.3A.1: whitelist universal Actor→Actor/Resource. Trust/feed/sugerencias consumen estos tipos pero NO derivan permisos de aquí.';
