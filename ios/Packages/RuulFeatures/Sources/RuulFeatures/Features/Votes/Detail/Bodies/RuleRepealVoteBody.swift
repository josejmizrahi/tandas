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
                    Text("Razón")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                    Text(desc)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "clock")
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
                Text("Cierra \(coordinator.vote.closesAt.ruulRelativeDescription)")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
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
                .foregroundStyle(Color.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Si pasa, esta regla se archiva")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text("Las multas ya emitidas siguen vigentes; solo deja de aplicarse a futuro.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    private var ruleCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("Acuerdo")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            Text(ruleTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RuulSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.sm, style: .continuous))
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
