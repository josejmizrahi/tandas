import SwiftUI
import RuulCore

/// Row used by both `GroupRulesCard` (compact) and `RulesListView`.
/// Renders the rule type icon + title + body preview + severity
/// label so meaning isn't carried by color alone.
public struct RuleRowView: View {
    let rule: GroupRule
    let compact: Bool

    public init(rule: GroupRule, compact: Bool = false) {
        self.rule = rule
        self.compact = compact
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: rule.isHighSeverity
                  ? "exclamationmark.triangle.fill"
                  : rule.ruleType.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(rule.isHighSeverity ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(rule.ruleType.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !rule.body.isEmpty {
                    Text(rule.previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 4)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(rule.title). \(String(localized: rule.ruleType.label))"))
    }
}

#Preview("Rows") {
    List {
        Section { RuleRowView(rule: RulesPreviewData.prohibition) }
        Section { RuleRowView(rule: RulesPreviewData.principle) }
        Section { RuleRowView(rule: RulesPreviewData.process, compact: true) }
    }
}
