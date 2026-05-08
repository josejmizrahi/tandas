# Rule Authoring

A `Rule` is a `WHEN [trigger] IF [conditions] THEN [consequences]` structure
persisted in the `rules` table. The rule engine consumes them.

## Anatomy

```swift
Rule(
    groupId: groupId,
    name: "Llegada tardía",
    isActive: true,
    trigger: RuleTrigger(eventType: .checkInRecorded),
    conditions: [
        RuleCondition(
            type: .checkInMinutesLate,
            config: .object(["thresholdMinutes": .int(0)])
        )
    ],
    consequences: [
        RuleConsequence(
            type: .fine,
            config: .object([
                "baseAmount":  .int(200),
                "stepAmount":  .int(50),
                "stepMinutes": .int(30),
            ])
        )
    ]
)
```

Persists to `rules`:
- `name` — human label (used in History + UI)
- `is_active` — toggle without deleting
- `trigger jsonb` — `{ "eventType": "checkInRecorded" }`
- `conditions jsonb` — array of `{ "type", "config" }`
- `consequences jsonb` — array of `{ "type", "config" }`
- `module_id` — which module owns this rule (for analytics + bulk toggle)

## Five canonical V1 rules (recurring_dinner template)

These ship in `templates.config.defaultRules` (migration 00021):

### 1. Llegada tardía
- Trigger: `checkInRecorded`
- Conditions: `checkInMinutesLate(thresholdMinutes: 0)`
- Consequence: `fine(baseAmount: 200, stepAmount: 50, stepMinutes: 30)`

### 2. No confirmó a tiempo
- Trigger: `eventClosed`
- Conditions: `responseStatusIs(status: "pending")`
- Consequence: `fine(amount: 200)`

### 3. Cancelación mismo día
- Trigger: `rsvpChangedSameDay`
- Conditions: `alwaysTrue`
- Consequence: `fine(amount: 200)`

### 4. No se presentó
- Trigger: `eventClosed`
- Conditions: `responseStatusIs(status: "going") AND checkInExists(exists: false)`
- Consequence: `fine(amount: 500)`

### 5. Anfitrión sin descripción
- Trigger: `hoursBeforeEvent(hours: 24)`
- Conditions: `memberIsHost AND eventDescriptionMissing`
- Consequence: `fine(amount: 100)`

## How the engine picks rules

```
SystemEvent arrives
    ↓
SELECT rules
WHERE group_id = event.group_id
  AND is_active = true
  AND trigger->>'eventType' = event.event_type
ORDER BY priority DESC
    ↓
For each Rule:
  resolve targets (TriggerEvaluator)
    ↓
  For each target:
    evaluate conditions (AND, short-circuit)
    if all match:
      execute consequences in order
      emit cascading SystemEvents
```

## Composing AND vs OR

Conditions inside a Rule are AND. There is no OR primitive — split into
two Rules with the same trigger if you need OR.

## Editing rules at runtime

`groups.governance.whoCanModifyRules` gates who can edit. V1 default:
`founder`. The founder edits via `EditRulesView` (shipped 2026-05-05
via plan `2026-05-05-edit-rules-view.md`). When governance is set to
`majorityVote`, changes open a generic Vote with
`vote_type='rule_change'`; on pass, `finalize_vote` (migration 00032)
emits a `ruleChangeApplyPending` user_action with deep-link
`ruul://rule/<uuid>/edit?proposedAmount=<int>` so the rule editor
pre-loads the proposed delta — see plan
`2026-05-07-open-votes-view.md` for the rule_change low-friction flow.

## Tests

Each evaluator + executor has a test under
`supabase/functions/_shared/ruleEngine.test.ts`. Add fixtures for new
rules so the regression catches engine drift.
