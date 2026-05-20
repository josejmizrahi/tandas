import SwiftUI

/// Detail-view template: scrollable content with a sticky CTA at the bottom.
/// Used for "view/edit a single item" screens (event detail, rule detail, etc).
public struct DetailScreenTemplate<Content: View>: View {
    private let title: String?
    private let primaryCTA: (label: String, perform: () -> Void)?
    private let secondaryCTA: (label: String, perform: () -> Void)?
    private let content: () -> Content

    public init(
        title: String? = nil,
        primaryCTA: (label: String, perform: () -> Void)? = nil,
        secondaryCTA: (label: String, perform: () -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.primaryCTA = primaryCTA
        self.secondaryCTA = secondaryCTA
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    if let title {
                        Text(title)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(Color.ruulTextPrimary)
                    }
                    content()
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.xxl)
            }
            if primaryCTA != nil || secondaryCTA != nil {
                stickyCTA
            }
        }
        .background(Color.ruulBackground)
    }

    private var stickyCTA: some View {
        HStack(spacing: RuulSpacing.xs) {
            if let secondaryCTA {
                RuulButton(secondaryCTA.label, style: .secondary, size: .large) { secondaryCTA.perform() }
            }
            if let primaryCTA {
                RuulButton(primaryCTA.label, style: .primary, size: .large, fillsWidth: true) { primaryCTA.perform() }
            }
        }
        .padding(.horizontal, RuulSpacing.lg)
        .padding(.vertical, RuulSpacing.md)
        // DS v3 §13: sticky CTA bar es chrome surface — Liquid Glass real.
        .ruulGlass(Rectangle(), material: .regular)
    }
}

#if DEBUG
#Preview("DetailScreenTemplate") {
    NavigationStack {
        DetailScreenTemplate(
            title: "Cena de los miércoles",
            primaryCTA: ("Confirmar", { }),
            secondaryCTA: ("Editar", { })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                ForEach(0..<5, id: \.self) { i in
                    RuulCard(.glass) {
                        Text("Card \(i)").font(.subheadline)
                    }
                }
            }
        }
    }
}
#endif
