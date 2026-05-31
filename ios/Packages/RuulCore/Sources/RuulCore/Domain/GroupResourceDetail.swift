import Foundation

/// V3 Resources Deep. Read shape returned by
/// `public.group_resource_detail(p_resource_id)` — the augmented
/// envelope (with `unit`, `metadata`, `series_id`, `archived_at`,
/// `ownership_metadata`) plus the typed `subtype` jsonb for the 5
/// subtype-backed types (`asset, fund, space, right, slot`). Envelope-
/// only types receive `subtype = nil`.
///
/// Subtype accessors (`assetSubtype`, etc.) lazily decode the raw
/// `RPCJSONValue` into strongly typed structs so feature code stays
/// branch-free.
public struct GroupResourceDetail: Sendable, Equatable, Hashable {
    public let resource: GroupResource
    public let subtype: RPCJSONValue?

    public init(resource: GroupResource, subtype: RPCJSONValue? = nil) {
        self.resource = resource
        self.subtype = subtype
    }
}

extension GroupResourceDetail: Decodable {
    private enum SubtypeKeys: String, CodingKey { case subtype }

    public init(from decoder: Decoder) throws {
        self.resource = try GroupResource(from: decoder)
        let c = try decoder.container(keyedBy: SubtypeKeys.self)
        self.subtype = try c.decodeIfPresent(RPCJSONValue.self, forKey: .subtype)
    }
}

public extension GroupResourceDetail {
    /// Lazily decode the asset subtype payload. Returns `nil` when the
    /// resource isn't an asset or the subtype row is missing.
    var assetSubtype: AssetSubtypeData? {
        guard resource.resourceType == .asset,
              let raw = subtype,
              case .object = raw else { return nil }
        do {
            let data = try JSONEncoder.tandas.encode(raw)
            return try JSONDecoder.tandas.decode(AssetSubtypeData.self, from: data)
        } catch {
            return nil
        }
    }
}
