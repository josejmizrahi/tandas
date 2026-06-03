import Foundation
import Observation

/// Rutea URLs entrantes hacia la pantalla correcta. Hoy solo invitaciones:
///
///   https://ruul.mx/invite/CODE   (universal link, AASA en web/public)
///   https://ruul.app/invite/CODE
///   ruul://invite/CODE            (custom scheme de Info.plist)
///
/// El código queda pendiente hasta que el shell pasa los gates de
/// sesión/actor y puede presentar `JoinByCodeView` con el código prellenado.
@MainActor
@Observable
public final class DeepLinkRouter {
    public private(set) var pendingInviteCode: String?

    public init() {}

    /// Procesa una URL entrante. Devuelve `true` si se reconoció.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard let code = Self.inviteCode(from: url) else { return false }
        pendingInviteCode = code
        return true
    }

    /// Devuelve y limpia el código pendiente (lo llama quien lo presenta).
    public func consumePendingInviteCode() -> String? {
        defer { pendingInviteCode = nil }
        return pendingInviteCode
    }

    /// Extrae el código de invitación de una URL soportada, o `nil`.
    public nonisolated static func inviteCode(from url: URL) -> String? {
        let segments = url.pathComponents.filter { $0 != "/" }

        switch url.scheme?.lowercased() {
        case "https", "http":
            // https://ruul.mx/invite/CODE → path ["invite", "CODE"]
            guard segments.count >= 2, segments[0] == "invite" else { return nil }
            return normalized(segments[1])

        case "ruul":
            // ruul://invite/CODE → host "invite", path ["CODE"]
            guard url.host()?.lowercased() == "invite", let code = segments.first else { return nil }
            return normalized(code)

        default:
            return nil
        }
    }

    private nonisolated static func normalized(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }
}
