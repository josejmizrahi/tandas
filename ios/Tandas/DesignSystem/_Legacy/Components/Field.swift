import SwiftUI

struct Field<Content: View>: View {
    let label: String?
    let description: String?
    let error: String?
    let content: Content

    init(label: String? = nil, description: String? = nil, error: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.description = description
        self.error = error
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.xs) {
            if let label {
                Text(label).font(.tandaBody.weight(.medium)).foregroundStyle(.white.opacity(0.85))
            }
            content
                .padding(.horizontal, Brand.Spacing.m)
                .padding(.vertical, Brand.Spacing.m)
                .adaptiveGlass(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous))
            if let error {
                Text(error).font(.tandaCaption).foregroundStyle(.red)
            } else if let description {
                Text(description).font(.tandaCaption).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
