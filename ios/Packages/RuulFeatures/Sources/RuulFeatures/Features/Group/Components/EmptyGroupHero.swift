import SwiftUI
import RuulUI

/// Estado vacío canónico del GroupSpace cuando todos los clusters
/// están vacíos (doctrine `group_space_situational`, 2026-05-24).
///
/// Doctrina post 2026-05-26: además de la presencia + invitar, el empty
/// state surface los **verbos universales** que un grupo Ruul tiene desde
/// día 1 sin activar módulos. Cada verbo es un `EmptyStateAction`
/// declarativo — el founder agrega/quita entries sin tocar este view.
@MainActor
struct EmptyGroupHero: View {
    /// Acción primaria — siempre "Invitar gente" en V1 porque sin gente
    /// los demás verbos no tienen consecuencia social.
    var primary: EmptyStateAction

    /// Verbos universales secundarios. Renderizan como chips glass
    /// wrap-friendly bajo la copy. Pasar `[]` muestra el hero clásico.
    var actions: [EmptyStateAction]

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

            Button(action: primary.handler) {
                Label(primary.label, systemImage: primary.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    Text("O empezá a coordinar:")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ruulTextSecondary)
                    actionsStrip
                }
                .padding(.top, RuulSpacing.xs)
            }
        }
        .padding(.top, RuulSpacing.lg)
    }

    /// Wrap-friendly grid of glass chips. Uses native iOS 26 wrapping
    /// via a flexible-width LazyVGrid so chips reflow on narrow widths.
    @ViewBuilder
    private var actionsStrip: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: RuulSpacing.xs)],
            alignment: .leading,
            spacing: RuulSpacing.xs
        ) {
            ForEach(actions) { action in
                Button {
                    action.handler()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: action.systemImage)
                            .font(.footnote.weight(.semibold))
                        Text(action.label)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
            }
        }
    }
}
