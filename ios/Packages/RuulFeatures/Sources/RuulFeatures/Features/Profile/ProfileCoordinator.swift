import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

/// Loads the user's own Profile (Nivel 0 — Identity, cross-group).
/// Fines and group-scoped derivations live in `MyFinesCoordinator`; this
/// coordinator no longer aggregates them.
@Observable
@MainActor
public final class ProfileCoordinator {
    public let userId: UUID
    private let profileRepo: any ProfileRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "profile")

    public var profile: Profile?
    public var isLoading: Bool = false
    public var isUploadingAvatar: Bool = false
    public var error: CoordinatorError?

    public init(userId: UUID, profileRepo: any ProfileRepository) {
        self.userId = userId
        self.profileRepo = profileRepo
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            self.profile = try await profileRepo.loadMine()
        } catch {
            log.warning("profile refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar tu perfil")
        }
    }

    public func clearError() { error = nil }

    public func updateDisplayName(_ newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            error = CoordinatorError(
                title: "Nombre vacío",
                message: "Tu nombre no puede estar vacío.",
                isRetryable: false
            )
            return
        }
        guard trimmed != profile?.displayName else { return }
        do {
            try await profileRepo.updateDisplayName(trimmed)
            await refresh()
        } catch {
            log.warning("updateDisplayName failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos guardar tu nombre")
        }
    }

    public func updateAvatar(data: Data, contentType: String) async {
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        do {
            _ = try await profileRepo.updateAvatar(data: data, contentType: contentType)
            await refresh()
        } catch {
            log.warning("updateAvatar failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos subir tu foto")
        }
    }
}
