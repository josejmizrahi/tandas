import SwiftUI

/// Generic data shape for a member row. Patterns receive this struct rather
/// than the product's `Member` model so the design system stays decoupled.
public struct MemberRowData: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let subtitle: String?
    public let avatarURL: URL?
    public let metaText: String?

    public init(id: String, name: String, subtitle: String? = nil, avatarURL: URL? = nil, metaText: String? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.avatarURL = avatarURL
        self.metaText = metaText
    }
}

/// Standard member row: avatar + name + subtitle + meta + optional trailing
/// action.
public struct MemberRowStub: View {
    private let data: MemberRowData
    private let trailingIcon: String?
    private let action: (() -> Void)?

    public init(_ data: MemberRowData, trailingIcon: String? = nil, action: (() -> Void)? = nil) {
        self.data = data
        self.trailingIcon = trailingIcon
        self.action = action
    }

    public var body: some View {
        HStack(spacing: RuulSpacing.s3) {
            RuulAvatar(name: data.name, imageURL: data.avatarURL, size: .medium)
            VStack(alignment: .leading, spacing: 2) {
                Text(data.name)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let subtitle = data.subtitle {
                    Text(subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Spacer()
            if let metaText = data.metaText {
                Text(metaText)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            if let trailingIcon, action != nil {
                Image(systemName: trailingIcon)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
        .padding(RuulSpacing.s4)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}

#if DEBUG
#Preview("MemberRowStub") {
    VStack(spacing: 0) {
        MemberRowStub(.init(id: "1", name: "Jose Mizrahi", subtitle: "admin", metaText: "$240"))
        Divider()
        MemberRowStub(.init(id: "2", name: "Ana Cohen", subtitle: "miembro", metaText: "$0"), trailingIcon: "chevron.right") {}
        Divider()
        MemberRowStub(.init(id: "3", name: "Ben Levi", subtitle: "miembro · grace", metaText: "—"))
    }
    .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
    .padding(RuulSpacing.s5)
    .background(Color.ruulBackgroundCanvas)
}
#endif
