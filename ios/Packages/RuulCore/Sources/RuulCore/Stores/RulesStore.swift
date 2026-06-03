import Foundation
import Observation

/// F.8 — store de reglas del contexto.
@MainActor
@Observable
public final class RulesStore {
    public private(set) var rules: [Rule] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(rpc: any RuulRPCClient, previewRules: [Rule], permissions: [String] = []) {
        self.rpc = rpc
        self.rules = previewRules
        self.myPermissions = permissions
        self.phase = .loaded
    }

    public var activeRules: [Rule] { rules.filter(\.isActive) }

    public func load(context: AppContext) async {
        if rules.isEmpty { phase = .loading }
        do {
            async let rulesTask = rpc.listRules(contextId: context.id)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (loaded, summary) = try await (rulesTask, summaryTask)
            rules = loaded
            myPermissions = summary.myPermissions
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func canManage(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("rules.manage")
    }

    public func createRule(_ input: CreateRuleInput, context: AppContext) async throws -> Rule {
        let rule = try await rpc.createRule(input)
        await load(context: context)
        return rule
    }
}
