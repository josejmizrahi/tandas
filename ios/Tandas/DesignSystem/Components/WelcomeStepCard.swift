import SwiftUI

struct WelcomeStepCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Brand.Spacing.m) {
                Label {
                    Text(title).font(.tandaTitle).foregroundStyle(.white)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(Brand.accent)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
