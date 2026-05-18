import Foundation

/// Every event the platform may emit. The rule engine matches `Rule.trigger
/// .eventType` against this enum.
///
/// Cases marked **(V1)** have a TriggerEvaluator implementation in
/// `_shared/ruleEngine.ts`. Other cases are declared so the model stays
/// V4-ready; the engine ignores rules whose trigger is not implemented yet.
// @codegen:enum
public enum SystemEventType: Codable, Sendable, Hashable {

    // MARK: - Event resource lifecycle
    case eventClosed
    case eventCreated
    case rsvpDeadlinePassed
    case hoursBeforeEvent

    // MARK: - RSVP / attendance
    case rsvpSubmitted
    case rsvpChangedSameDay
    case checkInRecorded
    case checkInMissed
    case eventDescriptionMissing

    // MARK: - Slot / Asset / Booking (Fase 2 — shared_resource)
    case slotAssigned
    case slotDeclined
    case slotExpired
    case slotSwapRequested
    case slotSwapApproved
    case bookingCreated
    case bookingCancelled
    case bookingExpired
    case assetCreated

    // MARK: - Fines + appeals
    case fineOfficialized
    case fineVoided
    case finePaid
    case fineReminderSent
    case appealCreated
    case appealResolved
    case voteOpened
    case voteCast
    case voteResolved

    // MARK: - Fund (Fase posterior)
    /// Emitted by `create_fund` (mig 00137) when a new fund resource
    /// lands. Lets ActivitySectionView surface "X creó el fondo Y" the
    /// same way assetCreated does for shared assets.
    case fundCreated
    case fundDeposit
    case fundThresholdReached
    /// Emitted by `fund_lock` (mig 00198) when an admin places a fund
    /// in locked state. Payload: `{locked_by, locked_reason}`. Rule
    /// engine consumes this to short-circuit policy-gated writers; the
    /// canonical RPCs themselves do not consult lock state (Constitution §9).
    case fundLocked
    /// Emitted by `fund_unlock` (mig 00198) when an admin releases a
    /// fund lock. Payload: `{unlocked_by, previous_locked_at}`.
    case fundUnlocked

    // MARK: - Space (mig 00207 + 00264 — Plans/Active/Space.md §9)
    /// Emitted by `create_space` (mig 00207) when a new space resource
    /// lands. Payload: `{name, capacity?, location_name?, location_lat?,
    /// location_lng?, description?}`. Drives "X creó el espacio Y" in
    /// the activity feed.
    case spaceCreated
    /// Emitted by `book_space` (mig 00265) when the *entire* space is
    /// claimed for a window (vs a single slot inside it). `member_id` =
    /// booker. Payload: `{booking_id, starts_at?, ends_at?, notes?}`.
    /// Coarser than `bookingCreated` (which fires per atom row in
    /// public.bookings); both atoms coexist so projections can derive
    /// "Palco entero" vs "slot 19:00".
    case spaceBooked
    /// Emitted by `release_space` (mig 00265) or by the auto-release
    /// rule when a no-check-in window expires. `member_id` = previous
    /// booker. Payload: `{released_by, reason}` where reason ∈
    /// {`manual`, `expired`, `cancelled`, `no_check_in`}.
    case spaceReleased
    /// Emitted by `join_waitlist` (mig 00265) when a member tries to
    /// book a space that is at capacity. `member_id` = the member that
    /// joined the queue. Payload: `{requested_at, priority,
    /// triggered_booking_id?}`.
    case spaceCapacityReached
    /// Emitted by `join_waitlist` (mig 00265) — appends a member to the
    /// ordered waitlist projection. Distinct atom from
    /// `spaceCapacityReached`: capacity reached fires once per overflow,
    /// waitlist joined fires per member. `member_id` = the joining
    /// member. Payload: `{priority, joined_at, notes?}`.
    case spaceWaitlistJoined
    /// Emitted by `promote_from_waitlist` (mig 00265) when a freed slot
    /// promotes the top of the waitlist. `member_id` = promoted member.
    /// Payload: `{promoted_by, original_joined_at, promoted_at}`.
    case spaceWaitlistPromoted
    /// Emitted by `grant_space_access` (mig 00265) — admin override or
    /// explicit grant that bypasses normal booking gates. `member_id` =
    /// granted member. Payload: `{granted_by, until?, reason?}`.
    case spaceAccessGranted
    /// Emitted by `revoke_space_access` (mig 00265) — terminates a
    /// previously-granted access. `member_id` = revoked member. Payload:
    /// `{revoked_by, reason?}`.
    case spaceAccessRevoked

    // MARK: - Rotation / membership
    case positionChanged
    case memberJoined
    case memberLeft

    // MARK: - Rule mutations (audit only — not rule-engine triggers)
    /// Emitted when a rule is toggled on/off (UPDATE rules.enabled).
    case ruleEnabledChanged
    /// Emitted when a rule's fine amount is edited (UPDATE rules.action).
    case ruleAmountChanged

    // MARK: - Governance / pending changes (audit only)
    /// Emitted by `apply_pending_change` (mig 00089) after a vote
    /// resolves and the queued change has been applied. Lets subsequent
    /// invocations short-circuit and gives the audit trail a marker.
    case pendingChangeApplied
    /// Emitted by `regenerate_invite_code` (mig 00176) when an admin
    /// rotates `groups.invite_code`. Audit only — not a rule-engine
    /// trigger. Payload carries `rotated_by` (user_id) so the timeline
    /// can render "X rotó el código del grupo".
    case inviteCodeRotated

    // MARK: - Group (Layer 1 Subject/Domain) lifecycle — mig 00178
    /// Group row inserted. Emitted by trigger; payload carries created_by.
    case groupCreated
    /// `groups.archived_at` flipped null → set (via `archive_group` RPC).
    case groupArchived
    /// `groups.archived_at` flipped set → null (via `unarchive_group`).
    case groupUnarchived
    /// `groups.name` changed. Payload carries old/new name.
    case groupRenamed
    /// `groups.governance` jsonb changed. Distinct from per-rule mutations
    /// (ruleEnabledChanged/ruleAmountChanged) which audit `public.rules`.
    case governanceUpdated

    // MARK: - Resource (Layer 3) lifecycle — mig 00186
    /// `resources.archived_at` flipped null → set (via `archive_resource`).
    /// Generic across all resource_types (event/fund/asset/slot/space/right).
    case resourceArchived
    /// `resources.archived_at` flipped set → null (via `unarchive_resource`).
    case resourceUnarchived
    /// `resources.metadata.title` or `metadata.name` changed.
    case resourceRenamed

    // MARK: - Capability (Layer 5) lifecycle — mig 00192
    /// `resource_capabilities.enabled` toggled by a user (not auto-seed).
    /// Payload: capability_block_id + new_enabled + resource_type.
    case capabilityToggled
    /// `resource_capabilities.config` jsonb mutated (founder edited
    /// thresholds, deadlines, etc.).
    case capabilityConfigUpdated
    /// New row inserted into `member_capability_overrides` (Isaac
    /// excluded from rotation, guest can book, etc.).
    case memberCapabilityOverridden

    // MARK: - Money / Governance flow (mig 00193, expense_threshold_warning pilot)
    /// Atom emitted by `ledger_entries_emit_atom` trigger on every insert.
    /// Payload: `{type, amount_cents, currency, from_member_id, to_member_id,
    /// resource_id, ledger_entry_id}`. Drives `expense_threshold_warning`
    /// rule template (Builder Beta 1 expansion).
    case ledgerEntryCreated
    /// Emitted by the `emitWarning` rule consequence. Surfaces in the
    /// activity feed; visible to admins via rule_evaluations audit.
    /// Payload: `{rule_id, target_member_id, reason, source_atom_id}`.
    case warningEmitted

    // MARK: - Right (Layer 4 resource_type='right') lifecycle — mig 00198
    /// Emitted by `create_right` when a new normative claim is
    /// materialised. Payload carries holder + target_resource + target
    /// capability + scope/priority/transferable/delegable/divisible knobs.
    case rightCreated
    /// Emitted by `transfer_right` — a transferable right was reassigned
    /// to a new holder. Payload: `{from_member_id, to_member_id,
    /// transferred_by, reason}`.
    case rightTransferred
    /// Emitted by `delegate_right` — holder unchanged, delegate stored
    /// in metadata. Payload: `{delegate_member_id, until, delegated_by,
    /// reason}`.
    case rightDelegated
    /// Emitted by `revoke_right` — status flipped to `revoked`. Payload:
    /// `{previous_status, revoked_by, reason}`.
    case rightRevoked
    /// Emitted by the right-expiration cron / consequence when `expires_at`
    /// is reached (reserved; cron lands in a follow-up slice).
    case rightExpired
    /// Emitted by `exercise_right` — holder or delegate used the right.
    /// Payload: `{exercised_by_user_id, exercised_by_member_id, context}`.
    case rightExercised
    /// Emitted by `suspend_right` — temporary lift planned via
    /// `metadata.suspended_until`. Payload: `{until, suspended_by, reason}`.
    case rightSuspended
    /// Emitted by `restore_right` — suspension cleared (or status lifted
    /// back to `active` from `revoked`).
    case rightRestored
    /// Emitted by the `notify-rights-expiring-soon-daily` cron (mig 00203)
    /// when a right enters its pre-expiry warning window (default 14 days).
    /// Idempotent — `metadata.expiration_warning_emitted` flags emitted
    /// rights so subsequent runs skip them. Drives the
    /// `right_expiration_warning` rule template.
    case rightExpiringSoon

    // MARK: - Asset universal atoms — mig 00199 (canonical asset spec §13)
    /// Asset ownership moved to another member or back to the group.
    /// Emitted by `transfer_asset(p_asset_id, p_to_member_id, p_notes)`.
    /// Payload: `{transferred_by, from_member_id, to_member_id, notes}`.
    case assetTransferred
    /// Asset assigned to a member for ongoing operational responsibility.
    /// Reserved for the assignment workflow; not emitted by a v1 RPC.
    case assetAssigned
    /// Counterpart of `assetAssigned` — assignment ended/returned.
    case assetReturned
    /// A custodian was designated. Emitted by
    /// `assign_custody(p_asset_id, p_custodian_member_id, p_notes)`.
    /// Payload: `{assigned_by, notes}`. `member_id` = custodian.
    case custodyAssigned
    /// Custody released — asset returns to group-level custody. Emitted
    /// by `release_custody(p_asset_id, p_notes)`. Payload:
    /// `{released_by, notes}`. `member_id` = previous custodian.
    case custodyReleased
    /// A maintenance task was logged (service / inspection / repair).
    /// Emitted by `log_maintenance(asset, kind, notes, cost, currency)`.
    /// Payload: `{logged_by, kind, notes, cost_cents, currency, status}`.
    case maintenanceLogged
    /// A previously-logged maintenance task was marked done. Emitted by
    /// `complete_maintenance(p_maintenance_event_id, p_notes)`. Payload:
    /// `{completed_by, notes, maintenance_event_id}`.
    case maintenanceCompleted
    /// A damage incident was reported. Emitted by
    /// `report_damage(asset, severity, notes, estimated_cost, currency)`.
    /// Payload: `{reported_by, severity, notes, estimated_cost_cents,
    /// currency}`. Severity bounded: minor|moderate|major|total.
    case damageReported
    /// Asset was used (free-form usage atom). Emitted by
    /// `record_asset_usage(asset, notes, units)`.
    /// Payload: `{used_by, notes, units}`.
    case assetUsed
    /// Asset checked out for temporary holding. Emitted by
    /// `check_out_asset(asset, to_member, expected_return, notes)`.
    /// Payload: `{checked_out_by, expected_return_at, notes}`.
    /// `member_id` = holder.
    case assetCheckedOut
    /// Asset returned (closes a prior checkout). Emitted by
    /// `check_in_asset(asset, condition_notes)`.
    /// Payload: `{checked_in_by, condition_notes}`.
    /// `member_id` = previous holder.
    case assetCheckedIn
    /// A new valuation point was recorded. Emitted by
    /// `record_valuation(asset, value_cents, currency, source, notes)`.
    /// Payload: `{recorded_by, value_cents, currency, source, notes}`.
    case valuationRecorded

    // MARK: - Resource links (mig 00202 — event uses space/asset/fund/right)
    /// Emitted by `link_resource_to_event`. Payload:
    /// `{link_id, link_kind, to_resource_id, to_resource_type, linked_by}`.
    /// Plans/Active/EventResource.md §12.
    case resourceLinked
    /// Emitted by `unlink_resource_from_event`. Same payload shape as
    /// `resourceLinked` with `unlinked_by` instead of `linked_by`.
    case resourceUnlinked

    // MARK: - Event lifecycle (mig 00203 — Plans/Active/EventResource.md §8)
    /// Emitted by trigger on `resources.status` → 'cancelled' (resource_type=
    /// event). Distinct from `eventClosed`, which today still fires for
    /// cancellations too via the legacy `cancel_event` RPC — drop in a
    /// follow-up once consumers move to this. Payload:
    /// `{title, previous_status, reason, cancelled_by}`.
    case eventCancelled
    /// Emitted by the `emit-event-started-atoms` cron (mig 00208) when an
    /// event's `starts_at` elapses and no `eventCancelled` atom exists.
    /// Lets the rule engine and `event_lifecycle_view` derive `is_live`
    /// from atoms instead of the clock. Payload: `{starts_at, title, host_id}`.
    case eventStarted
    /// Emitted by trigger on `resources.metadata` UPDATE for events
    /// (mig 00210) when any non-title key changes (location, starts_at,
    /// description, host_id, cover, …). Title-only renames keep flowing
    /// through `resourceRenamed`. Payload: `{changed_keys, changed_by,
    /// title, title_changed}`.
    case eventUpdated

    // MARK: - Asset rule overdue atoms (mig 00225 — Plans/Active/AssetRules.md §5)
    /// Emitted by the `emit-asset-overdue-events` cron when an asset's
    /// latest `assetCheckedOut` row has `expected_return_at` in the past
    /// and no later `assetCheckedIn` closed it. `member_id` = the
    /// previous holder so rules can fine the right person without
    /// re-resolving. Payload: `{expected_return_at, checked_out_at,
    /// days_overdue}`. Drives the `not_returned_fine` template.
    case assetCheckoutOverdue
    /// Emitted by the same cron when a `maintenanceLogged` atom hasn't
    /// been closed by a matching `maintenanceCompleted` within the
    /// grace window. `member_id` = null (resource-scoped). Payload:
    /// `{maintenance_event_id, days_open, logged_at}`. Drives the
    /// `maintenance_overdue_lock` template.
    case assetMaintenanceOverdue

    // MARK: - Role lifecycle (mig 00229 — Phase 5 RolesV2 completion)
    /// Emitted by `assign_role` when a member gains a role. Payload:
    /// `{role, user_id, assigned_by}`. `member_id` = the affected
    /// group_members row.
    case roleAssigned
    /// Emitted by `unassign_role` when a member loses a role. Payload:
    /// `{role, user_id, unassigned_by}`. `member_id` = the affected
    /// group_members row.
    case roleUnassigned

    case unknown(String)
}
