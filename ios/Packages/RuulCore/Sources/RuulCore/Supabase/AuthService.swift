import Foundation
import Supabase

public enum AuthError: Error, Equatable {
    case invalidOTP
    case appleCancelled
    case appleNoToken
    case network
    case unknown(String)
}

public struct AppSession: Sendable, Equatable {
    public let user: AppUser
    public let accessToken: String

    public init(user: AppUser, accessToken: String) {
        self.user = user
        self.accessToken = accessToken
    }
}

public struct AppUser: Sendable, Equatable {
    public let id: UUID
    public let email: String?
    public let phone: String?
    /// True when this user was created via `signInAnonymously` and has not
    /// yet been promoted by a successful OTP verify. Drives onboarding UX
    /// ("Termina el signup para no perder tu grupo"). Mirrored from
    /// Supabase `auth.users.is_anonymous`.
    public let isAnonymous: Bool

    public init(id: UUID, email: String?, phone: String?, isAnonymous: Bool = false) {
        self.id = id
        self.email = email
        self.phone = phone
        self.isAnonymous = isAnonymous
    }
}

public protocol AuthService: Actor {
    var session: AppSession? { get async }
    nonisolated var sessionStream: AsyncStream<AppSession?> { get }

    func signInWithApple() async throws -> AppSession
    func sendPhoneOTP(_ phone: String) async throws
    func verifyPhoneOTP(_ phone: String, code: String) async throws -> AppSession
    func sendEmailOTP(_ email: String) async throws
    func verifyEmailOTP(_ email: String, code: String) async throws -> AppSession
    func signOut() async throws

    /// Sign in anonymously if there's no active session. Used at app launch
    /// so the founder onboarding can create a group at step 2 (before OTP)
    /// — `create_group_with_admin` requires `auth.uid()`. The anon user is
    /// later promoted to a phone-authenticated user via OTP verify.
    ///
    /// Default impl is a no-op (Mock authservices have their own session
    /// management; only LiveAuthService needs a real RPC).
    func signInAnonymouslyIfNeeded() async throws

    /// Initiates a phone number change. Supabase sends an OTP to `newPhone`.
    func startPhoneChange(_ newPhone: String) async throws
    /// Verifies the OTP sent to `newPhone` to complete the phone change.
    func confirmPhoneChange(otp: String, newPhone: String) async throws
    /// Initiates an email change. Supabase sends an OTP to `newEmail`.
    func startEmailChange(_ newEmail: String) async throws
    /// Verifies the OTP sent to `newEmail` to complete the email change.
    func confirmEmailChange(otp: String, newEmail: String) async throws
}

public extension AuthService {
    public func signInAnonymouslyIfNeeded() async throws {
        // No-op default. LiveAuthService overrides.
    }
}

// MARK: - Mock

public actor MockAuthService: AuthService {
    private var _session: AppSession?
    public init() {}
    private var continuations: [UUID: AsyncStream<AppSession?>.Continuation] = [:]

    public var session: AppSession? { _session }

    public nonisolated var sessionStream: AsyncStream<AppSession?> {
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

    public func signInWithApple() async throws -> AppSession {
        let s = AppSession(
            user: AppUser(id: UUID(), email: "apple@example.com", phone: nil),
            accessToken: "mock-apple-token"
        )
        applySession(s)
        return s
    }

    public func sendPhoneOTP(_ phone: String) async throws { /* no-op */ }

    public func verifyPhoneOTP(_ phone: String, code: String) async throws -> AppSession {
        guard code == "123456" else { throw AuthError.invalidOTP }
        let s = AppSession(
            user: AppUser(id: UUID(), email: nil, phone: phone),
            accessToken: "mock-phone-token"
        )
        applySession(s)
        return s
    }

    public func sendEmailOTP(_ email: String) async throws { /* no-op */ }

    public func verifyEmailOTP(_ email: String, code: String) async throws -> AppSession {
        guard code == "123456" else { throw AuthError.invalidOTP }
        let s = AppSession(
            user: AppUser(id: UUID(), email: email, phone: nil),
            accessToken: "mock-email-token"
        )
        applySession(s)
        return s
    }

    public func signOut() async throws {
        applySession(nil)
    }

    public func startPhoneChange(_ newPhone: String) async throws { /* no-op */ }
    public func confirmPhoneChange(otp: String, newPhone: String) async throws { /* no-op */ }
    public func startEmailChange(_ newEmail: String) async throws { /* no-op */ }
    public func confirmEmailChange(otp: String, newEmail: String) async throws { /* no-op */ }
}

// MARK: - Live

public actor LiveAuthService: AuthService {
    private let client: SupabaseClient
    private var _session: AppSession?
    private var continuations: [UUID: AsyncStream<AppSession?>.Continuation] = [:]
    private var observerTask: Task<Void, Never>?

    public init(client: SupabaseClient) {
        self.client = client
        Task { await self.bootstrap() }
    }

    public var session: AppSession? { _session }

    public nonisolated var sessionStream: AsyncStream<AppSession?> {
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

    public func signInWithApple() async throws -> AppSession {
        throw AuthError.unknown("Use signInWithApple(idToken:) on LiveAuthService directly.")
    }

    public func signInWithApple(idToken: String, nonce: String) async throws -> AppSession {
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

    public func sendPhoneOTP(_ phone: String) async throws {
        try await client.auth.signInWithOTP(phone: phone)
    }

    public func verifyPhoneOTP(_ phone: String, code: String) async throws -> AppSession {
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

    public func sendEmailOTP(_ email: String) async throws {
        try await client.auth.signInWithOTP(email: email, shouldCreateUser: true)
    }

    public func verifyEmailOTP(_ email: String, code: String) async throws -> AppSession {
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

    public func signOut() async throws {
        try await client.auth.signOut()
        applySession(nil)
    }

    public func signInAnonymouslyIfNeeded() async throws {
        // Bail out if a session already exists (anon or otherwise) — never
        // wipe a user's session on app launch.
        if (try? await client.auth.session) != nil { return }
        // Anonymous sign-ins must be ENABLED in Supabase Dashboard →
        // Authentication → Providers. If disabled, the throw bubbles up;
        // GroupsRepository's reactive retry pattern still handles
        // create-group cases as a fallback.
        //
        // The bootstrap()-subscribed authStateChanges stream picks up the
        // new session and propagates it via applySession(_:); no manual
        // session yield needed here.
        _ = try await client.auth.signInAnonymously()
    }

    public func startPhoneChange(_ newPhone: String) async throws {
        _ = try await client.auth.update(user: UserAttributes(phone: newPhone))
    }

    public func confirmPhoneChange(otp: String, newPhone: String) async throws {
        _ = try await client.auth.verifyOTP(phone: newPhone, token: otp, type: .phoneChange)
    }

    public func startEmailChange(_ newEmail: String) async throws {
        _ = try await client.auth.update(user: UserAttributes(email: newEmail))
    }

    public func confirmEmailChange(otp: String, newEmail: String) async throws {
        _ = try await client.auth.verifyOTP(email: newEmail, token: otp, type: .emailChange)
    }
}

private extension Supabase.Session {
    public func toAppSession() -> AppSession {
        AppSession(
            user: AppUser(
                id: user.id,
                email: user.email,
                phone: user.phone,
                isAnonymous: user.isAnonymous
            ),
            accessToken: accessToken
        )
    }
}
