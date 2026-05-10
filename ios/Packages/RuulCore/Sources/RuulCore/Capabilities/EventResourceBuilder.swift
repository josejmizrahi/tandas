import Foundation
import OSLog

/// Pilot ResourceBuilder implementation that creates Event resources.
///
/// Wraps the existing EventRepository + RuleRepository pipelines.
/// Phase 2+ will introduce per-type builders (Slot, Booking, Asset, Fund)
/// that follow the same orchestration shape.
public actor EventResourceBuilder: ResourceBuilder {
    public nonisolated let resourceType: ResourceType = .event

    public nonisolated var requiredFields: [BuilderField] {
        [
            BuilderField(key: "title",     label: "Título",  kind: .text),
            BuilderField(key: "startsAt",  label: "Empieza", kind: .dateTime)
        ]
    }

    public nonisolated var optionalCapabilities: [String] {
        ["rsvp", "check_in", "rotation", "money", "rules", "voting", "recurrence"]
    }

    private let eventRepo: any EventRepository
    private let ruleRepo: any RuleRepository
    /// Optional. When injected, the builder persists each enabled
    /// capability to `public.resource_capabilities` after the event row
    /// lands. nil keeps backwards compat for callers that don't yet
    /// pass the repo (mocks, previews, tests).
    private let capabilityRepo: (any ResourceCapabilityRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.builder.event")

    public init(
        eventRepo: any EventRepository,
        ruleRepo: any RuleRepository,
        capabilityRepo: (any ResourceCapabilityRepository)? = nil
    ) {
        self.eventRepo = eventRepo
        self.ruleRepo = ruleRepo
        self.capabilityRepo = capabilityRepo
    }

    public func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult {
        guard draft.resourceType == .event else {
            throw ResourceBuilderError.underlying("EventResourceBuilder cannot build this type")
        }

        // Required-field validation. Surface specific keys so the wizard
        // can highlight the missing field.
        guard case let .string(title)? = draft.basicFields["title"], !title.isEmpty else {
            throw ResourceBuilderError.missingRequiredField("title")
        }
        guard let startsAt = draft.basicFields["startsAt"]?.dateValue else {
            throw ResourceBuilderError.missingRequiredField("startsAt")
        }

        var eventDraft = EventDraft.empty(suggestedDate: startsAt)
        eventDraft.title = title
        if case let .string(description)? = draft.basicFields["description"] {
            eventDraft.description = description
        }
        if case let .string(location)? = draft.basicFields["location"] {
            eventDraft.locationName = location
        }
        eventDraft.applyRules = draft.enabledCapabilities.contains("rules")

        let event: Event
        do {
            event = try await eventRepo.createEvent(
                eventDraft,
                in: draft.groupId,
                isRecurringGenerated: draft.seriesPattern != nil
            )
        } catch {
            throw ResourceBuilderError.rpcFailed(error.localizedDescription)
        }

        // Persist capability rows for the toggled blocks. This is the
        // bridge between the wizard's "enable RSVP/check-in/rotation"
        // toggles and the runtime resource_capabilities table the
        // resolver + future feature gates read from.
        var persistedCapabilityIds: [String] = []
        if let capabilityRepo {
            for blockId in draft.enabledCapabilities {
                let config = draft.capabilityConfigs[blockId] ?? .object([:])
                do {
                    _ = try await capabilityRepo.enable(
                        blockId,
                        on: event.id,
                        config: config
                    )
                    persistedCapabilityIds.append(blockId)
                } catch {
                    log.warning("enable capability \(blockId) failed: \(error.localizedDescription)")
                }
            }
        }

        // Seed initial rules scoped to the resource. Rules table has
        // resource_id (post Phase A) so the engine can route them.
        var createdRuleIds: [UUID] = []
        if !draft.initialRules.isEmpty {
            do {
                let result = try await ruleRepo.createInitialRules(
                    groupId: draft.groupId,
                    drafts: draft.initialRules
                )
                createdRuleIds = result.map(\.id)
            } catch {
                log.warning("createInitialRules failed: \(error.localizedDescription)")
            }
        }

        return ResourceCreationResult(
            resourceId: event.id,
            seriesId: nil,
            enabledCapabilityIds: persistedCapabilityIds.isEmpty
                ? draft.enabledCapabilities
                : persistedCapabilityIds,
            createdRuleIds: createdRuleIds,
            cascadedModuleIds: []
        )
    }
}

// MARK: - JSONConfig date helper

private extension JSONConfig {
    /// Best-effort decode of an ISO8601 / "yyyy-MM-dd HH:mm" date string
    /// embedded as a string value. Returns nil for any other shape.
    var dateValue: Date? {
        guard case let .string(raw) = self else { return nil }
        if let iso = ISO8601DateFormatter().date(from: raw) { return iso }
        let fallback = DateFormatter()
        fallback.dateFormat = "yyyy-MM-dd HH:mm"
        return fallback.date(from: raw)
    }
}
