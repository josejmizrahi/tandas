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
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    Text(fact.value)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                }
            }
        }
    }
}
