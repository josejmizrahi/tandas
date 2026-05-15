import SwiftUI

/// Single source for the visual chrome of each `ResourceType`: SF Symbol,
/// semantic color, and i18n label key. Pre-Pass-1, this lookup was
/// duplicated across ~20 `switch resource.resourceType` sites in
/// SwiftUI views — a violation of `feedback_no_hardcoded_verticals`.
///
/// Views should call `ResourceTypeChrome.resolve(resource.resourceType)`
/// and read `.symbol` / `.semanticColor` / `.labelKey` — never branch
/// on `resourceType` themselves.
public struct ResourceTypeChrome: Sendable {
    public let symbol: String
    public let semanticColor: Color
    public let labelKey: String
    /// Cover height for the resource detail hero. Events earn the full
    /// Luma-poster height (RuulSize.coverHero = 400) because they carry rich
    /// on-cover metadata. All other types use the compact hero
    /// (RuulSize.heroLarge = 240) — anything taller is dead gradient space.
    /// Hardcoded because RuulCore does not depend on RuulUI.
    public let coverHeroHeight: CGFloat

    public static func resolve(_ type: ResourceType) -> ResourceTypeChrome {
        switch type {
        case .event:
            return ResourceTypeChrome(
                symbol: "calendar",
                semanticColor: .accentColor,
                labelKey: "resource.type.event",
                coverHeroHeight: 400 // RuulSize.coverHero
            )
        case .fund:
            return ResourceTypeChrome(
                symbol: "banknote",
                semanticColor: .green,
                labelKey: "resource.type.fund",
                coverHeroHeight: 240 // RuulSize.heroLarge
            )
        case .asset:
            return ResourceTypeChrome(
                symbol: "key.fill",
                semanticColor: .orange,
                labelKey: "resource.type.asset",
                coverHeroHeight: 240 // RuulSize.heroLarge
            )
        case .space:
            return ResourceTypeChrome(
                symbol: "mappin.and.ellipse",
                semanticColor: .purple,
                labelKey: "resource.type.space",
                coverHeroHeight: 240 // RuulSize.heroLarge
            )
        case .slot:
            return ResourceTypeChrome(
                symbol: "ticket",
                semanticColor: .blue,
                labelKey: "resource.type.slot",
                coverHeroHeight: 240 // RuulSize.heroLarge
            )
        case .right:
            return ResourceTypeChrome(
                symbol: "person.badge.key.fill",
                semanticColor: .indigo,
                labelKey: "resource.type.right",
                coverHeroHeight: 240 // RuulSize.heroLarge
            )
        case .unknown:
            return ResourceTypeChrome(
                symbol: "questionmark.circle",
                semanticColor: .secondary,
                labelKey: "resource.type.unknown",
                coverHeroHeight: 240 // RuulSize.heroLarge
            )
        }
    }
}
