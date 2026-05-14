import SwiftUI
import RuulUI
import RuulCore

/// Resource Detail section that surfaces rotation state — only renders
/// when the resource's series carries a rotation capability_config.
///
/// Read-only display (Tier 5 Beta): next host, upcoming hosts (preview
/// of 3), rotation order in declared participant order, and a one-line
/// policy summary. Editing rotation comes via the wizard / settings
/// sheet (out of scope for Tier 5 Beta).
///
/// Data sources:
///   - `events.cycle_number` + `events.series_id` for the current
///     resource (via direct select).
///   - `resource_series.metadata->'capability_configs'->'rotation'`
///     via `ResourceSeriesRepository.list()` filtered to series_id.
///   - `rpc('next_host_for_series', p_series_id, p_cycle)` for each
///     upcoming cycle (current+1 .. current+3).
public struct RotationSectionView: View {
    @Environment(AppState.self) private var app

    public let context: ResourceDetailContext

    @State private var loadState: LoadState = .loading

    /// Registered with `CapabilitySectionCatalog` at boot. Renders for
    /// any resource whose capability set includes `rotation`. The actual
    /// "is there real data?" check happens inside the view — if the
    /// resource doesn't have a series with rotation cap_config, the
    /// section collapses to a quiet empty state instead of looking
    /// broken.
    public static let definition = CapabilitySection(
        id: "rotation",
        priority: 600,
        isEnabledFor: { caps in caps.contains("rotation") },
        render: { ctx in AnyView(RotationSectionView(context: ctx)) }
    )

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            header
            content
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Rotación")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            HStack(spacing: RuulSpacing.sm) {
                ProgressView()
                Text("Cargando rotación…")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)

        case .noData(let reason):
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(reason)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)

        case .data(let snapshot):
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                nextHostCard(snapshot)
                if !snapshot.upcomingHosts.isEmpty {
                    upcomingHostsRow(snapshot)
                }
                rotationOrder(snapshot)
                policySummary(snapshot)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func nextHostCard(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Próximo anfitrión")
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
            if let next = snapshot.upcomingHosts.first {
                HStack(spacing: RuulSpacing.sm) {
                    Image(systemName: "person.crop.circle.fill")
                        .ruulTextStyle(RuulTypography.titleLarge)
                        .foregroundStyle(Color.ruulAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.displayName)
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("Ciclo \(next.cycle)")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(RuulSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                        .fill(Color.ruulSurface)
                )
            } else {
                Text("Sin anfitrión asignado para el próximo turno")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .padding(RuulSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                            .fill(Color.ruulSurface)
                    )
            }
        }
    }

    @ViewBuilder
    private func upcomingHostsRow(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Siguientes turnos")
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
            HStack(spacing: RuulSpacing.md) {
                ForEach(snapshot.upcomingHosts) { host in
                    VStack(spacing: RuulSpacing.xxs) {
                        Image(systemName: "person.circle")
                            .ruulTextStyle(RuulTypography.title)
                            .foregroundStyle(Color.ruulTextSecondary)
                        Text(host.displayName)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextPrimary)
                            .lineLimit(1)
                        Text("#\(host.cycle)")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface)
            )
        }
    }

    @ViewBuilder
    private func rotationOrder(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Orden de rotación")
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
            VStack(spacing: 1) {
                ForEach(Array(snapshot.rotationOrder.enumerated()), id: \.offset) { idx, name in
                    HStack(spacing: RuulSpacing.sm) {
                        Text("\(idx + 1)")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.white)
                            .frame(width: 22, height: 22)
                            .background(
                                Circle()
                                    .fill(idx == snapshot.currentCursorIndex
                                        ? Color.ruulAccent
                                        : Color.ruulTextTertiary.opacity(0.5))
                            )
                        Text(name)
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer(minLength: 0)
                        if idx == snapshot.currentCursorIndex {
                            Text("ahora")
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulAccent)
                        }
                    }
                    .padding(.horizontal, RuulSpacing.md)
                    .padding(.vertical, RuulSpacing.sm)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func policySummary(_ snapshot: Snapshot) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.ruulTextTertiary)
            Text(snapshot.policyDescription)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RuulSpacing.md)
    }

    // MARK: - State machine

    private enum LoadState {
        case loading
        case noData(String)
        case data(Snapshot)
    }

    private struct Snapshot {
        struct UpcomingHost: Identifiable {
            let id: Int       // cycle number is unique within snapshot
            let cycle: Int
            let displayName: String
        }
        let rotationOrder: [String]    // display names in declared order
        let upcomingHosts: [UpcomingHost]
        let currentCursorIndex: Int    // which slot is "now" in rotationOrder
        let policyDescription: String
    }

    private func load() async {
        // 1. Tier 5 Beta is event-scoped. Other resource types would
        // need their own anchor (out of scope for this slice).
        guard context.resource.resourceType == .event else {
            await MainActor.run { loadState = .noData("Rotación sólo aplica a eventos por ahora") }
            return
        }

        do {
            // 2. Fetch the event row via eventRepo to get series_id +
            // cycle_number. EventRepository.event(id) decodes the full
            // Event row including the seriesId column added for Tier 5.
            let event = try await app.eventRepo.event(context.resource.id)
            guard let seriesId = event.seriesId else {
                await MainActor.run { loadState = .noData("Este evento no es parte de una serie") }
                return
            }
            let currentCycle = event.cycleNumber ?? 1

            // 3. Fetch the series to read the rotation cap_config from
            // metadata.capability_configs.rotation. The repo returns nil
            // when the series isn't found — degrade gracefully.
            guard let series = try await app.resourceSeriesRepo.fetchById(seriesId) else {
                await MainActor.run { loadState = .noData("La serie de este evento no existe") }
                return
            }
            guard let rotation = rotationConfig(from: series.metadata) else {
                await MainActor.run { loadState = .noData("Esta serie no tiene rotación configurada") }
                return
            }
            let participantIds = rotation.participants
            if participantIds.isEmpty {
                await MainActor.run { loadState = .noData("La rotación está vacía") }
                return
            }

            // 4. For each upcoming cycle, ask the server who's next. We
            // resolve cycles current+1 .. current+3 in parallel via the
            // repo's nextHostForSeries — single source of truth for the
            // rotation evaluation logic (mig 00132).
            let nextCycles = [currentCycle + 1, currentCycle + 2, currentCycle + 3]
            let resolved = try await withThrowingTaskGroup(of: (Int, UUID?).self) { group -> [(Int, UUID?)] in
                for c in nextCycles {
                    group.addTask {
                        let uid = try await app.resourceSeriesRepo.nextHostForSeries(seriesId: seriesId, cycle: c)
                        return (c, uid)
                    }
                }
                var out: [(Int, UUID?)] = []
                for try await pair in group { out.append(pair) }
                return out.sorted { $0.0 < $1.0 }
            }

            // 5. Resolve member display names + assemble the snapshot.
            // Use context.memberDirectory first (already loaded by the
            // outer detail view); fall back to a shortened id when a
            // participant left the group after the series was created.
            let upcomingHosts: [Snapshot.UpcomingHost] = resolved.compactMap { (cycle, uid) in
                guard let uid = uid else { return nil }
                let displayName = context.memberDirectory[uid]?.displayName ?? shortId(uid)
                return Snapshot.UpcomingHost(id: cycle, cycle: cycle, displayName: displayName)
            }
            let rotationOrder = participantIds.map { context.memberDirectory[$0]?.displayName ?? shortId($0) }
            // The "now" cursor: the slot whose user_id matches the CURRENT
            // event's host. Sequential math derives it from cycle_number;
            // random order would land elsewhere but the policy line
            // already discloses that.
            let cursor = (currentCycle - 1) % participantIds.count
            let policy = humanizePolicy(order: rotation.order, replacementPolicy: rotation.replacementPolicy)

            await MainActor.run {
                loadState = .data(Snapshot(
                    rotationOrder: rotationOrder,
                    upcomingHosts: upcomingHosts,
                    currentCursorIndex: cursor,
                    policyDescription: policy
                ))
            }
        } catch {
            await MainActor.run {
                loadState = .noData("No se pudo cargar la rotación")
            }
        }
    }

    /// Pulls the rotation sub-config out of `resource_series.metadata`.
    /// Returns nil when the envelope is absent or malformed. Lives here
    /// (not on JSONConfig) so the section owns the wire-shape contract;
    /// future per-series caps can mirror the pattern.
    private struct RotationConfig {
        let participants: [UUID]
        let order: String
        let replacementPolicy: String
    }

    private func rotationConfig(from metadata: JSONConfig) -> RotationConfig? {
        guard case .object(let root) = metadata,
              let capsAny = root["capability_configs"],
              case .object(let caps) = capsAny,
              let rotationAny = caps["rotation"],
              case .object(let rotation) = rotationAny else {
            return nil
        }

        var participants: [UUID] = []
        if let partsAny = rotation["participants"], case .array(let items) = partsAny {
            for item in items {
                if case .string(let s) = item, let uid = UUID(uuidString: s) {
                    participants.append(uid)
                }
            }
        }

        let order = rotation["order"]?.stringValue ?? "sequential"
        let replacementPolicy = rotation["replacementPolicy"]?.stringValue ?? "skip_to_next"

        return RotationConfig(
            participants: participants,
            order: order,
            replacementPolicy: replacementPolicy
        )
    }

    private func shortId(_ uid: UUID) -> String {
        String(uid.uuidString.lowercased().prefix(6))
    }

    private func humanizePolicy(order: String, replacementPolicy: String) -> String {
        let orderText = order == "random"
            ? "Orden aleatorio determinístico"
            : "En orden de la lista"
        let replacementText = replacementPolicy == "host_stays_until_swap"
            ? "el elegido se queda hasta que pida swap"
            : "si no puede, pasa al siguiente"
        return "\(orderText) · \(replacementText)."
    }
}
