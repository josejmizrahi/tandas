import SwiftUI
import RuulUI
import RuulCore

/// Member multi-picker used by `BuilderFieldRenderer` when a `.multiPicker`
/// field's key signals "members" (Tier 5: rotation's `participants` field).
///
/// Why a dedicated view: a multi-picker over the active group's members
/// requires async load + ordered output, neither of which fits cleanly
/// inside the catch-all renderer struct. This view owns:
///   - loading `[MemberWithProfile]` for the active group via
///     `AppState.groupsRepo.membersWithProfiles(of:)`
///   - rendering one toggle row per member
///   - preserving user-chosen selection ORDER in the bound `[String]`
///     (next_host_for_series walks `participants[(cycle-1) % count]`,
///     so alphabetical reshuffling would silently change rotation order)
///   - supporting exclusions: tapping an already-selected row toggles
///     it OUT, removing the user_id from the array
///
/// Implementation contract:
///   - The bound value is the canonical source of truth. The view
///     never owns a separate copy of selected user_ids.
///   - When the user taps an unselected row, the user_id is appended
///     to the end of the bound array → that becomes the next slot in
///     the rotation order.
///   - When the user taps a selected row, the user_id is removed and
///     the remaining members shift up by one. Their relative order is
///     preserved.
///   - Members not yet in the bound array are rendered alphabetically
///     below the selected set. Adding one preserves the prefix order
///     of the already-selected members.
struct MemberMultiPickerField: View {
    let label: String
    let helpText: String?
    @Binding var binding: [String]

    @Environment(AppState.self) private var app
    /// LoadPhase-driven state replaces the legacy `@State isLoading = true`
    /// + silent-error pattern. Previously a failed `membersWithProfiles`
    /// call left the spinner stuck (silent fail in production); now
    /// `.failed` renders a compact inline retry row so the user can
    /// recover the rotation builder without bouncing out of the wizard.
    @State private var phase: LoadPhase<[MemberWithProfile]> = .idle

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
                Text("Este grupo no tiene miembros para rotar")
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)
        case .failed(let err, _):
            inlineErrorRow(err)
        case .loaded(let members), .refreshing(let members):
            loadedBody(members: members)
        }
    }

    /// Compact inline error replacement for the spinner. Sheet-friendly —
    /// the full-screen `ErrorStateView` would dominate a rotation builder
    /// step. Tap "Reintentar" to re-run `load()`.
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

    @ViewBuilder
    private func loadedBody(members: [MemberWithProfile]) -> some View {
        VStack(spacing: 1) {
            ForEach(displayOrder(from: members), id: \.id) { entry in
                row(for: entry)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 1)
        )
        if !binding.isEmpty {
            Text("Rotación: \(binding.count) miembros en este orden")
                .font(.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }

    @ViewBuilder
    private func row(for entry: DisplayEntry) -> some View {
        let isSelected = entry.position != nil
        Button {
            toggle(entry.member.member.userId)
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                if let pos = entry.position {
                    Text("\(pos + 1)")
                        .font(.caption)
                        .foregroundStyle(Color.ruulTextInverse)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.ruulAccent))
                } else {
                    Circle()
                        .stroke(Color.ruulSeparator, lineWidth: 1)
                        .frame(width: 22, height: 22)
                }
                Text(entry.member.displayName)
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.ruulAccent : Color.ruulTextTertiary)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: - Display + ordering

    private struct DisplayEntry: Identifiable {
        let id: UUID
        let member: MemberWithProfile
        /// nil = not selected; otherwise zero-based position in rotation order.
        let position: Int?
    }

    /// Compute the rendered order: selected members in rotation order
    /// (top), then unselected members alphabetized (bottom). Members in
    /// the bound list whose user_id no longer matches a known member
    /// (e.g. member left the group after series was created) are dropped
    /// from display — but stay in the bound array if still encoded
    /// there; the caller / SQL layer (replacementPolicy=skip_to_next)
    /// handles that case.
    private func displayOrder(from members: [MemberWithProfile]) -> [DisplayEntry] {
        let memberById: [UUID: MemberWithProfile] = Dictionary(
            uniqueKeysWithValues: members.map { ($0.member.userId, $0) }
        )

        var entries: [DisplayEntry] = []
        var includedIds = Set<UUID>()

        for (idx, raw) in binding.enumerated() {
            guard let uid = UUID(uuidString: raw), let m = memberById[uid] else { continue }
            entries.append(DisplayEntry(id: uid, member: m, position: idx))
            includedIds.insert(uid)
        }

        let unselected = members
            .filter { !includedIds.contains($0.member.userId) }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        for m in unselected {
            entries.append(DisplayEntry(id: m.member.userId, member: m, position: nil))
        }
        return entries
    }

    private func toggle(_ userId: UUID) {
        let raw = userId.uuidString.lowercased()
        if let idx = binding.firstIndex(of: raw) {
            binding.remove(at: idx)
        } else {
            binding.append(raw)
        }
    }

    private func load() async {
        guard let groupId = app.activeGroupId else {
            // No active group → treat as empty (not a failure).
            await MainActor.run { self.phase = .empty }
            return
        }
        await MainActor.run { self.phase = .loading }
        do {
            let loaded = try await app.groupsRepo.membersWithProfiles(of: groupId)
            let active = loaded.filter { $0.member.active }
            await MainActor.run {
                self.phase = active.isEmpty ? .empty : .loaded(active)
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
