import Foundation
import Supabase

public protocol ProfileRepository: Actor {
    func loadMine() async throws -> Profile
    func updateDisplayName(_ name: String) async throws
    func updateAvatar(data: Data, contentType: String) async throws -> URL
    /// IANA timezone (e.g., "America/Mexico_City"). RLS allows self-write.
    func updateTimezone(_ tz: String) async throws
    /// BCP-47 locale tag (e.g., "es-MX"). RLS allows self-write.
    func updateLocale(_ locale: String) async throws

    /// LFPDPPP/CCPA right-to-erasure. Pseudonimiza profile, desactiva
    /// memberships, purga tokens + preferences, emite memberLeft system
    /// events. Devuelve el request_id loggeado en
    /// data_subject_rights_requests para audit trail. El cliente debe
    /// llamar AuthService.signOut() después.
    func deleteAccount() async throws -> UUID

    /// LFPDPPP/CCPA right-to-portability. Devuelve un JSON Data con
    /// profile + memberships + fines + rsvps + votes + system_events +
    /// ledger_entries + notification_preferences. iOS típicamente lo
    /// guarda a Files o lo comparte via UIActivityViewController.
    func exportMyData() async throws -> Data
}

public actor MockProfileRepository: ProfileRepository {
    private var _profile: Profile

    public init(seed: Profile = Profile(id: UUID(), displayName: "", avatarUrl: nil, phone: nil)) {
        self._profile = seed
    }

    public func loadMine() async throws -> Profile { _profile }

    public func updateDisplayName(_ name: String) async throws {
        _profile.displayName = name
    }

    public func updateAvatar(data: Data, contentType: String) async throws -> URL {
        let url = URL(string: "https://example.test/avatars/\(_profile.id.uuidString.lowercased()).jpg")!
        _profile.avatarUrl = url.absoluteString
        return url
    }

    public func updateTimezone(_ tz: String) async throws {
        _profile.timezone = tz
    }

    public func updateLocale(_ locale: String) async throws {
        _profile.locale = locale
    }

    public func deleteAccount() async throws -> UUID {
        _profile.displayName = "Cuenta eliminada"
        _profile.avatarUrl = nil
        _profile.phone = nil
        return UUID()
    }

    public func exportMyData() async throws -> Data {
        let payload: [String: Any] = [
            "exported_at": ISO8601DateFormatter().string(from: .now),
            "user_id": _profile.id.uuidString,
            "schema_version": 1,
            "profile": [
                "id": _profile.id.uuidString,
                "display_name": _profile.displayName
            ],
            "memberships": [],
            "fines": [],
            "rsvps": [],
            "votes": [],
            "system_events": [],
            "ledger_entries": [],
            "notification_preferences": []
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}

public actor LiveProfileRepository: ProfileRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) { self.client = client }

    public func loadMine() async throws -> Profile {
        let userId = try await client.auth.session.user.id
        let row: Profile = try await client
            .from("profiles")
            .select("id, display_name, avatar_url, phone, timezone, locale")
            .eq("id", value: userId.uuidString.lowercased())
            .single()
            .execute()
            .value
        return row
    }

    public func updateDisplayName(_ name: String) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("profiles")
            .update(["display_name": name])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()
    }

    public func updateAvatar(data: Data, contentType: String) async throws -> URL {
        let userId = try await client.auth.session.user.id
        let ext = Self.fileExtension(for: contentType)
        let ts = Int(Date.now.timeIntervalSince1970)
        let path = "\(userId.uuidString.lowercased())/avatar-\(ts).\(ext)"

        _ = try await client.storage
            .from("avatars")
            .upload(
                path,
                data: data,
                options: FileOptions(
                    cacheControl: "3600",
                    contentType: contentType,
                    upsert: true
                )
            )

        let publicURL = try client.storage.from("avatars").getPublicURL(path: path)

        try await client
            .from("profiles")
            .update(["avatar_url": publicURL.absoluteString])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()

        return publicURL
    }

    public func updateTimezone(_ tz: String) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("profiles")
            .update(["timezone": tz])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()
    }

    public func updateLocale(_ locale: String) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("profiles")
            .update(["locale": locale])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()
    }

    public func deleteAccount() async throws -> UUID {
        // SECURITY DEFINER en backend. Devuelve el request_id loggeado
        // en data_subject_rights_requests (mig 00253). El cliente
        // debe llamar AuthService.signOut() después para limpiar la
        // sesión local.
        let response: UUID = try await client
            .rpc("delete_my_account")
            .execute()
            .value
        return response
    }

    public func exportMyData() async throws -> Data {
        // Devuelve jsonb crudo. PostgREST lo serializa como JSON con
        // content-type application/json — el bytes ya está listo para
        // share/save.
        let raw = try await client.rpc("export_my_data").execute().data
        return raw
    }

    private static func fileExtension(for contentType: String) -> String {
        switch contentType.lowercased() {
        case "image/jpeg", "image/jpg":  return "jpg"
        case "image/png":                return "png"
        case "image/webp":               return "webp"
        case "image/heic":               return "heic"
        case "image/heif":               return "heif"
        default:                         return "jpg"
        }
    }
}
