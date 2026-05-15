import Foundation
import OSLog
import RuulCore

/// State machine + I/O for the Beta 1 Rule Builder (Template Gallery →
/// Param Form → Publish). 3 user-visible fases with 8 internal stages
/// per Plans/Active/Governance.md §10.2 — this coordinator owns the draft
/// and exposes a single `publish()` entry that wraps the
/// `publish_rule_version` RPC.
///
/// Beta 1 scope: only `RuleTemplateScope.group`. Resource/series scopes
/// added in a follow-up sprint when the rule list surfaces them
/// distinctly. Per-piece composition stays hidden (EditRulesView remains
/// for admin/dev only).
@Observable @MainActor
public final class RuleBuilderCoordinator: Identifiable {
    public nonisolated let id = UUID()


    /// Three user-visible fases. Internal disclosure (excepciones, conflict
    /// review, change_reason field) renders within the matching fase view.
    public enum Phase: Equatable, Sendable {
        case templatePick
        case paramFill
        case publish
        case done(RuleVersionPublishResult)
    }

    public private(set) var phase: Phase = .templatePick
    public private(set) var selectedTemplate: RuleBuilderTemplate?
    public private(set) var params: [String: JSONConfig] = [:]
    public private(set) var scope: RuleTemplateScope = .group
    public var changeReason: String = ""
    public private(set) var isPublishing: Bool = false
    public private(set) var error: CoordinatorError?

    public let group: Group
    public let templates: [RuleBuilderTemplate]
    private let repo: any RuleTemplateRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rule-builder")

    public init(
        group: Group,
        templates: [RuleBuilderTemplate],
        repo: any RuleTemplateRepository
    ) {
        self.group = group
        self.templates = templates.sorted { $0.sortOrder < $1.sortOrder }
        self.repo = repo
    }

    // MARK: Fase transitions

    public func selectTemplate(_ template: RuleBuilderTemplate) {
        selectedTemplate = template
        // Initialize params from template defaults (jsonb object → dict).
        if case .object(let defaults) = template.defaultParams {
            params = defaults
        } else {
            params = [:]
        }
        error = nil
        phase = .paramFill
    }

    public func goToReview() {
        guard selectedTemplate != nil else { return }
        phase = .publish
    }

    public func backToTemplatePick() {
        selectedTemplate = nil
        params = [:]
        changeReason = ""
        error = nil
        phase = .templatePick
    }

    public func backToParams() {
        error = nil
        phase = .paramFill
    }

    // MARK: Params editing

    public func setParam(_ key: String, intValue: Int) {
        params[key] = .int(intValue)
    }

    public func setParam(_ key: String, stringValue: String) {
        params[key] = .string(stringValue)
    }

    public func paramInt(_ key: String) -> Int? {
        params[key]?.intValue
    }

    /// Computed preview for the sticky bottom + review sheet.
    public var preview: String {
        guard let template = selectedTemplate else { return "" }
        return RuleBuilderSentenceFormatter.summary(template: template, params: params)
    }

    public var previewDetail: String {
        guard let template = selectedTemplate else { return "" }
        return RuleBuilderSentenceFormatter.detail(template: template, params: params)
    }

    // MARK: Publish

    public func publish() async {
        guard let template = selectedTemplate else { return }
        isPublishing = true
        error = nil
        defer { isPublishing = false }

        let reason = changeReason.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await repo.publishRuleVersion(
                groupId: group.id,
                templateId: template.id,
                shapeParams: .object(params),
                scope: scope,
                title: nil,
                changeReason: reason.isEmpty ? nil : reason
            )
            log.info("published rule \(result.ruleId) v\(result.version) from template \(template.id)")
            phase = .done(result)
        } catch {
            log.warning("publish failed: \(error.localizedDescription)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos publicar la regla")
        }
    }
}
