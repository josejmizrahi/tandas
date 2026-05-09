# Rules platform-only — drop legacy `rules` columns

> Status: **Slice E.1 done 2026-05-09** (view rename + setEnabled
> dual-write). Slice E.2 (model collapse + DB column drop) pending
> macOS session — needs `xcodebuild` to verify the model field
> renames don't regress before the column drop ships.
> Tracked en `Plans/Active/Audit-2026-05-06.md` § 5.2 item 6.

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

## Slice E.1 — done 2026-05-09 (Linux session, no Xcode build)

PR: `claude/rules-platform-only-cleanup` (TBD).

What shipped:

- **`OnboardingRule`** + **`RuleDraft`** + **`GroupRule`** gain
  computed `name` / `isActive` forwarders mirroring the platform
  shape. Mutable on `RuleDraft` (preserves the toggle binding in
  `InitialRulesView`). The legacy stored fields stay so decoders
  keep working during cohabitation.
- **9 view callsites** renamed (`rule.title → rule.name`,
  `rule.enabled → rule.isActive`, drop `rule.code` metadata row in
  `RuleDetailView` since `slug` is the platform identifier):
  - `RulesView`, `EditRulesView`, `EditRuleSheet`, `RuleDetailView`
  - `EditRulesCoordinator`, `InitialRulesView`
  - `CreateRuleChangeSheet`, `CreateRuleChangeCoordinator`
  - `RuleRepealVoteBody` (comment only)
- **`LiveRuleRepository.setEnabled`** dual-writes both `enabled`
  and `is_active` columns. Pre-2026-05-09 this writer touched only
  the legacy column, so toggling via `EditRulesView` left the
  platform column stale; `GroupRule.isLive = enabled && isActive`
  was masking the divergence with an AND. Post-fix the two columns
  stay in lockstep until E.2 drops the legacy one.
- **`RuleDetailView` "Estado" row** simplified from tristate
  (Activa / Pausada por el grupo / Deshabilitada) to binary
  (Activa / Deshabilitada). Tristate was a workaround for the
  divergence the dual-write fix removes.

Build verification: NOT run (Linux session, no `xcodebuild`).
Renames are mechanical (only Text(...) callsites + bindings to a
mutable computed property of the same type) so risk is low, but
**E.2 must run a full `xcodebuild test` before shipping further
changes**.

## Slice E.2 — pending (macOS session required)

1. **iOS Models** — drop legacy stored fields once views are stable:
   - [ ] `OnboardingRule`: drop `code`, `title`, `description`,
         `enabled`, `status` from CodingKeys + storage. Promote
         `name` / `isActive` to stored fields.
   - [ ] `GroupRule`: drop `code`, `title`, `description`,
         `enabled`, `action` from storage. Add `trigger`
         (RuleTrigger), `conditions: [RuleCondition]`. Verify
         decoders. Drop the `name` forwarder (becomes stored).
   - [ ] `RuleDraft`: drop `code` + `trigger: RuleTriggerSpec`.
         Add `slug: String`, `trigger: RuleTrigger` (platform),
         `conditions`, `consequences`. Update `defaults` array to
         canonical dinner template values (matching
         `templates.config.defaultRules`).
   - [ ] Migrate `InitialRulesView.exampleText` switch from
         `rule.code` to `rule.slug` (use
         `DinnerRecurringTemplate.RuleSlug.*` constants).

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
