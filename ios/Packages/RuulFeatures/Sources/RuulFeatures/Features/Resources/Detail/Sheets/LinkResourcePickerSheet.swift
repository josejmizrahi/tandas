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

    /// LoadPhase-driven state replaces the legacy `hasLoaded + silent error
    /// folded into errorText`. Previously a failed `resourceRepo.list` set
    /// `errorText` to a generic string but the user couldn't retry without
    /// dismissing the sheet; now `.failed` surfaces a proper retry button.
    /// `loadError` stays separate from `errorText` (link failures still
    /// flow through `errorText` since the sheet body is loaded).
    @State private var loadPhase: LoadPhase<[ResourceRow]> = .idle
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
            AsyncContentView(
                phase: loadPhase,
                onRetry: { await loadCandidates(force: true) },
                empty: { emptyScrollContainer },
                loaded: { rows in loadedScrollContainer(rows) }
            )
            .task { await loadCandidates() }
            .ruulSheetToolbar("Vincular recurso")
        }
    }

    // MARK: - Candidate filtering

    private func pickable(from rows: [ResourceRow]) -> [ResourceRow] {
        rows
            .filter { !alreadyLinkedIds.contains($0.id) }
            .sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
    }

    /// Shared scroll container so empty + loaded share the same chrome
    /// (header copy + padding). Keeps the user oriented when the picker
    /// flips between "no candidates" and "1 candidate" mid-session.
    private var emptyScrollContainer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                headerCopy
                emptyState
                inlineSubmitError
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.xxl)
        }
    }

    private func loadedScrollContainer(_ rows: [ResourceRow]) -> some View {
        let visible = pickable(from: rows)
        return ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                headerCopy
                if visible.isEmpty {
                    // Server returned rows but every one of them is already
                    // linked to this event — still an "empty" UX (nothing
                    // to do), but the AsyncContentView didn't trigger
                    // `.empty` because the raw list isn't empty.
                    emptyState
                } else {
                    VStack(spacing: RuulSpacing.xs) {
                        ForEach(visible) { row in
                            resourceRow(row)
                        }
                    }
                }
                inlineSubmitError
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.xxl)
        }
    }

    /// Inline error for `link()` failures — distinct from the full-screen
    /// `ContentUnavailableView` that `AsyncContentView` shows when the
    /// initial candidate fetch fails.
    @ViewBuilder
    private var inlineSubmitError: some View {
        if let errorText {
            Text(errorText)
                .font(.caption)
                .foregroundStyle(Color.red)
                .padding(.horizontal, RuulSpacing.xxs)
        }
    }

    // MARK: - Subviews

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("¿Qué usa este evento?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("Vincula un espacio, asset, fondo o derecho que se coordine durante este evento.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
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
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ruulAccent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(row))
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(row.resourceType.humanLabel)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.ruulAccent)
            }
            .padding(RuulSpacing.md)
            .background(
                Color.ruulBackgroundCanvas,
                in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
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
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            VStack(spacing: RuulSpacing.xs) {
                Text("Nada que vincular aún")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text("Crea un espacio, asset o fondo en el grupo y vuelve para vincularlo a este evento.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func loadCandidates(force: Bool = false) async {
        // Avoid re-running the request when the sheet body re-evaluates
        // unless the caller explicitly forces a retry from the error UI.
        if !force, case .loaded = loadPhase { return }
        if !force, case .refreshing = loadPhase { return }
        await MainActor.run { self.loadPhase = .loading }
        do {
            let rows = try await app.resourceRepo.list(
                in: groupId,
                types: Self.pickableTypes,
                statuses: nil,
                limit: 200
            )
            await MainActor.run {
                self.loadPhase = rows.isEmpty ? .empty : .loaded(rows)
            }
        } catch {
            await MainActor.run {
                self.loadPhase = .failed(
                    CoordinatorError.from(error, fallback: "No pudimos cargar los recursos del grupo"),
                    previous: nil
                )
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
