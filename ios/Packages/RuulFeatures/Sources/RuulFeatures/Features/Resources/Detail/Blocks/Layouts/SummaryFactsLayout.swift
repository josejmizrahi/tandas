import SwiftUI
import RuulCore
import RuulUI

/// Canonical key/value layout for Coordination blocks that carry
/// supporting facts (event Lugar address, rotation Next host + Queue,
/// future Schedule date+recurrence, future Access availability).
///
/// Doctrine (`Plans/Active/Fase1ComponentMap.md` §"Universal Resource
/// Detail — Coordination block grammar"): the *value* is the load-
/// bearing content (an address, a hostname, a date). The key is a
/// subordinate label. Apple Calendar / Reminders / Find My follow the
/// same pattern — they bias readability toward the value, not the
/// label.
///
/// Single fact: a 1-fact block (e.g. Lugar → single address row) reads
/// best with the value promoted; the block's own header chrome (icon +
/// title) already signals what the fact is *about*, so the value can
/// breathe.
struct SummaryFactsLayout: View {
    let facts: [FactRow]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.key)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                    Text(fact.value)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                }
            }
        }
    }
}
