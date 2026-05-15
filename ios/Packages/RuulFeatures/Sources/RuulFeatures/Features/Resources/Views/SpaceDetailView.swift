import SwiftUI
import RuulUI
import RuulCore

public struct SpaceDetailView: View {
    public let space: ResourceRow
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public init(space: ResourceRow) { self.space = space }

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

    private var chrome: ResourceTypeChrome { ResourceTypeChrome.resolve(.space) }

    private var name: String {
        if case .string(let s)? = space.metadata["name"], !s.isEmpty { return s }
        if case .string(let s)? = space.metadata["location_name"], !s.isEmpty { return s }
        return "Espacio"
    }

    private var address: String? {
        if case .string(let s)? = space.metadata["address"], !s.isEmpty { return s }
        return nil
    }

    private var capacity: Int? {
        if case .int(let i)? = space.metadata["capacity"] { return i }
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
                if let cap = capacity {
                    Text("Capacidad: \(cap)")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var informationSection: some View {
        sectionContainer(title: "INFORMACIÓN") {
            row(label: "Estado", value: space.status.capitalized)
            if let address {
                divider
                row(label: "Dirección", value: address)
            }
            if let cap = capacity {
                divider
                row(label: "Capacidad", value: "\(cap)")
            }
        }
    }

    private var capabilitiesPlaceholder: some View {
        sectionContainer(title: "CAPABILITIES") {
            row(label: "Próximamente", value: "Reservas + disponibilidad")
                .opacity(0.55)
        }
    }

    // Reusable container/row helpers — identical to FundDetailView

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
                .multilineTextAlignment(.trailing)
        }
        .padding(RuulSpacing.md)
    }
}
