import Foundation

/// R.2V — Similarity engine, duplicates, suggestions y merge.
/// Doctrina: el backend devuelve `reasons[]` semánticos; el frontend NO calcula
/// score ni traduce nada. Sólo presenta.

// MARK: - Reasons semánticos

public enum ContextSimilarityReason: String, Codable, Sendable, Hashable {
    case sameName = "same_name"
    case similarName = "similar_name"
    case sharedMembers = "shared_members"
    case sharedResources = "shared_resources"
    case sharedDecisions = "shared_decisions"
    case sharedObligations = "shared_obligations"
    case sharedDocuments = "shared_documents"

    public var label: String {
        switch self {
        case .sameName: return "Mismo nombre"
        case .similarName: return "Nombre parecido"
        case .sharedMembers: return "Mismos miembros"
        case .sharedResources: return "Mismos recursos"
        case .sharedDecisions: return "Mismas decisiones"
        case .sharedObligations: return "Mismas obligaciones"
        case .sharedDocuments: return "Mismos documentos"
        }
    }
}

public enum ResourceSimilarityReason: String, Codable, Sendable, Hashable {
    case sameName = "same_name"
    case similarName = "similar_name"
    case sharedOwners = "shared_owners"
    case sameType = "same_type"
    case sameContext = "same_context"

    public var label: String {
        switch self {
        case .sameName: return "Mismo nombre"
        case .similarName: return "Nombre parecido"
        case .sharedOwners: return "Mismos dueños"
        case .sameType: return "Mismo tipo"
        case .sameContext: return "Mismo contexto"
        }
    }
}

public enum RelationshipSuggestionReason: String, Codable, Sendable, Hashable {
    case nameStrongMatch = "name_strong_match"
    case namePartialMatch = "name_partial_match"
    case nameWeakMatch = "name_weak_match"

    public var label: String {
        switch self {
        case .nameStrongMatch: return "Nombre muy parecido"
        case .namePartialMatch: return "Nombre parecido"
        case .nameWeakMatch: return "Nombre similar"
        }
    }
}

// MARK: - context_similarity

public struct ContextSimilarityCandidate: Sendable, Equatable, Hashable, Identifiable {
    public let contextId: UUID
    public let displayName: String
    public let score: Double
    public let reasons: [ContextSimilarityReason]
    public let rawReasons: [String]

    public var id: UUID { contextId }

    public init(
        contextId: UUID,
        displayName: String,
        score: Double,
        reasons: [ContextSimilarityReason],
        rawReasons: [String] = []
    ) {
        self.contextId = contextId
        self.displayName = displayName
        self.score = score
        self.reasons = reasons
        self.rawReasons = rawReasons
    }
}

extension ContextSimilarityCandidate: Decodable {
    enum CodingKeys: String, CodingKey {
        case contextId = "context_id"
        case displayName = "display_name"
        case score
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextId = try c.decode(UUID.self, forKey: .contextId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.score = try c.decode(Double.self, forKey: .score)
        let raw = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        self.rawReasons = raw
        self.reasons = raw.compactMap(ContextSimilarityReason.init(rawValue:))
    }
}

// MARK: - resource_similarity

public struct ResourceSimilarityCandidate: Sendable, Equatable, Hashable, Identifiable {
    public let resourceId: UUID
    public let displayName: String
    public let resourceType: String
    public let contextActorId: UUID?
    public let score: Double
    public let reasons: [ResourceSimilarityReason]
    public let rawReasons: [String]

    public var id: UUID { resourceId }

    public init(
        resourceId: UUID,
        displayName: String,
        resourceType: String,
        contextActorId: UUID?,
        score: Double,
        reasons: [ResourceSimilarityReason],
        rawReasons: [String] = []
    ) {
        self.resourceId = resourceId
        self.displayName = displayName
        self.resourceType = resourceType
        self.contextActorId = contextActorId
        self.score = score
        self.reasons = reasons
        self.rawReasons = rawReasons
    }
}

extension ResourceSimilarityCandidate: Decodable {
    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case displayName = "display_name"
        case resourceType = "resource_type"
        case contextActorId = "context_actor_id"
        case score
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId = try c.decode(UUID.self, forKey: .resourceId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.resourceType = try c.decode(String.self, forKey: .resourceType)
        self.contextActorId = try c.decodeIfPresent(UUID.self, forKey: .contextActorId)
        self.score = try c.decode(Double.self, forKey: .score)
        let raw = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        self.rawReasons = raw
        self.reasons = raw.compactMap(ResourceSimilarityReason.init(rawValue:))
    }
}

// MARK: - duplicate_candidates / merge_candidates

public struct DuplicateContextPair: Sendable, Equatable, Hashable, Identifiable {
    public let aContextId: UUID
    public let aDisplayName: String
    public let bContextId: UUID
    public let bDisplayName: String
    public let score: Double
    public let reasons: [ContextSimilarityReason]
    public let rawReasons: [String]

    public var id: String { "\(aContextId.uuidString)|\(bContextId.uuidString)" }

    public init(
        aContextId: UUID, aDisplayName: String,
        bContextId: UUID, bDisplayName: String,
        score: Double, reasons: [ContextSimilarityReason], rawReasons: [String] = []
    ) {
        self.aContextId = aContextId
        self.aDisplayName = aDisplayName
        self.bContextId = bContextId
        self.bDisplayName = bDisplayName
        self.score = score
        self.reasons = reasons
        self.rawReasons = rawReasons
    }
}

extension DuplicateContextPair: Decodable {
    enum CodingKeys: String, CodingKey {
        case aContextId = "a_context_id"
        case aDisplayName = "a_display_name"
        case bContextId = "b_context_id"
        case bDisplayName = "b_display_name"
        case score
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.aContextId = try c.decode(UUID.self, forKey: .aContextId)
        self.aDisplayName = try c.decode(String.self, forKey: .aDisplayName)
        self.bContextId = try c.decode(UUID.self, forKey: .bContextId)
        self.bDisplayName = try c.decode(String.self, forKey: .bDisplayName)
        self.score = try c.decode(Double.self, forKey: .score)
        let raw = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        self.rawReasons = raw
        self.reasons = raw.compactMap(ContextSimilarityReason.init(rawValue:))
    }
}

public struct DuplicateResourcePair: Sendable, Equatable, Hashable, Identifiable {
    public let aResourceId: UUID
    public let aDisplayName: String
    public let bResourceId: UUID
    public let bDisplayName: String
    public let score: Double
    public let reasons: [ResourceSimilarityReason]
    public let rawReasons: [String]

    public var id: String { "\(aResourceId.uuidString)|\(bResourceId.uuidString)" }
}

extension DuplicateResourcePair: Decodable {
    enum CodingKeys: String, CodingKey {
        case aResourceId = "a_resource_id"
        case aDisplayName = "a_display_name"
        case bResourceId = "b_resource_id"
        case bDisplayName = "b_display_name"
        case score
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.aResourceId = try c.decode(UUID.self, forKey: .aResourceId)
        self.aDisplayName = try c.decode(String.self, forKey: .aDisplayName)
        self.bResourceId = try c.decode(UUID.self, forKey: .bResourceId)
        self.bDisplayName = try c.decode(String.self, forKey: .bDisplayName)
        self.score = try c.decode(Double.self, forKey: .score)
        let raw = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        self.rawReasons = raw
        self.reasons = raw.compactMap(ResourceSimilarityReason.init(rawValue:))
    }
}

public struct DuplicateCandidates: Decodable, Sendable, Equatable {
    public let contexts: [DuplicateContextPair]
    public let resources: [DuplicateResourcePair]
    public let threshold: Double?

    enum CodingKeys: String, CodingKey { case contexts, resources, threshold }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contexts = try c.decodeIfPresent([DuplicateContextPair].self, forKey: .contexts) ?? []
        self.resources = try c.decodeIfPresent([DuplicateResourcePair].self, forKey: .resources) ?? []
        self.threshold = try c.decodeIfPresent(Double.self, forKey: .threshold)
    }

    public init(
        contexts: [DuplicateContextPair] = [],
        resources: [DuplicateResourcePair] = [],
        threshold: Double? = nil
    ) {
        self.contexts = contexts
        self.resources = resources
        self.threshold = threshold
    }
}

// MARK: - relationship_suggestions

public struct RelationshipSuggestion: Sendable, Equatable, Hashable, Identifiable {
    public let suggestedRelationship: String
    public let aContextId: UUID
    public let aDisplayName: String
    public let bContextId: UUID
    public let bDisplayName: String
    public let confidence: Double
    public let reasons: [RelationshipSuggestionReason]
    public let rawReasons: [String]

    public var id: String { "\(aContextId.uuidString)|\(bContextId.uuidString)" }

    public init(
        suggestedRelationship: String,
        aContextId: UUID, aDisplayName: String,
        bContextId: UUID, bDisplayName: String,
        confidence: Double,
        reasons: [RelationshipSuggestionReason],
        rawReasons: [String] = []
    ) {
        self.suggestedRelationship = suggestedRelationship
        self.aContextId = aContextId
        self.aDisplayName = aDisplayName
        self.bContextId = bContextId
        self.bDisplayName = bDisplayName
        self.confidence = confidence
        self.reasons = reasons
        self.rawReasons = rawReasons
    }
}

extension RelationshipSuggestion: Decodable {
    enum CodingKeys: String, CodingKey {
        case suggestedRelationship = "suggested_relationship"
        case aContextId = "a_context_id"
        case aDisplayName = "a_display_name"
        case bContextId = "b_context_id"
        case bDisplayName = "b_display_name"
        case confidence
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.suggestedRelationship = try c.decode(String.self, forKey: .suggestedRelationship)
        self.aContextId = try c.decode(UUID.self, forKey: .aContextId)
        self.aDisplayName = try c.decode(String.self, forKey: .aDisplayName)
        self.bContextId = try c.decode(UUID.self, forKey: .bContextId)
        self.bDisplayName = try c.decode(String.self, forKey: .bDisplayName)
        self.confidence = try c.decode(Double.self, forKey: .confidence)
        let raw = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        self.rawReasons = raw
        self.reasons = raw.compactMap(RelationshipSuggestionReason.init(rawValue:))
    }
}

// MARK: - Creation guards

public struct ContextCreationCandidate: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let contextId: UUID
    public let displayName: String
    public let actorKind: ActorKind
    public let actorSubtype: String
    public let score: Double
    public let highConfidence: Bool
    public let rawReasons: [String]

    public var id: UUID { contextId }

    enum CodingKeys: String, CodingKey {
        case contextId = "context_id"
        case displayName = "display_name"
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case score
        case highConfidence = "high_confidence"
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextId = try c.decode(UUID.self, forKey: .contextId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.actorKind = try c.decode(ActorKind.self, forKey: .actorKind)
        self.actorSubtype = try c.decode(String.self, forKey: .actorSubtype)
        self.score = try c.decode(Double.self, forKey: .score)
        self.highConfidence = try c.decodeIfPresent(Bool.self, forKey: .highConfidence) ?? false
        self.rawReasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
    }

    public init(
        contextId: UUID, displayName: String,
        actorKind: ActorKind, actorSubtype: String,
        score: Double, highConfidence: Bool, rawReasons: [String]
    ) {
        self.contextId = contextId
        self.displayName = displayName
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.score = score
        self.highConfidence = highConfidence
        self.rawReasons = rawReasons
    }
}

public struct ResourceCreationCandidate: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let resourceId: UUID
    public let displayName: String
    public let resourceType: String
    public let score: Double
    public let highConfidence: Bool
    public let rawReasons: [String]

    public var id: UUID { resourceId }

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case displayName = "display_name"
        case resourceType = "resource_type"
        case score
        case highConfidence = "high_confidence"
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId = try c.decode(UUID.self, forKey: .resourceId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.resourceType = try c.decode(String.self, forKey: .resourceType)
        self.score = try c.decode(Double.self, forKey: .score)
        self.highConfidence = try c.decodeIfPresent(Bool.self, forKey: .highConfidence) ?? false
        self.rawReasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
    }

    public init(
        resourceId: UUID, displayName: String, resourceType: String,
        score: Double, highConfidence: Bool, rawReasons: [String]
    ) {
        self.resourceId = resourceId
        self.displayName = displayName
        self.resourceType = resourceType
        self.score = score
        self.highConfidence = highConfidence
        self.rawReasons = rawReasons
    }
}

// MARK: - Merge

public struct MergeContextResult: Decodable, Sendable, Equatable {
    public let sourceContextId: UUID
    public let targetContextId: UUID
    public let status: String
    public let alreadyMerged: Bool

    enum CodingKeys: String, CodingKey {
        case sourceContextId = "source_context_id"
        case targetContextId = "target_context_id"
        case status
        case alreadyMerged = "already_merged"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceContextId = try c.decode(UUID.self, forKey: .sourceContextId)
        self.targetContextId = try c.decode(UUID.self, forKey: .targetContextId)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "soft_merged"
        self.alreadyMerged = try c.decodeIfPresent(Bool.self, forKey: .alreadyMerged) ?? false
    }

    public init(sourceContextId: UUID, targetContextId: UUID, status: String, alreadyMerged: Bool) {
        self.sourceContextId = sourceContextId
        self.targetContextId = targetContextId
        self.status = status
        self.alreadyMerged = alreadyMerged
    }
}

public struct UnmergeContextResult: Decodable, Sendable, Equatable {
    public let sourceContextId: UUID
    public let previousTargetContextId: UUID?
    public let unmerged: Bool

    enum CodingKeys: String, CodingKey {
        case sourceContextId = "source_context_id"
        case previousTargetContextId = "previous_target_context_id"
        case unmerged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceContextId = try c.decode(UUID.self, forKey: .sourceContextId)
        self.previousTargetContextId = try c.decodeIfPresent(UUID.self, forKey: .previousTargetContextId)
        self.unmerged = try c.decodeIfPresent(Bool.self, forKey: .unmerged) ?? false
    }

    public init(sourceContextId: UUID, previousTargetContextId: UUID?, unmerged: Bool) {
        self.sourceContextId = sourceContextId
        self.previousTargetContextId = previousTargetContextId
        self.unmerged = unmerged
    }
}

// MARK: - Dismiss suggestion

public enum SuggestionType: String, Codable, Sendable, Hashable {
    case contextDuplicate = "context_duplicate"
    case resourceDuplicate = "resource_duplicate"
    case relationshipContains = "relationship_contains"
}

public struct DismissSuggestionResult: Decodable, Sendable, Equatable {
    public let subjectA: UUID
    public let subjectB: UUID
    public let suggestionType: SuggestionType
    public let dismissedAt: Date?

    enum CodingKeys: String, CodingKey {
        case subjectA = "subject_a"
        case subjectB = "subject_b"
        case suggestionType = "suggestion_type"
        case dismissedAt = "dismissed_at"
    }

    public init(subjectA: UUID, subjectB: UUID, suggestionType: SuggestionType, dismissedAt: Date?) {
        self.subjectA = subjectA
        self.subjectB = subjectB
        self.suggestionType = suggestionType
        self.dismissedAt = dismissedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.subjectA = try c.decode(UUID.self, forKey: .subjectA)
        self.subjectB = try c.decode(UUID.self, forKey: .subjectB)
        self.suggestionType = try c.decode(SuggestionType.self, forKey: .suggestionType)
        self.dismissedAt = try c.decodeIfPresent(Date.self, forKey: .dismissedAt)
    }
}
