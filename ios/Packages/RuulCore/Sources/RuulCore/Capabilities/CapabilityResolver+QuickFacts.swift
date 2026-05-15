import Foundation

public extension CapabilityResolver {
    /// Horizontal-pill facts for the detail screen header zone.
    ///
    /// Composes facts from active capabilities. Returns an empty array
    /// when there are no relevant facts — caller hides the QuickFacts
    /// strip entirely in that case.
    func quickFacts(
        for resource: ResourceRow,
        in group: Group,
        enabledCapabilities: Set<String>
    ) -> [QuickFact] {
        switch resource.resourceType {
        case .event: return eventQuickFacts(resource: resource, enabledCapabilities: enabledCapabilities)
        case .fund:  return fundQuickFacts(resource: resource, enabledCapabilities: enabledCapabilities)
        case .asset: return assetQuickFacts(resource: resource, enabledCapabilities: enabledCapabilities)
        case .right: return rightQuickFacts(resource: resource)
        case .space, .slot, .unknown:
            return []
        }
    }

    // MARK: - Per-type builders

    private func eventQuickFacts(
        resource: ResourceRow,
        enabledCapabilities: Set<String>
    ) -> [QuickFact] {
        var facts: [QuickFact] = []

        if enabledCapabilities.contains("scheduling"),
           let date = isoDate(resource.metadata["starts_at"]) {
            facts.append(QuickFact(
                id: "date",
                kind: .date,
                symbol: "calendar",
                label: date.ruulShortDate
            ))
            facts.append(QuickFact(
                id: "time",
                kind: .time,
                symbol: "clock",
                label: date.ruulShortTime
            ))
        }

        if let location = stringVal(resource.metadata["location"]), !location.isEmpty {
            facts.append(QuickFact(
                id: "location",
                kind: .location,
                symbol: "mappin.and.ellipse",
                label: location
            ))
        }

        if enabledCapabilities.contains("rsvp"),
           let capacity = intVal(resource.metadata["capacity"]),
           let attendees = intVal(resource.metadata["attendee_count"]) {
            facts.append(QuickFact(
                id: "capacity",
                kind: .capacity,
                symbol: "person.2",
                label: "\(attendees)/\(capacity)"
            ))
        }

        return facts
    }

    private func fundQuickFacts(
        resource: ResourceRow,
        enabledCapabilities: Set<String>
    ) -> [QuickFact] {
        var facts: [QuickFact] = []

        if enabledCapabilities.contains("ledger"),
           let balance = stringVal(resource.metadata["balance_display"]) {
            facts.append(QuickFact(
                id: "balance",
                kind: .balance,
                symbol: "banknote",
                label: balance
            ))
        }

        if let progress = stringVal(resource.metadata["progress_display"]) {
            facts.append(QuickFact(
                id: "progress",
                kind: .progress,
                symbol: "chart.bar",
                label: progress
            ))
        }

        return facts
    }

    private func assetQuickFacts(
        resource: ResourceRow,
        enabledCapabilities: Set<String>  // reserved for future gating
    ) -> [QuickFact] {
        var facts: [QuickFact] = []

        if let status = stringVal(resource.metadata["status_display"]) {
            facts.append(QuickFact(
                id: "status",
                kind: .status,
                symbol: "circle.fill",
                label: status
            ))
        }

        if let location = stringVal(resource.metadata["location"]), !location.isEmpty {
            facts.append(QuickFact(
                id: "location",
                kind: .location,
                symbol: "mappin.and.ellipse",
                label: location
            ))
        }

        return facts
    }

    private func rightQuickFacts(resource: ResourceRow) -> [QuickFact] {
        // Surfaces the right's normative-claim attributes — what makes
        // THIS claim different from a sibling claim on the same target.
        // Holder is rendered separately via the cover subtitle ("Holder:
        // X") so it doesn't crowd the pill strip.
        var facts: [QuickFact] = []

        // Status: `active` is implicit (no pill needed); `expired` /
        // `revoked` are the noteworthy states the holder cares about.
        let statusText: String? = {
            switch resource.status {
            case "active":  return nil
            case "expired": return "Vencido"
            case "revoked": return "Revocado"
            default:        return resource.status
            }
        }()
        if let label = statusText {
            facts.append(QuickFact(
                id: "status",
                kind: .status,
                symbol: "circle.fill",
                label: label
            ))
        }

        // Suspended? Suspension is an active-but-frozen state. Visible
        // until `restore_right` lifts it. The cron doesn't auto-lift
        // suspensions (intentional) so the pill is the user-facing
        // signal that exercise is currently blocked.
        if resource.metadata["suspended_until"]?.stringValue != nil
            || resource.metadata["suspended_at"]?.stringValue != nil {
            facts.append(QuickFact(
                id: "suspended",
                kind: .status,
                symbol: "pause.circle",
                label: "Suspendido"
            ))
        }

        // Priority — only render when explicitly higher than the default
        // (0). A right with priority 5 contests reservations with a right
        // at priority 3; the number is the user-facing precedence signal.
        if let priority = intVal(resource.metadata["priority"]), priority > 0 {
            facts.append(QuickFact(
                id: "priority",
                kind: .status,
                symbol: "arrow.up.right.circle",
                label: "Prioridad \(priority)"
            ))
        }

        // Transferable / exclusive: only render when true (the
        // affirmative claim shape). False values are the default and
        // would just add noise.
        if resource.metadata["exclusive"]?.boolValue == true {
            facts.append(QuickFact(
                id: "exclusive",
                kind: .status,
                symbol: "lock.shield",
                label: "Exclusivo"
            ))
        }
        if resource.metadata["transferable"]?.boolValue == true {
            facts.append(QuickFact(
                id: "transferable",
                kind: .status,
                symbol: "arrow.left.arrow.right",
                label: "Transferible"
            ))
        }

        // Expires_at — render only when future + within a sensible
        // window. Server-side cron `expire-due-rights-every-hour` flips
        // status to expired once it lapses, so we only show forward-
        // looking dates here.
        if let raw = resource.metadata["expires_at"]?.stringValue,
           let date = ISO8601DateFormatter().date(from: raw),
           date > Date.now {
            facts.append(QuickFact(
                id: "expires",
                kind: .date,
                symbol: "hourglass",
                label: "Vence \(date.ruulShortDate)"
            ))
        }

        return facts
    }

    // MARK: - JSONConfig accessors

    /// Extracts a `String` from a `JSONConfig?`. Handles `.string` case only;
    /// numeric-as-string coercion is intentionally omitted (display labels
    /// should be pre-formatted on the server side).
    func stringVal(_ config: JSONConfig?) -> String? {
        config?.stringValue
    }

    /// Extracts an `Int` from a `JSONConfig?`. Accepts `.int` and `.double`
    /// (postgres numeric sometimes decodes as double on the wire).
    func intVal(_ config: JSONConfig?) -> Int? {
        config?.intValue
    }

    /// Parses an ISO-8601 date string from a `JSONConfig?` value.
    func isoDate(_ config: JSONConfig?) -> Date? {
        guard let str = config?.stringValue else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }
}
