import SwiftUI
import RuulUI
import RuulCore

/// Body para `VoteType.ruleRepeal`. La regla referenciada (`vote.referenceId`)
/// será archivada por el trigger `archive_rule_on_repeal_pass` (migration
/// 00026) cuando el voto resuelva en `passed`. La razón del repeal vive
/// en `vote.description`; el payload está vacío por convención
/// (`EditRulesCoordinator.openRepealVote`).
///
/// V1 no fetchea la regla del repo aquí — la regla pudo haber sido
/// editada o archivada mid-vote, así que proyectamos solo lo que el
/// vote envuelve. El título del vote arranca con "Archivar: " seguido
/// del título de la regla; lo extraemos para resaltar el nombre.
public struct RuleRepealVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            warningCard

            ruleCard

            if let desc = coordinator.vote.description, !desc.isEmpty {
                VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                    Text("RAZÓN")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Text(desc)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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

    /// Warning card visible during the open vote. Once resolved, finalize
    /// flips status and the rule has already been archived (or not) by
    /// the trigger — we let the cast section handle the resolved-state
    /// messaging instead of mutating this card.
    private var warningCard: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: "trash.fill")
                .foregroundStyle(Color.ruulNegative)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Si pasa, esta regla se archiva")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Las multas ya emitidas siguen vigentes; solo deja de aplicarse a futuro.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulNegative.opacity(0.25), lineWidth: 1)
        )
    }

    private var ruleCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("ACUERDO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(ruleTitle)
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RuulSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.small, style: .continuous))
    }

    /// Extracts the rule title from `vote.title`. The convention set by
    /// `EditRulesCoordinator.openRepealVote` is `"Archivar: <rule.name>"`;
    /// we strip the prefix when present and fall back to the raw title
    /// for older rows or unconventional callers.
    private var ruleTitle: String {
        let raw = coordinator.vote.title
        let prefix = "Archivar: "
        if raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        return raw
    }
}
