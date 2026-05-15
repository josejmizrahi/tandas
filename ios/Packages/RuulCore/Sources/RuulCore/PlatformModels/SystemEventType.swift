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

    case unknown(String)
}
