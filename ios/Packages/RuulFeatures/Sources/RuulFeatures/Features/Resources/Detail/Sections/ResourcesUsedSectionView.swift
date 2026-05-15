import SwiftUI
import RuulCore
import RuulUI

/// Renders the list of resources an event currently uses
/// (Plans/Active/EventResource.md §12: "event puede usar
/// spaces/assets/funds. El event NO posee esos resources. Los coordina
/// temporalmente.").
///
/// Reads `resource_links` (mig 00198) via `AppState.resourceLinkRepo`,
/// resolves each link's `to_resource_id` against `AppState.resourceRepo`
/// to get the human-readable title + type. Hidden when the optional
/// `resourceLinkRepo` isn't wired (mock/preview without the repo) or the
/// resource isn't an event.
///
/// Read-only in v1: lists active links with an unlink action per row.
/// Attach UI (picker over the group's space/asset/fund/right resources)
/// lands in a follow-up; the empty state surfaces a stub button to make
/// the affordance discoverable.
public struct ResourcesUsedSectionView: View {
    @Environment(AppState.self) private var app
    public let context: ResourceDetailContext

    @State private var links: [ResourceLink] = []
    @State private var targetsById: [UUID: ResourceRow] = [:]
    @State private var hasLoaded: Bool = false
    @State private var isMutating: Bool = false
    @State private var errorMessage: String?

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            sectionHeader("RECURSOS", count: links.isEmpty ? nil : links.count)
            content
        }
        .task { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if links.isEmpty && hasLoaded {
            emptyState
        } else if !links.isEmpty {
            VStack(spacing: RuulSpacing.xs) {
                ForEach(links) { link in
                    linkRow(link)
                }
            }
            .cardBackground()
        } else {
            // Initial load — placeholder so the section's height is
            // stable while the network round-trip completes.
            EmptyView()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        HStack(spacing: RuulSpacing.sm) {
            iconBadge(systemName: "link")
            VStack(alignment: .leading, spacing: 2) {
                Text("Sin recursos vinculados")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Vincula un espacio, asset o fondo que use este evento.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    @ViewBuilder
    private func linkRow(_ link: ResourceLink) -> some View {
        let target = targetsById[link.toResourceId]
        HStack(spacing: RuulSpacing.sm) {
            iconBadge(systemName: iconForType(target?.resourceType))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: target, fallbackId: link.toResourceId))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text(typeLabel(target?.resourceType))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await unlink(link.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .ruulTextStyle(RuulTypography.subheadSemibold)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .buttonStyle(.plain)
            .disabled(isMutating)
            .accessibilityLabel("Quitar \(displayName(for: target, fallbackId: link.toResourceId))")
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    // MARK: - Data

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        guard let repo = app.resourceLinkRepo else {
            hasLoaded = true
            return
        }
        do {
            let rows = try await repo.listActiveUses(for: context.resource.id)
            var targets: [UUID: ResourceRow] = [:]
            for row in rows {
                if let r = try? await app.resourceRepo.resource(row.toResourceId) {
                    targets[row.toResourceId] = r
                }
            }
            await MainActor.run {
                self.links = rows
                self.targetsById = targets
                self.hasLoaded = true
            }
        } catch {
            await MainActor.run {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "No se pudieron cargar los recursos vinculados."
                self.hasLoaded = true
            }
        }
    }

    private func unlink(_ linkId: UUID) async {
        guard let repo = app.resourceLinkRepo else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await repo.unlink(linkId)
            await MainActor.run {
                self.links.removeAll { $0.id == linkId }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "No se pudo desvincular el recurso."
            }
        }
    }

    // MARK: - Presentation helpers

    private func displayName(for target: ResourceRow?, fallbackId: UUID) -> String {
        guard let target else { return "Recurso" }
        if case .string(let title)? = target.metadata["title"], !title.isEmpty { return title }
        if case .string(let name)? = target.metadata["name"], !name.isEmpty { return name }
        return target.resourceType.rawString.capitalized
    }

    private func typeLabel(_ type: ResourceType?) -> String {
        switch type {
        case .space:        return "Espacio"
        case .asset:        return "Asset"
        case .fund:         return "Fondo"
        case .right:        return "Derecho"
        case .event, .slot: return "Recurso"
        case .unknown:      return "Recurso"
        case .none:         return "Recurso"
        }
    }

    private func iconForType(_ type: ResourceType?) -> String {
        switch type {
        case .space:        return "mappin.and.ellipse"
        case .asset:        return "shippingbox"
        case .fund:         return "banknote"
        case .right:        return "key"
        case .event, .slot: return "cube"
        case .unknown:      return "cube"
        case .none:         return "cube"
        }
    }

    private func iconBadge(systemName: String) -> some View {
        ZStack {
            Circle().fill(Color.ruulAccent.opacity(0.15)).frame(width: 36, height: 36)
            Image(systemName: systemName)
                .ruulTextStyle(RuulTypography.subheadSemibold)
                .foregroundStyle(Color.ruulAccent)
        }
    }
}
