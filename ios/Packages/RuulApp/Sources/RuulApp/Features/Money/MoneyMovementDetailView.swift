import SwiftUI
import RuulCore

/// Detail surface for a single `MoneyMovement` ledger row. Read-only:
/// Foundation iOS never mutates ledger entries (reversals require a
/// dedicated future flow). Sections: summary hero + parties (from/to/
/// paid_by/recorded_by) + meta (source / split / description / dates).
struct MoneyMovementDetailView: View {
    let movement: MoneyMovement
    let myMembershipId: UUID
    /// V2-G5 — when provided, the view can cross-reference
    /// `movement.mandateId` against active mandates to surface the
    /// "actuó por mandato de…" context. Optional so previews and
    /// non-money callers can pass nil.
    let mandatesStore: MandatesStore?
    /// V3 Batch B-2 slice 2 — when set, party rows (from/to/paidBy)
    /// become tappable and call back with the membership_id. Caller
    /// resolves to MembershipBoundaryItem and pushes MemberDetailView.
    /// Nil = static labels (preview / standalone).
    let onSelectMember: ((UUID) -> Void)?

    init(
        movement: MoneyMovement,
        myMembershipId: UUID,
        mandatesStore: MandatesStore? = nil,
        onSelectMember: ((UUID) -> Void)? = nil
    ) {
        self.movement = movement
        self.myMembershipId = myMembershipId
        self.mandatesStore = mandatesStore
        self.onSelectMember = onSelectMember
    }

    var body: some View {
        List {
            heroSection
            partiesSection
            breakdownSection
            mandateSection
            metaSection
        }
        .navigationTitle(L10n.MoneyMovementDetail.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Lazy-refresh so the cross-reference works even if the
            // caller didn't pre-load mandates (e.g. opening detail
            // straight from a deep link before the surface has run
            // its own refresh).
            if let mandatesStore {
                await mandatesStore.refreshIfNeeded(groupId: movement.groupId)
            }
        }
    }

    /// Resolved mandate row if MandatesStore has it cached. Nil when
    /// `movement.mandateId` is nil, when the store wasn't provided,
    /// or when the mandate has already been revoked / expired (the
    /// `group_mandates_active` RPC excludes those rows).
    private var resolvedMandate: GroupMandate? {
        guard let mandatesStore, let mandateId = movement.mandateId else {
            return nil
        }
        return mandatesStore.mandates.first(where: { $0.id == mandateId })
    }

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: movement.type.systemImageName)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 76, height: 76)
                    .background(.thinMaterial, in: Circle())

                VStack(spacing: 4) {
                    Text("\(movement.amount.formatted()) \(movement.unit)")
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                        .strikethrough(movement.isReversal)
                    Text(movement.type.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if movement.isReversal {
                    Text(L10n.MoneyMovementDetail.reversalNotice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var partiesSection: some View {
        let hasParties = movement.fromDisplayName != nil
            || movement.toDisplayName != nil
            || movement.paidByDisplayName != nil
            || movement.recordedByDisplayName != nil
        if hasParties {
            Section(L10n.MoneyMovementDetail.partiesSection) {
                if let from = movement.fromDisplayName {
                    party(label: L10n.MoneyMovementDetail.fromLabel,
                          name: from,
                          membershipId: movement.fromMembershipId,
                          isMe: movement.fromMembershipId == myMembershipId)
                }
                if let to = movement.toDisplayName {
                    party(label: L10n.MoneyMovementDetail.toLabel,
                          name: to,
                          membershipId: movement.toMembershipId,
                          isMe: movement.toMembershipId == myMembershipId)
                }
                if let paidBy = movement.paidByDisplayName, paidBy != movement.fromDisplayName {
                    party(label: L10n.MoneyMovementDetail.paidByLabel,
                          name: paidBy,
                          membershipId: movement.paidByMembershipId,
                          isMe: movement.paidByMembershipId == myMembershipId)
                }
                if let recordedBy = movement.recordedByDisplayName {
                    // recordedBy es auth-side (user, no membership). No
                    // navegable porque el dataset no carga su
                    // membership_id en este shape.
                    party(label: L10n.MoneyMovementDetail.recordedByLabel,
                          name: recordedBy,
                          membershipId: nil,
                          isMe: false)
                }
            }
        }
    }

    /// V3 Batch B-2 — cuando `onSelectMember` está cableado y hay
    /// `membershipId` real, el row se vuelve un botón que navega a
    /// MemberDetailView. Cross-primitive link doctrine.
    @ViewBuilder
    private func party(
        label: LocalizedStringResource,
        name: String,
        membershipId: UUID?,
        isMe: Bool
    ) -> some View {
        if let onSelectMember, let mid = membershipId, !isMe {
            Button {
                onSelectMember(mid)
            } label: {
                partyContent(label: label, name: name, isMe: isMe, isNavigable: true)
            }
            .buttonStyle(.plain)
        } else {
            partyContent(label: label, name: name, isMe: isMe, isNavigable: false)
        }
    }

    @ViewBuilder
    private func partyContent(
        label: LocalizedStringResource,
        name: String,
        isMe: Bool,
        isNavigable: Bool
    ) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                Text(name)
                if isMe {
                    Text("(tú)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isNavigable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        } label: {
            Text(label)
        }
    }

    /// V3-S3 — per-participant breakdown of an expense split. Shows
    /// "Pedro: $33.33 / Tú: $33.34 / María: $33.33". Hidden for movements
    /// without a breakdown (settlements, sanctions, in-kind, or legacy
    /// rows where split_breakdown was never persisted).
    @ViewBuilder
    private var breakdownSection: some View {
        if let breakdown = movement.splitBreakdown, !breakdown.isEmpty {
            Section("Reparto") {
                ForEach(breakdown, id: \.membershipId) { share in
                    HStack {
                        Text(displayName(for: share))
                        Spacer()
                        Text(formattedAmount(share.amount))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // Footer total only when amounts are present (legacy rows
                // pre-S1 stored even-split without per-share amounts).
                if breakdown.allSatisfy({ $0.amount != nil }) {
                    HStack {
                        Text("Total")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(
                            formattedAmount(
                                breakdown.reduce(Decimal(0)) { $0 + ($1.amount ?? 0) }
                            )
                        )
                        .monospacedDigit()
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func displayName(for share: MoneyMovement.SplitShareDisplay) -> String {
        if share.membershipId == myMembershipId { return "Tú" }
        if let name = share.displayName, !name.isEmpty { return name }
        return "—"
    }

    private func formattedAmount(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = movement.unit
        f.locale = Locale(identifier: "es_MX")
        return f.string(from: value as NSNumber) ?? "\(value)"
    }

    @ViewBuilder
    private var mandateSection: some View {
        if movement.mandateId != nil {
            Section(L10n.MoneyMovementDetail.mandateSection) {
                if let mandate = resolvedMandate {
                    LabeledContent {
                        Text(mandate.type.label)
                    } label: {
                        Text(L10n.MoneyMovementDetail.mandateType)
                    }
                    if let principal = principalDescription(for: mandate) {
                        LabeledContent {
                            Text(principal)
                        } label: {
                            Text(L10n.MoneyMovementDetail.mandateOnBehalfOf)
                        }
                    }
                    if let endsAt = mandate.endsAt {
                        LabeledContent {
                            Text(endsAt, format: .dateTime.day().month().year())
                        } label: {
                            Text(L10n.MoneyMovementDetail.mandateEndsAt)
                        }
                    }
                } else if let mandateId = movement.mandateId {
                    LabeledContent {
                        Text(mandateId.uuidString.prefix(8) + "…")
                            .monospaced()
                            .font(.subheadline)
                    } label: {
                        Text(L10n.MoneyMovementDetail.mandateRowLabel)
                    }
                    Text(L10n.MoneyMovementDetail.mandateInactiveHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Renders "Por el grupo" / "Por un comité" / "Por <miembro>".
    /// `principal_id` resolution against group members is a future
    /// slice — Foundation MandatesStore doesn't pre-join the name yet.
    private func principalDescription(for mandate: GroupMandate) -> String? {
        String(localized: mandate.principalType.label)
    }

    @ViewBuilder
    private var metaSection: some View {
        Section(L10n.MoneyMovementDetail.metaSection) {
            if let description = movement.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                LabeledContent {
                    Text(description)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(6)
                } label: {
                    Text(L10n.MoneyMovementDetail.descriptionLabel)
                }
            }
            if let source = movement.sourceEntityKind {
                LabeledContent {
                    Text(source.capitalized)
                } label: {
                    Text(L10n.MoneyMovementDetail.sourceLabel)
                }
            }
            if let split = movement.splitMode {
                LabeledContent {
                    Text(split.capitalized)
                } label: {
                    Text(L10n.MoneyMovementDetail.splitModeLabel)
                }
            }
            if movement.inKind {
                LabeledContent {
                    Text(L10n.MoneyMovementDetail.inKindLabel)
                } label: {
                    Text(L10n.MoneyMovementDetail.typeLabel)
                }
            }
            if let occurred = movement.occurredAt {
                LabeledContent {
                    Text(occurred, format: .dateTime.day().month().year().hour().minute())
                } label: {
                    Text(L10n.MoneyMovementDetail.occurredAtLabel)
                }
            }
            if let created = movement.createdAt, created != movement.occurredAt {
                LabeledContent {
                    Text(created, format: .dateTime.day().month().year().hour().minute())
                } label: {
                    Text(L10n.MoneyMovementDetail.recordedAtLabel)
                }
            }
        }
    }
}
