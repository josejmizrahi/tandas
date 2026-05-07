import SwiftUI

/// DS doc canonical names mapped to existing implementations. The legacy
/// `EmptyStateView` / `ErrorStateView` / `RuulAvatar` APIs continue to work
/// unchanged. If the DS doc API diverges further, Fase D performs the hard
/// migration.
public typealias RuulEmptyState = EmptyStateView
public typealias RuulErrorState = ErrorStateView
public typealias RuulAvatarView = RuulAvatar
