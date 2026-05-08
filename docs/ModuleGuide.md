# Module Guide

A **module** is a unit of group functionality: a coherent bundle of
`Resource` types it provides, `Rule`s it ships, `SystemEvent`s it emits
or reacts to, and (optionally) tabs it adds to navigation.

## V1 modules

| id | What it does | Deps | Provides events |
|---|---|---|---|
| `basic_fines` | Monetary fines triggered by rule violations | `rsvp`, `check_in` | `fineOfficialized`, `finePaid`, `appealCreated`, `appealResolved` |
| `rotating_host` | Host rotation across active members | — | `positionChanged` |
| `rsvp` | Going/maybe/declined responses | — | `rsvpSubmitted`, `rsvpChangedSameDay`, `rsvpDeadlinePassed` |
| `check_in` | Self / manual / QR check-in at event | `rsvp` | `checkInRecorded`, `checkInMissed` |
| `appeal_voting` | Appeal a fine via group vote (uses generic `Vote`) | `basic_fines` | `voteOpened`, `voteCast`, `voteResolved` |

## When to write a module vs. extend a template

Module if:
- The functionality is reusable across templates (e.g. `basic_fines` works
  for cenas + recurso compartido + tandas)
- It declares its own `Resource` types or `Rule`s
- It can be enabled/disabled per group (toggle in `GroupSettingsSheet`)

Template-specific (NOT a module) if:
- It only makes sense in one template's UI (e.g. dinner home view layout)
- It's pure presentation, no platform primitives involved

## Adding a new module (Fase 2 example: SlotAssignment)

1. **Define the manifest**. Add to `Platform/Modules/V1Modules.swift` (or
   a separate `Phase2Modules.swift`):

```swift
extension GroupModule {
    static let slotAssignment = GroupModule(
        id: "slot_assignment",
        name: "Asignación de cupos",
        description: "Cupos rotativos asignados a miembros con aceptar/rechazar.",
        providedRules: [
            "Cupo no aceptado",
            "Cupo rechazado consecutivo",
        ],
        providedResourceTypes: [.slot],
        providedSystemEventTypes: [
            .slotAssigned, .slotDeclined, .slotExpired,
        ],
        providedTabs: [],
        dependencies: [],
        conflictsWith: ["rotating_host"]
    )
}
```

2. **Register it** in `ModuleRegistry.v1Modules` (rename to `allModules`
   in Fase 2 to drop the V1 connotation).

3. **Implement Resource lifecycle** if the module owns a new
   `ResourceType`. The slot's CRUD lives in a new `SlotRepository`
   actor under `Platform/Repositories/`.

4. **Implement Rule engine bits** if the module emits/reacts to events:
   - New `SystemEventType` cases → add to enum + EventTypes.md
   - New `ConditionType` / `ConsequenceType` cases → enum + Condition*/
     Consequence* docs + evaluator/executor in `_shared/ruleEngine.ts`

5. **Wire to a template**. Add the module id to the template's
   `defaultModules` array. Existing groups can opt-in via a future
   "module catalog" UI.

## Validation

`ModuleRegistry.validate(ids:)` catches:
- Unknown module ids
- Missing dependencies (`appeal_voting` needs `basic_fines`)
- Conflicts (`slot_assignment` conflicts with `rotating_host`)

Always validate before persisting `groups.active_modules`. The migration
should refuse to seed a template with invalid combinations.

## Module onboarding (post-creation activation)

A group inherits `Template.config.defaultModules` at creation. Any
later change requires explicit member action — modules are not auto-
activated when an evaluator stub becomes implementing.

**Activation flow** (Fase 2+; the UI for this lands with the first
modular activation case):

1. `GroupSettingsSheet → "Activar módulo"` lists all modules from
   `ModuleRegistry.allModules` not already in `group.activeModules`,
   filtered by `template.config.resourceTypes` compatibility.
2. Tapping `slot_assignment` shows `ModuleOnboardingSheet`:
   - Module presentation (name, description, what it adds — pulls
     from manifest).
   - Dependencies it will activate transitively (`appeal_voting`
     auto-pulls `basic_fines`).
   - Conflicts it will deactivate (`slot_assignment` removes
     `rotating_host`, with confirmation).
   - Default rules it will seed (jsonb preview).
3. On confirm: `ModuleService.activate(moduleId, groupId)` —
   - `ModuleRegistry.validate(activeModules + [moduleId])` — abort on
     conflict without explicit override.
   - Append to `groups.active_modules` jsonb (server-side RPC
     `update_group_modules`).
   - Insert default rules from `module.providedRules` into
     `rules` table (status=`active`, source=`module-default`).
   - Emit `SystemEvent.moduleActivated(moduleId)` so history shows
     the change as a governance event.
   - If `groups.governance.whoCanModifyGovernance ≠ founder`,
     `ModuleService.activate` opens a `module_activation` vote
     instead of writing directly. (vote_type pending.)

**Deactivation flow**:

- Symmetrical, but `ModuleService.deactivate(moduleId, groupId)`
  preserves historical Resources of types provided by the module
  (don't cascade-delete past Slots when `slot_assignment` deactivates).
- Default rules from `providedRules` are marked `is_active=false`,
  not deleted, so reactivation later picks up the same slugs.

**V1 status**: NOT implemented. `groups.active_modules` is set at
creation from `template.config.defaultModules` and never mutated.
First implementation lands with the first non-default module case
(likely Fase 2 `slot_assignment` or Fase 3 `common_fund`).

## Why modules vs. monolithic templates

A grupo of friends might want "cena recurrente + fondo común" without
host rotation. Modules let that grupo activate `basic_fines + rsvp +
check_in + common_fund` and turn off `rotating_host`. Without modules,
every variant of the dinner experience would need its own template row.
