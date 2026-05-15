import SwiftUI
import RuulUI
import RuulCore

public struct RightDetailView: View {
    public let right: ResourceRow
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public init(right: ResourceRow) { self.right = right }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                hero
                informationSection
                capabilitiesPlaceholder
            }
            .padding(RuulSpacing.lg)
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(name)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
        }
    }

    private var chrome: ResourceTypeChrome { ResourceTypeChrome.resolve(.right) }

    private var name: String {
        if case .string(let s)? = right.metadata["name"], !s.isEmpty { return s }
        if case .string(let s)? = right.metadata["title"], !s.isEmpty { return s }
        return "Derecho"
    }

    private var kind: String? {
        if case .string(let s)? = right.metadata["right_kind"], !s.isEmpty { return s }
        return nil
    }

    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: chrome.symbol)
                .font(.system(size: 32))
                .foregroundStyle(chrome.semanticColor)
                .frame(width: 60, height: 60)
                .background(chrome.semanticColor.opacity(0.12), in: RoundedRectangle(cornerRadius: RuulRadius.md))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let kind {
                    Text(kind)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var informationSection: some View {
        sectionContainer(title: "INFORMACIÓN") {
            row(label: "Estado", value: right.status.capitalized)
            if let kind {
                divider
                row(label: "Tipo", value: kind)
            }
        }
    }

    private var capabilitiesPlaceholder: some View {
        sectionContainer(title: "CAPABILITIES") {
            row(label: "Próximamente", value: "Acceso + transferencia")
                .opacity(0.55)
        }
    }

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(RuulSpacing.md)
    }
}
