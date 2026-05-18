import SwiftUI
import RuulUI
import RuulCore

/// Sheet wrapper around `AdvancedCapabilitiesView`. Pass-1 deprecated as
/// a primary entry point — the canonical surface is the Governance tab
/// embedding `AdvancedCapabilitiesView` directly. Retained for legacy
/// callers (none expected post-Pass-1 cleanup).
public struct ManageCapabilitiesSheet: View {
    @Environment(AppState.self) private var app

    public let resourceId: UUID
    public let resourceType: ResourceType
    public let enabled: [ResourceCapability]
    public let onChanged: () -> Void

    public init(
        resourceId: UUID,
        resourceType: ResourceType,
        enabled: [ResourceCapability],
        onChanged: @escaping () -> Void
    ) {
        self.resourceId = resourceId
        self.resourceType = resourceType
        self.enabled = enabled
        self.onChanged = onChanged
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                AdvancedCapabilitiesView(
                    resourceId: resourceId,
                    resourceType: resourceType,
                    enabled: enabled,
                    onChanged: onChanged
                )
                .environment(app)
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .ruulSheetToolbar("Capabilities")
        }
    }
}
