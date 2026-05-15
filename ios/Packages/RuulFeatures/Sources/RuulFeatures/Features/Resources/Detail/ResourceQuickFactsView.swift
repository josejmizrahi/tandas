import SwiftUI
import RuulCore
import RuulUI

/// Horizontal pills strip showing capability-driven quick facts for
/// a resource (date / time / location / capacity / balance / etc.).
/// Source of truth: `CapabilityResolver.quickFacts(...)`. Empty array
/// → caller hides the strip entirely (this view returns EmptyView).
@MainActor
public struct ResourceQuickFactsView: View {
    public let facts: [QuickFact]
    public let onTapLocation: (() -> Void)?

    public init(facts: [QuickFact], onTapLocation: (() -> Void)? = nil) {
        self.facts = facts
        self.onTapLocation = onTapLocation
    }

    public var body: some View {
        if facts.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.s2) {
                    ForEach(facts) { fact in
                        pill(for: fact)
                    }
                }
                .padding(.horizontal, RuulSpacing.s6)
            }
        }
    }

    @ViewBuilder
    private func pill(for fact: QuickFact) -> some View {
        let content = HStack(spacing: 6) {
            Image(systemName: fact.symbol)
                .ruulTextStyle(RuulTypography.calloutRegular)
                .foregroundStyle(Color.ruulTextSecondary)
            Text(fact.label)
                .ruulTextStyle(RuulTypography.calloutRegular)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, RuulSpacing.s4)
        .padding(.vertical, RuulSpacing.s2)
        .background(Capsule().fill(Color.ruulSurface))

        if fact.kind == .location, let onTap = onTapLocation {
            Button(action: onTap) { content }
                .buttonStyle(.ruulPress)
        } else {
            content
        }
    }
}

#if DEBUG
#Preview("QuickFacts — event") {
    ResourceQuickFactsView(facts: [
        QuickFact(id: "date", kind: .date, symbol: "calendar", label: "JUE 12 MAR"),
        QuickFact(id: "time", kind: .time, symbol: "clock", label: "9:00 PM"),
        QuickFact(id: "location", kind: .location, symbol: "mappin.and.ellipse", label: "Casa de JJ"),
        QuickFact(id: "capacity", kind: .capacity, symbol: "person.2", label: "8/12")
    ])
    .frame(maxWidth: .infinity)
    .background(Color.ruulBackground)
}

#Preview("QuickFacts — empty") {
    ResourceQuickFactsView(facts: [])
        .frame(width: 300, height: 50)
        .background(Color.ruulBackground)
}
#endif
