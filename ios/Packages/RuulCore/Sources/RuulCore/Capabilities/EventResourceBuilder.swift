import Foundation
import OSLog

/// Pilot ResourceBuilder implementation that creates Event resources.
///
/// Wraps the existing EventRepository + RuleRepository pipelines.
/// Phase 2+ will introduce per-type builders (Slot, Booking, Asset, Fund)
/// that follow the same orchestration shape.
public actor EventResourceBuilder: ResourceBuilder {
    public nonisolated let resourceType: ResourceType = .event
    public nonisolated let displayName: String = "Evento"
    public nonisolated let icon: String = "calendar.badge.clock"
    public nonisolated let summary: String = "Cena, junta, partido. Algo que pasa una vez (o se repite)."

    public nonisolated var requiredFields: [BuilderField] {
        [
            BuilderField(key: "title",     label: "Título",  kind: .text,
                         placeholder: "ej: Cena del jueves"),
            BuilderField(key: "startsAt",  label: "Empieza", kind: .dateTime)
        ]
    }

    public nonisolated var optionalCapabilities: [String] {
        ["rsvp", "check_in", "rotation", "money", "rules", "voting", "recurrence"]
    }

    private let eventRepo: any EventRepository
    private let ruleRepo: any RuleRepository
    /// Optional legacy capability repo. Kept for callers that don't yet
    /// inject draftRepo (mocks, previews). When draftRepo is present,
    /// the atomic RPC handles capability inserts itself.
    private let capabilityRepo: (any ResourceCapabilityRepository)?
    /// Legacy series + resource repos. Same fallback semantics as
    /// `capabilityRepo` above — only consulted on the non-atomic path.
    private let seriesRepo: (any ResourceSeriesRepository)?
    private let resourceRepo: (any ResourceRepository)?
    /// Atomic RPC client (mig 00101). When injected, `build(_:)` calls
    /// `build_resource_from_draft` instead of orchestrating N
    /// sequential writes — partial failure rolls back the whole batch
    /// instead of leaving orphan rows.
    private let draftRepo: (any ResourceDraftRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.builder.event")

    public init(
        eventRepo: any EventRepository,
        ruleRepo: any RuleRepository,
        capabilityRepo: (any ResourceCapabilityRepository)? = nil,
        seriesRepo: (any ResourceSeriesRepository)? = nil,
        resourceRepo: (any ResourceRepository)? = nil,
        draftRepo: (any ResourceDraftRepository)? = nil
    ) {
        self.eventRepo = eventRepo
        self.ruleRepo = ruleRepo
        self.capabilityRepo = capabilityRepo
        self.seriesRepo = seriesRepo
        self.resourceRepo = resourceRepo
        self.draftRepo = draftRepo
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

        // Atomic path (founder framing 2026-05-11 #5): when the host
        // app injected the draft repo, send the entire draft to the
        // server-side RPC in one shot. Partial failures roll back.
        if let draftRepo {
            do {
                let resourceId = try await draftRepo.build(draft)
                return ResourceCreationResult(
                    resourceId: resourceId,
                    seriesId: nil,  // RPC owns the series id internally
                    enabledCapabilityIds: draft.enabledCapabilities,
                    createdRuleIds: [],  // RPC bypasses createInitialRules; ids not returned in V1
                    cascadedModuleIds: []
                )
            } catch let e as ResourceDraftError {
                if case let .rpcFailed(msg) = e {
                    throw ResourceBuilderError.rpcFailed(msg)
                }
                throw ResourceBuilderError.rpcFailed("\(e)")
            } catch {
                throw ResourceBuilderError.rpcFailed(error.localizedDescription)
            }
        }

        // Legacy N-RPC path. Kept for mocks/previews + as a fallback
        // when callers haven't migrated to inject the draftRepo yet.
        _ = title; _ = startsAt

        var eventDraft = EventDraft.empty(suggestedDate: startsAt)
        eventDraft.title = title
        if case let .string(description)? = draft.basicFields["description"] {
            eventDraft.description = description
        }
        if case let .string(location)? = draft.basicFields["location"] {
            eventDraft.locationName = location
        }
        eventDraft.applyRules = draft.enabledCapabilities.contains("rules")

        // Recurrence path: when the wizard sent a seriesPattern, create
        // a ResourceSeries row first. The event we create below will be
        // linked to it via resources.series_id (post-event UPDATE — the
        // events table doesn't have a series_id column; only the
        // polymorphic resources row does).
        var createdSeriesId: UUID? = nil
        if let pattern = draft.seriesPattern, let seriesRepo {
            let series = ResourceSeries(
                groupId: draft.groupId,
                resourceType: "event",
                pattern: pattern,
                metadata: .object(["seedTitle": .string(title)]),
                active: true
            )
            do {
                let created = try await seriesRepo.create(series)
                createdSeriesId = created.id
            } catch {
                log.warning("create series failed: \(error.localizedDescription)")
            }
        }

        let event: Event
        do {
            event = try await eventRepo.createEvent(
                eventDraft,
                in: draft.groupId,
                isRecurringGenerated: createdSeriesId != nil
            )
        } catch {
            throw ResourceBuilderError.rpcFailed(error.localizedDescription)
        }

        // Link the event's resources row to the series via series_id.
        // Events get dual-written to resources via the mig 00039 trigger
        // (resources.id = event.id), so the UPDATE finds the row.
        if let seriesId = createdSeriesId, let resourceRepo {
            do {
                try await resourceRepo.setSeriesId(seriesId, on: event.id)
            } catch {
                log.warning("link series_id failed: \(error.localizedDescription)")
            }
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
            seriesId: createdSeriesId,
            enabledCapabilityIds: persistedCapabilityIds.isEmpty
                ? draft.enabledCapabilities
                : persistedCapabilityIds,
            createdRuleIds: createdRuleIds,
            cascadedModuleIds: []
        )
    }
}

// JSONConfig.dateValue / .uuidValue helpers live in SlotResourceBuilder.swift
// (module-wide extension). Keep them in one place to avoid redeclaration.
