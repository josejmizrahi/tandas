import SwiftUI

/// Avatar primitive. Loads a remote image, falls back to gradient + initials.
public struct RuulAvatar: View {
    public enum Size: Sendable, Hashable {
        case xs, small, medium, large, hero

        var diameter: CGFloat {
            switch self {
            case .xs:     return 24
            case .small:  return 32
            case .medium: return 40
            case .large:  return 56
            case .hero:   return 80
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .xs:     return 10
            case .small:  return 13
            case .medium: return 16
            case .large:  return 22
            case .hero:   return 32
            }
        }
    }

    public enum BorderStyle: Sendable, Hashable {
        case none
        case glass
        case accent
        case success
    }

    private let name: String
    private let imageURL: URL?
    private let size: Size
    private let border: BorderStyle

    public init(name: String, imageURL: URL? = nil, size: Size = .medium, border: BorderStyle = .none) {
        self.name = name
        self.imageURL = imageURL
        self.size = size
        self.border = border
    }

    public var body: some View {
        ZStack {
            if let url = imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .clipShape(Circle())
        .overlay(borderOverlay)
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials)
                .font(.system(size: size.fontSize, weight: .semibold))
                .foregroundStyle(Color.ruulTextInverse)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        switch border {
        case .none:
            EmptyView()
        case .glass:
            Circle().stroke(Color.ruulBorderGlass, lineWidth: 2)
        case .accent:
            Circle().stroke(Color.ruulAccentPrimary, lineWidth: 2)
        case .success:
            Circle().stroke(Color.ruulSemanticSuccess, lineWidth: 2)
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// Deterministic gradient seeded by name — same name always renders the
    /// same gradient, but different names get visually distinct ones.
    private var gradientColors: [Color] {
        let palette: [(Color, Color)] = [
            (.init(hex: 0x5B6CFF), .init(hex: 0x8B5CF6)),
            (.init(hex: 0x10B981), .init(hex: 0x06B6D4)),
            (.init(hex: 0xF59E0B), .init(hex: 0xEF4444)),
            (.init(hex: 0xEC4899), .init(hex: 0x8B5CF6)),
            (.init(hex: 0x3B82F6), .init(hex: 0x06B6D4)),
            (.init(hex: 0x14B8A6), .init(hex: 0x10B981)),
            (.init(hex: 0xF97316), .init(hex: 0xEC4899)),
            (.init(hex: 0x6366F1), .init(hex: 0x3B82F6))
        ]
        let hash = abs(name.hashValue) % palette.count
        return [palette[hash].0, palette[hash].1]
    }
}

#if DEBUG
#Preview("RuulAvatar") {
    VStack(spacing: RuulSpacing.s4) {
        HStack(spacing: RuulSpacing.s3) {
            RuulAvatar(name: "Jose Mizrahi", size: .xs)
            RuulAvatar(name: "Jose Mizrahi", size: .small)
            RuulAvatar(name: "Jose Mizrahi", size: .medium)
            RuulAvatar(name: "Jose Mizrahi", size: .large)
            RuulAvatar(name: "Jose Mizrahi", size: .hero)
        }
        HStack(spacing: RuulSpacing.s3) {
            RuulAvatar(name: "Ana Cohen", size: .large, border: .glass)
            RuulAvatar(name: "Ben Levi", size: .large, border: .accent)
            RuulAvatar(name: "Carla Roth", size: .large, border: .success)
        }
        HStack(spacing: RuulSpacing.s3) {
            ForEach(["Ana", "Ben", "Carla", "David", "Eli", "Fer"], id: \.self) { n in
                RuulAvatar(name: n, size: .medium)
            }
        }
    }
    .padding(RuulSpacing.s5)
    .background(Color.ruulBackgroundCanvas)
}
#endif
