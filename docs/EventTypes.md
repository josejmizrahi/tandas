# SystemEventTypes — Catalog

Every event the platform emits. Defined in `Platform/Models/SystemEventType.swift`.

| Case | Status | Emitted by | Payload contract |
|---|---|---|---|
| `eventCreated` | V1 | Trigger on `resources` insert (event resource) | `{ source: "manual_creation" \| "auto_generated" }` |
| `eventClosed` | V1 | Host action via `close_event` RPC | `{ host_id, closed_at, fines_proposed: int }` |
| `rsvpDeadlinePassed` | V1 (cron) | `emit-deadline-events` edge fn | `{ rsvp_deadline, starts_at }` |
| `hoursBeforeEvent` | V1 (cron, synthetic) | future cron `emit-time-events` | `{ hours }` |
| `rsvpSubmitted` | V1 | `set_rsvp` RPC | `{ status, plus_ones }` |
| `rsvpChangedSameDay` | V1 | `set_rsvp` flag | `{ from_status, to_status }` |
| `checkInRecorded` | V1 | `check_in_attendee` RPC | `{ method, location_verified, late_minutes }` |
| `checkInMissed` | future | computed on close | `{}` |
| `eventDescriptionMissing` | V1 | computed on `hoursBeforeEvent` | `{}` |
| `slotAssigned` | Fase 2 | future | `{ slot_id, member_id }` |
| `slotDeclined` | Fase 2 | future | `{ slot_id, member_id, reason }` |
| `slotExpired` | Fase 2 | future | `{ slot_id }` |
| `fineOfficialized` | V1 (cron) | `finalize-fine-reviews` edge fn | `{ fine_id, member_id, amount }` |
| `finePaid` | V1 | `pay_fine` RPC | `{ fine_id, member_id, amount }` |
| `fineReminderSent` | V1 (cron) | `send-fine-reminders` edge fn | `{ fine_id, amount, day_threshold, age_days }` |
| `appealCreated` | V1 | `start_appeal` RPC | `{ appeal_id, fine_id, member_id, reason }` |
| `appealResolved` | V1 | `close_appeal_vote` RPC | `{ appeal_id, resolution }` |
| `voteOpened` | V1 | `start_vote` RPC | `{ vote_type, reference_id }` |
| `voteCast` | V1 | `cast_vote` RPC | `{ choice }` |
| `voteResolved` | V1 (cron) | `finalize_vote` RPC | `{ vote_type, reference_id, resolution }` |
| `fundDeposit` | Fase posterior | future | `{ amount, source }` |
| `fundThresholdReached` | Fase posterior | future | `{ amount, threshold }` |
| `positionChanged` | Fase 2 | future | `{ from, to }` |
| `memberJoined` | V1 | `join_group_by_code` RPC | `{ via: invite_code }` |
| `memberLeft` | V1 | `leave_group` RPC | `{ reason }` |

**Implementation guard:** `SystemEventType.isImplementedInV1` returns true
for events with at least one production emitter or rule consumer.

**Adding a new event type**:
1. Add the case to the Swift enum (camelCase rawValue).
2. Update `isImplementedInV1` to the right branch.
3. If a rule should react, add a TriggerEvaluator in `_shared/ruleEngine.ts`.
4. If history should display it, add a branch to `HistoryItemPresentation`.
