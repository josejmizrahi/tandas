import SwiftUI
import OSLog
import RuulUI
import RuulCore

/// Edits `groups.governance` for an existing group. Mirrors the cards in
/// `GovernanceConfigView` (founder onboarding step 6) but works on a
/// post-onboarding RuulCore.Group via `groupsRepo.updateGovernance`.
///
/// Reachable from `GroupInfoSheet` "Editar gobierno" for members whose
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
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                modifyRulesCard
                createVotesCard
                removeMembersCard
                modifyGovernanceCard
                votingConfigCard
                if let error {
                    Text(error)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulNegative)
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.xxl)
        }
        .ruulAmbientScreen(palette: nil)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                RuulCloseToolbarButton { dismiss() }
            }
            ToolbarItem(placement: .principal) {
                Text("Gobierno")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? "Guardando…" : "Guardar") {
                    Task { await save() }
                }
                .foregroundStyle(hasChanges ? Color.ruulAccent : Color.ruulTextTertiary)
                .disabled(!hasChanges || isSaving)
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        .onAppear { hydrate() }
    }

    // MARK: - Cards

    private var modifyRulesCard: some View {
        permissionCard(
            title: "¿Quién modifica las reglas?",
            subtitle: "Cambiar montos, agregar reglas, desactivarlas.",
            selection: $rules.whoCanModifyRules,
            options: [.founder, .anyMember, .majorityVote]
        )
    }

    private var createVotesCard: some View {
        permissionCard(
            title: "¿Quién inicia votaciones?",
            subtitle: "Apelar multas, proponer cambios, decisiones del grupo.",
            selection: $rules.whoCanCreateVotes,
            options: [.founder, .anyMember]
        )
    }

    private var removeMembersCard: some View {
        permissionCard(
            title: "¿Quién quita miembros?",
            subtitle: "Sacar a alguien del grupo.",
            selection: $rules.whoCanRemoveMembers,
            options: [.founder, .majorityVote, .supermajorityVote]
        )
    }

    private var modifyGovernanceCard: some View {
        permissionCard(
            title: "¿Quién cambia este gobierno?",
            subtitle: "Quién puede editar las preguntas de esta misma página.",
            selection: $rules.whoCanModifyGovernance,
            options: [.founder, .majorityVote, .supermajorityVote]
        )
    }

    private var votingConfigCard: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                Text("Configuración de votación")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)

                quorumRow
                thresholdRow
                durationRow
                anonymousToggle
            }
        }
    }

    private var quorumRow: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            HStack {
                Text("Quórum")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
                Text("\(rules.votingQuorumPercent)%")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextAccent)
            }
            Slider(
                value: Binding(
                    get: { Double(rules.votingQuorumPercent) },
                    set: { rules.votingQuorumPercent = Int($0) }
                ),
                in: 25...100,
                step: 5
            )
            .tint(Color.ruulAccent)
            Text("Mínimo del grupo que debe votar para que la votación cuente.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private var thresholdRow: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            HStack {
                Text("Mayoría requerida")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
                Text("\(rules.votingThresholdPercent)%")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextAccent)
            }
            Slider(
                value: Binding(
                    get: { Double(rules.votingThresholdPercent) },
                    set: { rules.votingThresholdPercent = Int($0) }
                ),
                in: 50...75,
                step: 5
            )
            .tint(Color.ruulAccent)
            Text("% de votos a favor para aprobar.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private var durationRow: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            HStack {
                Text("Duración")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
                Stepper("\(rules.votingDurationHours) hrs",
                        value: $rules.votingDurationHours,
                        in: 24...168,
                        step: 24)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextAccent)
            }
            Text("Cuánto tiempo está abierta una votación antes de cerrarse.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private var anonymousToggle: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Toggle(isOn: $rules.votesAreAnonymous) {
                Text("Votos anónimos")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .tint(Color.ruulAccent)
            Text("Solo los conteos agregados son visibles. Recomendado.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    // MARK: - Helpers

    private func permissionCard(
        title: String,
        subtitle: String,
        selection: Binding<PermissionLevel>,
        options: [PermissionLevel]
    ) -> some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text(title)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(subtitle)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                Picker(selection: selection) {
                    ForEach(options, id: \.self) { level in
                        Text(label(for: level)).tag(level)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func label(for level: PermissionLevel) -> String {
        switch level {
        case .founder:           return "Founder"
        case .anyMember:         return "Cualquiera"
        case .majorityVote:      return "Votación"
        case .supermajorityVote: return "Votación 2/3"
        case .host:              return "Host"
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
