# Rules platform-only — drop legacy `rules` columns

> Status: stub. Tracked en `Plans/Active/Audit-2026-05-06.md` § 5.2 item 6
> (legacy rules columns drop) — fragmento que se posterga al sprint
> Phase 4 (custom rule editor) por costo de refactor iOS.

## Por qué se posterga

00033 marcó las columnas legacy de `public.rules` (`code`, `title`,
`description`, `trigger`, `action`, `enabled`, `status`, `exceptions`,
`approved_via_vote_id`) como NULLABLE + DEPRECATED, con el plan de
dropearlas pre-Fase 2.

Durante el sprint pre-Beta 1 (2026-05-08) se intentó cerrar este item.
Hallazgos que provocaron el deferral:

1. **iOS lee directo de columnas legacy**:
   - `OnboardingRule` (RuleRepository.swift): `title`, `description`,
     `enabled`, `status` son fields obligatorios.
   - `GroupRule` (GroupRule.swift): `title`, `code`, `description`,
     `enabled`, `action` son fields obligatorios.
   - `RuleDraft` (input form): solo entiende `code` + legacy `trigger`
     + `action.amount_mxn`.

2. **15+ views consumen `rule.title` / `rule.enabled`**:
   - `EditRulesView`, `RulesView`, `RuleDetailView`, `EditRuleSheet`,
     `InitialRulesView`, `CreateRuleChangeSheet`,
     `CreateRuleChangeCoordinator`, `RuleChangeVoteBody`,
     `RuleRepealVoteBody`, `EditRulesCoordinator`, …

3. **El refactor seguro requiere una pasada coordinada**:
   - Renombrar GroupRule.title → name + view callsites.
   - Renombrar GroupRule.enabled → isActive + view callsites.
   - Migrar OnboardingRule a platform shape.
   - Reescribir RuleDraft.defaults para que `trigger` sea
     `{eventType: 'checkInRecorded', config: {}}` en lugar de
     `{type: 'late_arrival', params: {…}}` (sintético, no entendible
     por el engine).
   - Reescribir LiveRuleRepository.createInitialRules.Params para
     mandar shape platform.
   - Reescribir create_initial_rule para aceptar el nuevo shape (sin
     traducción server-side).
   - Drop columns + drop default value de `code`/`title`/etc.
   - Update tests (~5 archivos).

   Estimado: 4-6 horas de trabajo focused.

4. **No es bloqueante para la app actual** — 00048 cerró el bug
   funcional (`create_initial_rule` ahora escribe ambas formas, y los
   rule engines disparan), así que el legacy columns-staying-around es
   schema noise sin impacto runtime.

## Cuándo ejecutar

- **Antes de** Fase 4 (custom rule editor). El editor necesitará UI que
  habla platform shape; mejor unificar en ese punto.
- **No antes** salvo que aparezca otro bug que requiera el drop.

## Tareas (cuando se ejecute)

1. **iOS Models**:
   - [ ] `OnboardingRule`: drop `code`, `title`, `description`, `enabled`,
         `status`. Add `name`, `isActive`. Update CodingKeys.
   - [ ] `GroupRule`: drop `code`, `title`, `description`, `enabled`,
         `action`. Add `name`, `isActive`, `trigger` (RuleTrigger),
         `conditions: [RuleCondition]`. Verify decoders.
   - [ ] `RuleDraft`: drop `code` + `trigger: RuleTriggerSpec`. Add
         `slug: String`, `trigger: RuleTrigger` (platform), `conditions`,
         `consequences`. Update `defaults` array to canonical dinner
         template values (matching `templates.config.defaultRules`).

2. **iOS Repositories**:
   - [ ] `LiveRuleRepository.createInitialRules.Params`: send platform
         fields directly. Drop `TriggerEnvelope` / `ActionEnvelope`.

3. **iOS Views (rename `rule.title` → `rule.name`, `rule.enabled` →
   `rule.isActive`)**:
   - [ ] EditRulesView, RulesView, RuleDetailView, EditRuleSheet,
         InitialRulesView
   - [ ] CreateRuleChangeSheet, CreateRuleChangeCoordinator
   - [ ] RuleChangeVoteBody, RuleRepealVoteBody
   - [ ] EditRulesCoordinator
   - [ ] (cualquier otro descubierto via `grep "rule\.title\|rule\.enabled"`)

4. **Server**:
   - [ ] `create_initial_rule`: cambiar firma a
         `(p_group_id, p_slug, p_name, p_is_active, p_trigger jsonb,
         p_conditions jsonb, p_consequences jsonb)`. Drop columnas
         legacy del INSERT.
   - [ ] `seed_dinner_template_rules`: drop columnas legacy del INSERT.
   - [ ] Migration final: `ALTER TABLE rules DROP COLUMN code, title,
         description, trigger, action, enabled, status, exceptions,
         approved_via_vote_id;`
   - [ ] Drop default `'active'`/`true` legacy in any remaining writers.

5. **Tests**:
   - [ ] RulesRepositoryTests, RuleFineShapeTests, EditRulesCoordinatorTests
   - [ ] FounderOnboardingCoordinatorTests
   - [ ] Cualquiera que decode rule rows con legacy fields.

## DoD

- [ ] `\d public.rules` muestra solo platform columns
      (`id, group_id, slug, name, is_active, trigger, conditions,
      consequences, module_id, proposed_by, created_at, updated_at`).
- [ ] Cero hits de `rules.title|rules.code|rules.enabled|rules.action`
      en `*.swift` y `*.ts` y `*.sql` (excluido migration history).
- [ ] V1 onboarding flow crea rules platform-only y disparan en engine.
- [ ] Custom rule editor (Fase 4) usa la misma RPC platform-shape.

## Costo

4-6 horas focused.
