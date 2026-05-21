import SwiftUI
import RuulCore
import RuulUI

/// Canonical **Money block** layout for Universal Resource Detail.
///
/// Doctrine (`Plans/Active/Fase1ComponentMap.md` §"Universal Resource
/// Detail — Coordination block grammar"): a Money block reads
/// identically inside a fund, a fine, a trust distribution, an expense.
/// Used today by:
///   - `FundBlockBuilder` (saldo)
///   - `FineBlockBuilder` (monto)
///
/// Apple Wallet card-detail shape: balance number is the visual anchor
/// — large monospaced digits so the eye lands on it first, supporting
/// line below in secondary tone. Delta (e.g. "+ $1,200 esta semana")
/// trails the primary in tint when present.
struct BalanceLayout: View {
    let fields: CapabilityBlock.BalanceFields
    let tint: ResourceFamilyTint

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.sm) {
                Text(fields.primary)
                    .font(.largeTitle.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let delta = fields.delta {
                    Text(delta)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint.color)
                }
                Spacer(minLength: 0)
            }
            if let supporting = fields.supporting {
                Text(supporting)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}
