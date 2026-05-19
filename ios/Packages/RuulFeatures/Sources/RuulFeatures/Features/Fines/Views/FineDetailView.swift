import SwiftUI
import RuulUI
import RuulCore

/// Single-fine detail screen. Hero amount on top, status pill underneath,
/// reason + evidence in cards, action footer (Pagar / Apelar / Ver
/// apelación). Apple Sports flat — monochrome chrome, color via dot only.
public struct FineDetailView: View {
    @Environment(AppState.self) private var app
    @Bindable var coordinator: FineDetailCoordinator
    public var onAppeal: (() -> Void)?
    public var onViewAppeal: ((Appeal) -> Void)?

    /// V1: gate for the "Anular multa" button. Resolved async on appear
    /// because governance.canPerform requires loading the user's Member row
    /// in the fine's group (cross-group fines via MyFinesView).
    public let computeCanVoidFine: () async -> Bool
    /// Factory: creates a fresh `VoidFineCoordinator` each time the sheet
    /// is opened. Captures `app.governance`, repos, and `coord.refresh`
    /// (via onSubmitted) lexically in MainTabView.fineDetailScreen.
    public let makeVoidFineCoordinator: () -> VoidFineCoordinator
    public let currentUserId: UUID

    public init(coordinator: FineDetailCoordinator, onAppeal: (() -> Void)?, onViewAppeal: ((Appeal) -> Void)?, computeCanVoidFine: @escaping () async -> Bool, makeVoidFineCoordinator: @escaping () -> VoidFineCoordinator, currentUserId: UUID) {
        self.coordinator = coordinator
        self.onAppeal = onAppeal
        self.onViewAppeal = onViewAppeal
        self.computeCanVoidFine = computeCanVoidFine
        self.makeVoidFineCoordinator = makeVoidFineCoordinator
        self.currentUserId = currentUserId
    }

    @State private var appealSheetPresented = false
    @State private var payConfirmPresented = false
    @State private var voidSheetPresented = false
    @State private var canVoidFine: Bool = false

    public var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    hero
                    if let coordError = coordinator.error {
                        RuulInlineMessage(
                            coordError.message ?? coordError.title,
                            style: .error,
                            action: coordError.isRetryable
                                ? .init(label: "Cerrar", handler: { coordinator.clearError() })
                                : nil
                        )
                    }
                    reasonCard
                    evidenceSection
                    voidedSection
                    appealStatusInline
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.s12)
            }
            .scrollIndicators(.hidden)

            actionFooter
        }
        .navigationTitle("Multa")
        .navigationBarTitleDisplayMode(.inline)
        .task { await coordinator.refresh() }
        .task { canVoidFine = await computeCanVoidFine() }
        .task { await coordinator.trackSeen() }
        .ruulSheet(isPresented: $appealSheetPresented) {
            AppealFineSheet(
                isPresented: $appealSheetPresented,
                fine: coordinator.fine
            ) { reason in
                Task { await coordinator.startAppeal(reason: reason) }
            }
        }
        .ruulSheet(isPresented: $voidSheetPresented) {
            // Fresh coordinator per open: makeVoidFineCoordinator() runs each
            // time the binding flips false→true. Deliberate — avoids leaking
            // partially-filled form state from cancelled sessions. The factory
            // wires onSubmitted = { coord.refresh() } so the parent repaints
            // before the sheet dismisses.
            VoidFineSheet(
                isPresented: $voidSheetPresented,
                coordinator: makeVoidFineCoordinator()
            )
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack(spacing: RuulSpacing.xs) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                Text(coordinator.fine.status.displayLabel)
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextPrimary)
                if coordinator.fine.status == .proposed {
                    Spacer()
                    RuulListSectionHeader("EN REVISIÓN 24H")
                }
            }
            RuulMoneyView(
                amount: coordinator.fine.amount,
                currency: "MXN",
                size: .large,
                color: heroAmountColor
            )
        }
        .padding(.top, RuulSpacing.lg)
    }

    private var heroAmountColor: RuulMoneyView.SemanticColor {
        switch coordinator.fine.status {
        case .officialized:        return .negative
        case .paid:                return .positive
        case .voided:              return .neutral
        case .proposed, .inAppeal: return .neutral
        }
    }

    // MARK: - Reason card

    private var reasonCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            RuulListSectionHeader("MOTIVO")
            Text(coordinator.fine.reason)
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    // MARK: - Evidence section (rule snapshot + details)

    @ViewBuilder
    private var evidenceSection: some View {
        if coordinator.fine.autoGenerated {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                RuulListSectionHeader("EVIDENCIA")
                evidenceBody
            }
        }
    }

    @ViewBuilder
    private var evidenceBody: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            evidenceRow(label: "Generada por", value: "Regla automática")
            if let createdAt = coordinator.fine.createdAt as Date? {
                evidenceRow(label: "Fecha", value: createdAt.ruulShortDate)
            }
            if let lateMinutes = coordinator.fine.details?["minutes_late"]?.intValue {
                evidenceRow(label: "Minutos tarde", value: "\(lateMinutes)")
            }
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private func evidenceRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(value)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }

    // MARK: - Voided section (admin closure reason after Anular)

    @ViewBuilder
    private var voidedSection: some View {
        if coordinator.fine.status == .voided,
           let waivedReason = coordinator.fine.waivedReason,
           !waivedReason.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                RuulListSectionHeader("ANULADA POR ADMIN")
                Text(waivedReason)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .padding(RuulSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.ruulSurface,
                        in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                            .stroke(Color.ruulSeparator, lineWidth: 0.5)
                    )
            }
        }
    }

    // MARK: - Inline appeal status (when there's an active appeal)

    @ViewBuilder
    private var appealStatusInline: some View {
        if let appeal = coordinator.existingAppeal {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack(spacing: RuulSpacing.xs) {
                    Circle()
                        .fill(appealDotColor(for: appeal.status))
                        .frame(width: 8, height: 8)
                    Text(appealStatusLabel(for: appeal.status))
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                Text(appeal.reason)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let counts = coordinator.voteCounts {
                    // AppealRepository expone AppealVoteCounts por compat con el
                    // protocol; el wire-shape ya es el genérico vote_casts (post-00047).
                    // Conversión local hasta que el AppealRepository protocol se
                    // colapse en VoteRepository (V2 follow-up).
                    VoteCountsBar(counts: VoteCounts(
                        inFavor:       counts.inFavor,
                        against:       counts.against,
                        abstained:     counts.abstained,
                        pending:       counts.pending,
                        totalEligible: counts.totalEligible,
                        resolution:    nil
                    ))
                }
                if appeal.isVotingOpen {
                    Button { onViewAppeal?(appeal) } label: {
                        HStack {
                            Text("Ver detalle de votación")
                                .ruulTextStyle(RuulTypography.callout)
                            Spacer()
                            Image(systemName: "arrow.right")
                                .ruulTextStyle(RuulTypography.captionBold)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(Color.ruulTextPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Sticky action footer

    @ViewBuilder
    private var actionFooter: some View {
        VStack {
            Spacer()
            SwiftUI.Group {
                if coordinator.isMine {
                    actionsForMyFine
                } else {
                    actionsForAdmin
                }
            }
        }
        .allowsHitTesting(footerHasContent)
    }

    /// True if either `actionsForMyFine` or `actionsForAdmin` would render
    /// non-empty content for the current state. Mirrors the gate logic in
    /// each builder so a footer with no actions doesn't capture taps over
    /// the scroll content beneath.
    private var footerHasContent: Bool {
        if coordinator.isMine {
            // Mirror `actionsForMyFine` gate: appeal-pending hides; only
            // .officialized and .proposed surface buttons.
            if let appeal = coordinator.existingAppeal, appeal.isVotingOpen {
                return false
            }
            switch coordinator.fine.status {
            case .officialized, .proposed: return true
            case .paid, .voided, .inAppeal: return false
            }
        } else {
            // Mirror `actionsForAdmin` gate.
            guard canVoidFine else { return false }
            return coordinator.fine.status == .proposed || coordinator.fine.status == .officialized
        }
    }

    @ViewBuilder
    private var actionsForAdmin: some View {
        if canVoidFine,
           coordinator.fine.status == .proposed || coordinator.fine.status == .officialized {
            RuulButton("Anular multa", style: .destructive, size: .large, fillsWidth: true) {
                voidSheetPresented = true
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.sm)
            // DS v3 §13: sticky CTA chrome — Liquid Glass real.
            .ruulGlass(Rectangle(), material: .regular)
        }
    }

    @ViewBuilder
    private var actionsForMyFine: some View {
        if let appeal = coordinator.existingAppeal, appeal.isVotingOpen {
            // Already appealed — no Pagar / Apelar buttons; just keep the
            // voting status visible above. The voting itself happens in
            // VoteOnAppealView for OTHER members; the appellant just waits.
            EmptyView()
        } else {
            switch coordinator.fine.status {
            case .officialized:
                VStack(spacing: RuulSpacing.xs) {
                    HStack(spacing: RuulSpacing.sm) {
                        RuulButton("Apelar", style: .glass, size: .large, fillsWidth: true) {
                            // Prefer parent-provided handler (e.g., navigation
                            // to a dedicated screen). Fall back to local sheet
                            // when callsite doesn't override.
                            if let onAppeal {
                                onAppeal()
                            } else {
                                appealSheetPresented = true
                            }
                        }
                        // V1: Ruul no procesa pagos (regulatorio). El botón
                        // solo registra "ya quedó" en el ledger — el
                        // intercambio real pasa fuera de la app. El copy
                        // anterior "Pagar" sonaba a Stripe/MP, lo que es
                        // engañoso. Ver Vision.md §"Frontera regulatoria".
                        RuulButton("Marcar como pagada", style: .primary, size: .large, fillsWidth: true) {
                            Task { await coordinator.payFine() }
                        }
                    }
                    Text("Coordina el pago por separado y márcalo aquí. Ruul no procesa cobros por ahora.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.vertical, RuulSpacing.sm)
                // DS v3 §13: sticky CTA chrome — Liquid Glass real.
                .ruulGlass(Rectangle(), material: .regular)
            case .proposed:
                proposedGraceBanner
            case .paid, .voided, .inAppeal:
                EmptyView()
            }
        }
    }

    /// Live countdown until the proposed fine auto-officializes. Backend
    /// honors `createdAt + 24h` via `finalize-fine-reviews` cron (mig 00016).
    /// El usuario que recibe la multa ya sabe cuánto le queda al anfitrión
    /// para voidearla manualmente; pasado ese plazo la deuda se vuelve
    /// oficial. TimelineView tickea cada minuto — no hace falta segundos.
    private var proposedGraceBanner: some View {
        let expiry = coordinator.fine.createdAt.addingTimeInterval(24 * 60 * 60)
        return TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = expiry.timeIntervalSince(context.date)
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                if remaining > 0 {
                    HStack(spacing: RuulSpacing.xs) {
                        Image(systemName: "hourglass")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                            .foregroundStyle(Color.ruulWarning)
                            .accessibilityHidden(true)
                        Text("Se oficializa en \(Self.formatGraceRemaining(remaining))")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                            .foregroundStyle(Color.ruulTextPrimary)
                    }
                } else {
                    Text("Pendiente de oficializar")
                        .ruulTextStyle(RuulTypography.subheadSemibold)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                Text("Si no aplica, espera a que el anfitrión la revise — o contacta directo.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.sm)
            .ruulGlass(Rectangle(), material: .regular)
        }
    }

    private static func formatGraceRemaining(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 1 {
            return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
        }
        return "\(max(1, minutes)) min"
    }

    // MARK: - Helpers

    private var statusDotColor: Color {
        switch coordinator.fine.status {
        case .proposed:     return .ruulWarning
        case .officialized: return .ruulNegative
        case .paid:         return .ruulPositive
        case .voided:       return .ruulTextTertiary
        case .inAppeal:     return .ruulInfo
        }
    }

    private func appealDotColor(for status: AppealStatus) -> Color {
        switch status {
        case .voting:           return .ruulInfo
        case .resolvedInFavor:  return .ruulPositive
        case .resolvedAgainst:  return .ruulNegative
        case .expired:          return .ruulTextTertiary
        }
    }

    private func appealStatusLabel(for status: AppealStatus) -> String {
        switch status {
        case .voting:           return "EN VOTACIÓN"
        case .resolvedInFavor:  return "APELACIÓN GANADA"
        case .resolvedAgainst:  return "APELACIÓN PERDIDA"
        case .expired:          return "VOTACIÓN VENCIDA"
        }
    }
}
