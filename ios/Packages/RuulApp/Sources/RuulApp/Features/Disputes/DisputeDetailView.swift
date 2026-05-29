import SwiftUI
import RuulCore

/// Universal detail surface for one dispute. Apple Mail thread feel:
/// hero (title + parties + status) on top, optional description, then
/// the append-only timeline; resolution + escalated decision render
/// when present. Actions section gates by status.
public struct DisputeDetailView: View {
    @Bindable var store: DisputesStore
    let groupId: UUID
    let dispute: GroupDispute
    /// V3 Batch B-4 — cuando se cablea, el subject label (cuando
    /// subjectKind == .sanction y hay subjectId) se vuelve un botón
    /// que invoca este callback con el sanction_id. Caller resuelve
    /// el GroupSanction y empuja SanctionDetailView. Default no-op
    /// para previews y standalone.
    let onSelectSanction: ((UUID) -> Void)?

    public init(
        store: DisputesStore,
        groupId: UUID,
        dispute: GroupDispute,
        onSelectSanction: ((UUID) -> Void)? = nil
    ) {
        self.store = store
        self.groupId = groupId
        self.dispute = dispute
        self.onSelectSanction = onSelectSanction
    }

    public var body: some View {
        List {
            heroSection
            descriptionSection
            timelineSection
            resolutionSection
            escalatedDecisionSection
            actionsSection
        }
        .navigationTitle(dispute.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: dispute.id) {
            await store.loadDetail(disputeId: dispute.id)
        }
        .refreshable {
            await store.refreshDetail()
        }
        .sheet(isPresented: $store.isAppendEventPresented) {
            AddDisputeEventSheet(store: store)
        }
        .sheet(isPresented: $store.isResolvePresented) {
            ResolveDisputeView(store: store, groupId: groupId)
        }
        .sheet(isPresented: $store.isEscalatePresented) {
            EscalateDisputeSheet(store: store, groupId: groupId)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(dispute.title)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    statusBadge(for: status)
                }
                subjectRow
                if let opener = openerName, !opener.isEmpty {
                    Text("\(String(localized: L10n.Disputes.openedByLabel)) \(opener)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let respondent = respondentName, !respondent.isEmpty {
                    Text("\(String(localized: L10n.Disputes.respondentLabel)) \(respondent)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let mediator = mediatorName, !mediator.isEmpty {
                    Text("\(String(localized: L10n.Disputes.mediatorLabel)) \(mediator)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let when = openedAt {
                    Text("\(String(localized: L10n.Disputes.openedAtLabel)) \(when.formatted(.dateTime.day().month().year().hour().minute()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        let body = store.detail?.description ?? dispute.description
        Section(L10n.Disputes.descriptionSection) {
            if let body, !body.isEmpty {
                Text(body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 2)
            } else {
                Text(L10n.Disputes.descriptionEmpty)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var timelineSection: some View {
        Section(L10n.Disputes.timelineSection) {
            switch store.detailPhase {
            case .idle, .loading:
                if store.events.isEmpty {
                    HStack {
                        ProgressView()
                        Text(L10n.Disputes.detailLoading)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    timelineRows
                }
            case .failed(let message):
                Label {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            case .loaded:
                if store.events.isEmpty {
                    Text(L10n.Disputes.timelineEmpty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    timelineRows
                }
            }
        }
    }

    @ViewBuilder
    private var timelineRows: some View {
        ForEach(store.events) { event in
            TimelineRow(event: event)
        }
    }

    @ViewBuilder
    private var resolutionSection: some View {
        if let detail = store.detail, let resolution = detail.resolution, !resolution.isEmpty {
            Section(L10n.Disputes.resolutionSection) {
                if let method = detail.resolutionMethod {
                    HStack {
                        Label(method.label, systemImage: "checkmark.seal")
                            .font(.callout.weight(.medium))
                        Spacer()
                        if let when = detail.resolvedAt {
                            Text(when.formatted(.dateTime.day().month().year()))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(resolution)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var escalatedDecisionSection: some View {
        if let detail = store.detail, detail.escalatedDecisionId != nil {
            Section(L10n.Disputes.escalatedDecisionLabel) {
                Label("Voto vinculado", systemImage: "arrow.up.forward.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if status.isOpen {
            Section(L10n.Disputes.detailActionsSection) {
                Button {
                    store.beginAppendingEvent(disputeId: dispute.id, defaultType: .comment)
                } label: {
                    Label(L10n.Disputes.appendEventButton, systemImage: "text.bubble")
                }
                Button {
                    store.beginEscalating(disputeId: dispute.id, suggestedTitle: dispute.title)
                } label: {
                    Label(L10n.Disputes.escalateButton, systemImage: "arrow.up.forward.circle")
                }
                Button {
                    store.beginResolving(disputeId: dispute.id)
                } label: {
                    Label(L10n.Disputes.resolveButton, systemImage: "checkmark.seal")
                }
            }
        }
    }

    /// V3 Batch B-4 — subject del dispute como link a la entidad cuando
    /// es navegable. Hoy solo cableamos `.sanction` (el caso más común
    /// per uso real). Otros kinds (.rule/.resource/.member/.other)
    /// quedan como label estático hasta que el slice respectivo
    /// aterrice.
    @ViewBuilder
    private var subjectRow: some View {
        let kind = subjectKind
        let subjectId = store.detail?.subjectId ?? dispute.subjectId
        if kind == .sanction, let sid = subjectId, let cb = onSelectSanction {
            Button {
                cb(sid)
            } label: {
                HStack(spacing: 4) {
                    Label(kind.label, systemImage: kind.systemImageName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } else {
            Label(kind.label, systemImage: kind.systemImageName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived

    private var status: DisputeStatus { store.detail?.status ?? dispute.status }
    private var subjectKind: DisputeSubjectKind { store.detail?.subjectKind ?? dispute.subjectKind }
    private var openerName: String? { store.detail?.openedByDisplayName ?? dispute.openedByDisplayName }
    private var respondentName: String? { store.detail?.respondentDisplayName ?? dispute.respondentDisplayName }
    private var mediatorName: String? { store.detail?.mediatorDisplayName ?? dispute.mediatorDisplayName }
    private var openedAt: Date? { store.detail?.openedAt ?? dispute.openedAt }

    @ViewBuilder
    private func statusBadge(for status: DisputeStatus) -> some View {
        let tint: Color = {
            switch status {
            case .open:       return .blue
            case .inReview:   return .indigo
            case .mediation:  return .teal
            case .escalated:  return .orange
            case .resolved:   return .green
            case .dismissed:  return .gray
            case .closed:     return .gray
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

private struct TimelineRow: View {
    let event: GroupDisputeEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(event.eventType.label, systemImage: event.eventType.systemImageName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let when = event.createdAt {
                    Text(when.formatted(.dateTime.day().month().hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let actor = event.actorDisplayName, !actor.isEmpty {
                Text(actor)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if let body = event.body, !body.isEmpty {
                Text(body)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 2)
    }
}
