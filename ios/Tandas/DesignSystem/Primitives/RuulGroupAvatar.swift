import SwiftUI
import RuulUI

/// Avatar del **grupo**. Usa color ramp automático per `Group.category`.
/// Distinto de `RuulPersonAvatar` (que es de un miembro). Per DS v3 §3.11.
///
/// Hasta que Fase 2 agregue `category`/`initials`/`avatarURL` al model
/// `Group`, este componente acepta la categoría como parámetro explícito y
/// deriva iniciales del nombre. Cuando Fase 2 land, se simplifica a tomar
/// solo `Group`.
public struct RuulGroupAvatar: View {
    public enum Size: Sendable, Hashable {
        case xs, sm, md, lg, xl

        var dimension: CGFloat {
            switch self {
            case .xs: return 20
            case .sm: return 24
            case .md: return 32
            case .lg: return 40
            case .xl: return 56
            }
        }
        var fontSize: CGFloat {
            switch self {
            case .xs: return 9
            case .sm: return 11
            case .md: return 12
            case .lg: return 14
            case .xl: return 18
            }
        }
    }

    private let groupName: String
    private let initials: String
    private let category: GroupCategory
    private let imageURL: URL?
    private let size: Size

    /// Init explícito (compatible con `Group` model actual sin `category` field).
    public init(
        groupName: String,
        initials: String? = nil,
        category: GroupCategory,
        imageURL: URL? = nil,
        size: Size = .md
    ) {
        self.groupName = groupName
        self.initials = initials ?? Self.derivedInitials(from: groupName)
        self.category = category
        self.imageURL = imageURL
        self.size = size
    }

    public var body: some View {
        let ramp = category.ramp

        ZStack {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: placeholder(ramp: ramp)
                    }
                }
            } else {
                placeholder(ramp: ramp)
            }
        }
        .frame(width: size.dimension, height: size.dimension)
        .clipShape(Circle())
    }

    private func placeholder(ramp: GroupColorRamp) -> some View {
        ZStack {
            Circle().fill(ramp.background)
            Text(initials)
                .font(.system(size: size.fontSize, weight: .semibold))
                .foregroundStyle(ramp.foreground)
        }
    }

    /// Deriva iniciales 1-2 chars desde el nombre (primera letra de las
    /// primeras 2 palabras significativas). Ignora artículos comunes.
    static func derivedInitials(from name: String) -> String {
        let stopwords: Set<String> = ["el", "la", "los", "las", "de", "del", "y"]
        let words = name
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty && !stopwords.contains($0.lowercased()) }
            .prefix(2)
        let initials = words.compactMap { $0.first.map(String.init) }.joined()
        return initials.uppercased()
    }
}

#if DEBUG
#Preview("RuulGroupAvatar") {
    VStack(spacing: RuulSpacing.md) {
        HStack(spacing: RuulSpacing.sm) {
            RuulGroupAvatar(groupName: "Cena del Jueves", category: .socialRecurring, size: .xs)
            RuulGroupAvatar(groupName: "Cena del Jueves", category: .socialRecurring, size: .sm)
            RuulGroupAvatar(groupName: "Cena del Jueves", category: .socialRecurring, size: .md)
            RuulGroupAvatar(groupName: "Cena del Jueves", category: .socialRecurring, size: .lg)
            RuulGroupAvatar(groupName: "Cena del Jueves", category: .socialRecurring, size: .xl)
        }
        VStack(spacing: RuulSpacing.xs) {
            ForEach(GroupCategory.allCases, id: \.self) { cat in
                HStack(spacing: RuulSpacing.sm) {
                    RuulGroupAvatar(groupName: cat.displayName, category: cat, size: .lg)
                    Text(cat.displayName).font(.ruulCaption)
                    Spacer()
                }
            }
        }
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
