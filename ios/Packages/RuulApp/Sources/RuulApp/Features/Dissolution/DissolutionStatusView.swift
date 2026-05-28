import SwiftUI
import RuulCore

/// Primitiva 25 surface. Two states:
/// - **No active dissolution**: explainer + destructive CTA that opens
///   `ProposeDissolutionSheet` (which fires `propose_dissolution(...)`
///   and auto-creates the linked supermajority vote).
/// - **Active dissolution**: banner with status + proposer + reason +
///   linked decision + pending obligations gate, plus a Finalize CTA
///   when the linked vote has passed and obligations are clear.
///
/// Reached from `GroupSettingsView` > Zona destructiva > Cerrar grupo.
public struct DissolutionStatusView: View {
    @Bindable var store: DissolutionStore
    let groupId: UUID

    public init(store: DissolutionStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            switch store.phase {
            case .idle, .loading:
                placeholderSection
            case .failed(let message):
                errorSection(message: message)
            case .loaded:
                if let active = store.active {
                    activeContent(active)
                } else {
                    emptyContent
                }
            }
        }
        .navigationTitle(L10n.Dissolution.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .sheet(isPresented: $store.isProposePresented) {
            ProposeDissolutionSheet(store: store, groupId: groupId)
        }
        .confirmationDialog(
            Text(L10n.Dissolution.finalizeConfirmTitle),
            isPresented: $store.isFinalizeConfirmPresented,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { _ = await store.finalize(groupId: groupId) }
            } label: {
                Text(L10n.Dissolution.finalizeAction)
            }
            Button(role: .cancel) {} label: { Text(L10n.Dissolution.cancel) }
        } message: {
            Text(L10n.Dissolution.finalizeConfirmMessage)
        }
        .task {
            await store.refresh(groupId: groupId)
        }
    }

    // MARK: - Empty state (no active dissolution)

    @ViewBuilder
    private var emptyContent: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Dissolution.headline)
                    .font(.headline)
                Text(L10n.Dissolution.intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        Section {
            Text(L10n.Dissolution.processHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Dissolution.emptyTitle).font(.body.weight(.semibold))
                Text(L10n.Dissolution.emptyDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button(role: .destructive) {
                store.beginProposing()
            } label: {
                Label(L10n.Dissolution.proposeButton, systemImage: "xmark.octagon")
            }
        }
    }

    // MARK: - Active dissolution

    @ViewBuilder
    private func activeContent(_ active: GroupDissolution) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label(L10n.Dissolution.activeBannerTitle, systemImage: "exclamationmark.octagon")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                    statusBadge(for: active.status)
                }
                if let name = active.initiatedByDisplayName, !name.isEmpty {
                    Text("\(String(localized: L10n.Dissolution.proposedByLabel)) \(name)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let proposedAt = active.proposedAt {
                    Text("\(String(localized: L10n.Dissolution.proposedAtLabel)) \(proposedAt.formatted(.dateTime.day().month().year()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let approvedAt = active.approvedAt {
                    Text("\(String(localized: L10n.Dissolution.approvedAtLabel)) \(approvedAt.formatted(.dateTime.day().month().year()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }

        if let reason = active.reason, !reason.isEmpty {
            Section(L10n.Dissolution.reasonLabel) {
                Text(reason)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }

        if active.sourceDecisionId != nil {
            Section(L10n.Dissolution.linkedDecisionLabel) {
                Label(L10n.Decisions.menuLink, systemImage: "checkmark.seal")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }

        Section(L10n.Dissolution.openObligationsTitle) {
            if active.openObligationsCount == 0 {
                Label(L10n.Dissolution.openObligationsZero, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Label {
                    Text("\(active.openObligationsCount) obligaciones aún abiertas")
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text(L10n.Dissolution.openObligationsCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if store.canFinalize {
            Section {
                Button(role: .destructive) {
                    store.isFinalizeConfirmPresented = true
                } label: {
                    Label(L10n.Dissolution.finalizeButton, systemImage: "xmark.octagon.fill")
                }
            }
        }
    }

    // MARK: - Phase helpers

    @ViewBuilder
    private var placeholderSection: some View {
        Section {
            HStack {
                ProgressView()
                Text("Cargando…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func errorSection(message: String) -> some View {
        Section {
            ContentUnavailableView {
                Label(L10n.Dissolution.errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: L10n.Dissolution.retry)) {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for status: DissolutionStatus) -> some View {
        let tint: Color = {
            switch status {
            case .proposed:    return .orange
            case .approved:    return .blue
            case .liquidating: return .yellow
            case .executed:    return .red
            case .cancelled:   return .gray
            }
        }()
        Text(status.label)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}
