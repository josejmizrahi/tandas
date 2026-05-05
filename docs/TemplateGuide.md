# Template Guide

A **template** is a serializable group archetype: tabs, default modules,
default governance, default settings, default rules, onboarding flow.
Stored as a row in `public.templates` with full config in jsonb. Read at
boot by `TemplateRegistry`.

## Anatomy

The `config` column maps 1:1 to `TemplateConfig` Swift struct:

```jsonc
{
  "id": "recurring_dinner",
  "availableInVersion": 1,
  "defaultModules":     ["basic_fines", "rotating_host", "rsvp", "check_in", "appeal_voting"],
  "defaultGovernance":  { /* GovernanceRules — see Governance.md */ },
  "defaultSettings":    { /* template-specific keys */ },
  "defaultRules":       [ /* TemplateRule[] — see RuleAuthoring.md */ ],
  "suggestedTabs":      [ /* TabConfig[] */ ],
  "onboardingFlow":     [ /* OnboardingStepConfig[] */ ]
}
```

## Anatomy of `recurring_dinner` (V1)

Migration `00021` seeds it. Key facts:

- **Modules**: 5 (basic_fines, rotating_host, rsvp, check_in, appeal_voting)
- **Governance**: founder edits, host closes, any member proposes votes
- **Settings**: `eventVocabulary: "cena"`, `frequencyType: "weekly"`,
  `rotationMode: "manual"`, `gracePeriodEvents: 3`
- **Default rules**: 5 (the canonical fines from `RuleAuthoring.md`)
- **Tabs**: Inicio (template-specific home), Inbox, Reglas, Yo (universal)
- **Onboarding**: 11 steps (welcome → confirm)

## Adding a new template (Fase 2 example: Recurso compartido)

1. **Insert the row** in a new migration:

```sql
insert into public.templates (id, version, name, description, icon, config, available)
values (
  'shared_resource',
  1,
  'Recurso compartido',
  'Boletos, cupos o activos que rotan entre miembros.',
  'square.stack.3d.up.fill',
  jsonb_build_object(
    'id', 'shared_resource',
    'availableInVersion', 2,
    'defaultModules', jsonb_build_array('slot_assignment', 'rotating_position'),
    'defaultGovernance', jsonb_build_object(
      'whoCanModifyRules', 'majorityVote',
      ...
    ),
    'defaultSettings', jsonb_build_object(
      'eventVocabulary', 'turno',
      ...
    ),
    'defaultRules', jsonb_build_array(...),
    'suggestedTabs', jsonb_build_array(...),
    'onboardingFlow', jsonb_build_array(...)
  ),
  true
)
on conflict (id) do update set ...;
```

2. **Register modules** the template activates. If they're new, add them
   to `Platform/Modules/V1Modules.swift` (or a Fase 2 file) and to
   `ModuleRegistry.v1Modules`.

3. **Build template-specific Views** under
   `ios/Tandas/Templates/SharedResource/Views/`. The home view here
   replaces `DinnerHomeView`. Universal views (Inbox / Rules / Yo) are
   reused as-is.

4. **Wire the onboarding step dispatcher**. The founder coordinator
   reads `template.config.onboardingFlow` to know which steps to render.
   New step types may need new view dispatchers in `OnboardingRootView`.

5. **Test the flow end-to-end**: founder selects template → group is
   created with correct `base_template`/`active_modules`/`governance`/
   `settings` → tabs render correctly → rules fire on test events.

## Why config-driven (not Swift classes)

If templates were Swift classes, you couldn't:
- Allow a group to fork another group's config as its starting point
- Modify a template post-launch without an app update
- Build a "make your own template" UI in Fase 4
- A/B test variations of the same template

The cost is one indirection (`config -> TemplateConfig` Codable) on each
boot — caches in `TemplateRegistry`, hot-path lookups stay synchronous.

## Validating a template

`ModuleRegistry.validate(ids:)` catches dependency / conflict errors at
template install time. Use it in CI / migration tests:

```swift
let issues = ModuleRegistry.validate(ids: template.config.defaultModules ?? [])
if !issues.isEmpty {
    // fail the migration test
}
```
