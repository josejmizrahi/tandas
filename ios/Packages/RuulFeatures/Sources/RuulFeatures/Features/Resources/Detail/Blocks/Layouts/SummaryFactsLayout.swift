import SwiftUI
import RuulCore
import RuulUI

struct SummaryFactsLayout: View {
    let facts: [FactRow]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.key)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                    Text(fact.value)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
        }
    }
}
