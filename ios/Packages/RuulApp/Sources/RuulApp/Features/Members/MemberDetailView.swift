import SwiftUI
import RuulCore

/// Detail surface for a single member inside a group (Primitiva 1 +
/// 11 + 12 + 17 + 18 surfaces). Read-only Foundation slice — replaces
/// the direct push to `MemberHistoryView` from the boundary list.
///
/// Pattern: Contacts.app card scroll — a centred identity hero on top
/// followed by a stack of `Section`s. Sections collapse to invisible
/// when they have no data (per `doctrine_group_space_situational`).
///
/// Stores consumed:
/// - `sanctionsStore`   — group-wide list, filtered locally by
///   `targetMembershipId == memberItem.membershipId`.
/// - `reputationStore`  — events for THIS subject only; loaded on
///   `.task` via `refreshIfNeeded`.
/// - `moneyStore`       — only used when the member IS the caller
///   (the RPCs are keyed to the caller's own membership).
public struct MemberDetailView: View {
    @Bindable var sanctionsStore: SanctionsStore
    @Bindable var reputationStore: ReputationStore
    @Bindable var moneyStore: MoneyStore
    let groupId: UUID
    let memberItem: MembershipBoundaryItem

    /// How many recent history rows to render inline before linking out
    /// to the full `MemberHistoryView`.
    private let recentHistoryLimit = 5

    public init(
        sanctionsStore: SanctionsStore,
        reputationStore: ReputationStore,
        moneyStore: MoneyStore,
        groupId: UUID,
        memberItem: MembershipBoundaryItem
    ) {
        self.sanctionsStore = sanctionsStore
        self.reputationStore = reputationStore
        self.moneyStore = moneyStore
        self.groupId = groupId
        self.memberItem = memberItem
    }

    public var body: some View {
        List {
            identitySection
            rolesSection
            sanctionsSection
            if memberItem.isCurrentUser {
                moneySection
            }
            historySection
        }
        .navigationTitle(L10n.MemberDetail.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: MemberFullHistoryDestination.self) { _ in
            MemberHistoryView(
                store: reputationStore,
                groupId: groupId,
                memberItem: memberItem
            )
        }
        .task {
            if let mid = memberItem.membershipId {
                await reputationStore.refreshIfNeeded(
                    groupId: groupId,
                    subjectMembershipId: mid,
                    limit: 50
                )
            }
            await sanctionsStore.refreshIfNeeded(groupId: groupId)
        }
        .refreshable {
            if let mid = memberItem.membershipId {
                await reputationStore.refresh(
                    groupId: groupId,
                    subjectMembershipId: mid,
                    limit: 50
                )
            }
            await sanctionsStore.refresh(groupId: groupId)
        }
    }

    // MARK: - Identity

    @ViewBuilder
    private var identitySection: some View {
        Section {
            VStack(spacing: 12) {
                MemberAvatarView(item: memberItem)
                    .frame(width: 96, height: 96)

                VStack(spacing: 4) {
                    Text(memberItem.displayName)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if let username = memberItem.username, !username.isEmpty {
                        Text("@\(username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if memberItem.status != .active {
                    MembershipStatusBadge(status: memberItem.status)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            LabeledContent {
                Text(memberItem.membershipType.label)
            } label: {
                Text(L10n.MemberDetail.memberTypeLabel)
            }

            if let joined = memberItem.joinedAt {
                LabeledContent {
                    Text(joined, format: .dateTime.day().month().year())
                } label: {
                    Text(L10n.MemberDetail.joinedAtLabel)
                }
            }
        }
    }

    // MARK: - Roles

    @ViewBuilder
    private var rolesSection: some View {
        Section(L10n.MemberDetail.rolesSection) {
            if memberItem.roleNames.isEmpty {
                Text(L10n.MemberDetail.rolesEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(memberItem.roleNames, id: \.self) { roleName in
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.rectangle.badge.checkmark")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text(roleName)
                            .font(.body)
                    }
                }
            }
        }
    }

    // MARK: - Sanciones (filtered to this member)

    @ViewBuilder
    private var sanctionsSection: some View {
        let mine = filteredSanctions
        // Hide entirely when there are none AND the store has finished
        // loading without an error — empty cluster = invisible.
        if !mine.isEmpty {
            Section(L10n.MemberDetail.sanctionsSection) {
                ForEach(mine) { sanction in
                    SanctionRowView(sanction: sanction)
                }
            }
        }
    }

    private var filteredSanctions: [GroupSanction] {
        guard let mid = memberItem.membershipId else { return [] }
        return sanctionsStore.sanctions.filter { $0.targetMembershipId == mid }
    }

    // MARK: - Money (self only)

    @ViewBuilder
    private var moneySection: some View {
        Section(L10n.MemberDetail.moneySection) {
            if let balance = moneyStore.balance {
                LabeledContent {
                    Text("\(balance.formatted()) MXN")
                        .monospacedDigit()
                } label: {
                    Text(L10n.MemberDetail.moneyBalanceLabel)
                }
            }

            LabeledContent {
                Text("\(moneyStore.obligations.count)")
                    .monospacedDigit()
            } label: {
                Text(L10n.MemberDetail.moneyObligationsLabel)
            }

            if moneyStore.obligations.isEmpty, moneyStore.balance == nil {
                Text(L10n.MemberDetail.moneyEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - History (inline preview + see-all link)

    @ViewBuilder
    private var historySection: some View {
        Section(L10n.MemberDetail.historySection) {
            switch reputationStore.phase {
            case .idle, .loading:
                ForEach(0..<3, id: \.self) { _ in
                    placeholderHistoryRow
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.Reputation.errorTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(String(localized: L10n.Reputation.retry)) {
                        Task {
                            if let mid = memberItem.membershipId {
                                await reputationStore.refresh(
                                    groupId: groupId,
                                    subjectMembershipId: mid
                                )
                            }
                        }
                    }
                    .font(.footnote)
                }
            case .loaded:
                if reputationStore.events.isEmpty {
                    Text(L10n.MemberDetail.historyEmpty)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(reputationStore.events.prefix(recentHistoryLimit)) { event in
                        historyRow(for: event)
                    }
                    if reputationStore.events.count > recentHistoryLimit {
                        NavigationLink(value: MemberFullHistoryDestination()) {
                            Text(L10n.MemberDetail.viewFullHistory)
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(for event: GroupReputationEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.kind.label)
                    .font(.body.weight(.semibold))
                if let reason = event.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let when = event.when {
                    Text(when, format: .dateTime.day().month().year())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var placeholderHistoryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle").frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Placeholder kind").font(.body.weight(.semibold))
                Text("Placeholder reason that takes some width.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .redacted(reason: .placeholder)
    }

    /// Hashable token so the inline "Ver historial completo" row can
    /// push the dedicated `MemberHistoryView` via the destination
    /// declared on this view's NavigationStack ancestor.
    private struct MemberFullHistoryDestination: Hashable {}
}

