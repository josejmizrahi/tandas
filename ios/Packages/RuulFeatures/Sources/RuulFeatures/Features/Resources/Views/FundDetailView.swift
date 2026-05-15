import SwiftUI
import RuulUI
import RuulCore

/// Detail view for a fund — pooled money resource.
/// Metadata expected: `name: String` (required), `currency: String` (required),
/// `goal_amount: Double` (optional). Shows enabled capabilities and an archive
/// footer placeholder (Pass 3 wires the actual RPC).
public struct FundDetailView: View {
    public let fund: ResourceRow
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public init(fund: ResourceRow) { self.fund = fund }

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

    // MARK: - Computed

    private var chrome: ResourceTypeChrome { ResourceTypeChrome.resolve(.fund) }

    private var name: String {
        if case .string(let s)? = fund.metadata["name"], !s.isEmpty { return s }
        return "Fondo"
    }

    private var currency: String {
        if case .string(let s)? = fund.metadata["currency"] { return s }
        return "MXN"
    }

    private var goalAmount: Double? {
        if case .double(let d)? = fund.metadata["goal_amount"] { return d }
        if case .int(let i)? = fund.metadata["goal_amount"] { return Double(i) }
        return nil
    }

    // MARK: - Sections

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
                Text("\(currency) · creado \(relativeCreated)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var informationSection: some View {
        sectionContainer(title: "INFORMACIÓN") {
            row(label: "Moneda", value: currency)
            divider
            row(label: "Estado", value: fund.status.capitalized)
            if let goal = goalAmount {
                divider
                row(label: "Meta", value: formatCurrency(goal))
            }
        }
    }

    private var capabilitiesPlaceholder: some View {
        sectionContainer(title: "CAPABILITIES") {
            row(label: "Próximamente", value: "Saldo + contribuciones")
                .opacity(0.55)
        }
    }

    private var relativeCreated: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return f.localizedString(for: fund.createdAt, relativeTo: .now)
    }

    private func formatCurrency(_ amount: Double) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: amount)) ?? "\(currency) \(Int(amount))"
    }

    // MARK: - Reusable

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
