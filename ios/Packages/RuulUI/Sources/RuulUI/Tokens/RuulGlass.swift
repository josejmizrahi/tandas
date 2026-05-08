import SwiftUI

/// Glass material tokens.
///
/// Used by the `.ruulGlass(...)` modifier (defined in
/// `Modifiers/GlassEffect+Ruul.swift`) to apply iOS 26 Liquid Glass with
/// optional tint and interactivity, with a graceful fallback when the user
/// has reduce-transparency enabled.
public enum GlassMaterial: Sendable {
    case thin
    case regular
    case thick
}

/// Where the glass is being used. Currently informational, but reserved so we
/// can tune tint per context later (e.g. navbar glass might want a slightly
/// stronger tint than card glass).
public enum GlassContext: Sendable {
    case button
    case card
    case overlay
    case navbar
}
