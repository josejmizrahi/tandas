import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

/// Coordinator backing `AddManualFineSheet`. Loads the group's members,
/// validates the form, calls `FineRepository.issueManual`, and humanizes
/// server errors. View is dumb: only renders this state and dispatches
/// `submit(...)`.
///
/// V1 entry: `EventDetailView` host actions; eventId always non-nil.
@Observable @MainActor
public final class AddManualFineCoordinator {
    public let groupId: UUID
    public let eventId: UUID

    public private(set) var members: [MemberWithProfile] = []
    public private(set) var isLoadingMembers: Bool = true
    public var selectedMemberId: UUID?
    public var amountText: String = ""
    public var reason: String = ""
    public private(set) var isSubmitting: Bool = false
    public private(set) var error: String?

    private let fineRepo: any FineRepository
    private let groupsRepo: any GroupsRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.addManual")

    public init(
        groupId: UUID,
        eventId: UUID,
        fineRepo: any FineRepository,
        groupsRepo: any GroupsRepository
    ) {
        self.groupId = groupId
        self.eventId = eventId
        self.fineRepo = fineRepo
        self.groupsRepo = groupsRepo
    }

    // MARK: - Derived state

    /// Decimal parsed from `amountText`. Locale-tolerant: accepts "200",
    /// "200.50", "200,50". Returns nil if empty / unparseable / negative.
    public var parsedAmount: Decimal? {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = [trimmed,
                          trimmed.replacingOccurrences(of: ",", with: "."),
                          trimmed.replacingOccurrences(of: ".", with: ",")]
        for c in candidates {
            if let d = Decimal(string: c), d >= 0 { return d }
        }
        return nil
    }

    public var canSubmit: Bool {
        guard !isSubmitting else { return false }
        guard selectedMemberId != nil else { return false }
        guard parsedAmount != nil else { return false }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return true
    }

    /// Display name of the selected member, or empty string if none.
    public var selectedMemberName: String {
        guard let id = selectedMemberId,
              let mwp = members.first(where: { $0.member.userId == id })
        else { return "" }
        return mwp.displayName
    }

    // MARK: - Member loading

    /// Loads members of the group, excludes the current user, sorts founders
    /// first then alphabetically.
    public func loadMembers(currentUserId: UUID) async {
        isLoadingMembers = true
        defer { isLoadingMembers = false }
        do {
            let rows = try await groupsRepo.membersWithProfiles(of: groupId)
            members = rows
                .filter { $0.member.userId != currentUserId }
                .sorted { lhs, rhs in
                    if lhs.member.isFounder != rhs.member.isFounder {
                        return lhs.member.isFounder
                    }
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
        } catch {
            log.warning("loadMembers failed: \(error.localizedDescription)")
            members = []
        }
    }

    // MARK: - Submit

    /// Issues the manual fine via FineRepository. Returns the resulting Fine
    /// on success, nil on failure (caller can read `error` for the message).
    /// Caller is responsible for dismissing the sheet on success.
    @discardableResult
    public func submit() async -> Fine? {
        guard canSubmit else { return nil }
        guard let userId = selectedMemberId,
              let amount = parsedAmount else { return nil }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)

        isSubmitting = true
        error = nil
        defer { isSubmitting = false }

        do {
            let fine = try await fineRepo.issueManual(
                groupId: groupId,
                userId: userId,
                amount: amount,
                reason: trimmedReason,
                eventId: eventId
            )
            return fine
        } catch {
            self.error = humanize(error: error)
            return nil
        }
    }

    /// Maps server raise strings + transport failures to user-facing Spanish
    /// messages. Defensive — UI also gates each error case where possible.
    private func humanize(error: Error) -> String {
        let raw = (error as NSError).localizedDescription.lowercased()
        if raw.contains("auth required") {
            return "Tu sesión expiró. Volvé a entrar."
        }
        if raw.contains("admin only") {
            return "Solo admins pueden multar manualmente."
        }
        if raw.contains("target user not a member") {
            return "Esa persona ya no es miembro del grupo."
        }
        if raw.contains("amount must be non-negative") {
            return "El monto no puede ser negativo."
        }
        if raw.contains("reason required") {
            return "Escribe un motivo (al menos 2 caracteres)."
        }
        return "No pudimos enviar la multa. Intenta de nuevo."
    }
}
