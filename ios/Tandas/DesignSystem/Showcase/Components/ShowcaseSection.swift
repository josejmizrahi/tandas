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
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            Text(title)
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            if let subtitle {
                Text(subtitle)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            content()
                .padding(.top, RuulSpacing.s2)
        }
        .padding(RuulSpacing.s5)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
    }
}
#endif
