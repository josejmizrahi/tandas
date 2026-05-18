import Foundation

/// A curated UX recipe that pre-composes shape pieces (from
/// `public.rule_shapes`) into a user-friendly, parameterized rule.
/// Templates are the Beta 1 Rule Builder surface — the user picks one
/// and fills 1-3 params; per-piece composition stays hidden.
///
/// Loaded from `public.rule_templates` via `list_rule_templates()` RPC
/// at app boot. Canonical source for additions = mig SQL (mig 00171 seeded
/// the Beta 1 catalog); a future codegen path may emit SQL from a TS file
/// in `supabase/functions/_shared/ruleTemplates/`.
///
/// Per Plans/Active/Governance.md §0.5 (hybrid doctrine 2026-05-14).
public struct RuleBuilderTemplate: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let displayNameES: String
    public let descriptionES: String
    public let category: String
    public let templateKind: String
    public let requiredCapabilities: [String]
    public let defaultParams: JSONConfig
    public let composition: Composition
    public let status: String
    public let sortOrder: Int

    // Universal-contract fields — mig 00295 (Plans/Active/UniversalRuleTemplates.md §6).
    // All optional/default-bearing so existing mock and live call sites still
    // compile. Catalog rows seeded pre-mig-00295 decode with the column-level
    // defaults (`uncategorized`, empty arrays, `post_beta`).

    /// Universal category from `Plans/Active/UniversalRuleTemplates.md §3`
    /// (e.g. "C — Obligation", "D — Governance"). Rendered as a badge chip
    /// in the Gallery card. Defaults to `"uncategorized"` for legacy rows.
    public let doctrinalCategory: String

    /// Antitemplate hints rendered as the "Esto NO" line on the Gallery
    /// card. Distinguishes neighbouring templates (e.g. `deadline_enforcement`
    /// is NOT `capacity_limit`).
    public let whatItIsNot: [String]

    /// Coordination patterns this template applies to. The §2.1 universality
    /// test requires ≥5 entries before a template enters the catalog.
    public let examplesAcrossVerticals: [TemplateVerticalExample]

    /// es-MX templated string with `{{param_key}}` placeholders. The
    /// declarative sentence formatter interpolates current form params
    /// into this template. `nil` = fall back to the legacy hardcoded
    /// formatter for templates seeded before mig 00295.
    public let naturalLanguagePreviewTemplate: String?

    /// Template-specific conflict signatures `publish_rule_composition`
    /// runs at publish-time.
    public let conflictsToDetect: [String]

    /// Lifecycle marker. Gallery filters on `beta1`; admin views can list
    /// `post_beta` to see the backlog.
    public let betaStatus: String

    /// Scope levels this template supports when published (subset of
    /// `{occurrence, resource, series, resource_type, capability, group,
    /// global_default}`). Empty = inherits from trigger shape.
    public let supportedScopes: [String]

    /// Fixture ids that must exist before this template can be published.
    /// CI lint blocks templates with < 5 fixtures.
    public let testsRequired: [String]

    /// When non-nil: this template is an alias of a more universal one
    /// (e.g. `late_arrival_fine` → `missed_obligation_consequence`). The
    /// Gallery filters aliased templates out; the engine resolves them
    /// just fine because rule_versions FK by template_id.
    public let aliasOf: String?

    public struct Composition: Codable, Sendable, Hashable {
        public let triggerShapeId: String
        public let conditionShapeIds: [String]
        public let consequenceShapeIds: [String]
        public let scopeHint: String?

        public enum CodingKeys: String, CodingKey {
            case triggerShapeId      = "trigger_shape_id"
            case conditionShapeIds   = "condition_shape_ids"
            case consequenceShapeIds = "consequence_shape_ids"
            case scopeHint           = "scope_hint"
        }

        public init(
            triggerShapeId: String,
            conditionShapeIds: [String] = [],
            consequenceShapeIds: [String] = [],
            scopeHint: String? = nil
        ) {
            self.triggerShapeId      = triggerShapeId
            self.conditionShapeIds   = conditionShapeIds
            self.consequenceShapeIds = consequenceShapeIds
            self.scopeHint           = scopeHint
        }
    }

    public enum CodingKeys: String, CodingKey {
        case id, category, composition, status
        case displayNameES                  = "display_name_es"
        case descriptionES                  = "description_es"
        case templateKind                   = "template_kind"
        case requiredCapabilities           = "required_capabilities"
        case defaultParams                  = "default_params"
        case sortOrder                      = "sort_order"
        case doctrinalCategory              = "doctrinal_category"
        case whatItIsNot                    = "what_it_is_not"
        case examplesAcrossVerticals        = "examples_across_verticals"
        case naturalLanguagePreviewTemplate = "natural_language_preview_template_es"
        case conflictsToDetect              = "conflicts_to_detect"
        case betaStatus                     = "beta_status"
        case supportedScopes                = "supported_scopes"
        case testsRequired                  = "tests_required"
        case aliasOf                        = "alias_of"
    }

    public init(
        id: String,
        displayNameES: String,
        descriptionES: String,
        category: String,
        templateKind: String,
        requiredCapabilities: [String] = [],
        defaultParams: JSONConfig = .object([:]),
        composition: Composition,
        status: String = "active",
        sortOrder: Int = 100,
        doctrinalCategory: String = "uncategorized",
        whatItIsNot: [String] = [],
        examplesAcrossVerticals: [TemplateVerticalExample] = [],
        naturalLanguagePreviewTemplate: String? = nil,
        conflictsToDetect: [String] = [],
        betaStatus: String = "post_beta",
        supportedScopes: [String] = [],
        testsRequired: [String] = [],
        aliasOf: String? = nil
    ) {
        self.id                             = id
        self.displayNameES                  = displayNameES
        self.descriptionES                  = descriptionES
        self.category                       = category
        self.templateKind                   = templateKind
        self.requiredCapabilities           = requiredCapabilities
        self.defaultParams                  = defaultParams
        self.composition                    = composition
        self.status                         = status
        self.sortOrder                      = sortOrder
        self.doctrinalCategory              = doctrinalCategory
        self.whatItIsNot                    = whatItIsNot
        self.examplesAcrossVerticals        = examplesAcrossVerticals
        self.naturalLanguagePreviewTemplate = naturalLanguagePreviewTemplate
        self.conflictsToDetect              = conflictsToDetect
        self.betaStatus                     = betaStatus
        self.supportedScopes                = supportedScopes
        self.testsRequired                  = testsRequired
        self.aliasOf                        = aliasOf
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                   = try c.decode(String.self, forKey: .id)
        self.displayNameES        = try c.decode(String.self, forKey: .displayNameES)
        self.descriptionES        = try c.decode(String.self, forKey: .descriptionES)
        self.category             = try c.decode(String.self, forKey: .category)
        self.templateKind         = try c.decode(String.self, forKey: .templateKind)
        self.requiredCapabilities = (try? c.decode([String].self, forKey: .requiredCapabilities)) ?? []
        self.defaultParams        = (try? c.decode(JSONConfig.self, forKey: .defaultParams)) ?? .object([:])
        self.composition          = try c.decode(Composition.self, forKey: .composition)
        self.status               = (try? c.decode(String.self, forKey: .status)) ?? "active"
        self.sortOrder            = (try? c.decode(Int.self, forKey: .sortOrder)) ?? 100
        self.doctrinalCategory    = (try? c.decode(String.self, forKey: .doctrinalCategory)) ?? "uncategorized"
        self.whatItIsNot          = (try? c.decode([String].self, forKey: .whatItIsNot)) ?? []
        self.examplesAcrossVerticals = (try? c.decode([TemplateVerticalExample].self, forKey: .examplesAcrossVerticals)) ?? []
        self.naturalLanguagePreviewTemplate = try c.decodeIfPresent(String.self, forKey: .naturalLanguagePreviewTemplate)
        self.conflictsToDetect    = (try? c.decode([String].self, forKey: .conflictsToDetect)) ?? []
        self.betaStatus           = (try? c.decode(String.self, forKey: .betaStatus)) ?? "post_beta"
        self.supportedScopes      = (try? c.decode([String].self, forKey: .supportedScopes)) ?? []
        self.testsRequired        = (try? c.decode([String].self, forKey: .testsRequired)) ?? []
        self.aliasOf              = try c.decodeIfPresent(String.self, forKey: .aliasOf)
    }
}

/// One coordination example declared by a template's `examples_across_verticals`
/// array. Used in §2.1 universality validation and rendered as a chip on the
/// Gallery card.
public struct TemplateVerticalExample: Codable, Sendable, Hashable {
    public let vertical: String
    public let labelGrupo: String
    public let params: JSONConfig

    public enum CodingKeys: String, CodingKey {
        case vertical
        case labelGrupo = "label_grupo"
        case params
    }

    public init(vertical: String, labelGrupo: String, params: JSONConfig = .object([:])) {
        self.vertical   = vertical
        self.labelGrupo = labelGrupo
        self.params     = params
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.vertical   = try c.decode(String.self, forKey: .vertical)
        self.labelGrupo = try c.decode(String.self, forKey: .labelGrupo)
        self.params     = (try? c.decode(JSONConfig.self, forKey: .params)) ?? .object([:])
    }
}

/// Scope envelope passed to `publish_rule_version`. Mirrors the server
/// `p_scope jsonb` argument — `{type: "group"}`, `{type: "resource", id}`,
/// or `{type: "series", id}`.
public enum RuleTemplateScope: Sendable, Hashable {
    case group
    case resource(UUID)
    case series(UUID)

    fileprivate func asJSON() -> JSONConfig {
        switch self {
        case .group:
            return .object(["type": .string(RuleScope.group)])
        case .resource(let id):
            return .object([
                "type": .string(RuleScope.resource),
                "id":   .string(id.uuidString.lowercased())
            ])
        case .series(let id):
            return .object([
                "type": .string(RuleScope.series),
                "id":   .string(id.uuidString.lowercased())
            ])
        }
    }
}

/// Conflict surfaced by `publish_rule_version`. Beta 1 only emits
/// `same_scope_overlapping` (severity=warning). Future: blocking conflicts
/// trigger a different UI flow.
public struct RuleVersionConflict: Codable, Sendable, Hashable {
    public let type: String
    public let severity: String
    public let againstRuleVersionId: UUID
    public let againstRuleTitle: String?

    public enum CodingKeys: String, CodingKey {
        case type, severity
        case againstRuleVersionId = "against_rule_version_id"
        case againstRuleTitle     = "against_rule_title"
    }

    public init(
        type: String,
        severity: String,
        againstRuleVersionId: UUID,
        againstRuleTitle: String? = nil
    ) {
        self.type                 = type
        self.severity             = severity
        self.againstRuleVersionId = againstRuleVersionId
        self.againstRuleTitle     = againstRuleTitle
    }
}

/// Result of `publish_rule_version` / `publish_rule_composition`. The
/// returned rule is already active — the iOS layer can navigate to
/// its detail view.
///
/// `slug` is set by the composition endpoint (mig 00246) — every
/// composer-published rule gets a stable id. `publish_rule_version`
/// (template-driven) returns null here today because the template id
/// IS the slug equivalent; if/when that's unified the field becomes
/// canonical for both paths.
public struct RuleVersionPublishResult: Codable, Sendable, Hashable {
    public let ruleId: UUID
    public let ruleVersionId: UUID
    public let version: Int
    public let slug: String?
    public let conflicts: [RuleVersionConflict]

    public enum CodingKeys: String, CodingKey {
        case ruleId        = "rule_id"
        case ruleVersionId = "rule_version_id"
        case version
        case slug
        case conflicts
    }

    public init(
        ruleId: UUID,
        ruleVersionId: UUID,
        version: Int,
        slug: String? = nil,
        conflicts: [RuleVersionConflict] = []
    ) {
        self.ruleId        = ruleId
        self.ruleVersionId = ruleVersionId
        self.version       = version
        self.slug          = slug
        self.conflicts     = conflicts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ruleId        = try c.decode(UUID.self, forKey: .ruleId)
        self.ruleVersionId = try c.decode(UUID.self, forKey: .ruleVersionId)
        self.version       = try c.decode(Int.self, forKey: .version)
        self.slug          = try c.decodeIfPresent(String.self, forKey: .slug)
        self.conflicts     = (try? c.decode([RuleVersionConflict].self, forKey: .conflicts)) ?? []
    }
}

extension RuleBuilderTemplate {
    /// JSON-encodes a scope value for the `publish_rule_version` RPC.
    /// Public so coordinators/tests can serialize scopes without
    /// constructing the JSONConfig manually.
    public static func scopeJSON(_ scope: RuleTemplateScope) -> JSONConfig {
        scope.asJSON()
    }
}
