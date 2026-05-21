import SwiftUI
import RuulUI
import RuulCore

/// Single-resource picker for `BuilderField.resourcePicker` (slice 9).
/// Sibling of `MemberPickerField` — same async-load shape, picks one
/// `ResourceRow` from the active group.
///
/// Why a dedicated view: prior to slice 9 the renderer fell back to
/// "Selector de recurso no disponible — Próximamente" for any field
/// declared as `.resourcePicker` (SlotResourceBuilder's `assetId`,
/// RightResourceBuilder's optional `targetResourceId`, etc.). Asking
/// the user to paste a UUID was hostile UX; this view loads the
/// group's resources and lets them tap-to-select.
///
/// Output contract: writes the chosen resource's `id` (UUID) into the
/// bound `JSONConfig` as a string. The wizard's server-side
/// `build_resource_from_draft` reads `basic_fields->>'<key>'` and
/// casts to UUID — matching that contract for every consumer.
///
/// Type filtering: deferred. `BuilderField` doesn't yet carry a
/// `validResourceTypes` hint, so the picker lists all non-archived
/// resources in the active group. A consumer that wants narrower
/// scoping (e.g. SlotResourceBuilder needing only assets) should
/// either filter the results post-hoc or wait for the field-hint
/// extension. Most consumers today have small enough resource
/// inventories that the flat list works.
struct ResourcePickerField: View {
    let label: String
    let helpText: String?
    @Binding var binding: JSONConfig?

    @Environment(AppState.self) private var app
    /// LoadPhase-driven state replaces the legacy `@State isLoading = true`
    /// + silent-error pattern. Previously a failed query left the spinner
    /// stuck forever (silent fail in production); now `.failed` renders a
    /// compact inline retry row so the user can recover without bouncing
    /// out of the sheet.
    @State private var phase: LoadPhase<[ResourceRow]> = .idle

    init(
        label: String,
        helpText: String?,
        binding: Binding<JSONConfig?>
    ) {
        self.label = label
        self.helpText = helpText
        self._binding = binding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            content
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            HStack(spacing: RuulSpacing.sm) {
                ProgressView()
                Text("Cargando recursos…")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)
        case .empty:
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "tray")
                    .foregroundStyle(Color(.tertiaryLabel))
                Text("Aún no hay recursos en este grupo.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)
        case .failed(let err, _):
            inlineErrorRow(err)
        case .loaded(let rows), .refreshing(let rows):
            picker(for: rows)
        }
    }

    /// Compact inline error replacement for the spinner. Sheet-friendly —
    /// the full-screen `ContentUnavailableView` would dominate a picker
    /// row. Tap "Reintentar" to re-run `load()`.
    private func inlineErrorRow(_ err: CoordinatorError) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(err.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                if let msg = err.message {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button("Reintentar") { Task { await load() } }
                .font(.footnote)
                .foregroundStyle(Color.ruulAccent)
        }
        .padding(RuulSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    private func picker(for rows: [ResourceRow]) -> some View {
        let visible = filteredAndSorted(rows)
        return Picker("", selection: pickerBinding) {
            Text("Selecciona…").tag(Optional<UUID>(nil))
            ForEach(visible) { row in
                Text(displayName(row)).tag(Optional(row.id))
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }

    // MARK: - Picker bridging

    private var pickerBinding: Binding<UUID?> {
        Binding(
            get: {
                guard case let .string(raw)? = binding else { return nil }
                return UUID(uuidString: raw)
            },
            set: { newValue in
                if let uuid = newValue {
                    binding = .string(uuid.uuidString.lowercased())
                } else {
                    binding = nil
                }
            }
        )
    }

    /// Filters out archived rows and sorts alphabetically. Pulled out of
    /// the body so both `.loaded` and `.refreshing` reuse it.
    private func filteredAndSorted(_ rows: [ResourceRow]) -> [ResourceRow] {
        rows
            .filter { $0.archivedAt == nil }
            .sorted { lhs, rhs in
                displayName(lhs).localizedCaseInsensitiveCompare(displayName(rhs)) == .orderedAscending
            }
    }

    /// Fallback chain: metadata.name → metadata.title → resource type
    /// human label. Matches the same convention used elsewhere
    /// (LinkResourcePickerSheet, ResourceTitleBlock).
    private func displayName(_ row: ResourceRow) -> String {
        if case .string(let s)? = row.metadata["name"], !s.isEmpty { return s }
        if case .string(let s)? = row.metadata["title"], !s.isEmpty { return s }
        return row.resourceType.humanLabel
    }

    // MARK: - Load

    private func load() async {
        guard let groupId = app.activeGroupId else {
            // No active group → treat as empty (not a failure).
            await MainActor.run { self.phase = .empty }
            return
        }
        await MainActor.run { self.phase = .loading }
        do {
            // ResourceRepository.list takes a non-nullable `types` array,
            // so we pass the canonical six. A future BuilderField hint
            // (`validResourceTypes`) would let the picker narrow this
            // per consumer (e.g. SlotResourceBuilder needing only assets).
            let rows = try await app.resourceRepo.list(
                in: groupId,
                types: ResourceType.allCases,
                statuses: nil,
                limit: 200
            )
            let visible = filteredAndSorted(rows)
            await MainActor.run {
                self.phase = visible.isEmpty ? .empty : .loaded(rows)
            }
        } catch {
            await MainActor.run {
                self.phase = .failed(
                    CoordinatorError.from(error, fallback: "No pudimos cargar los recursos"),
                    previous: nil
                )
            }
        }
    }
}
