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

    public static func resolve(_ type: ResourceType) -> ResourceTypeChrome {
        switch type {
        case .event:
            return ResourceTypeChrome(
                symbol: "calendar",
                semanticColor: .accentColor,
                labelKey: "resource.type.event"
            )
        case .fund:
            return ResourceTypeChrome(
                symbol: "banknote",
                semanticColor: .green,
                labelKey: "resource.type.fund"
            )
        case .asset:
            return ResourceTypeChrome(
                symbol: "key.fill",
                semanticColor: .orange,
                labelKey: "resource.type.asset"
            )
        case .space:
            return ResourceTypeChrome(
                symbol: "mappin.and.ellipse",
                semanticColor: .purple,
                labelKey: "resource.type.space"
            )
        case .slot:
            return ResourceTypeChrome(
                symbol: "ticket",
                semanticColor: .blue,
                labelKey: "resource.type.slot"
            )
        case .right:
            return ResourceTypeChrome(
                symbol: "person.badge.key.fill",
                semanticColor: .indigo,
                labelKey: "resource.type.right"
            )
        case .unknown:
            return ResourceTypeChrome(
                symbol: "questionmark.circle",
                semanticColor: .secondary,
                labelKey: "resource.type.unknown"
            )
        }
    }
}
