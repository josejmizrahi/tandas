import SwiftUI
import RuulCore

/// Read-only **identity** surface for a group. Mirrors Apple Contacts /
/// Instagram profile patterns: header card on top, then declared
/// sections (purpose, rules, decision rules, members, future culture +
/// rituals). Edit affordances jump out to existing edit sheets/lists
/// — this view never owns mutation.
///
/// Consumes stores already in the container; no new RPCs. Foundation
/// status appears at the top only when the group is not yet ready.
public struct GroupProfileView: View {
    let container: DependencyContainer
    let group: GroupListItem

    public init(container: DependencyContainer, group: GroupListItem) {
        self.container = container
        self.group = group
    }

    public var body: some View {
        List {
            headerSection
            foundationHintSection
            purposeSection
            rulesSection
            decisionRulesSection
            membersSection
            culturePlaceholderSection
            ritualsPlaceholderSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.GroupProfile.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .sheet(isPresented: purposeSheetBinding) {
            EditPurposeView(store: container.purposeStore, groupId: group.id)
        }
        .sheet(isPresented: decisionRulesSheetBinding) {
            EditDecisionRulesView(store: container.decisionRulesStore, groupId: group.id)
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        await container.purposeStore.refreshIfNeeded(groupId: group.id)
        await container.rulesStore.refreshIfNeeded(groupId: group.id)
        await container.decisionRulesStore.refreshIfNeeded(groupId: group.id)
        await container.membersStore.refreshIfNeeded(groupId: group.id)
        await container.foundationStatusStore.refresh(groupId: group.id)
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        Section {
            VStack(alignment: .center, spacing: 12) {
                avatarHero
                VStack(spacing: 2) {
                    Text(group.name)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if let category = group.category, !category.isEmpty {
                        Text(category)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let summary = group.purposeSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    @ViewBuilder
    private var avatarHero: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
                .frame(width: 96, height: 96)
            Text(initials)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var initials: String {
        let parts = group.name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "?" }
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        let joined = letters.joined()
        return joined.isEmpty ? "?" : joined.uppercased()
    }

    @ViewBuilder
    private var foundationHintSection: some View {
        if let status = container.foundationStatusStore.status, !status.isReady {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.Foundation.notReadySummary)
                            .font(.subheadline.weight(.semibold))
                        Text("\(container.foundationStatusStore.completeCount)/5 listos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var purposeSection: some View {
        Section {
            let hasAny = container.purposeStore.hasAnyPurpose
            if hasAny {
                ForEach(GroupPurposeKind.displayOrder, id: \.self) { kind in
                    if let purpose = container.purposeStore.purpose(for: kind),
                       !purpose.trimmedBody.isEmpty {
                        purposeRow(kind: kind, body: purpose.trimmedBody)
                    }
                }
            } else {
                Text(L10n.GroupProfile.noPurpose)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        } header: {
            sectionHeader(L10n.GroupProfile.purposeSection) {
                container.purposeStore.beginEditing(kind: .declared)
            }
        }
    }

    @ViewBuilder
    private func purposeRow(kind: GroupPurposeKind, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(body)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            if container.rulesStore.hasRules {
                ForEach(container.rulesStore.topRules) { rule in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: rule.ruleType.systemImageName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(rule.isHighSeverity ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !rule.body.isEmpty {
                                Text(rule.previewText)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if container.rulesStore.rules.count > container.rulesStore.topRules.count {
                    Text("+\(container.rulesStore.rules.count - container.rulesStore.topRules.count) más")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.GroupProfile.noRules)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        } header: {
            sectionHeader(L10n.GroupProfile.rulesSection) {
                container.rulesStore.beginCreating()
            }
        }
    }

    @ViewBuilder
    private var decisionRulesSection: some View {
        Section {
            if let dr = container.decisionRulesStore.rules {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: dr.defaultMethod.systemImageName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dr.defaultMethod.label)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(dr.defaultMethod.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: dr.defaultLegitimacySource.systemImageName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dr.defaultLegitimacySource.label)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(dr.defaultLegitimacySource.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let q = dr.quorumMin {
                        Text("Quórum mínimo: \(q)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text("Aún no configurado.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        } header: {
            sectionHeader(L10n.GroupProfile.decisionsSection) {
                container.decisionRulesStore.beginEditing()
            }
        }
    }

    @ViewBuilder
    private var membersSection: some View {
        Section {
            let items = container.membersStore.items
            if items.isEmpty {
                Text("Aún no hay miembros activos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                HStack(spacing: -8) {
                    ForEach(Array(items.prefix(5))) { item in
                        MemberAvatarView(item: item)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                    }
                    Spacer()
                    Text(String(format: String(localized: L10n.GroupProfile.memberCount), items.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(L10n.GroupProfile.membersSection)
        }
    }

    @ViewBuilder
    private var culturePlaceholderSection: some View {
        Section {
            placeholderRow(systemImage: "sparkles",
                           label: L10n.GroupProfile.cultureSoon)
        } header: {
            Text(L10n.GroupProfile.cultureSection)
        }
    }

    @ViewBuilder
    private var ritualsPlaceholderSection: some View {
        Section {
            placeholderRow(systemImage: "calendar",
                           label: L10n.GroupProfile.ritualsSoon)
        } header: {
            Text(L10n.GroupProfile.ritualsSection)
        }
    }

    @ViewBuilder
    private func placeholderRow(systemImage: String, label: LocalizedStringResource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Section header helper

    @ViewBuilder
    private func sectionHeader(_ title: LocalizedStringResource,
                               onEdit: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                onEdit()
            } label: {
                Text(L10n.GroupProfile.editButton)
                    .font(.caption.weight(.semibold))
            }
            .textCase(nil)
        }
    }

    // MARK: - Sheet bindings (shared stores)

    private var purposeSheetBinding: Binding<Bool> {
        Binding(
            get: { container.purposeStore.isEditPresented },
            set: { container.purposeStore.isEditPresented = $0 }
        )
    }

    private var decisionRulesSheetBinding: Binding<Bool> {
        Binding(
            get: { container.decisionRulesStore.isEditPresented },
            set: { container.decisionRulesStore.isEditPresented = $0 }
        )
    }
}
