-- 00033 — Deprecate legacy columns of public.rules.
--
-- Audit doc § 5.1 #6 (cerrar F0). Marca columnas legacy como nullable
-- + agrega deprecation comments. Esto prepara para el DROP completo
-- (pre-Fase 2) sin romper las 3 RPCs que aún escriben en ellas:
--
--   - seed_dinner_template_rules (00015): inserta legacy + platform
--   - propose_rule (00003 / 00026?): inserta legacy + platform
--   - create_initial_rule: idem
--
-- Por qué deprecate ahora vs drop:
--   El drop completo requiere actualizar las 3 RPCs en sync con la
--   migration. Hacerlo atómico es riesgoso (rollback complejo si una
--   RPC falla). Esta deprecación permite:
--     1. Una próxima migration actualiza una RPC para skip legacy.
--     2. Verificar que el insert sigue funcionando con NULL en legacy.
--     3. Repetir para las otras 2 RPCs.
--     4. Final migration drop columnas legacy.
--   4 pasos seguros vs 1 paso peligroso.
--
-- iOS impact: cero. iOS lee columnas platform (name, is_active,
-- conditions, consequences) — verificado en Models/Rule.swift y
-- Models/GroupRule.swift CodingKeys.

alter table public.rules
  alter column code         drop not null,
  alter column title        drop not null,
  alter column trigger      drop not null,
  alter column action       drop not null,
  alter column enabled      drop not null,
  alter column status       drop not null;
-- description ya era nullable, no cambia.

comment on column public.rules.code         is 'DEPRECATED — drop pre-Fase 2. Use rules.id for stable references.';
comment on column public.rules.title        is 'DEPRECATED — drop pre-Fase 2. Use rules.name (canonical).';
comment on column public.rules.description  is 'DEPRECATED — drop pre-Fase 2. Description embedido en rules.consequences config si necesario.';
comment on column public.rules.trigger      is 'DEPRECATED — drop pre-Fase 2. Use rules.conditions + consequences (Platform shape).';
comment on column public.rules.action       is 'DEPRECATED — drop pre-Fase 2. Use rules.consequences.';
comment on column public.rules.enabled      is 'DEPRECATED — drop pre-Fase 2. Use rules.is_active (canonical).';
comment on column public.rules.status       is 'DEPRECATED — drop pre-Fase 2. Status implicit via rules.is_active=false to disable.';
