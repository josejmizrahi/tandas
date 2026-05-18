import Foundation

/// Polymorphic resource deep link. Cubre los 6 resource types canónicos
/// (event/fund/asset/slot/space/right) con una sola estructura. El
/// receiver (RootShell) deja que el detail polimórfico —
/// ResourceDetailSheet o EventDetailHost equivalent— hidrate por id.
///
/// Antes solo existía `EventDeepLink`. Compartir un fund/asset/slot/
/// space/right desde notif o URL no tenía handler y la app abría en
/// Home sin contexto.
///
/// Formatos aceptados:
///   - `ruul://resource/<uuid>`            — sin tipo, resource detail
///                                            polimórfico decide chrome
///   - `ruul://event/<uuid>`               — back-compat con EventDeepLink
///   - `ruul://<type>/<uuid>` donde type ∈
///     {fund, asset, slot, space, right}   — semantic deep link
///   - `https://{ruul.mx,ruul.app}/<path>/<uuid>` — universal links equivalentes
public struct ResourceDeepLink: Sendable, Hashable {
    public let resourceId: UUID
    /// Tipo hint para que el receptor escoja chrome correcto sin
    /// hidratar. `nil` cuando el deep link no especifica (formato
    /// `ruul://resource/<id>`). El router puede aún resolver tipo
    /// vía repo.
    public let resourceType: ResourceType?

    public static let userInfoKey = "ruul_resource_id"
    public static let typeUserInfoKey = "ruul_resource_type"

    public init(resourceId: UUID, resourceType: ResourceType? = nil) {
        self.resourceId = resourceId
        self.resourceType = resourceType
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.userInfoKey] as? String,
              let id = UUID(uuidString: raw) else { return nil }
        self.resourceId = id
        if let typeRaw = userInfo[Self.typeUserInfoKey] as? String,
           ResourceType.knownRawValues.contains(typeRaw) {
            self.resourceType = ResourceType.from(raw: typeRaw)
        } else {
            self.resourceType = nil
        }
    }

    public init?(url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        // ruul://<type>/<uuid>
        if scheme == "ruul",
           let host = url.host?.lowercased(),
           let last = url.pathComponents.last(where: { $0 != "/" }),
           let id = UUID(uuidString: last) {
            switch host {
            case "resource":
                self.resourceId = id
                self.resourceType = nil
                return
            case "event", "fund", "asset", "slot", "space", "right":
                self.resourceId = id
                self.resourceType = ResourceType.from(raw: host)
                return
            default:
                return nil
            }
        }
        // https://{ruul.mx,ruul.app}/<path>/<uuid>
        if RuulDomain.isOurHTTPS(url),
           url.pathComponents.count >= 3,
           let id = UUID(uuidString: url.pathComponents[2]) {
            let segment = url.pathComponents[1].lowercased()
            switch segment {
            case "resource":
                self.resourceId = id
                self.resourceType = nil
                return
            case "event", "fund", "asset", "slot", "space", "right":
                self.resourceId = id
                self.resourceType = ResourceType.from(raw: segment)
                return
            default:
                return nil
            }
        }
        return nil
    }

    public var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [Self.userInfoKey: resourceId.uuidString]
        if let resourceType { info[Self.typeUserInfoKey] = resourceType.rawString }
        return info
    }
}
