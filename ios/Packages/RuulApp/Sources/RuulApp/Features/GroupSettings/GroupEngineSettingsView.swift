import SwiftUI
import RuulCore

/// V3-D.17 — surface that makes the Rule Engine visible, controllable
/// and explainable to founders/admins.
///
/// Four sections (locked):
///   1. Estado            — engine on/off, last evaluation, 24h counts.
///   2. Activación        — kill switch (Engine Enabled toggle).
///   3. Cuota             — read-only D.17 (window + max).
///   4. Salud             — emitted / failed / rate-limited + light.
///
/// State is held locally; no new Store. Repository (CanonicalRule-
/// EvaluationsRepository) is injected via the DependencyContainer.
struct GroupEngineSettingsView: View {
    let container: DependencyContainer
    let groupId: UUID
    /// Caller hands a pre-computed permission set. Gating happens before
    /// presenting this view (the row in GroupSettingsView is hidden when
    /// the user lacks `engine.toggle`), but the kill switch itself
    /// double-checks so a stale-permission session can't fire the RPC.
    let canToggle: Bool

    @State private var summary: GroupRuleEngineSummary?
    @State private var quota: GroupRuleEngineQuota?
    @State private var phase: LoadPhase = .loading
    @State private var errorMessage: String?
    @State private var togglePending: Bool = false
    @State private var toggleError: UserFacingError?
    @State private var pendingTargetActive: Bool?

    enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed
    }

    var body: some View {
        List {
            switch phase {
            case .loading:
                Section { ProgressView() }
            case .failed:
                Section {
                    ContentUnavailableView {
                        Label("No pudimos cargar el motor", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage ?? "Reintenta en un momento.")
                    } actions: {
                        Button("Reintentar") { Task { await load() } }
                    }
                }
            case .loaded:
                statusSection
                activationSection
                quotaSection
                healthSection
            }
        }
        .navigationTitle("Motor de reglas")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(
            toggleError?.title ?? "",
            isPresented: Binding(
                get: { toggleError != nil },
                set: { if !$0 { toggleError = nil } }
            ),
            actions: { Button("OK") { toggleError = nil } },
            message: { Text(toggleError?.message ?? "") }
        )
    }

    // MARK: - 1. Estado

    @ViewBuilder
    private var statusSection: some View {
        let s = summary
        Section("Estado") {
            HStack {
                Label("Motor", systemImage: "gearshape.2")
                Spacer()
                if let active = s?.engineActive {
                    Text(active ? "Activo" : "Apagado")
                        .foregroundStyle(active ? .green : .secondary)
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Evaluaciones (24h)") {
                Text("\(s?.totalEvaluations ?? 0)")
            }
            LabeledContent("Coincidieron") {
                Text("\(s?.matchedCount ?? 0)")
            }
            LabeledContent("Consecuencias emitidas") {
                Text("\(s?.emittedActionsCount ?? 0)")
            }
        }
    }

    // MARK: - 2. Activación (kill switch)

    @ViewBuilder
    private var activationSection: some View {
        Section {
            if canToggle, let active = summary?.engineActive {
                Toggle(
                    isOn: Binding(
                        get: { pendingTargetActive ?? active },
                        set: { newValue in
                            Task { await toggle(to: newValue) }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Motor activado")
                        if !active {
                            Text("Las reglas dejarán de ejecutarse hasta volver a activar el motor.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(togglePending)
            } else if let active = summary?.engineActive {
                LabeledContent(
                    "Motor activado",
                    value: active ? "Activo" : "Apagado"
                )
            }
        } header: {
            Text("Activación")
        } footer: {
            if !canToggle {
                Text("Solo los administradores con permiso engine.toggle pueden activar o desactivar el motor.")
            }
        }
    }

    // MARK: - 3. Cuota (read-only)

    @ViewBuilder
    private var quotaSection: some View {
        Section {
            LabeledContent("Evaluaciones por ventana") {
                Text("\(quota?.maxEvalsPerWindow ?? 60)")
            }
            LabeledContent("Duración de la ventana") {
                Text("\((quota?.windowSeconds ?? 60))s")
            }
        } header: {
            Text("Cuota")
        } footer: {
            Text("La cuota es de solo lectura por ahora.")
        }
    }

    // MARK: - 4. Salud

    @ViewBuilder
    private var healthSection: some View {
        Section {
            HStack(spacing: 10) {
                healthDot
                Text(healthLabel)
                    .font(.subheadline.weight(.medium))
            }
            LabeledContent("Emitidas") {
                Text("\(summary?.emittedActionsCount ?? 0)")
            }
            LabeledContent("Fallidas") {
                Text("\(summary?.failedActionsCount ?? 0)")
                    .foregroundStyle((summary?.failedActionsCount ?? 0) > 0 ? .red : .primary)
            }
            LabeledContent("Limitadas por cuota") {
                Text("\(summary?.rateLimitedCount ?? 0)")
                    .foregroundStyle((summary?.rateLimitedCount ?? 0) > 0 ? .orange : .primary)
            }
        } header: {
            Text("Salud")
        }
    }

    private var healthDot: some View {
        Circle().fill(healthColor).frame(width: 10, height: 10)
    }

    private var healthColor: Color {
        switch summary?.health {
        case .red:    return .red
        case .yellow: return .orange
        case .green:  return .green
        case .none:   return .secondary
        }
    }

    private var healthLabel: String {
        switch summary?.health {
        case .red:    return "Hay consecuencias fallidas"
        case .yellow:
            if let s = summary, !s.engineActive { return "Motor apagado" }
            return "Cuota afectando ejecuciones"
        case .green:  return "Todo en orden"
        case .none:   return "Sin datos"
        }
    }

    // MARK: - Loading

    private func load() async {
        if summary == nil { phase = .loading }
        do {
            let since = Date().addingTimeInterval(-24 * 60 * 60)
            async let summaryTask = container.ruleEvaluationsRepository.engineSummary(
                groupId: groupId, since: since
            )
            async let quotaTask = container.ruleEvaluationsRepository.engineQuota(
                groupId: groupId
            )
            self.summary = try await summaryTask
            self.quota = try await quotaTask
            self.phase = .loaded
        } catch {
            self.errorMessage = UserFacingError.from(error).message
            self.phase = .failed
        }
    }

    // MARK: - Toggle

    private func toggle(to newValue: Bool) async {
        guard canToggle else { return }
        guard !togglePending else { return }
        togglePending = true
        pendingTargetActive = newValue
        defer {
            togglePending = false
            pendingTargetActive = nil
        }
        do {
            let result = try await container.ruleEvaluationsRepository.setEngineActive(
                groupId: groupId, active: newValue
            )
            // Reflect server truth into the local summary so the toggle
            // stays consistent with what the engine will actually do on
            // the next event.
            if var current = summary {
                summary = GroupRuleEngineSummary(
                    groupId: current.groupId,
                    since: current.since,
                    engineActive: result.engineActive,
                    totalEvaluations: current.totalEvaluations,
                    matchedCount: current.matchedCount,
                    unmatchedCount: current.unmatchedCount,
                    emittedActionsCount: current.emittedActionsCount,
                    failedActionsCount: current.failedActionsCount,
                    evaluationsByTrigger: current.evaluationsByTrigger,
                    actionsByConsequenceKind: current.actionsByConsequenceKind,
                    engineSkippedBreakdown: current.engineSkippedBreakdown
                )
                _ = current
            }
        } catch {
            toggleError = UserFacingError.from(error)
        }
    }
}
