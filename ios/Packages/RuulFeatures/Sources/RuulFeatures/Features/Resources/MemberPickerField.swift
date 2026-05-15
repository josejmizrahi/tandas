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
    @State private var members: [MemberWithProfile] = []
    @State private var isLoading: Bool = true

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
        } else if candidates.isEmpty {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "person.2.slash")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Sin miembros disponibles")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)
        } else {
            Picker("", selection: pickerBinding) {
                Text("Selecciona…").tag(Optional<UUID>(nil))
                ForEach(candidates) { mwp in
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

    private var candidates: [MemberWithProfile] {
        members
            .filter { $0.member.active && $0.member.id != excludedMemberId }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    // MARK: - Load

    private func load() async {
        guard let groupId = app.activeGroupId else {
            isLoading = false
            return
        }
        do {
            let loaded = try await app.groupsRepo.membersWithProfiles(of: groupId)
            await MainActor.run {
                self.members = loaded
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
