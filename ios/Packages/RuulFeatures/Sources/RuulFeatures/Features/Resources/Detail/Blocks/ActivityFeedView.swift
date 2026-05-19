import SwiftUI
import RuulCore
import RuulUI

struct ActivityFeedView: View {
    let entries: [ActivityEntry]
    let hasMore: Bool
    let onSeeMore: () -> Void

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Actividad")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextSecondary)
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
                if hasMore {
                    Button(action: onSeeMore) {
                        Text("Ver más")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(RuulSpacing.lg)
            .background(
                Color.ruulSurfaceSecondary,
                in: RoundedRectangle(cornerRadius: RuulRadius.md)
            )
        }
    }
}
