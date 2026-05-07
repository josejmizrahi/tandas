import SwiftUI

/// Bloque 6 — onboarding step where the founder configures who can do
/// what in the group. Inserted between InitialRulesView (step 5) and
/// InviteMembersView (step 7). Skippable: defaults from the template
/// (backfilled by migration 00019) apply if user taps "Usar defaults".
struct GovernanceConfigView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var rules: GovernanceRules = .recurringDinnerDefaults

    var body: some View {
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.allCases.count,
            title: "Cómo se gobierna",
            subtitle: "Quién decide qué. Puedes cambiarlo después en Reglas.",
            primaryCTA: ("Continuar", coord.isLoading, { Task { await coord.advanceFromGovernance(rules: rules) } }),
            secondaryCTA: ("Usar defaults", { Task { await coord.skipGovernance() } }),
            canContinue: true
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                modifyRulesCard
                createVotesCard
                votingConfigCard
            }
        }
        .onAppear {
            // Seed the form from existing governance if the founder backed
            // out + returned. Otherwise template defaults already apply.
            if let existing = coord.createdGroup?.governance {
                rules = existing
            }
        }
    }

    // MARK: - Section 1: who can modify rules

    private var modifyRulesCard: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("¿Quién modifica las reglas?")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Quién puede cambiar montos, agregar reglas, o desactivarlas.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                permissionPicker(selection: $rules.whoCanModifyRules,
                                  options: [.founder, .anyMember, .majorityVote])
            }
        }
    }

    // MARK: - Section 2: who can create votes

    private var createVotesCard: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("¿Quién inicia votaciones?")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Quién puede abrir una votación: apelar multas, cambiar reglas, etc.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                permissionPicker(selection: $rules.whoCanCreateVotes,
                                  options: [.founder, .anyMember])
            }
        }
    }

    // MARK: - Section 3: voting configuration

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

    private func permissionPicker(
        selection: Binding<PermissionLevel>,
        options: [PermissionLevel]
    ) -> some View {
        Picker(selection: selection) {
            ForEach(options, id: \.self) { level in
                Text(label(for: level)).tag(level)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
    }

    private func label(for level: PermissionLevel) -> String {
        switch level {
        case .founder:           return "Solo founder"
        case .anyMember:         return "Cualquiera"
        case .majorityVote:      return "Votación"
        case .supermajorityVote: return "Votación 2/3"
        case .host:              return "Solo host"
        case .treasurer:         return "Tesorero"
        case .unknown(let s):    return s
        }
    }

    private var progressValue: Double {
        Double(FounderStep.governance.index) / Double(FounderStep.allCases.count - 1)
    }
}
