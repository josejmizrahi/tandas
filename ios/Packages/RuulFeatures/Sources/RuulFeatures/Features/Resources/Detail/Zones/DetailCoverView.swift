import SwiftUI
import RuulUI
import RuulCore

/// Cover hero for the polymorphic resource detail. Renders the image
/// (or animated gradient fallback) full-bleed with classic stretch +
/// parallax behavior driven by the enclosing scroll offset.
///
/// The view is meant to be the first child of the detail's ScrollView,
/// followed by a content panel that pulls up under the cover via an
/// `UnevenRoundedRectangle`. The cover height stays constant; pulling
/// the scroll down adds stretch, pushing it up moves the cover at half
/// speed for parallax.
///
/// Honors `\.accessibilityReduceMotion` — stretch + parallax collapse to
/// a static cover for reduce-motion users.
public struct DetailCoverView: View {
    public let imageURL: URL?
    public let fallbackCoverName: String?
    public let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        imageURL: URL?,
        fallbackCoverName: String? = nil,
        height: CGFloat = 380
    ) {
        self.imageURL = imageURL
        self.fallbackCoverName = fallbackCoverName
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .global).minY
            let stretch = reduceMotion ? 0 : max(0, minY)
            let parallax = reduceMotion ? 0 : max(0, -minY / 2)
            ZStack(alignment: .bottom) {
                cover
                    .frame(width: geo.size.width, height: height + stretch)
                    .clipped()
                    .offset(y: -stretch + parallax)
                    .accessibilityHidden(true)

                LinearGradient(
                    colors: [.clear, Color.ruulImageBadge],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
                .offset(y: -stretch + parallax)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private var cover: some View {
        if let imageURL {
            AsyncImage(url: imageURL, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .empty, .failure:
                    fallbackCover
                @unknown default:
                    fallbackCover
                }
            }
        } else {
            fallbackCover
        }
    }

    private var fallbackCover: some View {
        // RuulCoverView itself clips with a rounded corner; at hero size
        // the clipping is visually invisible because we additionally clip
        // the ZStack via `.clipped()`. Passing the catalog through keeps
        // the fallback consistent with EventRow / EventCard.
        RuulCoverView(RuulCoverCatalog.cover(named: fallbackCoverName))
    }
}

// MARK: - Previews

#Preview("With image URL") {
    DetailCoverView(
        imageURL: URL(string: "https://images.unsplash.com/photo-1530103862676-de8c9debad1d"),
        fallbackCoverName: "sunset"
    )
}

#Preview("Fallback only") {
    DetailCoverView(imageURL: nil, fallbackCoverName: "ocean")
}
