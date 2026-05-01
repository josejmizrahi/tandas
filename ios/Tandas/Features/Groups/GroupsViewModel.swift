import SwiftUI

@MainActor
@Observable
final class GroupsViewModel {
    var joinCode: String = ""
    var joinError: String?
    var isJoining: Bool = false
    var joinedGroup: Group?

    let groupsRepo: any GroupsRepository

    init(groupsRepo: any GroupsRepository) { self.groupsRepo = groupsRepo }

    func join() async {
        let code = joinCode.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 8, code.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            joinError = "El código tiene 8 caracteres."
            return
        }
        joinError = nil
        isJoining = true
        defer { isJoining = false }
        do {
            joinedGroup = try await groupsRepo.joinByCode(code)
        } catch GroupsError.inviteCodeNotFound {
            joinError = "No encontramos ese grupo. Revisa el código."
        } catch {
            joinError = "No pudimos unirte. Intenta de nuevo."
        }
    }
}
