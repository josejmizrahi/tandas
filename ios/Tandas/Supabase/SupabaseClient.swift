import Foundation
import Supabase

enum SupabaseConfigError: Error {
    case missingURL
    case missingAnonKey
    case malformedURL
}

enum SupabaseEnvironment {
    /// `SupabaseClient` is `Sendable`, so `shared` does not need actor isolation.
    /// Keeping it nonisolated lets the EnvironmentKey conformance below stay
    /// nonisolated under Swift 6 strict concurrency.
    static let shared: SupabaseClient = {
        do {
            return try makeClient()
        } catch {
            fatalError("Supabase configuration error: \(error)")
        }
    }()

    static func makeClient() throws -> SupabaseClient {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let urlString = info["TandasSupabaseURL"] as? String, !urlString.isEmpty else {
            throw SupabaseConfigError.missingURL
        }
        guard let anonKey = info["TandasSupabaseAnonKey"] as? String, !anonKey.isEmpty else {
            throw SupabaseConfigError.missingAnonKey
        }
        guard let url = URL(string: urlString) else {
            throw SupabaseConfigError.malformedURL
        }
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(
                db: SupabaseClientOptions.DatabaseOptions(
                    encoder: .tandas,
                    decoder: .tandas
                )
            )
        )
    }

    /// Host string read from the same Info.plist value the client was built from.
    /// Convenient for debug captions; `SupabaseClient.supabaseURL` is internal in
    /// supabase-swift 2.x.
    static var configuredHost: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let urlString = info["TandasSupabaseURL"] as? String,
              let url = URL(string: urlString),
              let host = url.host()
        else { return "?" }
        return host
    }
}
