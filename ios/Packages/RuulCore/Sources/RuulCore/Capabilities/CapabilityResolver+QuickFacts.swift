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
        case .space, .slot, .right, .unknown:
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
