import SwiftUI
import RuulCore
import RuulUI

struct BalanceLayout: View {
    let fields: CapabilityBlock.BalanceFields
    let tint: ResourceFamilyTint

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.sm) {
                Text(fields.primary)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let delta = fields.delta {
                    Text(delta)
                        .ruulTextStyle(RuulTypography.captionSemibold)
                        .foregroundStyle(tint.color)
                }
            }
            if let supporting = fields.supporting {
                Text(supporting)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }
}
