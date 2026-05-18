import SwiftUI
import RuulCore
import RuulUI

/// Content of the Governance tab. Pass 1 surfaces capability management
/// (formerly behind `ManageCapabilitiesSheet`) inline plus an optional
/// archive action. Pass 2+ adds role/permission summary + rule scope
/// hierarchy preview.
///
/// Loads its own capability list on appear instead of reading from the
/// parent — keeps the tab self-contained and avoids threading caps
/// through `ResourceDetailContext`.
@MainActor
public struct GovernanceTabView: View {
    @Environment(AppState.self) private var app

    public let resource: ResourceRow
    public let onArchive: (() -> Void)?

    @State private var capabilities: [ResourceCapability] = []
    @State private var isLoading: Bool = true

    public init(
        resource: ResourceRow,
        onArchive: (() -> Void)? = nil
    ) {
        self.resource = resource
        self.onArchive = onArchive
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xl) {
            AdvancedCapabilitiesView(
                resourceId: resource.id,
                resourceType: resource.resourceType,
                enabled: capabilities.filter { $0.enabled },
                onChanged: { Task { await reload() } }
            )

            if let onArchive {
                advancedSection {
                    Button(action: onArchive) {
                        HStack(spacing: RuulSpacing.sm) {
                            Image(systemName: "archivebox")
                                .frame(width: 24)
                            Text("Archivar este recurso")
                                .ruulTextStyle(RuulTypography.body)
                            Spacer()
                        }
                        .foregroundStyle(Color.red)
                        .padding(RuulSpacing.md)
                    }
                    .buttonStyle(.plain)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                    .overlay(RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5))
                }
            }
        }
        .task { await reload() }
    }

    @ViewBuilder
    private func advancedSection<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("AVANZADO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            content()
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        capabilities = (try? await app.resourceCapabilityRepo.list(resourceId: resource.id)) ?? []
    }
}
