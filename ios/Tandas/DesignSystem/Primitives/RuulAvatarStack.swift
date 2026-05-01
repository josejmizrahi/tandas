import SwiftUI

/// Overlapping avatars with overflow indicator. Wraps participants in a
/// `GlassEffectContainer` so the blur is consistent across multiple glass
/// borders.
public struct RuulAvatarStack: View {
    /// Generic data shape for the stack — does NOT import any model from the
    /// product. Callers pass simple records.
    public struct Person: Identifiable, Sendable, Hashable {
        public let id: String
        public let name: String
        public let imageURL: URL?

        public init(id: String, name: String, imageURL: URL? = nil) {
            self.id = id
            self.name = name
            self.imageURL = imageURL
        }
    }

    private let people: [Person]
    private let size: RuulAvatar.Size
    private let maxVisible: Int

    public init(people: [Person], size: RuulAvatar.Size = .medium, maxVisible: Int = 5) {
        self.people = people
        self.size = size
        self.maxVisible = maxVisible
    }

    public var body: some View {
        GlassEffectContainer(spacing: -overlap) {
            HStack(spacing: -overlap) {
                ForEach(visiblePeople) { person in
                    RuulAvatar(name: person.name, imageURL: person.imageURL, size: size, border: .glass)
                }
                if overflowCount > 0 {
                    overflowBadge
                }
            }
        }
    }

    private var visiblePeople: [Person] {
        Array(people.prefix(maxVisible))
    }

    private var overflowCount: Int {
        max(0, people.count - maxVisible)
    }

    private var overflowBadge: some View {
        Text("+\(overflowCount)")
            .font(.system(size: size.fontSize, weight: .semibold))
            .foregroundStyle(Color.ruulTextPrimary)
            .frame(width: size.diameter, height: size.diameter)
            .ruulGlass(Circle(), material: .regular)
            .overlay(Circle().stroke(Color.ruulBorderGlass, lineWidth: 2))
    }

    private var overlap: CGFloat {
        size.diameter * 0.30
    }
}

#if DEBUG
#Preview("RuulAvatarStack") {
    let crowd = (1...12).map { i in
        RuulAvatarStack.Person(id: "\(i)", name: "Person \(i)")
    }
    return VStack(spacing: RuulSpacing.s5) {
        RuulAvatarStack(people: Array(crowd.prefix(3)))
        RuulAvatarStack(people: Array(crowd.prefix(5)))
        RuulAvatarStack(people: crowd, maxVisible: 5)
        RuulAvatarStack(people: crowd, size: .large, maxVisible: 4)
        RuulAvatarStack(people: Array(crowd.prefix(4)), size: .small)
    }
    .padding(RuulSpacing.s5)
    .background(Color.ruulBackgroundCanvas)
}
#endif
