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
    /// callback. El padre (MainTabView reviewProposedScreen) lo wireá a
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
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.red)
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
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
        .sheet(isPresented: voidSheetBinding) {
            voidSheet
                .presentationDetents([.medium])
                .presentationBackground(.thinMaterial)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("EVENTO")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            Text(coordinator.event.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("Estas multas se oficializan automáticamente 24 h después del cierre. Anula las que consideres injustas.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, RuulSpacing.xs)
        }
        .padding(.top, RuulSpacing.md)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nada que revisar", systemImage: "checkmark.circle.fill")
        } description: {
            Text("No hay multas propuestas pendientes para este evento.")
        }
        .padding(.top, RuulSpacing.lg)
    }

    private var proposedSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            RuulListSectionHeader("PROPUESTAS") {
                HStack(spacing: RuulSpacing.sm) {
                    Text("\(coordinator.proposed.count)")
                        .font(.footnote.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color(.tertiaryLabel))
                    Button("Oficializar todas") {
                        Task { await coordinator.officializeAll() }
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.primary)
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
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(fine.reason)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
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
                        .font(.footnote)
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.sm)
                        .background(Color.ruulBackground, in: Capsule())
                        .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
                }
                .buttonStyle(.ruulPress)
                Button {
                    Task { await coordinator.officialize(fineId: fine.id) }
                } label: {
                    Text("Oficializar")
                        .font(.footnote)
                        .foregroundStyle(Color.ruulTextInverse)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.sm)
                        .background(Color.primary, in: Capsule())
                }
                .buttonStyle(.ruulPress)
            }
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var resolvedSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack {
                Text("YA RESUELTAS")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                Spacer()
                Text("\(coordinator.resolved.count)")
                    .font(.footnote.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color(.tertiaryLabel))
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
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
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
