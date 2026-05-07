#if DEBUG
import SwiftUI

/// Section wrapper for showcase rows: title + scrollable content area.
struct ShowcaseSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text(title)
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            if let subtitle {
                Text(subtitle)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            content()
                .padding(.top, RuulSpacing.xs)
        }
        .padding(RuulSpacing.lg)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
    }
}
#endif
