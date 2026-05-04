import SwiftUI

/// Host's grace-period dashboard. Lists all proposed fines for an event
/// with quick actions: oficializar (skip the 24h wait) or anular (void).
/// If the host does nothing, finalize-fine-reviews cron officializes
/// everything 24h after the event closes.
struct ReviewProposedFinesView: View {
    @Bindable var coordinator: ReviewProposedFinesCoordinator
    let memberLookup: (UUID) -> String
    @State private var voidConfirmFor: Fine?
    @State private var voidReason: String = ""

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s6) {
                    header
                    if !coordinator.proposed.isEmpty {
                        proposedSection
                    } else if !coordinator.isLoading {
                        emptyState
                    }
                    if !coordinator.resolved.isEmpty {
                        resolvedSection
                    }
                }
                .padding(.horizontal, RuulSpacing.s5)
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
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
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
                .padding(.top, RuulSpacing.s2)
        }
        .padding(.top, RuulSpacing.s4)
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "checkmark.circle.fill",
            title: "Nada que revisar",
            message: "No hay multas propuestas pendientes para este evento."
        )
        .padding(.top, RuulSpacing.s5)
    }

    private var proposedSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            HStack {
                Text("PROPUESTAS")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                Text("\(coordinator.proposed.count)")
                    .ruulTextStyle(RuulTypography.statSmall)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                Button("Oficializar todas") {
                    Task { await coordinator.officializeAll() }
                }
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextPrimary)
                .disabled(coordinator.isMutating)
            }
            ForEach(coordinator.proposed) { fine in
                proposedFineRow(fine)
            }
        }
    }

    private func proposedFineRow(_ fine: Fine) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
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
                Text(fine.amountFormatted)
                    .ruulTextStyle(RuulTypography.statMedium)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            HStack(spacing: RuulSpacing.s2) {
                Button {
                    voidConfirmFor = fine
                } label: {
                    Text("Anular")
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.s3)
                        .background(Color.ruulBackgroundCanvas, in: Capsule())
                        .overlay(Capsule().stroke(Color.ruulBorderSubtle, lineWidth: 0.5))
                }
                .buttonStyle(.ruulPress)
                Button {
                    Task { await coordinator.officialize(fineId: fine.id) }
                } label: {
                    Text("Oficializar")
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextInverse)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.s3)
                        .background(Color.ruulTextPrimary, in: Capsule())
                }
                .buttonStyle(.ruulPress)
            }
        }
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    private var resolvedSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            HStack {
                Text("YA RESUELTAS")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                Text("\(coordinator.resolved.count)")
                    .ruulTextStyle(RuulTypography.statSmall)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            ForEach(coordinator.resolved) { fine in
                FineCard(
                    fine: fine,
                    ruleName: nil,
                    eventTitle: memberLookup(fine.userId),
                    onTap: {}
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
                VStack(alignment: .leading, spacing: RuulSpacing.s4) {
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
