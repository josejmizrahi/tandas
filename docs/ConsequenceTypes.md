# ConsequenceTypes — Catalog

When a Rule's conditions match, all its consequences execute. Each has a
`type` + `config` jsonb. The engine runs them server-side via
`_shared/ruleEngine.ts:ConsequenceExecutor`.

Defined in `Platform/Models/ConsequenceType.swift`.

## V1 implemented

### `fine`

Creates a `fines` row with `status='proposed'`, plus a
`fine_review_periods` row giving the host 24h to review/edit/forgive
before `finalize-fine-reviews` cron officializes.

Two config shapes:

```json
// Flat fee
{ "amount": 200 }

// Escalating (e.g. late arrival)
{ "baseAmount": 200, "stepAmount": 50, "stepMinutes": 30 }
```

Escalating fee = `baseAmount + stepAmount * floor(lateMinutes / stepMinutes)`.

Emits `fineOfficialized` system event when the grace period ends (via the
cron). Apple-pay / cash payment flow updates `fines.paid` and emits
`finePaid`.

### `startVote`

Opens a generic Vote via `start_vote` RPC. Used today by:

- **Fine appeals** — when a member appeals an officialized fine, the
  appeal flow calls `start_vote(vote_type='fine_appeal', reference_id=fine_id, payload={member_id})`.
  `start_vote` excludes the infractor from `vote_casts` (governance fix
  00023) so a 2-member group can't auto-resolve against itself.
- **Rule change proposals** — when governance is `majorityVote`,
  `EditRulesView` calls `start_vote(vote_type='rule_change', reference_id=rule_id, payload={proposedAmount})`.
  On pass, migration 00032 emits a `ruleChangeApplyPending` user_action
  with deep-link to the rule editor.

Config:

```json
{ "voteType": "fine_appeal" | "rule_change" | ..., "durationHoursOverride": 72 }
```

Other vote_types (member_removal, fund_withdrawal, etc.) ship with
their respective primitives in later phases.

## Reserved for later phases

| Case | Phase | Use case |
|---|---|---|
| `loseTurn` | Fase 2 | Skip member's next host turn |
| `losePriority` | Fase 2 | Drop member's rotation priority |
| `serviceCompensation` | Fase 4 | Member owes a non-monetary service (host an extra event) |
| `blockTemporary` | Fase 4 | Temporarily block from action (e.g. RSVP) |
| `reciprocity` | Fase 4 | Create a non-monetary debt between members |
| `logOnly` | V1+ | Pure audit consequence — emit log row, no side effects |
| `sumPoints` | Fase posterior | Member points/karma |
| `subtractPoints` | "" | "" |
| `sendNotification` | V1+ | Push notif via send-event-notification (APNs shipped 2026-05-07) |
| `createEvent` | Fase 4 | Auto-create another event |
| `assignSlot` | Fase 2 | Assign a slot to a member |
| `transferRight` | Fase 2 | Move a slot/asset between members |
| `callWebhook` | Fase 4 | External integration |

Consequences of these types throw `NotImplementedError`. The rule using
them is skipped with a structured log.

**Adding a consequence**:
1. Add the case to the Swift enum.
2. Document the config schema in this file.
3. Implement `ConsequenceExecutor` in `_shared/ruleEngine.ts`.
4. Update `isImplementedInV1` if it ships in V1.
5. Write a unit test exercising the side effects (DB rows + emitted events).
6. If the consequence emits a new `SystemEventType`, add it to
   [EventTypes](EventTypes.md) AND `Platform/Models/SystemEventType.swift`.
