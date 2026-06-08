import SwiftUI

/// R.5V.2 — Hero card secundaria. NO es el header de un Detail View
/// (para eso usar `RuulDetailHero`). Esto es para hero cards inline:
/// HomeView greeting, banners callout, empty states rich, summary
/// cards en lists.
///
/// Doctrina UX §V.1: native first, semantic colors via Theme.Tint.
/// Material `regularMaterial` para profundidad sin shadows ad-hoc.
public struct RuulHeroCard<Content: View>: View {
    public let title: String
    public let subtitle: String?
    public let systemImage: String?
    public let tint: Color
    public let content: () -> Content

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        tint: Color = Theme.Tint.primary,
        @ViewBuilder content: @escaping () -> Content = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: Theme.IconSize.md))
                        .foregroundStyle(tint)
                        .frame(width: 44, height: 44)
                        .background(tint.badgeFill, in: Circle())
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Text.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
                Spacer()
            }
            content()
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: Theme.cardShape())
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            RuulHeroCard(
                title: "Buenos días",
                subtitle: "Tienes 3 cosas que requieren tu atención",
                systemImage: "sun.max.fill",
                tint: Theme.Tint.warning
            )
            RuulHeroCard(
                title: "Liquidación lista",
                subtitle: "Debes $1,200 a María",
                systemImage: "banknote.fill",
                tint: Theme.Tint.success
            ) {
                Button("Marcar pagado") {}
                    .buttonStyle(.glassProminent)
            }
        }
        .padding()
    }
}
