import Foundation
import Supabase

enum AuthError: Error, Equatable {
    case invalidOTP
    case appleCancelled
    case appleNoToken
    case network
    case unknown(String)
}

struct AppSession: Sendable, Equatable {
    let user: AppUser
    let accessToken: String
}

struct AppUser: Sendable, Equatable {
    let id: UUID
    let email: String?
    let phone: String?
}

protocol AuthService: Actor {
    var session: AppSession? { get async }
    nonisolated var sessionStream: AsyncStream<AppSession?> { get }

    func signInWithApple() async throws -> AppSession
    func sendPhoneOTP(_ phone: String) async throws
    func verifyPhoneOTP(_ phone: String, code: String) async throws -> AppSession
    func sendEmailOTP(_ email: String) async throws
    func verifyEmailOTP(_ email: String, code: String) async throws -> AppSession
    func signOut() async throws
}

// MARK: - Mock

actor MockAuthService: AuthService {
    private var _session: AppSession?
    private var continuations: [UUID: AsyncStream<AppSession?>.Continuation] = [:]

    var session: AppSession? { _session }

    nonisolated var sessionStream: AsyncStream<AppSession?> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregister(id: id) }
            }
            Task { await self.register(continuation, id: id) }
        }
    }

    private func register(_ c: AsyncStream<AppSession?>.Continuation, id: UUID) {
        continuations[id] = c
        c.yield(_session)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func applySession(_ s: AppSession?) {
        _session = s
        for (_, c) in continuations {
            c.yield(s)
        }
    }

    func signInWithApple() async throws -> AppSession {
        let s = AppSession(
            user: AppUser(id: UUID(), email: "apple@example.com", phone: nil),
            accessToken: "mock-apple-token"
        )
        applySession(s)
        return s
    }

    func sendPhoneOTP(_ phone: String) async throws { /* no-op */ }

    func verifyPhoneOTP(_ phone: String, code: String) async throws -> AppSession {
        guard code == "123456" else { throw AuthError.invalidOTP }
        let s = AppSession(
            user: AppUser(id: UUID(), email: nil, phone: phone),
            accessToken: "mock-phone-token"
        )
        applySession(s)
        return s
    }

    func sendEmailOTP(_ email: String) async throws { /* no-op */ }

    func verifyEmailOTP(_ email: String, code: String) async throws -> AppSession {
        guard code == "123456" else { throw AuthError.invalidOTP }
        let s = AppSession(
            user: AppUser(id: UUID(), email: email, phone: nil),
            accessToken: "mock-email-token"
        )
        applySession(s)
        return s
    }

    func signOut() async throws {
        applySession(nil)
    }
}

// MARK: - Live

actor LiveAuthService: AuthService {
    private let client: SupabaseClient
    private var _session: AppSession?
    private var continuations: [UUID: AsyncStream<AppSession?>.Continuation] = [:]
    private var observerTask: Task<Void, Never>?

    init(client: SupabaseClient) {
        self.client = client
        Task { await self.bootstrap() }
    }

    var session: AppSession? { _session }

    nonisolated var sessionStream: AsyncStream<AppSession?> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregister(id: id) }
            }
            Task { await self.register(continuation, id: id) }
        }
    }

    private func register(_ c: AsyncStream<AppSession?>.Continuation, id: UUID) {
        continuations[id] = c
        c.yield(_session)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func applySession(_ s: AppSession?) {
        _session = s
        for (_, c) in continuations {
            c.yield(s)
        }
    }

    private func bootstrap() async {
        if let session = try? await client.auth.session {
            applySession(session.toAppSession())
        }
        let stream = client.auth.authStateChanges
        observerTask = Task { [weak self] in
            for await change in stream {
                let mapped = change.session?.toAppSession()
                await self?.applySession(mapped)
            }
        }
    }

    func signInWithApple() async throws -> AppSession {
        throw AuthError.unknown("Use signInWithApple(idToken:) on LiveAuthService directly.")
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> AppSession {
        do {
            let response = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            )
            let mapped = response.toAppSession()
            applySession(mapped)
            return mapped
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    func sendPhoneOTP(_ phone: String) async throws {
        try await client.auth.signInWithOTP(phone: phone)
    }

    func verifyPhoneOTP(_ phone: String, code: String) async throws -> AppSession {
        do {
            let response = try await client.auth.verifyOTP(phone: phone, token: code, type: .sms)
            guard let session = response.session else { throw AuthError.invalidOTP }
            let mapped = session.toAppSession()
            applySession(mapped)
            return mapped
        } catch {
            throw AuthError.invalidOTP
        }
    }

    func sendEmailOTP(_ email: String) async throws {
        try await client.auth.signInWithOTP(email: email, shouldCreateUser: true)
    }

    func verifyEmailOTP(_ email: String, code: String) async throws -> AppSession {
        do {
            let response = try await client.auth.verifyOTP(email: email, token: code, type: .email)
            guard let session = response.session else { throw AuthError.invalidOTP }
            let mapped = session.toAppSession()
            applySession(mapped)
            return mapped
        } catch {
            throw AuthError.invalidOTP
        }
    }

    func signOut() async throws {
        try await client.auth.signOut()
        applySession(nil)
    }
}

private extension Supabase.Session {
    func toAppSession() -> AppSession {
        AppSession(
            user: AppUser(
                id: user.id,
                email: user.email,
                phone: user.phone
            ),
            accessToken: accessToken
        )
    }
}
