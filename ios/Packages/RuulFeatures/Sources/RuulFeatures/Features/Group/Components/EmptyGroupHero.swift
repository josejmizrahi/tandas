import SwiftUI
import RuulUI

/// Estado vacío canónico del GroupSpace cuando todos los clusters
/// están vacíos (doctrine_group_space_situational, 2026-05-24).
/// Sólo se monta debajo del PresenceHeader — no reemplaza presencia.
/// La acción primaria es invitar gente; "Crear algo" queda sutil.
@MainActor
struct EmptyGroupHero: View {
    var onInvite: () -> Void
    var onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Este grupo todavía está vacío.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Invita a las personas con las que vas a coordinar.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextSecondary)
            }

            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Button(action: onInvite) {
                    Label("Invitar gente", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button("Crear algo", action: onCreate)
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.top, RuulSpacing.lg)
    }
}
