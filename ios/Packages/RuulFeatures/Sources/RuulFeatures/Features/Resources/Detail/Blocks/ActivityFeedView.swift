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
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: RuulSpacing.sm) {
                            Text(entry.relativeTime)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .frame(width: 64, alignment: .leading)
                            Text(entry.sentence)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                        }
                    }
                }
                if hasMore {
                    Button(action: onSeeMore) {
                        Text("Ver más")
                            .font(.subheadline.weight(.semibold))
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
