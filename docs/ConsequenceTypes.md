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

## Reserved for later phases

| Case | Phase | Use case |
|---|---|---|
| `loseTurn` | V2 | Skip member's next host turn |
| `losePriority` | V2 | Drop member's rotation priority |
| `serviceCompensation` | V2 | Member owes a non-monetary service (host an extra event) |
| `blockTemporary` | V2 | Temporarily block from action (e.g. RSVP) |
| `reciprocity` | V2 | Create a non-monetary debt between members |
| `logOnly` | V1+ | Pure audit consequence — emit log row, no side effects |
| `sumPoints` | Fase posterior | Member points/karma |
| `subtractPoints` | "" | "" |
| `sendNotification` | V1+ | Push notif via send-event-notification (stub until APNs) |
| `startVote` | V2 | Open a Vote with a referenceId — uses `start_vote` RPC |
| `createEvent` | V2 | Auto-create another event |
| `assignSlot` | Fase 2 | Assign a slot to a member |
| `transferRight` | Fase 2 | Move a slot/asset between members |
| `callWebhook` | V3 | External integration |

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
