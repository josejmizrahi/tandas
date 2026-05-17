import SwiftUI
import RuulUI
import RuulCore

/// Host's grace-period dashboard. Lists all proposed fines for an event
/// with quick actions: oficializar (skip the 24h wait) or anular (void).
/// If the host does nothing, finalize-fine-reviews cron officializes
/// everything 24h after the event closes.
public struct ReviewProposedFinesView: View {
    @Bindable var coordinator: ReviewProposedFinesCoordinator
    @Environment(AppState.self) private var app
    public let memberLookup: (UUID) -> String

    public init(coordinator: ReviewProposedFinesCoordinator, memberLookup: @escaping (UUID) -> String, onSelectFine: @escaping (Fine) -> Void = { _ in }) {
        self.coordinator = coordinator
        self.memberLookup = memberLookup
        self.onSelectFine = onSelectFine
    }
    /// Tap en cualquier FineCard (proposed o resolved) dispatch este
    /// callback. El padre (RootShell reviewProposedScreen) lo wireá a
    /// `fineDetailRoute = fine` para push FineDetailView. Default no-op
    /// preservado por back-compat con tests/previews.
    public var onSelectFine: (Fine) -> Void = { _ in }
    @State private var voidConfirmFor: Fine?
    @State private var voidReason: String = ""

    public var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    header
                    if let err = coordinator.error {
                        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                            Text("ERROR AL CARGAR")
                                .ruulTextStyle(RuulTypography.sectionLabel)
                                .foregroundStyle(Color.ruulNegative)
                            Text(err)
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(RuulSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
                    }
                    if !coordinator.proposed.isEmpty {
                        proposedSection
                    } else if !coordinator.isLoading && coordinator.error == nil {
                        emptyState
                    }
                    if !coordinator.resolved.isEmpty {
                        resolvedSection
                    }
                    // Beta 1 W2-C1: removed the DEBUG residual that
                    // leaked "DEBUG eventId=... loaded=N proposed=N
                    // resolved=N" — devtool string visible to users
                    // in prod build.
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.s12)
            }
            .scrollIndicators(.hidden)
            .refreshable { await coordinator.refresh() }
        }
        .task { await coordinator.refresh() }
        .navigationTitle("Multas propuestas")
        .navigationBarTitleDisplayMode(.large)
        .ruulSheet(isPresented: voidSheetBinding) {
            voidSheet
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("EVENTO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(coordinator.event.title)
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Estas multas se oficializan automáticamente 24 h después del cierre. Anula las que consideres injustas.")
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, RuulSpacing.xs)
        }
        .padding(.top, RuulSpacing.md)
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "checkmark.circle.fill",
            title: "Nada que revisar",
            message: "No hay multas propuestas pendientes para este evento."
        )
        .padding(.top, RuulSpacing.lg)
    }

    private var proposedSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            RuulListSectionHeader("PROPUESTAS") {
                HStack(spacing: RuulSpacing.sm) {
                    Text("\(coordinator.proposed.count)")
                        .ruulTextStyle(RuulTypography.statSmall)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Button("Oficializar todas") {
                        Task { await coordinator.officializeAll() }
                    }
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .disabled(coordinator.isMutating)
                }
            }
            RuulSeparatedRows(items: coordinator.proposed) { fine in
                proposedFineRow(fine)
            }
        }
    }

    private func proposedFineRow(_ fine: Fine) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memberLookup(fine.userId))
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(fine.reason)
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                RuulMoneyView(
                    amount: fine.amount,
                    currency: "MXN",
                    size: .medium,
                    color: .neutral
                )
            }
            HStack(spacing: RuulSpacing.xs) {
                Button {
                    voidConfirmFor = fine
                } label: {
                    Text("Anular")
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.sm)
                        .background(Color.ruulBackground, in: Capsule())
                        .overlay(Capsule().stroke(Color.ruulSeparator, lineWidth: 0.5))
                }
                .buttonStyle(.ruulPress)
                Button {
                    Task { await coordinator.officialize(fineId: fine.id) }
                } label: {
                    Text("Oficializar")
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextInverse)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.sm)
                        .background(Color.ruulTextPrimary, in: Capsule())
                }
                .buttonStyle(.ruulPress)
            }
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private var resolvedSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack {
                Text("YA RESUELTAS")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                Text("\(coordinator.resolved.count)")
                    .ruulTextStyle(RuulTypography.statSmall)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            RuulSeparatedRows(items: coordinator.resolved) { fine in
                FineCard(
                    fine: fine,
                    ruleName: nil,
                    eventTitle: memberLookup(fine.userId),
                    onTap: { onSelectFine(fine) }
                )
            }
        }
    }

    // MARK: - Void confirmation sheet

    private var voidSheetBinding: Binding<Bool> {
        Binding(
            get: { voidConfirmFor != nil },
            set: { if !$0 { voidConfirmFor = nil; voidReason = "" } }
        )
    }

    @ViewBuilder
    private var voidSheet: some View {
        if let fine = voidConfirmFor {
            ModalSheetTemplate(
                title: "Anular multa",
                dismissAction: { voidConfirmFor = nil; voidReason = "" }
            ) {
                VStack(alignment: .leading, spacing: RuulSpacing.md) {
                    Text("Esta multa de \(fine.amountFormatted) para \(memberLookup(fine.userId)) se va a anular. Opcionalmente, deja una razón.")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                    RuulTextField("Razón (opcional)", text: $voidReason, label: "Razón")
                    RuulButton(
                        "Anular multa",
                        style: .destructive,
                        size: .large,
                        fillsWidth: true
                    ) {
                        let reason = voidReason.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await coordinator.void(fineId: fine.id, reason: reason.isEmpty ? nil : reason)
                            voidConfirmFor = nil
                            voidReason = ""
                        }
                    }
                }
            }
        }
    }
}
