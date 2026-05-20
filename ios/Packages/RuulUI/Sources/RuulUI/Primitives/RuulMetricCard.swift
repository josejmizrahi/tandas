import SwiftUI

/// Numeric stat tile — Apple Sports / Luma style monochrome card with a
/// tracked-uppercase label and a big monospaced numeral. Optional unit
/// (e.g. "$" prefix, "%" suffix) and trend delta badge ("+12% vs mes
/// pasado").
///
/// Designed to compose in dashboards (group health, host stats) without
/// adding chrome — the surface is `ruulSurface` with the
/// signature 0.5pt subtle border.
public struct RuulMetricCard: View {
    public enum Size: Sendable, Hashable {
        case compact   // statSmall numeral, fits in 2-up grids
        case regular   // statMedium, fits in 1-up rows
        case hero      // statHero, full-width feature
    }

    public enum Trend: Sendable, Hashable {
        case up(String)
        case down(String)
        case flat(String)

        var icon: String {
            switch self {
            case .up:   return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .flat: return "arrow.right"
            }
        }

        var color: Color {
            switch self {
            case .up:   return .green
            case .down: return .red
            case .flat: return Color(.tertiaryLabel)
            }
        }

        var label: String {
            switch self {
            case .up(let s), .down(let s), .flat(let s): return s
            }
        }
    }

    private let label: String
    private let value: String
    private let unitPrefix: String?
    private let unitSuffix: String?
    private let trend: Trend?
    private let size: Size

    public init(
        label: String,
        value: String,
        unitPrefix: String? = nil,
        unitSuffix: String? = nil,
        trend: Trend? = nil,
        size: Size = .regular
    ) {
        self.label = label
        self.value = value
        self.unitPrefix = unitPrefix
        self.unitSuffix = unitSuffix
        self.trend = trend
        self.size = size
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            valueRow
            if let trend {
                trendRow(trend)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.lg)
        .background(.ultraThinMaterial, in: shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
    }

    private var valueRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            if let unitPrefix {
                Text(unitPrefix)
                    .font(unitFont)
                    .foregroundStyle(Color.secondary)
            }
            Text(value)
                .font(valueFont)
                .foregroundStyle(Color.primary)
            if let unitSuffix {
                Text(unitSuffix)
                    .font(unitFont)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private func trendRow(_ trend: Trend) -> some View {
        HStack(spacing: RuulSpacing.xxs) {
            Image(systemName: trend.icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(trend.color)
            Text(trend.label)
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private var valueFont: Font {
        switch size {
        case .compact: return .footnote.monospacedDigit().weight(.bold)
        case .regular: return .body.monospacedDigit().weight(.bold)
        case .hero:    return .largeTitle.monospacedDigit().weight(.heavy)
        }
    }

    private var unitFont: Font {
        switch size {
        case .compact: return .caption
        case .regular: return .footnote
        case .hero:    return .headline
        }
    }

    private var accessibilityLabel: String {
        let composed = [unitPrefix, value, unitSuffix].compactMap { $0 }.joined()
        var parts = ["\(label): \(composed)"]
        if let trend { parts.append(trend.label) }
        return parts.joined(separator: ". ")
    }
}

#if DEBUG
#Preview("RuulMetricCard") {
    ScrollView {
        VStack(spacing: RuulSpacing.sm) {
            RuulMetricCard(
                label: "ASISTENCIA PROMEDIO",
                value: "87",
                unitSuffix: "%",
                trend: .up("+5% vs mes pasado"),
                size: .hero
            )
            HStack(spacing: RuulSpacing.sm) {
                RuulMetricCard(
                    label: "MULTAS DEL MES",
                    value: "1240",
                    unitPrefix: "$",
                    trend: .down("-15%"),
                    size: .compact
                )
                RuulMetricCard(
                    label: "EVENTOS",
                    value: "4",
                    trend: .flat("igual"),
                    size: .compact
                )
            }
            RuulMetricCard(
                label: "MIEMBROS ACTIVOS",
                value: "12",
                unitSuffix: " de 14",
                size: .regular
            )
        }
        .padding(RuulSpacing.lg)
    }
    .background(Color.ruulBackground)
}
#endif
