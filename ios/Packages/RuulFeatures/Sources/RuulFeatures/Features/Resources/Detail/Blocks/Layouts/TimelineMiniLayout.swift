import SwiftUI
import RuulCore
import RuulUI

struct TimelineMiniLayout: View {
    let entries: [CapabilityBlock.TimelineEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: RuulSpacing.sm) {
                    Text(entry.relativeTime)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .frame(width: 64, alignment: .leading)
                    Text(entry.sentence)
                        .ruulTextStyle(RuulTypography.subhead)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
        }
    }
}
