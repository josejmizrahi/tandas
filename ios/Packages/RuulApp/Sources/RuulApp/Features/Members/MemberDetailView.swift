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
/// - `rolesStore`       — drives the Edit Roles sheet (Primitiva 17).
/// - `membersStore`     — refreshed after assign/revoke so the inline
///   role list reflects the new server state without a parent rebuild.
public struct MemberDetailView: View {
    @Bindable var sanctionsStore: SanctionsStore
    @Bindable var reputationStore: ReputationStore
    @Bindable var moneyStore: MoneyStore
    @Bindable var rolesStore: RolesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID
    let memberItem: MembershipBoundaryItem

    @State private var isManagingRoles: Bool = false

    /// How many recent history rows to render inline before linking out
    /// to the full `MemberHistoryView`.
    private let recentHistoryLimit = 5

    public init(
        sanctionsStore: SanctionsStore,
        reputationStore: ReputationStore,
        moneyStore: MoneyStore,
        rolesStore: RolesStore,
        membersStore: MembersStore,
        groupId: UUID,
        memberItem: MembershipBoundaryItem
    ) {
        self.sanctionsStore = sanctionsStore
        self.reputationStore = reputationStore
        self.moneyStore = moneyStore
        self.rolesStore = rolesStore
        self.membersStore = membersStore
        self.groupId = groupId
        self.memberItem = memberItem
    }

    /// Live projection of the member — picks up the latest snapshot
    /// from `membersStore` (refreshed after assign/revoke) and falls
    /// back to the originally-passed item.
    private var displayedItem: MembershipBoundaryItem {
        membersStore.items.first(where: { $0.id == memberItem.id }) ?? memberItem
    }

    public var body: some View {
        let item = displayedItem
        return List {
            identitySection(item: item)
            rolesSection(item: item)
            sanctionsSection(item: item)
            if item.isCurrentUser {
                moneySection
            }
            historySection(item: item)
        }
        .navigationTitle(L10n.MemberDetail.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: MemberFullHistoryDestination.self) { _ in
            MemberHistoryView(
                store: reputationStore,
                groupId: groupId,
                memberItem: item
            )
        }
        .sheet(isPresented: $isManagingRoles) {
            ManageMemberRolesSheet(
                rolesStore: rolesStore,
                membersStore: membersStore,
                groupId: groupId,
                memberItem: item
            )
        }
        .task {
            if let mid = item.membershipId {
                await reputationStore.refreshIfNeeded(
                    groupId: groupId,
                    subjectMembershipId: mid,
                    limit: 50
                )
            }
            await sanctionsStore.refreshIfNeeded(groupId: groupId)
            await rolesStore.refreshIfNeeded(groupId: groupId)
        }
        .refreshable {
            if let mid = item.membershipId {
                await reputationStore.refresh(
                    groupId: groupId,
                    subjectMembershipId: mid,
                    limit: 50
                )
            }
            await sanctionsStore.refresh(groupId: groupId)
            await rolesStore.refresh(groupId: groupId)
        }
    }

    // MARK: - Identity

    @ViewBuilder
    private func identitySection(item: MembershipBoundaryItem) -> some View {
        Section {
            VStack(spacing: 12) {
                MemberAvatarView(item: item)
                    .frame(width: 96, height: 96)

                VStack(spacing: 4) {
                    Text(item.displayName)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if let username = item.username, !username.isEmpty {
                        Text("@\(username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if item.status != .active {
                    MembershipStatusBadge(status: item.status)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            LabeledContent {
                Text(item.membershipType.label)
            } label: {
                Text(L10n.MemberDetail.memberTypeLabel)
            }

            if let joined = item.joinedAt {
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
    private func rolesSection(item: MembershipBoundaryItem) -> some View {
        // Manage button is only meaningful for real memberships; pending
        // invites have no membership id to target. Backend gates the
        // mutation by `roles.manage` — we surface its error if denied.
        Section(L10n.MemberDetail.rolesSection) {
            if item.roleNames.isEmpty {
                Text(L10n.MemberDetail.rolesEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(item.roleNames, id: \.self) { roleName in
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.rectangle.badge.checkmark")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text(roleName)
                            .font(.body)
                    }
                }
            }
            if item.membershipId != nil {
                Button {
                    isManagingRoles = true
                } label: {
                    Label(L10n.MemberDetail.manageRolesButton, systemImage: "pencil")
                }
            }
        }
    }

    // MARK: - Sanciones (filtered to this member)

    @ViewBuilder
    private func sanctionsSection(item: MembershipBoundaryItem) -> some View {
        let mine = filteredSanctions(for: item)
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

    private func filteredSanctions(for item: MembershipBoundaryItem) -> [GroupSanction] {
        guard let mid = item.membershipId else { return [] }
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
    private func historySection(item: MembershipBoundaryItem) -> some View {
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
                            if let mid = item.membershipId {
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

// MARK: - Manage Roles Sheet

/// Quick-action sheet for assigning / revoking roles on a single
/// membership (Primitiva 17 / B3). Backend gates by `roles.manage`;
/// the error is surfaced inline. "Remove last role" raises a backend
/// error too — same path.
private struct ManageMemberRolesSheet: View {
    @Bindable var rolesStore: RolesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID
    let memberItem: MembershipBoundaryItem

    @Environment(\.dismiss) private var dismiss
    @State private var pendingRoleId: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                switch rolesStore.phase {
                case .idle, .loading:
                    ForEach(0..<3, id: \.self) { _ in
                        placeholderRow
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label(L10n.Roles.errorTitle, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button(String(localized: L10n.Roles.retry)) {
                            Task { await rolesStore.refresh(groupId: groupId) }
                        }
                    }
                    .listRowBackground(Color.clear)
                case .loaded:
                    if rolesStore.roles.isEmpty {
                        Text(L10n.MemberDetail.manageRolesEmpty)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    } else {
                        if !rolesStore.systemRoles.isEmpty {
                            Section(L10n.Roles.systemSection) {
                                ForEach(rolesStore.systemRoles) { role in
                                    row(for: role)
                                }
                            }
                        }
                        if !rolesStore.customRoles.isEmpty {
                            Section(L10n.Roles.customSection) {
                                ForEach(rolesStore.customRoles) { role in
                                    row(for: role)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.MemberDetail.manageRolesTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.MemberDetail.manageRolesDone)) {
                        dismiss()
                    }
                }
            }
            .alert(
                String(localized: L10n.MemberDetail.manageRolesErrorTitle),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                ),
                actions: { Button("OK") { errorMessage = nil } },
                message: { Text(errorMessage ?? "") }
            )
            .task {
                await rolesStore.refreshIfNeeded(groupId: groupId)
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(for role: GroupRole) -> some View {
        let isAssigned = assignedRoleNames.contains(role.name)
        let isPending = pendingRoleId == role.id
        Button {
            toggle(role: role, isAssigned: isAssigned)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let description = role.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                } else if isAssigned {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pendingRoleId != nil)
    }

    @ViewBuilder
    private var placeholderRow: some View {
        HStack {
            Text("Placeholder role").font(.body.weight(.semibold))
            Spacer()
            Image(systemName: "circle")
        }
        .redacted(reason: .placeholder)
    }

    private var assignedRoleNames: Set<String> {
        let live = membersStore.items.first(where: { $0.id == memberItem.id }) ?? memberItem
        return Set(live.roleNames)
    }

    private func toggle(role: GroupRole, isAssigned: Bool) {
        guard let mid = memberItem.membershipId, pendingRoleId == nil else { return }
        pendingRoleId = role.id
        Task {
            defer { pendingRoleId = nil }
            do {
                if isAssigned {
                    try await rolesStore.revokeRole(membershipId: mid, roleId: role.id)
                } else {
                    try await rolesStore.assignRole(membershipId: mid, roleId: role.id)
                }
                await membersStore.refresh(groupId: groupId)
                await rolesStore.refresh(groupId: groupId)
            } catch {
                errorMessage = UserFacingError.from(error).message
            }
        }
    }
}
