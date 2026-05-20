import SwiftUI
import RuulUI
import RuulCore

/// Single-member picker used by `BuilderFieldRenderer` for `.memberPicker`
/// fields (slice 8). Sibling of `MemberMultiPickerField` — same async
/// load shape, single selection.
///
/// Why a dedicated view: prior to slice 8 the renderer fell back to a
/// disabled placeholder ("Selector de miembros no disponible —
/// Próximamente") because reaching the group's member list from inside
/// the renderer required an async dependency the catch-all struct
/// couldn't host. This view owns:
///   - loading `[MemberWithProfile]` via
///     `AppState.groupsRepo.membersWithProfiles(of:)` for the active
///     group
///   - rendering a Menu-style Picker over active members
///   - writing the chosen member's `group_members.id` (NOT `user_id`)
///     into the bound `JSONConfig` as a UUID string — that's what the
///     server-side RPCs (`create_right`, `transfer_right`, etc.) gate
///     on. MemberMultiPickerField outputs `user_id` instead because
///     rotation rules walk users; the contract differs by feature.
///
/// Empty + error states render inline so the wizard step doesn't have to
/// know about them.
struct MemberPickerField: View {
    let label: String
    let helpText: String?
    @Binding var binding: JSONConfig?
    /// Optional exclusion (e.g. the current holder in a transfer flow).
    let excludedMemberId: UUID?

    @Environment(AppState.self) private var app
    /// LoadPhase-driven state replaces the legacy `@State isLoading = true`
    /// + silent-error pattern. Previously a failed `membersWithProfiles`
    /// call left the spinner stuck (silent fail); now `.failed` renders a
    /// compact inline retry row so the user can recover without bouncing
    /// out of the wizard.
    @State private var phase: LoadPhase<[MemberWithProfile]> = .idle

    init(
        label: String,
        helpText: String?,
        binding: Binding<JSONConfig?>,
        excludedMemberId: UUID? = nil
    ) {
        self.label = label
        self.helpText = helpText
        self._binding = binding
        self.excludedMemberId = excludedMemberId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.ruulTextSecondary)
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
                Text("Cargando miembros…")
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)
        case .empty:
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "person.2.slash")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Sin miembros disponibles")
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextSecondary)
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
    /// the full-screen `ErrorStateView` would dominate a picker row. Tap
    /// "Reintentar" to re-run `load()`.
    private func inlineErrorRow(_ err: CoordinatorError) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.ruulNegative)
            VStack(alignment: .leading, spacing: 2) {
                Text(err.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                if let msg = err.message {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
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
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulNegative.opacity(0.3), lineWidth: 1)
        )
    }

    private func picker(for rows: [MemberWithProfile]) -> some View {
        let visible = candidates(from: rows)
        return Picker("", selection: pickerBinding) {
            Text("Selecciona…").tag(Optional<UUID>(nil))
            ForEach(visible) { mwp in
                Text(mwp.displayName).tag(Optional(mwp.member.id))
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 1)
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

    private func candidates(from members: [MemberWithProfile]) -> [MemberWithProfile] {
        members
            .filter { $0.member.active && $0.member.id != excludedMemberId }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
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
            let loaded = try await app.groupsRepo.membersWithProfiles(of: groupId)
            let visible = candidates(from: loaded)
            await MainActor.run {
                self.phase = visible.isEmpty ? .empty : .loaded(loaded)
            }
        } catch {
            await MainActor.run {
                self.phase = .failed(
                    CoordinatorError.from(error, fallback: "No pudimos cargar los miembros"),
                    previous: nil
                )
            }
        }
    }
}
