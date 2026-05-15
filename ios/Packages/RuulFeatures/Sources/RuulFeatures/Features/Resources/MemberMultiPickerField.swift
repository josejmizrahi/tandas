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
    @State private var members: [MemberWithProfile] = []
    @State private var isLoading: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(label)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
            content
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: RuulSpacing.sm) {
                ProgressView()
                Text("Cargando miembros…")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)
        } else if members.isEmpty {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "person.2.slash")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Este grupo no tiene miembros para rotar")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)
        } else {
            VStack(spacing: 1) {
                ForEach(displayOrder, id: \.id) { entry in
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
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
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
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextInverse)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.ruulAccent))
                } else {
                    Circle()
                        .stroke(Color.ruulSeparator, lineWidth: 1)
                        .frame(width: 22, height: 22)
                }
                Text(entry.member.displayName)
                    .ruulTextStyle(RuulTypography.body)
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
    private var displayOrder: [DisplayEntry] {
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
            isLoading = false
            return
        }
        do {
            let loaded = try await app.groupsRepo.membersWithProfiles(of: groupId)
            await MainActor.run {
                self.members = loaded.filter { $0.member.active }
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.members = []
                self.isLoading = false
            }
        }
    }
}
