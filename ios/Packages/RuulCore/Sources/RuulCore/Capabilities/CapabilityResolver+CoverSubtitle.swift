import Foundation

public extension CapabilityResolver {
    /// Subtitle line for the cover hero overlay. Returns `nil` to hide the line.
    ///
    /// Examples by type:
    /// - event:  "Hosted by Daniel · 8 going"
    /// - fund:   "$4,500 of $10,000 raised"
    /// - asset:  "Custodian: Lynda"
    ///
    /// Member names are resolved via `memberDirectory` (keyed by member UUID)
    /// so the caller can pass a pre-loaded snapshot without triggering async
    /// work inside the resolver.
    func coverSubtitle(
        for resource: ResourceRow,
        in group: Group,
        memberDirectory: [UUID: MemberWithProfile],
        enabledCapabilities: Set<String>
    ) -> String? {
        switch resource.resourceType {
        case .event:
            return eventCoverSubtitle(
                resource: resource,
                memberDirectory: memberDirectory,
                enabledCapabilities: enabledCapabilities
            )
        case .fund:
            return fundCoverSubtitle(resource: resource)
        case .asset:
            return assetCoverSubtitle(resource: resource, memberDirectory: memberDirectory)
        case .space, .slot, .right, .unknown:
            return nil
        }
    }

    // MARK: - Per-type builders

    private func eventCoverSubtitle(
        resource: ResourceRow,
        memberDirectory: [UUID: MemberWithProfile],
        enabledCapabilities: Set<String>
    ) -> String? {
        var parts: [String] = []

        if let hostIdStr = stringVal(resource.metadata["host_id"]),
           let hostId = UUID(uuidString: hostIdStr),
           let host = memberDirectory[hostId] {
            parts.append("Hosted by \(host.displayName)")
        }

        if enabledCapabilities.contains("rsvp"),
           let attendees = intVal(resource.metadata["attendee_count"]),
           attendees > 0 {
            parts.append("\(attendees) going")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func fundCoverSubtitle(resource: ResourceRow) -> String? {
        guard let raised = stringVal(resource.metadata["balance_display"]),
              let goal = stringVal(resource.metadata["goal_display"]) else { return nil }
        return "\(raised) of \(goal) raised"
    }

    private func assetCoverSubtitle(
        resource: ResourceRow,
        memberDirectory: [UUID: MemberWithProfile]
    ) -> String? {
        guard let custodianIdStr = stringVal(resource.metadata["custodian_id"]),
              let custodianId = UUID(uuidString: custodianIdStr),
              let custodian = memberDirectory[custodianId] else { return nil }
        return "Custodian: \(custodian.displayName)"
    }
}
