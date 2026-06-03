import Foundation
import Observation

/// F.1A-2 — store del shell de configuración del contexto.
@MainActor
@Observable
public final class ContextSettingsStore {
    public private(set) var settings: ContextSettings?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(rpc: any RuulRPCClient, previewSettings: ContextSettings) {
        self.rpc = rpc
        self.settings = previewSettings
        self.phase = .loaded
    }

    public func load(contextId: UUID) async {
        if settings == nil { phase = .loading }
        do {
            settings = try await rpc.contextSettingsSummary(contextId: contextId)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func can(_ action: String) -> Bool { settings?.can(action) ?? false }

    /// F.1A polish — wrapper sobre `update_context` que refresca el summary.
    /// El backend devuelve el ContextSettings actualizado; lo cacheamos.
    public func update(_ input: UpdateContextInput) async throws {
        settings = try await rpc.updateContext(input)
        phase = .loaded
    }

    /// F.1A polish — edita name/description/visibility/image en una sola llamada.
    public func setGeneral(
        contextId: UUID,
        displayName: String? = nil,
        description: String? = nil,
        visibility: String? = nil,
        imageUrl: String? = nil
    ) async throws {
        try await update(UpdateContextInput(
            contextId: contextId,
            displayName: displayName,
            description: description,
            visibility: visibility,
            imageUrl: imageUrl
        ))
    }

    /// F.1A polish — actualiza decisions_config (default_voting_model/quorum/majority_rule).
    public func setDecisionsConfig(contextId: UUID, _ fields: [String: JSONValue]) async throws {
        try await update(UpdateContextInput(
            contextId: contextId,
            decisionsConfig: .object(fields)
        ))
    }

    /// F.1A polish — actualiza money_config (currency/default_split/settlement_policy).
    public func setMoneyConfig(contextId: UUID, _ fields: [String: JSONValue]) async throws {
        try await update(UpdateContextInput(
            contextId: contextId,
            moneyConfig: .object(fields)
        ))
    }

    /// F.1A polish — actualiza reservations_config (priority_policy/conflict_resolution/cancellation_policy).
    public func setReservationsConfig(contextId: UUID, _ fields: [String: JSONValue]) async throws {
        try await update(UpdateContextInput(
            contextId: contextId,
            reservationsConfig: .object(fields)
        ))
    }

    /// F.1A polish — actualiza invitations_config (who_can_invite/open_invites).
    public func setInvitationsConfig(contextId: UUID, _ fields: [String: JSONValue]) async throws {
        try await update(UpdateContextInput(
            contextId: contextId,
            invitationsConfig: .object(fields)
        ))
    }
}
