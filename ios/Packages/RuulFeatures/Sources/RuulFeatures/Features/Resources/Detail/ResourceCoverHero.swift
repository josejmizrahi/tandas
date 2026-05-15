import SwiftUI
import RuulCore
import RuulUI

/// Cover hero for the resource detail v2. Full-bleed image (when
/// `coverImageURL` is set) OR a procedural MeshGradient fallback
/// derived from the group's category ramp. Vignette overlay at
/// bottom + white-text title/date/subtitle anchored bottom-leading.
/// Status pill anchored top-trailing.
///
/// Parallax: GeometryReader-driven scale + offset on scroll. Stretches
/// when scroll-pulled-down; compresses on scroll-up.
@MainActor
public struct ResourceCoverHero: View {
    public let title: String
    public let subtitle: String?
    public let dateLabel: String?
    public let timeLabel: String?
    public let statusPill: StatusPill?
    public let coverImageURL: URL?
    public let groupCategory: GroupCategory
    /// Explicit palette for the mesh fallback when no cover image is
    /// set. When non-nil, the cover gradient and the detail screen's
    /// ambient layer derive from the same source so the two color
    /// fields always match. When nil, falls back to `groupCategory.ramp`.
    public let palette: [Color]?
    /// Cover frame height. Lets the caller right-size the hero per
    /// resource type — events get the full poster (400pt), funds /
    /// slots / assets get a quieter 200pt stamp since they don't carry
    /// rich on-cover metadata.
    public let height: CGFloat

    public struct StatusPill: Sendable, Hashable {
        public let label: String
        public let color: Color
        public init(label: String, color: Color) {
            self.label = label
            self.color = color
        }
    }

    public init(
        title: String,
        subtitle: String? = nil,
        dateLabel: String? = nil,
        timeLabel: String? = nil,
        statusPill: StatusPill? = nil,
        coverImageURL: URL? = nil,
        groupCategory: GroupCategory,
        palette: [Color]? = nil,
        height: CGFloat = RuulSize.coverHero
    ) {
        self.title = title
        self.subtitle = subtitle
        self.dateLabel = dateLabel
        self.timeLabel = timeLabel
        self.statusPill = statusPill
        self.coverImageURL = coverImageURL
        self.groupCategory = groupCategory
        self.palette = palette
        self.height = height
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            coverContent
            vignette
            bottomOverlay
            if let pill = statusPill {
                statusPillOverlay(pill)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.hero, style: .continuous))
        .ruulElevation(.md)
        .padding(.horizontal, RuulSpacing.lg)
        .padding(.top, RuulSpacing.sm)
        .padding(.bottom, RuulSpacing.lg)
    }

    // MARK: - Cover content

    @ViewBuilder
    private var coverContent: some View {
        if let url = coverImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .empty, .failure:
                    meshFallback
                @unknown default:
                    meshFallback
                }
            }
        } else {
            meshFallback
        }
    }

    /// Procedural MeshGradient — uses the explicitly-supplied palette
    /// when provided (so the cover and the detail screen's ambient
    /// derive from the same source and always match), otherwise falls
    /// back to the group's category ramp.
    @ViewBuilder
    private var meshFallback: some View {
        if let palette, palette.count >= 4 {
            MeshGradient(
                width: 2,
                height: 2,
                points: [
                    .init(0, 0), .init(1, 0),
                    .init(0, 1), .init(1, 1)
                ],
                colors: [
                    palette[0],
                    palette[1],
                    palette[2],
                    palette[3]
                ]
            )
        } else {
            let ramp = groupCategory.ramp
            MeshGradient(
                width: 2,
                height: 2,
                points: [
                    .init(0, 0), .init(1, 0),
                    .init(0, 1), .init(1, 1)
                ],
                colors: [
                    ramp.background,
                    ramp.accent,
                    ramp.foreground,
                    ramp.accent.opacity(0.85)
                ]
            )
        }
    }

    // MARK: - Overlays

    private var vignette: some View {
        LinearGradient(
            colors: [
                Color.ruulImageVignetteMid.opacity(0),
                Color.ruulImageVignetteDeep
            ],
            startPoint: .center,
            endPoint: .bottom
        )
    }

    private func statusPillOverlay(_ pill: StatusPill) -> some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: RuulSpacing.s1) {
                    Circle()
                        .fill(Color.ruulOnImage)
                        .frame(width: 6, height: 6)
                    Text(pill.label)
                        .ruulTextStyle(RuulTypography.captionBold)
                        .foregroundStyle(Color.ruulOnImage)
                }
                .padding(.horizontal, RuulSpacing.s2)
                .padding(.vertical, 6)
                .background(Capsule().fill(pill.color.opacity(0.85)))
                .padding(.trailing, RuulSpacing.s4)
                .padding(.top, RuulSpacing.s4)
            }
            Spacer()
        }
    }

    private var bottomOverlay: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s1) {
            if let dateLabel {
                HStack(spacing: RuulSpacing.s1) {
                    Text(dateLabel)
                    if let timeLabel {
                        Text("·")
                        Text(timeLabel)
                    }
                }
                .ruulTextStyle(RuulTypography.captionBold)
                .foregroundStyle(Color.ruulOnImageSecondary)
                .textCase(.uppercase)
            }
            Text(title)
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(Color.ruulOnImage)
                .lineLimit(3)
                .shadow(color: Color.ruulImageTextShadow, radius: RuulSpacing.md, x: 0, y: 4)
            if let subtitle {
                Text(subtitle)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulOnImageSecondary)
                    .lineLimit(2)
            }
        }
        .padding(RuulSpacing.lg)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Mesh fallback — socialRecurring") {
    ResourceCoverHero(
        title: "Cena del Jueves",
        subtitle: "Hosted by Daniel · 8 going",
        dateLabel: "JUE 12 MAR",
        timeLabel: "9:00 PM",
        statusPill: .init(label: "OPEN", color: .green),
        coverImageURL: nil,
        groupCategory: .socialRecurring
    )
}

#Preview("Mesh fallback — rotatingSavings") {
    ResourceCoverHero(
        title: "Tanda Marzo",
        subtitle: "Ronda 3 de 8 · $2,400 MXN",
        dateLabel: "VIE 14 MAR",
        timeLabel: "6:00 PM",
        statusPill: .init(label: "ACTIVA", color: .blue),
        coverImageURL: nil,
        groupCategory: .rotatingSavings
    )
}

#Preview("No pill, no subtitle") {
    ResourceCoverHero(
        title: "Reunión Trimestral",
        dateLabel: "LUN 17 MAR",
        groupCategory: .professionalInformal
    )
}
#endif
