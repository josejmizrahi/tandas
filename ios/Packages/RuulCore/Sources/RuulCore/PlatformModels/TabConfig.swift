import Foundation

/// One tab in the main navigation. Loaded from `templates.config.suggestedTabs`.
/// The app reads these at boot and renders `RootShell` accordingly.
///
/// `viewType` is the discriminator the app uses to pick which view to render:
/// `dinner_home` for the template-specific home, `inbox` / `rules` /
/// `profile` for universal views.
public struct TabConfig: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let icon: String         // SF Symbol name
    public let order: Int
    public let viewType: String
    public let isUniversal: Bool

    public init(
        id: String,
        title: String,
        icon: String,
        order: Int,
        viewType: String,
        isUniversal: Bool
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.order = order
        self.viewType = viewType
        self.isUniversal = isUniversal
    }
}
