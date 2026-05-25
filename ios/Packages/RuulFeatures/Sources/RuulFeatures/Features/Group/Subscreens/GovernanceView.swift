import SwiftUI
import OSLog
import RuulUI
import RuulCore

/// Edits `groups.governance` for an existing group. Mirrors the cards in
/// `GovernanceConfigView` (founder onboarding step 6) but works on a
/// post-onboarding RuulCore.Group via `groupsRepo.updateGovernance`.
///
/// Reachable from Ajustes → "Cómo se aprueban votos" for members whose
/// permission level matches `governance.whoCanModifyGovernance`. When that
/// level is `majorityVote`, the contract is "this opens a vote", not
/// "writes directly" — V1 we still write directly; the vote-gated path
/// ships when generic vote creation UI lands (P0 #5 in audit).
public struct GovernanceView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let group: RuulCore.Group
    public var onSaved: ((RuulCore.Group) -> Void)?

    public init(group: RuulCore.Group, onSaved: ((RuulCore.Group) -> Void)?) {
        self.group = group
        self.onSaved = onSaved
    }

    @State private var rules: GovernanceRules = .recurringDinnerDefaults
    @State private var initialRules: GovernanceRules = .recurringDinnerDefaults
    @State private var isSaving: Bool = false
    @State private var error: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "groups.governance")

    public var body: some View {
        Form {
            permissionSection(
                title: "¿Quién modifica las reglas?",
                subtitle: "Cambiar montos, agregar reglas, desactivarlas.",
                selection: $rules.whoCanModifyRules,
                options: [.founder, .anyMember, .majorityVote]
            )
            permissionSection(
                title: "¿Quién inicia votaciones?",
                subtitle: "Apelar multas, proponer cambios, decisiones del grupo.",
                selection: $rules.whoCanCreateVotes,
                options: [.founder, .anyMember]
            )
            permissionSection(
                title: "¿Quién quita miembros?",
                subtitle: "Sacar a alguien del grupo.",
                selection: $rules.whoCanRemoveMembers,
                options: [.founder, .majorityVote, .supermajorityVote]
            )
            permissionSection(
                title: "¿Quién cambia esta configuración?",
                subtitle: "Quién puede editar las preguntas de esta misma página.",
                selection: $rules.whoCanModifyGovernance,
                options: [.founder, .majorityVote, .supermajorityVote]
            )

            Section {
                quorumRow
                thresholdRow
                durationRow
                anonymousToggle
            } header: {
                Text("¿Cuándo decimos que una votación pasó?")
            } footer: {
                if let error {
                    Text(error)
                        .foregroundStyle(Color.ruulNegative)
                }
            }
        }
        .navigationTitle("Cómo se aprueban votos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? "Guardando…" : "Guardar") {
                    Task { await save() }
                }
                .disabled(!hasChanges || isSaving)
            }
        }
        .onAppear { hydrate() }
    }

    private var quorumRow: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            HStack {
                Text("Mínimo de gente que debe votar")
                Spacer()
                Text("\(rules.votingQuorumPercent)%")
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(rules.votingQuorumPercent) },
                    set: { rules.votingQuorumPercent = Int($0) }
                ),
                in: 25...100,
                step: 5
            )
            Text("Si vota menos gente, la decisión no cuenta.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private var thresholdRow: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            HStack {
                Text("Cuánto necesita votar a favor")
                Spacer()
                Text("\(rules.votingThresholdPercent)%")
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(rules.votingThresholdPercent) },
                    set: { rules.votingThresholdPercent = Int($0) }
                ),
                in: 50...75,
                step: 5
            )
            Text("Porcentaje de gente que tiene que decir sí para que pase.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private var durationRow: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Stepper(
                value: $rules.votingDurationHours,
                in: 24...168,
                step: 24
            ) {
                HStack {
                    Text("Días que dura la votación")
                    Spacer()
                    let days = max(1, rules.votingDurationHours / 24)
                    Text(days == 1 ? "1 día" : "\(days) días")
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }
            }
            Text("Después de este tiempo la votación se cierra sola.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private var anonymousToggle: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Toggle("Votos anónimos", isOn: $rules.votesAreAnonymous)
            Text("Solo los conteos agregados son visibles. Recomendado.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - Helpers

    private func permissionSection(
        title: String,
        subtitle: String,
        selection: Binding<PermissionLevel>,
        options: [PermissionLevel]
    ) -> some View {
        Section {
            Picker(selection: selection) {
                ForEach(options, id: \.self) { level in
                    Text(label(for: level)).tag(level)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
        } header: {
            Text(title)
        } footer: {
            Text(subtitle)
        }
    }

    // Labels shown inside a segmented Picker — short forms required to
    // avoid truncation. The card subtitle above each picker carries the
    // longer explanation. Per Plans/Active/HumanLayerSimplification.md §C.4
    // we friendlier-up "Founder" / "Votación" / "Votación 2/3" / "Host"
    // (English + jargon leaks) without losing precision.
    private func label(for level: PermissionLevel) -> String {
        switch level {
        case .founder:           return "Fundador"
        case .anyMember:         return "Cualquiera"
        case .majorityVote:      return "Mayoría"
        case .supermajorityVote: return "Dos tercios"
        case .host:              return "Anfitrión"
        case .treasurer:         return "Tesorero"
        case .unknown(let s):    return s
        }
    }

    private var hasChanges: Bool {
        rules != initialRules
    }

    private func hydrate() {
        let current = group.effectiveGovernance
        rules = current
        initialRules = current
    }

    private func save() async {
        guard hasChanges, !isSaving else { return }
        isSaving = true
        error = nil
        defer { Task { @MainActor in isSaving = false } }
        do {
            let updated = try await app.groupsRepo.updateGovernance(groupId: group.id, rules: rules)
            await app.refreshProfileAndGroups()
            await MainActor.run {
                onSaved?(updated)
                dismiss()
            }
        } catch {
            log.warning("update governance failed: \(error.localizedDescription)")
            await MainActor.run {
                self.error = "No pudimos guardar los cambios: \(error.localizedDescription)"
            }
        }
    }
}
