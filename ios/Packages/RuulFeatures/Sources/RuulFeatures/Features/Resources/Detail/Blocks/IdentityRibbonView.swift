import SwiftUI
import RuulCore
import RuulUI

/// Universal Resource Detail — **Identity layer ribbon**.
///
/// The page's first answer to *¿qué es esto?*: icon + name + family
/// subtitle. Apple references: Wallet card top (large icon block +
/// card name), Calendar event header (icon + title), Home accessory
/// detail (large symbol + name + room).
///
/// Sized for visual weight at the top of the page so the identity
/// reads as the page anchor — icon block 56pt with a 36pt SF Symbol,
/// title at `.title.weight(.semibold)`. This sits above the StateHero
/// which carries the *what's happening now* line; together they form
/// the canonical Apple two-tier card top.
struct IdentityRibbonView: View {
    let ribbon: IdentityRibbon

    var body: some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: ribbon.icon)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(ribbon.tint.color)
                .frame(width: 56, height: 56)
                .background(
                    ribbon.tint.color.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(ribbon.title)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if !ribbon.subtitleSegments.isEmpty {
                    Text(ribbon.subtitleSegments.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
