import Foundation
import Observation

/// F.1A-1 — store del shell de configuración personal.
@MainActor
@Observable
public final class PersonalSettingsStore {
    public private(set) var settings: PersonalSettings?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(rpc: any RuulRPCClient, previewSettings: PersonalSettings) {
        self.rpc = rpc
        self.settings = previewSettings
        self.phase = .loaded
    }

    public func load() async {
        if settings == nil { phase = .loading }
        do {
            settings = try await rpc.personalSettingsSummary()
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func can(_ action: String) -> Bool { settings?.can(action) ?? false }

    // MARK: - Mutaciones

    /// F.1A-1 — actualiza un slot de notificación.
    public func setNotification(_ key: NotificationKey, push: Bool? = nil, email: Bool? = nil) async throws {
        guard let current = settings else { return }
        let slot = current.notifications.slot(for: key)
        let newSlot: [String: JSONValue] = [
            "push": .bool(push ?? slot.push),
            "email": .bool(email ?? slot.email),
        ]
        let metadata: JSONValue = .object([
            "notifications": .object([key.rawValue: .object(newSlot)])
        ])
        _ = try await rpc.updateMyProfileMetadata(metadata)
        await load()
    }
}

/// 7 categorías canónicas de notificaciones (mirror del backend).
public enum NotificationKey: String, Sendable, CaseIterable, Identifiable {
    case invitations
    case decisions
    case reservations
    case events
    case obligations
    case money
    case rules

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .invitations:  return "Invitaciones"
        case .decisions:    return "Decisiones"
        case .reservations: return "Reservaciones"
        case .events:       return "Eventos"
        case .obligations:  return "Obligaciones"
        case .money:        return "Dinero"
        case .rules:        return "Reglas"
        }
    }
}

extension NotificationSettings {
    public func slot(for key: NotificationKey) -> NotificationSlot {
        switch key {
        case .invitations:  return invitations
        case .decisions:    return decisions
        case .reservations: return reservations
        case .events:       return events
        case .obligations:  return obligations
        case .money:        return money
        case .rules:        return rules
        }
    }
}
