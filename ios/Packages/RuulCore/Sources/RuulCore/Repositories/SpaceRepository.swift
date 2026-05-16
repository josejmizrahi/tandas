import Foundation
import Supabase

public enum SpaceError: Error, Equatable {
    case rpcFailed(String)
    case notFound
    case decodeFailed(String)
}

/// CRUD surface for `resource_type='space'`. Reads come from the
/// polymorphic `public.resources` table filtered by resource_type;
/// writes go through `create_space` (mig 00203).
///
/// No dedicated `spaces` table exists — Space lives entirely in
/// `resources.metadata` jsonb. The repo decodes via `ResourceRow.decodeAsSpace()`.
public protocol SpaceRepository: Actor {
    /// All active (non-archived) spaces for a group, newest first.
    func listForGroup(_ groupId: UUID) async throws -> [Space]

    /// Single space by id. Throws `notFound` if missing or archived.
    func get(_ spaceId: UUID) async throws -> Space

    /// Creates a new space. Returns the inserted row's id.
    func create(
        groupId: UUID,
        name: String,
        capacity: Int?,
        locationName: String?,
        locationLat: Double?,
        locationLng: Double?,
        description: String?
    ) async throws -> UUID
}

// MARK: - Mock

public actor MockSpaceRepository: SpaceRepository {
    private var spaces: [Space]

    public init(seed: [Space] = []) {
        self.spaces = seed
    }

    public func listForGroup(_ groupId: UUID) async throws -> [Space] {
        spaces
            .filter { $0.groupId == groupId && $0.archivedAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func get(_ spaceId: UUID) async throws -> Space {
        guard let s = spaces.first(where: { $0.id == spaceId && $0.archivedAt == nil }) else {
            throw SpaceError.notFound
        }
        return s
    }

    @discardableResult
    public func create(
        groupId: UUID,
        name: String,
        capacity: Int?,
        locationName: String?,
        locationLat: Double?,
        locationLng: Double?,
        description: String?
    ) async throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpaceError.rpcFailed("space name required")
        }
        let id = UUID()
        let now = Date()
        let space = Space(
            id: id,
            groupId: groupId,
            name: trimmed,
            capacity: capacity,
            locationName: locationName,
            locationLat: locationLat,
            locationLng: locationLng,
            description: description,
            status: "active",
            createdAt: now,
            updatedAt: now
        )
        spaces.append(space)
        return id
    }

    /// Test helper: install a snapshot so view code can render without
    /// going through the wizard.
    public func stub(_ space: Space) {
        spaces.append(space)
    }
}

// MARK: - Live

public actor LiveSpaceRepository: SpaceRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func listForGroup(_ groupId: UUID) async throws -> [Space] {
        do {
            let rows: [ResourceRow] = try await client
                .from("resources")
                .select()
                .eq("group_id", value: groupId.uuidString.lowercased())
                .eq("resource_type", value: "space")
                .is("archived_at", value: nil)
                .order("created_at", ascending: false)
                .execute()
                .value
            return try rows.map { try $0.decodeAsSpace() }
        } catch let e as SpaceError {
            throw e
        } catch let e as ResourceRowError {
            throw SpaceError.decodeFailed("\(e)")
        } catch {
            throw SpaceError.rpcFailed(error.localizedDescription)
        }
    }

    public func get(_ spaceId: UUID) async throws -> Space {
        do {
            let row: ResourceRow = try await client
                .from("resources")
                .select()
                .eq("id", value: spaceId.uuidString.lowercased())
                .eq("resource_type", value: "space")
                .single()
                .execute()
                .value
            return try row.decodeAsSpace()
        } catch let e as ResourceRowError {
            throw SpaceError.decodeFailed("\(e)")
        } catch {
            throw SpaceError.rpcFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public func create(
        groupId: UUID,
        name: String,
        capacity: Int?,
        locationName: String?,
        locationLat: Double?,
        locationLng: Double?,
        description: String?
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_group_id: String
            let p_name: String
            let p_capacity: Int?
            let p_location_name: String?
            let p_location_lat: Double?
            let p_location_lng: Double?
            let p_description: String?
        }
        do {
            let response = try await client
                .rpc("create_space", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_name: name,
                    p_capacity: capacity,
                    p_location_name: (locationName?.isEmpty ?? true) ? nil : locationName,
                    p_location_lat: locationLat,
                    p_location_lng: locationLng,
                    p_description: (description?.isEmpty ?? true) ? nil : description
                ))
                .execute()
            // The RPC returns a single uuid; Supabase Swift wraps it as JSON.
            let raw = String(decoding: response.data, as: UTF8.self)
                .trimmingCharacters(in: .init(charactersIn: "\"\n "))
            guard let id = UUID(uuidString: raw) else {
                throw SpaceError.decodeFailed("create_space returned non-UUID: \(raw)")
            }
            return id
        } catch let e as SpaceError {
            throw e
        } catch {
            throw SpaceError.rpcFailed(error.localizedDescription)
        }
    }
}
