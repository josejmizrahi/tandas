import SwiftUI

/// R.5V.2 — **El componente más reusado de Ruul.** Single source para el top
/// de TODA Detail View (Context, Resource, Document, Decision, Event, Actor).
///
/// Founder firma 2026-06-07: *"Context/Resource/Document/Decision Detail van
/// a terminar necesitando el mismo encabezado. Ese componente se va a reutilizar
/// muchísimo."*
///
/// Doctrina UX §0.2 Patrón Detail: Hero es la PRIMERA sección visual
/// (antes de Attention/Widgets/Sections/Actions/Activity).
///
/// Estructura:
/// ```
/// [icon]  Title                          [status]
///         Subtitle · Subtitle
///         [chip] [chip] [chip]
/// ```
public struct RuulDetailHero: View {
    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let tint: Color
    public let status: RuulStatusBadge.State?
    public let chips: [String]

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = Theme.Tint.primary,
        status: RuulStatusBadge.State? = nil,
        chips: [String] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.status = status
        self.chips = chips
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: Theme.IconSize.lg))
                    .foregroundStyle(tint)
                    .frame(width: 56, height: 56)
                    .background(tint.badgeFill, in: Circle())

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let status {
                    RuulStatusBadge(status)
                }
            }

            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.xs)
                                .background(Theme.Tint.primary.badgeFill, in: Capsule())
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        // R.17 (founder 2026-07-09: "no me gusta ese card… de todos lados") —
        // hero PLANO, mismo lenguaje que el hero de Dinero: typography
        // prominente sobre el fondo agrupado, sin glass card flotante.
        // El tint vive solo en el icon circle.
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            RuulDetailHero(
                title: "Casa Valle",
                subtitle: "Vacation Home · Familia Mizrahi",
                systemImage: "house.fill",
                tint: Theme.Tint.success,
                status: .active,
                chips: ["Reservable", "Asegurable", "Documentable"]
            )
            RuulDetailHero(
                title: "Contrato de arrendamiento",
                subtitle: "Receipt · Subido hace 3 días",
                systemImage: "doc.text.fill",
                tint: Theme.Tint.info,
                status: .archived
            )
            RuulDetailHero(
                title: "Decisión: cambiar fecha del viaje",
                subtitle: "Cena Semanal · Votación abierta",
                systemImage: "questionmark.circle.fill",
                tint: .purple,
                status: .pending,
                chips: ["3 votos", "Mayoría simple"]
            )
        }
        .padding()
    }
}
