import SwiftUI

/// Body para `VoteType.fineAppeal`. Renderiza fine context (amount,
/// reason) + appeal reason + close-time hint. Diseñado para usar en
/// `VoteDetailView` (Task D1) vía `VoteDetailCoordinator`.
///
/// **V1 duplicación con `VoteOnAppealSheet`**: el sheet existente
/// (`Features/Fines/Sheets/VoteOnAppealSheet.swift`) preserva su entry
/// point intacto con su propio rendering — no se refactoriza en V1
/// para evitar regresión en el flow probado en producción
/// (`cast_appeal_vote` legacy + `AppealVoteCounts` + `Fine`/`Appeal`
/// domain inputs vs. el `VoteDetailCoordinator` genérico). Resultado:
/// dos rendering paths para fine_appeal — sheet (legacy) + body (router).
/// V2 cleanup: audit § 5.2 unificará removiendo `appeal_votes` legacy
/// y migrando el sheet a usar este body. Ver
/// `Plans/Phase0.5-UIResourceGeneralization.md` Sub-fase C/D.
///
/// **Payload shape esperado** (poblado por el caller del `start_vote`
/// RPC para vote_type='fine_appeal' — migration 00023 sólo extrae
/// `member_id` para excluir al apelante de los eligible voters; el
/// resto del payload es caller-supplied):
///   - `fine_amount` (int, opcional) — monto en la moneda del grupo
///   - `fine_reason` (string, opcional) — razón original de la multa
///   - `member_id`   (uuid, opcional) — apelante (excluído de votar)
///
/// Si los campos no están presentes el body degrada elegantemente
/// (mostrando solo `vote.description` como appeal reason).
struct FineAppealVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    private var fineAmount: Int? {
        coordinator.vote.payload["fine_amount"]?.intValue
    }

    private var fineReason: String? {
        coordinator.vote.payload["fine_reason"]?.stringValue
    }

    private var appealReason: String? {
        coordinator.vote.description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            fineCard
            appealReasonCard
            closesAtRow
        }
    }

    private var fineCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("MULTA APELADA")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            HStack(alignment: .firstTextBaseline) {
                if let reason = fineReason, !reason.isEmpty {
                    Text(reason)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                } else {
                    Text("(Sin razón registrada)")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                Spacer(minLength: RuulSpacing.sm)
                if let amount = fineAmount {
                    Text("$\(amount)")
                        .ruulTextStyle(RuulTypography.statMedium)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var appealReasonCard: some View {
        if let reason = appealReason, !reason.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("ARGUMENTO DE APELACIÓN")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(reason)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    private var closesAtRow: some View {
        HStack(spacing: RuulSpacing.xs) {
            Image(systemName: "clock")
                .foregroundStyle(Color.ruulTextTertiary)
                .accessibilityHidden(true)
            Text("Cierra \(coordinator.vote.closesAt.ruulRelativeDescription)")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
        }
    }
}
