import SwiftUI
import RuulUI
import RuulCore

/// Surfaces placeholder claims tied to the caller's verified phone
/// (Camino B post-login flow). Presented as a sheet from RootShell when
/// `app.pendingPlaceholderClaims` is non-empty.
///
/// For each pending claim the user can:
///   - Aceptar: merge in place, refresh the list.
///   - Revisar: push ClaimReviewView to see fines/votes/events count
///     and decide consciously.
///
/// Decline is intentionally NOT offered from this list — it requires the
/// token (magic-link path). Phone-match path can re-decide later via the
/// admin-shared link if they want to disavow.
@MainActor
public struct PendingClaimsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var workingUid: UUID?
    @State private var errorMessage: String?
    @State private var reviewing: PendingPlaceholderClaim?

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    intro

                    if app.pendingPlaceholderClaims.isEmpty {
                        empty
                    } else {
                        ForEach(app.pendingPlaceholderClaims) { claim in
                            claimCard(claim)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .ruulSheetToolbar("Invitaciones pendientes")
            .sheet(item: $reviewing) { claim in
                ClaimReviewView(token: nil, placeholderUid: claim.placeholderUid)
                    .presentationBackground(.ultraThinMaterial)
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Te agregaron a estos grupos")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            Text("Tu número coincide con un miembro pendiente. Acepta para unir tu cuenta con el historial que ya hay.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
    }

    private var empty: some View {
        VStack(spacing: RuulSpacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.ruulAccent)
            Text("Nada pendiente").font(.headline)
            Text("Ya no hay invitaciones esperando.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xl)
    }

    private func claimCard(_ claim: PendingPlaceholderClaim) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text(claim.groupName)
                .font(.headline)
            Text("Te agregaron como \(claim.displayName)")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            HStack(spacing: RuulSpacing.sm) {
                Button("Revisar") { reviewing = claim }
                    .buttonStyle(.bordered)
                    .disabled(workingUid == claim.placeholderUid)
                Spacer()
                Button(action: { accept(claim) }) {
                    if workingUid == claim.placeholderUid {
                        ProgressView()
                    } else {
                        Text("Aceptar")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(workingUid != nil)
            }
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
    }

    private func accept(_ claim: PendingPlaceholderClaim) {
        guard let repo = app.claimRepo else {
            errorMessage = "Servicio no disponible."
            return
        }
        workingUid = claim.placeholderUid
        errorMessage = nil
        Task {
            defer { workingUid = nil }
            do {
                _ = try await repo.acceptByUid(claim.placeholderUid)
                await app.refreshPendingPlaceholderClaims()
                await app.refreshProfileAndGroups()
                if app.pendingPlaceholderClaims.isEmpty {
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
