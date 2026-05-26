import SwiftUI

/// Declarative action surfaced in `EmptyGroupHero` when a group has no
/// situational signal yet. Each entry describes ONE coordination verb
/// that the group can exercise from day 1 without activating modules.
///
/// Scalability: when a new universal primitive lands (e.g. a future
/// "position" resource type, or a new wallet flow), the caller adds an
/// `EmptyStateAction` to the list passed into `EmptyGroupHero`. The hero
/// renders them in a wrap-friendly grid; nothing else changes.
///
/// Doctrine (audit 2026-05-26):
///   The base verbs every Ruul group has from day 1 — independent of
///   `active_modules`, templates, or governance presets — are:
///     1. Invitar gente            (primary)
///     2. Crear evento             (create_event_v2)
///     3. Coordinar dinero          (shared pool seeded at group create)
///     4. Tomar una decisión        (start_vote, always universal)
///     5. Definir reglas            (create_initial_rule)
///     6. Crear recurso (asset/    (build_resource_from_draft, create_asset)
///        space/right)
///
/// Only #1 is a primary CTA (the group is dead without people). The rest
/// render as a chip strip under the hero copy.
@MainActor
public struct EmptyStateAction: Identifiable {
    public let id: String
    public let label: String
    public let systemImage: String
    public let handler: () -> Void

    public init(
        id: String,
        label: String,
        systemImage: String,
        handler: @escaping () -> Void
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.handler = handler
    }
}
