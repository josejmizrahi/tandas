import SwiftUI
import RuulUI
import RuulCore

/// Container del detail screen de un Vote. Header (title + meta) +
/// body type-specific (router por vote.voteType) + cast section
/// compartida.
///
/// Bodies son views privadas en archivos separados bajo Detail/Bodies/.
/// Cuando llega un nuevo vote_type, agregar su body file y un case
/// nuevo al switch.
public struct VoteDetailView: View {
    @Bindable var coordinator: VoteDetailCoordinator
    @Environment(AppState.self) private var app

    @State private var showFinalizeConfirm = false
    @State private var showCancelConfirm = false
    /// P1 — sensoryFeedback trigger para celebrar la resolución cuando
    /// el vote cierra mientras el usuario está mirando. Cambia de nil
    /// → outcome al primer refresh post-cierre; el modifier abajo
    /// dispara haptic + animation. No haptic si el vote ya estaba
    /// resolved cuando entró (no debería haber celebración para algo
    /// histórico).
    @State private var resolutionFeedbackTrigger: VoteResolution?

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                VoteHeader(vote: coordinator.vote)
                SwiftUI.Group {
                    if let error = coordinator.error, coordinator.counts == nil {
                        ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                            .transition(.opacity)
                    } else if coordinator.isLoading && coordinator.counts == nil {
                        RuulLoadingState()
                            .frame(minHeight: 200)
                            .transition(.opacity)
                    } else {
                        bodyForType
                        VoteCastSection(coordinator: coordinator)
                        adminActionsSection
                    }
                }
                .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
                .animation(.linear(duration: RuulDuration.fast), value: coordinator.isLoading)
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .ruulAmbientScreen(palette: nil)
        .task { await coordinator.refresh() }
        .refreshable { await coordinator.refresh() }
        .sensoryFeedback(.success, trigger: resolutionFeedbackTrigger)
        .onChange(of: coordinator.vote.counts?.resolution) { oldValue, newValue in
            // Solo celebra cuando la resolución llega DURANTE esta
            // sesión (oldValue nil → newValue not nil). Si entramos
            // con el vote ya cerrado, no haptic — esto no es noticia.
            if oldValue == nil, let res = newValue {
                resolutionFeedbackTrigger = res
            }
        }
        .alert("Finalizar votación", isPresented: $showFinalizeConfirm) {
            Button("Finalizar", role: .destructive) {
                Task { await coordinator.finalizeManually() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("¿Finalizar este voto ahora? Se calculará el resultado con los votos actuales.")
        }
        .alert("Cancelar votación", isPresented: $showCancelConfirm) {
            Button("Cancelar votación", role: .destructive) {
                Task { await coordinator.cancelVote() }
            }
            Button("No cancelar", role: .cancel) {}
        } message: {
            Text("¿Cancelar este voto? Solo puedes cancelar si nadie ha votado aún.")
        }
    }

    @ViewBuilder
    private var adminActionsSection: some View {
        if coordinator.shouldShowFinalize || coordinator.shouldShowCancel {
            VStack(spacing: RuulSpacing.sm) {
                if coordinator.shouldShowFinalize {
                    Button {
                        showFinalizeConfirm = true
                    } label: {
                        HStack {
                            if coordinator.isFinalizingManually {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            }
                            Text("Finalizar votación")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.ruulAccent)
                    .disabled(coordinator.isFinalizingManually)
                }
                if coordinator.shouldShowCancel {
                    Button(role: .destructive) {
                        showCancelConfirm = true
                    } label: {
                        Text("Cancelar votación")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(coordinator.isCancellingVote)
                }
            }
            .padding(.top, RuulSpacing.xs)
        }
    }

    @ViewBuilder
    private var bodyForType: some View {
        switch coordinator.vote.voteType {
        case .fineAppeal:        FineAppealVoteBody(coordinator: coordinator)
        case .generalProposal:   GeneralProposalVoteBody(coordinator: coordinator)
        case .ruleChange:        RuleChangeVoteBody(coordinator: coordinator)
        case .ruleRepeal:        RuleRepealVoteBody(coordinator: coordinator)
        case .memberRemoval:     MemberRemovalVoteBody(coordinator: coordinator)
        case .fundWithdrawal,
             .roleAssignment,
             .slotDispute,
             .ledgerReview:      GenericVoteBody(coordinator: coordinator)
        }
    }
}

// MARK: - Private subview

private struct VoteHeader: View {
    public let vote: Vote

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(spacing: RuulSpacing.sm) {
                Text(typeLabel.uppercased())
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulAccent)
                Spacer(minLength: 0)
                countdownChip
            }
            Text(vote.title)
                .ruulTextStyle(RuulTypography.titleLarge)
                .foregroundStyle(Color.ruulTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, RuulSpacing.md)
    }

    /// "Cierra en 3 d 4 h" / "Cierra en 12 h" / "Cierra en 4 min" para
    /// votos abiertos. Para votos resueltos muestra "Cerrado" + tiempo
    /// relativo. Sin este chip el usuario no sabía cuánto tiempo tenía
    /// para votar; el cron `finalize-votes` los cierra al pasar
    /// `closesAt` sin previo aviso.
    @ViewBuilder
    private var countdownChip: some View {
        switch vote.status {
        case .open:
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let remaining = vote.closesAt.timeIntervalSince(context.date)
                if remaining > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .ruulTextStyle(RuulTypography.caption)
                            .accessibilityHidden(true)
                        Text("Cierra en \(Self.formatRemaining(remaining))")
                            .ruulTextStyle(RuulTypography.caption)
                    }
                    .foregroundStyle(remaining < 60 * 60 ? Color.ruulWarning : Color.ruulTextSecondary)
                } else {
                    Text("Por cerrar")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulWarning)
                }
            }
        case .resolved:
            resolutionChip
        case .cancelled:
            Text("Cancelado")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }

    /// Chip de outcome cuando el vote ya cerró. Reemplaza el "Cerrado"
    /// neutral con el resultado real ("Aprobado" / "Rechazado" / "Sin
    /// quórum") y el dot color matching. Lee de vote.counts.resolution
    /// (server populated post-finalize_vote). Si la resolución todavía
    /// no llegó (race window <1s entre cron y refresh), cae al "Cerrado"
    /// neutral.
    @ViewBuilder
    private var resolutionChip: some View {
        if let res = vote.counts?.resolution {
            HStack(spacing: 4) {
                Circle()
                    .fill(resolutionColor(res))
                    .frame(width: 8, height: 8)
                Text(resolutionLabel(res))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        } else {
            Text("Cerrado")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }

    private func resolutionLabel(_ res: VoteResolution) -> String {
        switch res {
        case .passed:       return "Aprobado"
        case .failed:       return "Rechazado"
        case .quorumFailed: return "Sin quórum"
        }
    }

    private func resolutionColor(_ res: VoteResolution) -> Color {
        switch res {
        case .passed:       return .ruulPositive
        case .failed:       return .ruulNegative
        case .quorumFailed: return .ruulTextTertiary
        }
    }

    private static func formatRemaining(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days >= 1 { return hours == 0 ? "\(days) d" : "\(days) d \(hours) h" }
        if hours >= 1 { return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min" }
        return "\(max(1, minutes)) min"
    }

    private var typeLabel: String {
        switch vote.voteType {
        case .fineAppeal:       return "Apelación de multa"
        case .generalProposal:  return "Propuesta"
        case .ruleChange:       return "Cambio de regla"
        case .ruleRepeal:       return "Archivar regla"
        case .memberRemoval:    return "Remover miembro"
        case .fundWithdrawal:   return "Retirar fondos"
        case .roleAssignment:   return "Asignar rol"
        case .slotDispute:      return "Disputa de slot"
        case .ledgerReview:     return "Revisión de gasto"
        }
    }
}
