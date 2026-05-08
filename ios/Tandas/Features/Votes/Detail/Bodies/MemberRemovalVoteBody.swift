import SwiftUI
import RuulUI

/// Body para `VoteType.memberRemoval`. El miembro objetivo vive en
/// `vote.referenceId` (= `auth.users.id`). El servidor V1 no tiene
/// trigger automático para borrar `group_members` cuando el voto pasa
/// — eso queda como follow-up junto al `archive_rule_on_repeal_pass`
/// pattern. Mientras: si el voto resuelve `passed`, el botón "Aplicar
/// remoción" llama directo a `removeMember` (RLS lo permite a admins).
///
/// V1 no fetchea el `MemberWithProfile` desde el coordinator (no
/// tiene groupsRepo). El título del vote arranca con "Quitar a "
/// seguido del display name del miembro; lo extraemos para resaltar
/// el nombre.
struct MemberRemovalVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            warningCard

            memberCard

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

    private var warningCard: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: "person.fill.xmark")
                .foregroundStyle(Color.ruulNegative)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Si pasa, este miembro queda fuera del grupo")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Pierde acceso a eventos, multas e historial. La decisión es del grupo, no del founder.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulNegative.opacity(0.25), lineWidth: 1)
        )
    }

    private var memberCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("MIEMBRO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(memberName)
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RuulSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.small, style: .continuous))
    }

    /// Extracts the member display name from `vote.title`. The convention
    /// set by the start-vote caller is `"Quitar a <displayName>"`; we
    /// strip the prefix when present and fall back to the raw title.
    private var memberName: String {
        let raw = coordinator.vote.title
        let prefix = "Quitar a "
        if raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        return raw
    }
}
