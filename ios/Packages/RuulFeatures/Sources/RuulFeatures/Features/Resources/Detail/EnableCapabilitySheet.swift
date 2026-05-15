import SwiftUI
import RuulUI
import RuulCore

/// Picker for "activar otra capability" on a Resource. Lists every block
/// in `CapabilityCatalog.v1` that:
///   - declares this resource's type in `enabledResourceTypes`, AND
///   - isn't already enabled on the resource.
///
/// Tap a row → writes a `resource_capabilities` row via
/// `ResourceCapabilityRepository.enable(blockId, on:, config: .empty)`,
/// fires `onEnabled` so the parent refreshes its enabled set, and
/// dismisses the sheet.
///
/// Founder framing 2026-05-10: this is the affordance that makes the
/// resource page evolve over time. "Cena simple" → add RSVP → add
/// expenses → add host rotation → add rules. The detail composes
/// itself from whatever rows live in `resource_capabilities`.
public struct EnableCapabilitySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let resourceId: UUID
    public let resourceType: ResourceType
    public let alreadyEnabled: Set<String>
    public let onEnabled: (String) -> Void

    @State private var submittingId: String?
    @State private var errorText: String?

    public init(
        resourceId: UUID,
        resourceType: ResourceType,
        alreadyEnabled: Set<String>,
        onEnabled: @escaping (String) -> Void
    ) {
        self.resourceId = resourceId
        self.resourceType = resourceType
        self.alreadyEnabled = alreadyEnabled
        self.onEnabled = onEnabled
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    headerCopy
                    if availableBlocks.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: RuulSpacing.xs) {
                            ForEach(availableBlocks, id: \.id) { block in
                                blockRow(block)
                            }
                        }
                    }
                    if let errorText {
                        Text(errorText)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulNegative)
                            .padding(.horizontal, RuulSpacing.xxs)
                    }
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.xxl)
            }
            .ruulAmbientScreen(palette: app.activeGroup?.ambientPalette)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("Activar función")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        }
    }

    // MARK: - Available blocks

    /// Blocks that apply to this resource type and aren't already on.
    /// Sorted by displayName so the picker reads alphabetically.
    private var availableBlocks: [any CapabilityBlock] {
        CapabilityCatalog.v1.blocks
            .filter { $0.enabledResourceTypes.contains(resourceType) }
            .filter { !alreadyEnabled.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Subviews

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Agrega una función")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("La página del recurso crecerá con la función nueva activada — sin volver a crearlo.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(.top, RuulSpacing.xs)
    }

    private func blockRow(_ block: any CapabilityBlock) -> some View {
        Button {
            Task { await enable(block) }
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulAccent.opacity(0.15))
                        .frame(width: 40, height: 40)
                    if submittingId == block.id {
                        ProgressView()
                    } else {
                        Image(systemName: iconFor(block.id))
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                            .foregroundStyle(Color.ruulAccent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.displayName)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(block.summary)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .ruulTextStyle(RuulTypography.calloutBold)
                    .foregroundStyle(Color.ruulAccent)
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(submittingId != nil)
    }

    private var emptyState: some View {
        VStack(spacing: RuulSpacing.lg) {
            Spacer(minLength: RuulSpacing.xl)
            ZStack {
                Circle().fill(Color.ruulSurface).frame(width: 72, height: 72)
                Image(systemName: "sparkles")
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            VStack(spacing: RuulSpacing.xs) {
                Text("Ya tienes todo")
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Este recurso ya tiene activadas todas las funciones disponibles para su tipo.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func enable(_ block: any CapabilityBlock) async {
        submittingId = block.id
        errorText = nil
        do {
            _ = try await app.resourceCapabilityRepo.enable(
                block.id,
                on: resourceId,
                config: .object([:])
            )
            onEnabled(block.id)
            dismiss()
        } catch {
            errorText = "No pudimos activar \(block.displayName). Intenta de nuevo."
        }
        submittingId = nil
    }

    // MARK: - Display

    /// SF Symbol fallback per capability id. Matches the icons used by
    /// the dynamic-section renderers so visual identity stays stable.
    private func iconFor(_ id: String) -> String {
        switch id {
        case "rsvp":           return "checkmark.circle.fill"
        case "check_in":       return "qrcode"
        case "schedule":       return "calendar"
        case "recurrence":     return "arrow.triangle.2.circlepath"
        case "rotation":       return "person.2.arrow.trianglehead.counterclockwise"
        case "rotating_host":  return "person.2.arrow.trianglehead.counterclockwise"
        case "assignment":     return "checkmark.square"
        case "attendance":     return "list.bullet.clipboard"
        case "participants":   return "person.3"
        case "money":          return "arrow.left.arrow.right"
        case "expenses":       return "cart.fill"
        case "contributions":  return "arrow.up.bin.fill"
        case "payouts":        return "tray.and.arrow.down.fill"
        case "rules":          return "list.bullet.clipboard.fill"
        case "voting":         return "hand.raised.fill"
        case "guests":         return "person.crop.circle.badge.plus"
        case "booking":        return "calendar.badge.checkmark"
        default:               return "square.dashed"
        }
    }
}
