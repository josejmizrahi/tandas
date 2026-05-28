import SwiftUI
import RuulCore

/// Detail surface for a single `GroupSanction` (Primitiva 11). Read +
/// act surface: shows full info + two context-aware actions — Pagar
/// (monetaria, dirigida a mí, obligation abierta) y, según quien mire,
/// **Apelar** (yo soy el sancionado) o **Disputar** (soy tercero).
/// Ambas abren `DisputeSanctionSheet`; el path de escalada a voto
/// vive dentro de la disputa resultante (`EscalateDisputeSheet`).
///
/// Closed sanctions (completed/reversed/cancelled) muestran un hint
/// neutro y ocultan las acciones — la fila sigue navegable para que el
/// historial tenga superficie consultable.
public struct SanctionDetailView: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID
    let sanction: GroupSanction

    @State private var pendingPaySanction: GroupSanction?

    public init(
        container: DependencyContainer,
        groupId: UUID,
        myMembershipId: UUID,
        sanction: GroupSanction
    ) {
        self.container = container
        self.groupId = groupId
        self.myMembershipId = myMembershipId
        self.sanction = sanction
    }

    public var body: some View {
        @Bindable var disputesStore = container.disputesStore
        return List {
            heroSection
            infoSection
            actionsSection
        }
        .navigationTitle(L10n.SanctionDetail.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pendingPaySanction) { sanction in
            PaySanctionSheet(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId,
                sanction: sanction
            ) {
                pendingPaySanction = nil
                Task {
                    await container.moneyStore.refresh(groupId: groupId, membershipId: myMembershipId)
                    await container.sanctionsStore.refresh(groupId: groupId)
                }
            }
        }
        .sheet(isPresented: $disputesStore.isDisputeSanctionPresented) {
            DisputeSanctionSheet(store: disputesStore, groupId: groupId)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: sanction.kind.systemImageName)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(sanction.isDisputed ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                    .frame(width: 80, height: 80)
                    .background(.thinMaterial, in: Circle())

                VStack(spacing: 4) {
                    Text(sanction.kind.label)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(sanction.status.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(sanction.isDisputed
                                            ? Color.orange.opacity(0.18)
                                            : Color.gray.opacity(0.12))
                        )
                        .foregroundStyle(sanction.isDisputed
                                          ? AnyShapeStyle(.orange)
                                          : AnyShapeStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Info

    @ViewBuilder
    private var infoSection: some View {
        Section(L10n.SanctionDetail.infoSection) {
            LabeledContent {
                Text(sanction.targetDisplayName)
            } label: {
                Text(L10n.SanctionDetail.targetLabel)
            }
            if let issuer = sanction.issuedByDisplayName {
                LabeledContent {
                    Text(issuer)
                } label: {
                    Text(L10n.SanctionDetail.issuerLabel)
                }
            }
            LabeledContent {
                Text(sanction.reason)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(6)
            } label: {
                Text(L10n.SanctionDetail.reasonLabel)
            }
            if sanction.isMonetary, let amount = sanction.amount, let unit = sanction.unit {
                LabeledContent {
                    Text("\(amount.formatted()) \(unit)")
                        .monospacedDigit()
                } label: {
                    Text(L10n.SanctionDetail.amountLabel)
                }
            }
            if let starts = sanction.startsAt {
                LabeledContent {
                    Text(starts, format: .dateTime.day().month().year())
                } label: {
                    Text(L10n.SanctionDetail.startsAtLabel)
                }
            }
            if let ends = sanction.endsAt {
                LabeledContent {
                    Text(ends, format: .dateTime.day().month().year())
                } label: {
                    Text(L10n.SanctionDetail.endsAtLabel)
                }
            }
            if let created = sanction.createdAt {
                LabeledContent {
                    Text(created, format: .dateTime.day().month().year())
                } label: {
                    Text(L10n.SanctionDetail.createdAtLabel)
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section(L10n.SanctionDetail.actionsSection) {
            if sanction.status.isOpen {
                if canPay {
                    Button {
                        pendingPaySanction = sanction
                    } label: {
                        Label(L10n.SanctionDetail.payAction, systemImage: "creditcard")
                    }
                } else if sanction.isMonetary, sanction.targetMembershipId == myMembershipId {
                    Text(L10n.SanctionDetail.paidHint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if sanction.status != .disputed {
                    Button {
                        container.disputesStore.beginDisputingSanction(sanction.id)
                    } label: {
                        if isTarget {
                            Label(L10n.SanctionDetail.appealAction, systemImage: "checkmark.seal")
                        } else {
                            Label(L10n.SanctionDetail.disputeAction, systemImage: "scale.3d")
                        }
                    }
                }
            } else {
                Text(L10n.SanctionDetail.closedHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isTarget: Bool {
        sanction.targetMembershipId == myMembershipId
    }

    /// Pay shows only when the sanction is monetary, targets me, AND
    /// the linked `group_obligations` row is still in my open list.
    /// Mirrors the cluster filter on `MoneyDashboardView` so the two
    /// surfaces agree.
    private var canPay: Bool {
        guard sanction.isMonetary,
              sanction.targetMembershipId == myMembershipId,
              sanction.status.isOpen
        else { return false }
        guard let oid = sanction.obligationId else { return true }
        return container.moneyStore.obligations.contains { $0.id == oid }
    }
}
