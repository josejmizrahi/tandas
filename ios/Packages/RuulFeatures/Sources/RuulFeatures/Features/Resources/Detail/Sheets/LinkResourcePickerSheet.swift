import SwiftUI
import RuulCore
import RuulUI

/// Picker that attaches a space/asset/fund/right to the current event
/// via `link_resource_to_event` (mig 00198, Plans/Active/EventResource.md
/// §12). Lists every group resource of the four target types that
/// isn't already actively linked to the event; tapping a row links and
/// dismisses.
///
/// Caller passes the event id, the group id (to scope the listing), and
/// the set of currently-linked target ids so we can hide them. `onLinked`
/// fires after a successful RPC so the section can refresh.
public struct LinkResourcePickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let eventId: UUID
    public let groupId: UUID
    public let alreadyLinkedIds: Set<UUID>
    public let onLinked: (UUID) -> Void

    @State private var candidates: [ResourceRow] = []
    @State private var hasLoaded: Bool = false
    @State private var submittingId: UUID?
    @State private var errorText: String?

    private static let pickableTypes: [ResourceType] = [.space, .asset, .fund, .right]

    public init(
        eventId: UUID,
        groupId: UUID,
        alreadyLinkedIds: Set<UUID>,
        onLinked: @escaping (UUID) -> Void
    ) {
        self.eventId = eventId
        self.groupId = groupId
        self.alreadyLinkedIds = alreadyLinkedIds
        self.onLinked = onLinked
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    headerCopy
                    if hasLoaded && pickable.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: RuulSpacing.xs) {
                            ForEach(pickable) { row in
                                resourceRow(row)
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
            .ruulAmbientScreen(palette: nil)
            .task { await loadCandidates() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("Vincular recurso")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        }
    }

    // MARK: - Candidate filtering

    private var pickable: [ResourceRow] {
        candidates
            .filter { !alreadyLinkedIds.contains($0.id) }
            .sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
    }

    // MARK: - Subviews

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("¿Qué usa este evento?")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Vincula un espacio, asset, fondo o derecho que se coordine durante este evento.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(.top, RuulSpacing.xs)
    }

    private func resourceRow(_ row: ResourceRow) -> some View {
        Button {
            Task { await link(row) }
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulAccent.opacity(0.15))
                        .frame(width: 40, height: 40)
                    if submittingId == row.id {
                        ProgressView()
                    } else {
                        Image(systemName: iconFor(row.resourceType))
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                            .foregroundStyle(Color.ruulAccent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(row))
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(1)
                    Text(row.resourceType.humanLabel)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .ruulTextStyle(RuulTypography.calloutBold)
                    .foregroundStyle(Color.ruulAccent)
            }
            .padding(RuulSpacing.md)
            .background(
                Color.ruulBackgroundCanvas,
                in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
            )
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
                Image(systemName: "link.badge.plus")
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            VStack(spacing: RuulSpacing.xs) {
                Text("Nada que vincular aún")
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Crea un espacio, asset o fondo en el grupo y vuelve para vincularlo a este evento.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func loadCandidates() async {
        guard !hasLoaded else { return }
        do {
            let rows = try await app.resourceRepo.list(
                in: groupId,
                types: Self.pickableTypes,
                statuses: nil,
                limit: 200
            )
            await MainActor.run {
                self.candidates = rows
                self.hasLoaded = true
            }
        } catch {
            await MainActor.run {
                self.errorText = "No pudimos cargar los recursos del grupo."
                self.hasLoaded = true
            }
        }
    }

    private func link(_ row: ResourceRow) async {
        guard let repo = app.resourceLinkRepo else {
            errorText = "Función no disponible en esta sesión."
            return
        }
        submittingId = row.id
        errorText = nil
        do {
            _ = try await repo.link(event: eventId, uses: row.id)
            onLinked(row.id)
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription
                ?? "No pudimos vincular \(displayName(row))."
        }
        submittingId = nil
    }

    // MARK: - Display

    private func displayName(_ row: ResourceRow) -> String {
        if case .string(let title)? = row.metadata["title"], !title.isEmpty { return title }
        if case .string(let name)? = row.metadata["name"], !name.isEmpty { return name }
        return row.resourceType.humanLabel
    }

    private func iconFor(_ type: ResourceType) -> String {
        switch type {
        case .space:  return "mappin.and.ellipse"
        case .asset:  return "shippingbox"
        case .fund:   return "banknote"
        case .right:  return "key"
        case .event, .slot, .unknown:
            return "cube"
        }
    }
}
