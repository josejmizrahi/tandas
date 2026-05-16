import SwiftUI
import RuulUI
import RuulCore

/// Shared chrome for the stub capability sections in this folder. Renders
/// the same hairline-bordered card shape that the Asset sections use,
/// with a section label on top and one or more rows inside. Used by every
/// `Stubs/*.swift` section so the file-level views can stay ~30 LoC each.
///
/// Two row helpers:
///   - `placeholderRow(...)` — generic "Próximamente" body with a symbol.
///   - `metadataRow(...)`    — label / value pair when we already have data.
@MainActor
struct CapabilityStubCard<Content: View>: View {
    let label: String
    let content: () -> Content

    init(label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(label)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) {
                content()
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }
}

@MainActor
struct StubPlaceholderRow: View {
    let symbol: String
    let title: String
    let subtitle: String?

    init(symbol: String, title: String = "Próximamente", subtitle: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: symbol)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextTertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let subtitle {
                    Text(subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Spacer()
        }
        .padding(RuulSpacing.md)
    }
}

@MainActor
struct StubMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(RuulSpacing.md)
    }
}

@MainActor
struct StubDivider: View {
    var body: some View {
        Divider()
            .background(Color.ruulSeparator)
            .padding(.leading, RuulSpacing.md)
    }
}
