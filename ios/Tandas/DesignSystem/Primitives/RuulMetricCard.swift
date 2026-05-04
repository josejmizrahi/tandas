import SwiftUI

/// Numeric stat tile — Apple Sports / Luma style monochrome card with a
/// tracked-uppercase label and a big monospaced numeral. Optional unit
/// (e.g. "$" prefix, "%" suffix) and trend delta badge ("+12% vs mes
/// pasado").
///
/// Designed to compose in dashboards (group health, host stats) without
/// adding chrome — the surface is `ruulBackgroundElevated` with the
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
            case .up:   return .ruulSemanticSuccess
            case .down: return .ruulSemanticError
            case .flat: return .ruulTextTertiary
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
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text(label)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            valueRow
            if let trend {
                trendRow(trend)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: shape)
        .overlay(shape.stroke(Color.ruulBorderSubtle, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
    }

    private var valueRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            if let unitPrefix {
                Text(unitPrefix)
                    .ruulTextStyle(unitStyle)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Text(value)
                .ruulTextStyle(valueStyle)
                .foregroundStyle(Color.ruulTextPrimary)
            if let unitSuffix {
                Text(unitSuffix)
                    .ruulTextStyle(unitStyle)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }

    private func trendRow(_ trend: Trend) -> some View {
        HStack(spacing: RuulSpacing.s1) {
            Image(systemName: trend.icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(trend.color)
            Text(trend.label)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private var valueStyle: RuulTextStyle {
        switch size {
        case .compact: return RuulTypography.statSmall
        case .regular: return RuulTypography.statMedium
        case .hero:    return RuulTypography.statHero
        }
    }

    private var unitStyle: RuulTextStyle {
        switch size {
        case .compact: return RuulTypography.caption
        case .regular: return RuulTypography.callout
        case .hero:    return RuulTypography.headline
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
        VStack(spacing: RuulSpacing.s3) {
            RuulMetricCard(
                label: "ASISTENCIA PROMEDIO",
                value: "87",
                unitSuffix: "%",
                trend: .up("+5% vs mes pasado"),
                size: .hero
            )
            HStack(spacing: RuulSpacing.s3) {
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
        .padding(RuulSpacing.s5)
    }
    .background(Color.ruulBackgroundCanvas)
}
#endif
