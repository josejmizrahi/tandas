import SwiftUI
import RuulUI
import RuulCore

/// Canonical "Summary" zone — polymorphic, capability-driven. Replaces
/// `EventStatusSummary` (event-only host+attending) and `DetailSummaryView`
/// (metadata-row card). Same view for every `Resource`; the content
/// inspects `enabledCapabilities` + `resource.metadata` to assemble:
///
///   1. TypeStrip          — type pill + status pill + series link (later)
///   2. HeroStat           — single big focal stat (date / balance / role)
///   3. KPIRow             — up to 4 stat tiles contributed by capabilities
///   4. CapabilitiesChips  — subtle row of enabled capability labels
///   5. MetaLine           — "Creado por X · hace N días"
///
/// Design principle (memoria `project_resource_detail_capability_driven` +
/// `feedback_no_hardcoded_verticals`): branch by **capability**, never by
/// `resource_type`. Capability is the right axis because it's runtime /
/// template-driven.
public struct ResourceSummaryView: View {
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?

    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            typeStrip
            if let hero = heroStat {
                heroView(hero)
            }
            if !kpis.isEmpty {
                kpiRow
            }
            if !capabilityChips.isEmpty {
                capChipsRow
            }
            metaLine
        }
    }

    // MARK: - Type / status strip

    private var typeStrip: some View {
        HStack(spacing: RuulSpacing.xs) {
            RuulBadge(typeLabel, style: .neutral, icon: typeIcon)
            if let status = statusBadge {
                RuulBadge(status.label, style: status.style)
            }
            Spacer(minLength: 0)
        }
    }

    private var typeLabel: String { context.resource.resourceType.humanLabel }
    private var typeIcon: String { ResourceTypeChrome.resolve(context.resource.resourceType).symbol }

    /// Maps free-form `resourceStatus` strings to a badge presentation.
    /// Falls back to nil for "default" states ("open", "active", "draft")
    /// so the user only sees a pill when something noteworthy is going on.
    private var statusBadge: (label: String, style: RuulBadge.Style)? {
        let raw = context.resource.resourceStatus.lowercased()
        switch raw {
        case "open", "active":      return nil
        case "draft":               return ("Borrador", .neutral)
        case "closed":              return ("Cerrado", .neutral)
        case "cancelled", "canceled": return ("Cancelado", .negative)
        case "pending":             return ("Pendiente", .warning)
        case "completed", "done":   return ("Completado", .positive)
        case "scheduled":           return nil // schedule capability shows date directly
        case "":                    return nil
        default:                    return (raw.capitalized, .neutral)
        }
    }

    // MARK: - Hero stat (single, capability-priority-ranked)

    private struct HeroStat {
        let title: String      // big text
        let subtitle: String?  // small caption below
        let icon: String       // SF Symbol
        let tone: RuulBadge.Style
    }

    /// Collects candidate heroes from active capabilities and picks the
    /// highest-priority one. Lower priority number = higher rank.
    private var heroStat: HeroStat? {
        var candidates: [(priority: Int, stat: HeroStat)] = []

        if isEnabled("schedule") || isEnabled("recurrence") || isEnabled("rsvp") {
            if let when = scheduleHero {
                candidates.append((priority: 100, stat: when))
            }
        }
        if isMoneyEnabled, let money = moneyHero {
            candidates.append((priority: 200, stat: money))
        }
        if isEnabled("host_actions"), let host = hostHero {
            candidates.append((priority: 400, stat: host))
        }

        return candidates.sorted { $0.priority < $1.priority }.first?.stat
    }

    private var scheduleHero: HeroStat? {
        guard let startsAt = resolvedStartsAt else { return nil }
        return HeroStat(
            title: startsAt.ruulEventDayTitle,
            subtitle: startsAt.ruulEventTimeOfDay,
            icon: "clock",
            tone: .info
        )
    }

    private var moneyHero: HeroStat? {
        // V1: no inline ledger query — keep it as a soft signal. When
        // SummaryContribution registry lands, the Money contribution can
        // compute real balance vs goal here.
        guard isMoneyEnabled else { return nil }
        let label = moneyLabel
        return HeroStat(
            title: label.isEmpty ? "Dinero compartido" : label,
            subtitle: "Ver detalle abajo",
            icon: "banknote.fill",
            tone: .info
        )
    }

    private var hostHero: HeroStat? {
        guard let name = hostName else { return nil }
        return HeroStat(
            title: "\(name) está hospedando",
            subtitle: nil,
            icon: "star.fill",
            tone: .info
        )
    }

    @ViewBuilder
    private func heroView(_ hero: HeroStat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.sm) {
            Image(systemName: hero.icon)
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(hero.tone.foregroundColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(hero.title)
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle = hero.subtitle {
                    Text(subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .textCase(.uppercase)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - KPI row

    private struct KPITile: Identifiable {
        let id: String
        let icon: String
        let label: String
        let value: String
    }

    private var kpis: [KPITile] {
        var tiles: [KPITile] = []

        // Capacity / RSVP confirmados — appears when rsvp capability is on
        // OR when capacity_max is declared on the resource (events).
        if let confirmedTile = confirmedKPI { tiles.append(confirmedTile) }
        // Host KPI — distinct from hero. Surfaces "Daniel host" when the
        // hero already used schedule (date) as the focal stat.
        if let hostTile = hostKPI { tiles.append(hostTile) }
        // Location KPI — collapsed name to avoid duplicating LocationSection.
        if let locTile = locationKPI { tiles.append(locTile) }
        // Money signal — if money capability(ies) enabled, surface a chip.
        if let moneyTile = moneyKPI { tiles.append(moneyTile) }

        return Array(tiles.prefix(4))
    }

    private var kpiRow: some View {
        LazyVGrid(columns: gridColumns, spacing: RuulSpacing.sm) {
            ForEach(kpis) { tile in
                kpiCard(tile)
            }
        }
    }

    private var gridColumns: [GridItem] {
        // 2-column grid scales nicely 1-4 tiles. A single tile stretches
        // across one column (looks OK), two columns balance, three+ wrap.
        Array(repeating: GridItem(.flexible(), spacing: RuulSpacing.sm), count: 2)
    }

    private func kpiCard(_ tile: KPITile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: tile.icon)
                    .ruulTextStyle(RuulTypography.microSemibold)
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(tile.label.uppercased())
                    .font(.ruulMicro.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
                    .lineLimit(1)
            }
            Text(tile.value)
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, RuulSpacing.sm)
        .padding(.horizontal, RuulSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    // KPI providers — each capability contributes 0..1 tile.

    private var confirmedKPI: KPITile? {
        guard isEnabled("rsvp") || resolvedCapacityMax != nil else { return nil }
        let going = interactor?.rsvps.filter { $0.status == .going }
            .reduce(0) { $0 + 1 + $1.plusOnes } ?? 0
        if let cap = resolvedCapacityMax {
            return KPITile(id: "rsvp", icon: "person.3.fill", label: "Confirmados", value: "\(going) de \(cap)")
        }
        if going == 0 { return nil }
        let val = going == 1 ? "1" : "\(going)"
        return KPITile(id: "rsvp", icon: "person.3.fill", label: "Confirmados", value: val)
    }

    private var hostKPI: KPITile? {
        // Only surface as KPI when we already used schedule for the hero —
        // otherwise it's the hero itself. Avoids duplication.
        guard let name = hostName, scheduleHero != nil else { return nil }
        return KPITile(id: "host", icon: "star.fill", label: "Hospedando", value: name)
    }

    private var locationKPI: KPITile? {
        guard let loc = locationName else { return nil }
        return KPITile(id: "location", icon: "mappin", label: "Lugar", value: loc)
    }

    private var moneyKPI: KPITile? {
        guard isMoneyEnabled, moneyHero == nil else { return nil }
        return KPITile(id: "money", icon: "banknote.fill", label: "Dinero", value: moneyLabel.isEmpty ? "Activo" : moneyLabel)
    }

    // MARK: - Capabilities chips row

    /// Returns enabled capabilities in a user-facing label form. Order
    /// follows a curated priority so the row reads consistently.
    private var capabilityChips: [(id: String, label: String)] {
        let caps = context.enabledCapabilities
        var out: [(id: String, label: String)] = []
        let mapping: [(String, String)] = [
            ("rsvp",          "Confirmaciones"),
            ("host_actions",  "Host"),
            ("money",         "Dinero"),
            ("expenses",      "Gastos"),
            ("contributions", "Aportes"),
            ("payouts",       "Payouts"),
            ("ledger",        "Ledger"),
            ("schedule",      "Agenda"),
            ("recurrence",    "Recurrente"),
            ("rules",         "Reglas"),
            ("voting",        "Votos"),
            ("checkin",       "Check-in")
        ]
        for (cap, label) in mapping where caps.contains(cap) {
            out.append((cap, label))
        }
        return out
    }

    private var capChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.xs) {
                ForEach(capabilityChips, id: \.id) { chip in
                    Text(chip.label)
                        .font(.ruulCaption.weight(.medium))
                        .foregroundStyle(Color.ruulTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(Color.ruulSurface)
                        )
                        .overlay(
                            Capsule().stroke(Color.ruulSeparator, lineWidth: 0.5)
                        )
                }
            }
        }
    }

    // MARK: - Meta line

    private var metaLine: some View {
        HStack(spacing: RuulSpacing.xs) {
            if let creatorPart = creatorString {
                Text(creatorPart)
            }
            Text("·")
            Text(relativeCreated)
            Spacer(minLength: 0)
        }
        .font(.ruulCaption)
        .foregroundStyle(Color.ruulTextTertiary)
    }

    private var creatorString: String? {
        guard let creator = context.resource.createdBy,
              let name = context.memberDirectory[creator]?.displayName else { return nil }
        return "Creado por \(name)"
    }

    private var relativeCreated: String {
        context.resource.createdAt.ruulRelative
    }

    // MARK: - Derived helpers

    private func isEnabled(_ cap: String) -> Bool {
        context.enabledCapabilities.contains(cap)
    }

    private var isMoneyEnabled: Bool {
        let caps = context.enabledCapabilities
        return caps.contains("money") || caps.contains("expenses")
            || caps.contains("contributions") || caps.contains("payouts")
            || caps.contains("ledger")
    }

    private var moneyLabel: String {
        var parts: [String] = []
        let caps = context.enabledCapabilities
        if caps.contains("expenses")      { parts.append("Gastos") }
        if caps.contains("contributions") { parts.append("Aportes") }
        if caps.contains("payouts")       { parts.append("Payouts") }
        return parts.joined(separator: " · ")
    }

    /// `starts_at` from event interactor (typed) or metadata jsonb. Mirrors
    /// the EventStatusSummary pattern so non-live previews still render.
    private var resolvedStartsAt: Date? {
        if let evt = interactor?.event {
            return evt.startsAt
        }
        if case let .string(s)? = context.resource.metadata["starts_at"],
           let date = isoFormatter.date(from: s) {
            return date
        }
        if case let .string(s)? = context.resource.metadata["startsAt"],
           let date = isoFormatter.date(from: s) {
            return date
        }
        return nil
    }

    private var resolvedCapacityMax: Int? {
        interactor?.event.capacityMax
            ?? context.resource.metadata["capacity_max"]?.intValue
            ?? context.resource.metadata["capacityMax"]?.intValue
    }

    private var hostName: String? {
        let hostId = interactor?.event.hostId
            ?? context.resource.metadata["host_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        guard let hostId else { return nil }
        return context.memberDirectory[hostId]?.displayName
    }

    private var locationName: String? {
        let raw = interactor?.event.locationName
            ?? context.resource.metadata["location_name"]?.stringValue
            ?? context.resource.metadata["locationName"]?.stringValue
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Formatters

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Style → Color bridge

private extension RuulBadge.Style {
    var foregroundColor: Color {
        switch self {
        case .neutral:  return .ruulTextSecondary
        case .positive: return .ruulPositive
        case .negative: return .ruulNegative
        case .warning:  return .ruulWarning
        case .info:     return .ruulInfo
        case .subtle:   return .ruulTextSecondary
        case .accent:   return .ruulAccent
        }
    }
}
