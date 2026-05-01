#if DEBUG
import SwiftUI

/// Row used inside a `ShowcaseSection` to label a single demo + show variants.
struct ShowcaseRow<Content: View>: View {
    let label: String
    let snippet: String?
    let content: () -> Content

    init(_ label: String, snippet: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.snippet = snippet
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            HStack {
                Text(label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
                if let snippet {
                    Button {
                        UIPasteboard.general.string = snippet
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            content()
        }
    }
}
#endif
