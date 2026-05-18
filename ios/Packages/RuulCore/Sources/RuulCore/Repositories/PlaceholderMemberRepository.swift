import Foundation
import OSLog
import Supabase

/// Result of `create-placeholder-member` edge function. Mirrors the three
/// `kind`s the server returns (created / existing_user / duplicate_placeholder)
/// plus a generic failure for anything else.
public enum PlaceholderMemberCreateResult: Sendable, Equatable {
    case created(memberId: UUID, inviteId: UUID, placeholderUserId: UUID)
    case existingUser(userId: UUID, displayName: String?)
    case duplicatePlaceholder(userId: UUID)
    case failed(String)
}

public protocol PlaceholderMemberRepository: Actor {
    /// Invokes the `create-placeholder-member` edge function. The function
    /// runs the dup-phone preflight (real-user vs unclaimed placeholder),
    /// creates the anonymous auth.users row, and atomically finalizes
    /// profile + group_members + invite. WhatsApp is fire-and-forget.
    func create(groupId: UUID, displayName: String, phoneE164: String) async throws -> PlaceholderMemberCreateResult
}

// MARK: - Live

public actor LivePlaceholderMemberRepository: PlaceholderMemberRepository {
    private let client: SupabaseClient
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "placeholderMembers")

    public init(client: SupabaseClient) { self.client = client }

    public func create(groupId: UUID, displayName: String, phoneE164: String) async throws -> PlaceholderMemberCreateResult {
        struct Body: Encodable {
            let group_id: String
            let display_name: String
            let phone_e164: String
        }
        struct Response: Decodable {
            let kind: String
            let member_id: String?
            let invite_id: String?
            let placeholder_user_id: String?
            let user_id: String?
            let display_name: String?
            let error: String?
        }

        let body = Body(
            group_id: groupId.uuidString.lowercased(),
            display_name: displayName,
            phone_e164: phoneE164
        )

        do {
            let response: Response = try await client.functions.invoke(
                "create-placeholder-member",
                options: FunctionInvokeOptions(body: body)
            )

            switch response.kind {
            case "created":
                guard let mid = response.member_id.flatMap(UUID.init(uuidString:)),
                      let iid = response.invite_id.flatMap(UUID.init(uuidString:)),
                      let pid = response.placeholder_user_id.flatMap(UUID.init(uuidString:)) else {
                    return .failed("malformed_created_response")
                }
                return .created(memberId: mid, inviteId: iid, placeholderUserId: pid)
            case "existing_user":
                guard let uid = response.user_id.flatMap(UUID.init(uuidString:)) else {
                    return .failed("malformed_existing_user_response")
                }
                return .existingUser(userId: uid, displayName: response.display_name)
            case "duplicate_placeholder":
                guard let uid = response.user_id.flatMap(UUID.init(uuidString:)) else {
                    return .failed("malformed_duplicate_response")
                }
                return .duplicatePlaceholder(userId: uid)
            default:
                return .failed(response.error ?? "unknown_kind_\(response.kind)")
            }
        } catch let error as FunctionsError {
            // The Supabase SDK wraps non-2xx as FunctionsError; for our
            // 409s we still want a structured signal. Try to read the body
            // out of the error so the UI can surface a useful message.
            log.warning("create-placeholder-member non-2xx: \(String(describing: error), privacy: .public)")
            switch error {
            case .httpError(_, let data):
                if let message = String(data: data, encoding: .utf8) {
                    return .failed(message)
                }
                return .failed("http_error")
            default:
                return .failed(error.localizedDescription)
            }
        } catch {
            log.error("create-placeholder-member failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Mock

public actor MockPlaceholderMemberRepository: PlaceholderMemberRepository {
    public var nextResult: PlaceholderMemberCreateResult?
    public var createCalls: [(groupId: UUID, displayName: String, phoneE164: String)] = []

    public init(nextResult: PlaceholderMemberCreateResult? = nil) {
        self.nextResult = nextResult
    }

    public func create(groupId: UUID, displayName: String, phoneE164: String) async throws -> PlaceholderMemberCreateResult {
        createCalls.append((groupId, displayName, phoneE164))
        if let r = nextResult { return r }
        return .created(memberId: UUID(), inviteId: UUID(), placeholderUserId: UUID())
    }
}
