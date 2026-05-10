# Rules platform-only — drop legacy `rules` columns

> Status: **Slices E.1 + E.2 both done 2026-05-09**. E.1 (PR #3,
> commit 625aa5a) renamed view callsites and dual-wrote
> `setEnabled`. E.2 (this PR) collapsed the iOS models onto the
> platform shape, rewrote the writer RPCs platform-only, and dropped
> the legacy columns via migration `00058_drop_rules_legacy_columns`.
> Migration `00059_restore_rules_trigger_column` re-added `trigger`
> immediately after — `trigger jsonb` was the platform WHEN field
> shared with the legacy shape, not legacy-only, and the rule engine
> reads it. Backfilled from slug; column is NOT NULL going forward.
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

## Slice E.2 — done 2026-05-09

What shipped:

1. **iOS Models** collapsed onto platform shape:
   - `OnboardingRule` now stores `slug`/`name`/`isActive` only;
     legacy `code`/`title`/`description`/`enabled`/`status` removed.
   - `GroupRule` adds `trigger`/`conditions` as stored fields and
     drops `code`/`title`/`description`/`enabled`/`action`. The
     `name` forwarder is now a real column. `withEnabled` renamed
     to `withIsActive`.
   - `RuleDraft` swaps `code` + `RuleTriggerSpec` for `slug` +
     platform `trigger`/`conditions`/`consequences`. `amountMXN` is
     now a computed read/write over `consequences[0].config.amount`
     (or `baseAmount` for escalating shapes). `defaults` mirrors
     `templates.config.defaultRules` 1:1.
   - `RuleTriggerSpec` and the local `AnyCodable` envelope deleted
     — no remaining callers.
   - `InitialRulesView.exampleText` switches on `rule.slug` against
     `DinnerRecurringTemplate.RuleSlug.*`.

2. **iOS Repositories**:
   - `LiveRuleRepository.createInitialRules.Params` sends platform
     fields directly. `setEnabled`/`withEnabled` renamed to
     `setIsActive`/`withIsActive` end-to-end.

3. **iOS Views** updated to platform shape:
   - `RulesView`, `EditRulesView`, `EditRuleSheet`, `RuleDetailView`
     drop the `rule.description` blocks (description no longer
     persisted per-rule; lives in `templates.config`).
   - `EditRulesCoordinator` toggle path uses `setIsActive` /
     `withIsActive`.
   - `FounderOnboardingCoordinator` filters on `\.isActive` and
     mutates drafts via `copy.isActive = false`.

4. **Server**: migration `00058_drop_rules_legacy_columns.sql`:
   - Rewrites `create_initial_rule(p_group_id, p_slug, p_name,
     p_is_active, p_trigger, p_conditions, p_consequences)` —
     platform-only INSERT.
   - Rewrites `seed_dinner_template_rules` to insert platform-only
     rows.
   - Rewrites `emit_rule_mutation_events` (00024 trigger fn) to
     read `is_active`/`name` instead of `enabled`/`title`. Audit
     event types unchanged so consumers don't break.
   - Rewrites `archive_rule_on_repeal_pass` (00026 trigger fn) to
     write `is_active = false` instead of `enabled = false` +
     `status = 'archived'`.
   - Drops the orphaned V1 `evaluate_event_rules(uuid)` function
     (replaced by `_shared/ruleEngine.ts` and `process-system-events`
     long ago; only referenced by a "does not invoke" comment).
   - `ALTER TABLE rules DROP COLUMN code, title, description,
     trigger, action, enabled, status, exceptions,
     approved_via_vote_id`.

5. **Tests**:
   - `RulesRepositoryTests`, `RuleFineShapeTests`,
     `CreateRuleChangeCoordinatorTests`, `FounderOnboardingCoordinatorTests`
     updated to construct `GroupRule` / `RuleDraft` in platform shape.
   - `supabase/functions/_tests/db/rule_mutation_audit.test.ts`
     reads `is_active`/`name` instead of `enabled`/`title`.

## DoD verification

- `\d public.rules` post-migration shows only platform columns
  (`id`, `group_id`, `slug`, `name`, `is_active`, `trigger`,
  `conditions`, `consequences`, `module_id`, `proposed_by`,
  `created_at`, `updated_at`). **Verify via MCP `execute_sql`
  before merging.**
- Zero hits of `rules.(title|code|enabled|action|status|exceptions|
  approved_via_vote_id|description)` in `*.swift` / `*.ts` / active
  `*.sql` (rollback + historical migrations excluded).
- V1 onboarding flow creates rules platform-only; engine fires.

## Costo real

4-6h focused as estimated.
