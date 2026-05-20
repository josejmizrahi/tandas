import SwiftUI
import RuulCore
import RuulUI

struct ProgressLayout: View {
    let fields: CapabilityBlock.ProgressFields
    let tint: ResourceFamilyTint

    private var fraction: Double {
        fields.total == 0 ? 0 : min(1.0, Double(fields.current) / Double(fields.total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(fields.label)
                .font(.subheadline)
                .foregroundStyle(Color.ruulTextPrimary)
            ProgressView(value: fraction)
                .tint(tint.color)
        }
    }
}
