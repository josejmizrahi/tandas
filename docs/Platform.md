# ruul Platform — Architecture

> ruul is **infraestructura de autogobierno para grupos**. The platform
> layer is template-agnostic; templates compose platform primitives to
> produce concrete experiences (V1: Cena recurrente).

## The 7 primary citizens

Every concept in the platform reduces to one of these. If you find
"event"-specific or "fine"-specific logic in `Platform/`, it's misplaced.

| # | Citizen | What it is | Where it lives |
|---|---|---|---|
| 1 | **Group** | The container. Has identity, members, governance, base template, active modules, settings. | `groups` table, `Models/Group.swift` |
| 2 | **Member** | A human in a group. Carries roles[], rotation order, status. | `group_members`, `Models/Member.swift` |
| 3 | **Resource** | Anything the group manages. V1 implements `event`; future: `slot`, `fund`, `position`, `asset`, `contribution`. | `resources` table (V1 events still in legacy `events` w/ `events_view` projection), `Platform/Models/Resource.swift` |
| 4 | **Rule** | Declarative `WHEN [trigger] IF [conditions] THEN [consequences]`. | `rules` table, `Platform/Models/Rule.swift` |
| 5 | **SystemEvent** | Append-only log of everything that happened. Source of truth — any state can be reconstructed by replay. | `system_events` table, `Platform/Models/SystemEvent.swift` |
| 6 | **Action** | What a member must attend to. Inbox queue. | `user_actions` table, `Platform/Models/UserAction.swift` |
| 7 | **Vote** | Generic decision mechanism. V1 emits `fine_appeal`; V2+ adds `rule_change`, `member_removal`, etc. | `votes` + `vote_casts`, `Platform/Models/Vote.swift` |

## The reactive flow

```
[Member action] ──► repo emits [SystemEvent]
                      │
                      ▼
            [process-system-events] (cron, every 1m)
                      │
                      ▼
                [RuleEngine] ──► finds matching Rules
                      │
                      ▼
       evaluates conditions (AND) ──► if all true:
                      │
                      ▼
       executes consequences ──► creates/updates resources
                      │                  │
                      └──── emits more [SystemEvent]s
                              (cascade until quiescent)
```

Every action emits a SystemEvent. The engine is server-only (TS in
`supabase/functions/_shared/ruleEngine.ts`). The client never evaluates
rules — eliminates client/server drift.

## Determinism rule

Evaluators and executors NEVER use:
- `Date.now()` — timestamps come from the triggering SystemEvent
- RNG — outcomes must be reproducible
- Mutable shared state — pure functions only

Why: replay capability + auditability + tests that don't flake.

## Templates as configuration, not code

A template is a `templates.config` jsonb row, not a Swift class. To ship
a new template:
1. INSERT a row in `templates` with `config: {...}`.
2. Register any new modules it activates in `ModuleRegistry`.
3. Build the template-specific Views in `Templates/<id>/Views/`.

The `recurring_dinner` template (V1) is in migration `00021`. See
[TemplateGuide](TemplateGuide.md).

## Modules as composable units

A `Group` has ONE base template + N active modules. V1 modules:
- `basic_fines` — monetary fines (deps: rsvp, check_in)
- `rotating_host` — host rotation
- `rsvp` — attendance responses
- `check_in` — arrival registration (deps: rsvp)
- `appeal_voting` — fine appeals via generic Vote (deps: basic_fines)

See [ModuleGuide](ModuleGuide.md).

## Governance

Each group carries `groups.governance` jsonb — who can do what. NOT
hardcoded "founder edits". 6 permission levels × 6 governance actions.

See [Governance](Governance.md).

## Catalogs

- [SystemEventTypes](EventTypes.md) — 24 cases, V1 implementation status
- [ConditionTypes](ConditionTypes.md) — 16 cases, V1 implementation status
- [ConsequenceTypes](ConsequenceTypes.md) — 15 cases, V1 implementation status

## Authoring rules

[RuleAuthoring](RuleAuthoring.md) — how to compose a rule, examples.

## Adding a module / template

- New module → Module struct in `Platform/Modules/V1Modules.swift` (or new file) + registry registration. See [ModuleGuide](ModuleGuide.md).
- New template → INSERT in `templates` table + new folder under `Templates/<id>/`. See [TemplateGuide](TemplateGuide.md).
