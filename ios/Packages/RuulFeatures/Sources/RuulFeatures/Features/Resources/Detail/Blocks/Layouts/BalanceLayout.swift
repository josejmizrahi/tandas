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
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
                if let delta = fields.delta {
                    Text(delta)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint.color)
                }
            }
            if let supporting = fields.supporting {
                Text(supporting)
                    .font(.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }
}
