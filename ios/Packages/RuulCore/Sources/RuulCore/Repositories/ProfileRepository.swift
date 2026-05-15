import Foundation
import Supabase

public protocol ProfileRepository: Actor {
    func loadMine() async throws -> Profile
    func updateDisplayName(_ name: String) async throws
    /// Uploads `data` to the per-user avatar prefix (`{userId}/avatar-{ts}.{ext}`),
    /// updates `profiles.avatar_url` with the public URL, and returns it.
    /// `contentType` must match the bucket-allowed MIME types
    /// (jpeg / png / webp / heic / heif). Size limit is 2 MB at bucket level.
    func updateAvatar(data: Data, contentType: String) async throws -> URL
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
        // Deterministic mock URL for previews/tests.
        let url = URL(string: "https://example.test/avatars/\(_profile.id.uuidString.lowercased()).jpg")!
        _profile.avatarUrl = url.absoluteString
        return url
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
        // Timestamp suffix forces CDN cache miss on re-upload (avatars are
        // overwritten in place via upsert, but plain `avatar.ext` would be
        // served stale by intermediaries).
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
