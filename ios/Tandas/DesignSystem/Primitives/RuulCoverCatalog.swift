import SwiftUI

/// Curated catalog of programmatic event covers, Luma-style.
///
/// Each cover is a `MeshGradient` + an optional decorative shape, rendered
/// entirely in SwiftUI (no image assets). Identified by a stable string key so
/// it can be persisted to Supabase as `groups.cover_image_name` and re-rendered
/// later from the same key.
public enum RuulCoverCatalog {
    public static let all: [RuulCover] = [
        .sunset, .midnight, .citrus, .ocean, .forest,
        .candy, .ember, .lilac, .mint, .clay
    ]

    public static func cover(named name: String?) -> RuulCover {
        guard let name else { return .sunset }
        return all.first(where: { $0.id == name }) ?? .sunset
    }
}

public struct RuulCover: Identifiable, Sendable, Hashable {
    public let id: String          // persisted in Supabase
    public let palette: [Color]
    public let decoration: Decoration

    public enum Decoration: Sendable, Hashable {
        case none
        case orb(opacity: Double)
        case grid
        case rays
    }

    fileprivate init(id: String, palette: [Color], decoration: Decoration = .none) {
        self.id = id
        self.palette = palette
        self.decoration = decoration
    }
}

// MARK: - Curated covers

public extension RuulCover {
    static let sunset   = RuulCover(id: "sunset",
        palette: [hex(0xFFB199), hex(0xFF6F91), hex(0xC862FF), hex(0xFFA17F),
                  hex(0xFF6F91), hex(0xA17AFF), hex(0xFFD27A), hex(0xE65BB1), hex(0x7B5BFF)],
        decoration: .orb(opacity: 0.35))

    static let midnight = RuulCover(id: "midnight",
        palette: [hex(0x141B5C), hex(0x1F1A78), hex(0x2D1A85), hex(0x0B1140),
                  hex(0x231C8C), hex(0x3F2E9E), hex(0x070A2B), hex(0x1A1668), hex(0x4F3DC4)],
        decoration: .orb(opacity: 0.25))

    static let citrus   = RuulCover(id: "citrus",
        palette: [hex(0xFFE873), hex(0xFFAA42), hex(0xFF6B3D), hex(0xFFD94A),
                  hex(0xFFB84D), hex(0xFF7A4A), hex(0xFFC44A), hex(0xFF995C), hex(0xFFE057)],
        decoration: .rays)

    static let ocean    = RuulCover(id: "ocean",
        palette: [hex(0x2DD4BF), hex(0x06B6D4), hex(0x3B82F6), hex(0x5EEAD4),
                  hex(0x22D3EE), hex(0x60A5FA), hex(0x14B8A6), hex(0x0EA5E9), hex(0x818CF8)],
        decoration: .none)

    static let forest   = RuulCover(id: "forest",
        palette: [hex(0x10B981), hex(0x84CC16), hex(0x14B8A6), hex(0x4ADE80),
                  hex(0xA3E635), hex(0x2DD4BF), hex(0x166534), hex(0x365314), hex(0x115E59)],
        decoration: .grid)

    static let candy    = RuulCover(id: "candy",
        palette: [hex(0xFCA5A5), hex(0xF9A8D4), hex(0xC4B5FD), hex(0xFBA4C4),
                  hex(0xF0ABFC), hex(0xA5B4FC), hex(0xFB7185), hex(0xE879F9), hex(0x818CF8)],
        decoration: .orb(opacity: 0.4))

    static let ember    = RuulCover(id: "ember",
        palette: [hex(0xDC2626), hex(0xF97316), hex(0xFBBF24), hex(0xB91C1C),
                  hex(0xEA580C), hex(0xF59E0B), hex(0x991B1B), hex(0xC2410C), hex(0xCA8A04)],
        decoration: .rays)

    static let lilac    = RuulCover(id: "lilac",
        palette: [hex(0xC4B5FD), hex(0xDDD6FE), hex(0xE9D5FF), hex(0xA78BFA),
                  hex(0xC4B5FD), hex(0xD8B4FE), hex(0x8B5CF6), hex(0xA855F7), hex(0xBFA0F0)],
        decoration: .none)

    static let mint     = RuulCover(id: "mint",
        palette: [hex(0xA7F3D0), hex(0x6EE7B7), hex(0x99F6E4), hex(0x86EFAC),
                  hex(0x67E8F9), hex(0xBBF7D0), hex(0x34D399), hex(0x22D3EE), hex(0x4ADE80)],
        decoration: .grid)

    static let clay     = RuulCover(id: "clay",
        palette: [hex(0xD6BCFA), hex(0xFEC89A), hex(0xFFB4A2), hex(0xCDB4DB),
                  hex(0xFFC8A2), hex(0xFFAFCC), hex(0xB5838D), hex(0xE5989B), hex(0xFFB4A2)],
        decoration: .none)

    private static func hex(_ value: UInt32) -> Color { Color(hex: value) }
}

// MARK: - Renderable view

public struct RuulCoverView: View {
    private let cover: RuulCover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ cover: RuulCover) {
        self.cover = cover
    }

    public var body: some View {
        ZStack {
            // Apple Invites signature: a 4x4 mesh gradient that breathes
            // continuously via TimelineView. Each interior control point drifts
            // on its own sine wave so the gradient feels alive without ever
            // looking jittery. Reduce-motion users get the static center frame.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                let t = reduceMotion
                    ? 0
                    : context.date.timeIntervalSinceReferenceDate
                MeshGradient(
                    width: 4,
                    height: 4,
                    points: meshPoints(at: t),
                    colors: paddedPalette
                )
            }
            decorationLayer
        }
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
    }

    /// 4x4 = 16 control points. Corners + edge midpoints stay locked; the four
    /// interior points drift on slow phase-shifted sine waves. Amplitude is
    /// tiny (≤0.06) so the motion reads as "breathing", not "wobbling".
    private func meshPoints(at t: TimeInterval) -> [SIMD2<Float>] {
        let amp: Float = 0.06
        let speed: Float = 0.18
        let p = Float(t) * speed
        // Four interior offsets, each on a different phase so the mesh swirls.
        let dx1 = amp * sin(p);              let dy1 = amp * cos(p * 0.9)
        let dx2 = amp * cos(p * 1.1);        let dy2 = amp * sin(p * 1.2 + 1)
        let dx3 = amp * sin(p * 0.85 + 2);   let dy3 = amp * cos(p + 1.5)
        let dx4 = amp * cos(p * 1.05 + 3);   let dy4 = amp * sin(p * 0.95 + 0.5)
        return [
            .init(0, 0),                 .init(0.33, 0),                  .init(0.67, 0),                  .init(1, 0),
            .init(0, 0.33),              .init(0.33 + dx1, 0.33 + dy1),   .init(0.67 + dx2, 0.33 + dy2),   .init(1, 0.33),
            .init(0, 0.67),              .init(0.33 + dx3, 0.67 + dy3),   .init(0.67 + dx4, 0.67 + dy4),   .init(1, 0.67),
            .init(0, 1),                 .init(0.33, 1),                  .init(0.67, 1),                  .init(1, 1)
        ]
    }

    /// Curated covers ship 9 colors (matching the previous 3x3 mesh). The 4x4
    /// mesh needs 16. We tile / repeat to fill — visually identical because the
    /// gradient interpolates between adjacent points.
    private var paddedPalette: [Color] {
        let base = cover.palette
        guard base.count < 16 else { return Array(base.prefix(16)) }
        var padded = base
        while padded.count < 16 {
            padded.append(base[padded.count % base.count])
        }
        return padded
    }

    @ViewBuilder
    private var decorationLayer: some View {
        switch cover.decoration {
        case .none:
            EmptyView()
        case .orb(let opacity):
            Circle()
                .fill(Color.ruulOverlayHighlight.opacity(opacity / 0.18))
                .frame(width: 80, height: 80)
                .blur(radius: 16)
                .offset(x: 40, y: -30)
        case .grid:
            GridOverlay()
        case .rays:
            RaysOverlay()
        }
    }
}

private struct GridOverlay: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 24
            context.opacity = 0.10
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(.white), lineWidth: 0.5)
        }
    }
}

private struct RaysOverlay: View {
    var body: some View {
        Canvas { context, size in
            context.opacity = 0.18
            let center = CGPoint(x: size.width * 0.85, y: size.height * 0.15)
            for i in 0..<12 {
                let angle = Double(i) * (.pi / 6)
                let length: CGFloat = 200
                var path = Path()
                path.move(to: center)
                path.addLine(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
                context.stroke(path, with: .color(.white), lineWidth: 1.2)
            }
        }
    }
}

#if DEBUG
#Preview("RuulCoverCatalog") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: RuulSpacing.s3) {
            ForEach(RuulCoverCatalog.all) { cover in
                VStack(spacing: 4) {
                    RuulCoverView(cover)
                        .aspectRatio(16/10, contentMode: .fit)
                    Text(cover.id)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
        }
        .padding(RuulSpacing.s5)
    }
    .background(Color.ruulBackgroundCanvas)
}
#endif
