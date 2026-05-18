import SwiftUI
import RuulUI
import RuulCore

/// Capability management surface — enable inactive, edit configs, disable
/// enabled, cascade dependency alerts. Body extracted from
/// `ManageCapabilitiesSheet` so it can render inline inside
/// `GovernanceTabView` (no NavigationStack / ruulSheetToolbar wrapper).
///
/// The sheet wrapper still exists for legacy fullScreenCover callers but
/// post-Pass-1 the canonical entry point is the Governance tab.
@MainActor
public struct AdvancedCapabilitiesView: View {
    @Environment(AppState.self) private var app

    public let resourceId: UUID
    public let resourceType: ResourceType
    public let enabled: [ResourceCapability]
    public let onChanged: () -> Void

    @State private var pendingId: String?
    @State private var errorText: String?
    @State private var editingBlock: (block: any CapabilityBlock, config: JSONConfig)?
    @State private var cascadeDisable: CascadeContext?
    @State private var cascadeEnable: CascadeContext?

    private struct CascadeContext: Identifiable {
        let id = UUID()
        let targetId: String
        let related: [String]
    }

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

    private var enabledIds: Set<String> { Set(enabled.map { $0.capabilityBlockId }) }

    private var availableBlocks: [any CapabilityBlock] {
        CapabilityCatalog.v1.blocks(for: resourceType)
            .filter { !enabledIds.contains($0.id) }
    }

    private var enabledBlocks: [(block: any CapabilityBlock, row: ResourceCapability)] {
        enabled.compactMap { row in
            guard let block = CapabilityCatalog.v1.byId[row.capabilityBlockId] else { return nil }
            return (block, row)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xl) {
            if !enabledBlocks.isEmpty {
                section(title: "ACTIVAS") {
                    VStack(spacing: 0) {
                        ForEach(enabledBlocks, id: \.block.id) { item in
                            enabledRow(block: item.block, row: item.row)
                            if item.block.id != enabledBlocks.last?.block.id {
                                Divider().background(Color.ruulSeparator).padding(.leading, 56)
                            }
                        }
                    }
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                    .overlay(RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5))
                }
            }
            if !availableBlocks.isEmpty {
                section(title: "DISPONIBLES") {
                    VStack(spacing: 0) {
                        ForEach(availableBlocks, id: \.id) { block in
                            availableRow(block)
                            if block.id != availableBlocks.last?.id {
                                Divider().background(Color.ruulSeparator).padding(.leading, 56)
                            }
                        }
                    }
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                    .overlay(RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5))
                }
            }
            if let errorText {
                Text(errorText)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulNegative)
            }
        }
        .fullScreenCover(item: editingBinding) { ctx in
            EditCapabilityConfigSheet(
                resourceId: resourceId,
                block: ctx.block,
                initialConfig: ctx.config,
                onSaved: {
                    editingBlock = nil
                    onChanged()
                }
            )
            .environment(app)
        }
        .alert(
            "Esto desactivará también:",
            isPresented: disableAlertBinding,
            presenting: cascadeDisable
        ) { ctx in
            Button("Desactivar todas", role: .destructive) {
                Task { await disableCascade(ctx.targetId, dependents: ctx.related) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { ctx in
            Text(ctx.related.compactMap { CapabilityCatalog.v1.byId[$0]?.displayName }.joined(separator: ", "))
        }
        .alert(
            "Activar también:",
            isPresented: enableAlertBinding,
            presenting: cascadeEnable
        ) { ctx in
            Button("Activar todas") {
                Task { await enableCascade(ctx.targetId, missing: ctx.related) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { ctx in
            Text(ctx.related.compactMap { CapabilityCatalog.v1.byId[$0]?.displayName }.joined(separator: ", "))
        }
    }

    @ViewBuilder
    private func enabledRow(block: any CapabilityBlock, row: ResourceCapability) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.ruulPositive)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.displayName)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(block.summary)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Menu {
                if !block.optionalFields.isEmpty || !block.requiredFields.isEmpty {
                    Button("Editar configuración", systemImage: "slider.horizontal.3") {
                        editingBlock = (block, row.config)
                    }
                }
                Button("Desactivar", systemImage: "minus.circle", role: .destructive) {
                    let resolver = CapabilityDependencyResolver()
                    let blockers = resolver.dependents(of: block.id, in: enabledIds)
                    if blockers.isEmpty {
                        Task { await disable(block.id) }
                    } else {
                        cascadeDisable = CascadeContext(targetId: block.id, related: blockers)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .ruulTextStyle(RuulTypography.subheadMedium)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .disabled(pendingId != nil)
        }
        .padding(RuulSpacing.md)
        .opacity(pendingId == block.id ? 0.4 : 1.0)
    }

    @ViewBuilder
    private func availableRow(_ block: any CapabilityBlock) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: "circle")
                .foregroundStyle(Color.ruulTextTertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.displayName)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(block.summary)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                let resolver = CapabilityDependencyResolver()
                let missing = resolver.missingDependencies(of: block.id, in: enabledIds)
                if missing.isEmpty {
                    Task { await enable(block.id) }
                } else {
                    cascadeEnable = CascadeContext(targetId: block.id, related: missing)
                }
            } label: {
                Text("Activar")
                    .ruulTextStyle(RuulTypography.captionBold)
                    .foregroundStyle(Color.ruulAccent)
            }
            .buttonStyle(.plain)
            .disabled(pendingId != nil)
        }
        .padding(RuulSpacing.md)
        .opacity(pendingId == block.id ? 0.4 : 1.0)
    }

    private var disableAlertBinding: Binding<Bool> {
        Binding(get: { cascadeDisable != nil }, set: { if !$0 { cascadeDisable = nil } })
    }

    private var enableAlertBinding: Binding<Bool> {
        Binding(get: { cascadeEnable != nil }, set: { if !$0 { cascadeEnable = nil } })
    }

    private func disableCascade(_ targetId: String, dependents: [String]) async {
        pendingId = targetId
        errorText = nil
        defer { pendingId = nil }
        do {
            for id in dependents {
                try await app.resourceCapabilityRepo.disable(id, on: resourceId)
            }
            try await app.resourceCapabilityRepo.disable(targetId, on: resourceId)
            onChanged()
        } catch {
            errorText = "No pudimos desactivar todas las capabilities."
        }
    }

    private func enableCascade(_ targetId: String, missing: [String]) async {
        pendingId = targetId
        errorText = nil
        defer { pendingId = nil }
        do {
            for id in missing {
                _ = try await app.resourceCapabilityRepo.enable(id, on: resourceId, config: .empty)
            }
            _ = try await app.resourceCapabilityRepo.enable(targetId, on: resourceId, config: .empty)
            onChanged()
        } catch {
            errorText = "No pudimos activar todas las capabilities."
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            content()
        }
    }

    private var editingBinding: Binding<EditingContext?> {
        Binding(
            get: {
                guard let e = editingBlock else { return nil }
                return EditingContext(block: e.block, config: e.config)
            },
            set: { new in
                if new == nil { editingBlock = nil }
            }
        )
    }

    private func enable(_ blockId: String) async {
        pendingId = blockId
        errorText = nil
        defer { pendingId = nil }
        do {
            _ = try await app.resourceCapabilityRepo.enable(blockId, on: resourceId, config: .empty)
            onChanged()
        } catch {
            errorText = "No pudimos activar esta capability."
        }
    }

    private func disable(_ blockId: String) async {
        pendingId = blockId
        errorText = nil
        defer { pendingId = nil }
        do {
            try await app.resourceCapabilityRepo.disable(blockId, on: resourceId)
            onChanged()
        } catch {
            errorText = "No pudimos desactivar esta capability."
        }
    }
}

/// Wraps the editing context so `fullScreenCover(item:)` can drive it.
private struct EditingContext: Identifiable {
    let block: any CapabilityBlock
    let config: JSONConfig

    var id: String { block.id }
}
