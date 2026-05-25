import SwiftUI
import RuulUI
import RuulCore

/// Magic-link / phone-match landing for placeholder claims.
///
/// - With `token`: Camino A (magic link). User can Aceptar (merge in place)
///   or Rechazar (decline + dispute the placeholder). Token is single-use.
/// - With `placeholderUid` only: Camino B (phone match from PendingClaimsView).
///   Shows the history summary for context but accept goes via UID; decline
///   is hidden because we don't have a token to burn.
@MainActor
public struct ClaimReviewView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let token: String?
    public let placeholderUid: UUID?

    @State private var summary: PlaceholderHistorySummary?
    @State private var isLoadingSummary = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    public init(token: String?, placeholderUid: UUID?) {
        self.token = token
        self.placeholderUid = placeholderUid
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    intro
                    summarySection
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .ruulSheetToolbar("Reclamar tu lugar")
            .safeAreaInset(edge: .bottom) { bottomActions }
            .task { await loadSummary() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Te agregaron a un grupo en Ruul")
                .font(.headline)
                .foregroundStyle(Color.primary)
            Text("Tu lugar ya está reservado. Acepta para unir tu cuenta con el historial existente, o rechaza si no eres quien creen.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if isLoadingSummary {
            HStack { ProgressView(); Text("Cargando historial…") }
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        } else if let summary {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Historial atribuido")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                metricRow(systemImage: "exclamationmark.circle", label: "Fines", value: summary.fineCount)
                metricRow(systemImage: "checkmark.seal", label: "Votos emitidos", value: summary.voteCount)
                metricRow(systemImage: "calendar", label: "Eventos registrados", value: summary.eventCount)
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
        } else if placeholderUid == nil {
            // Token-only path with no preloaded summary — we'd need a fetch
            // by token endpoint to preview. Skip the summary; accept still
            // works (server enforces token validity).
            Text("Confirma para ver tu grupo.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
    }

    private func metricRow(systemImage: String, label: String, value: Int) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.ruulAccent)
                .frame(width: 22)
            Text(label).font(.subheadline)
            Spacer()
            Text("\(value)")
                .font(.headline)
                .foregroundStyle(Color.primary)
        }
    }

    private var bottomActions: some View {
        VStack(spacing: RuulSpacing.sm) {
            Button(action: accept) {
                if isWorking { ProgressView() } else { Text("Aceptar y entrar") }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(isWorking)

            if token != nil {
                Button("No soy yo", role: .destructive, action: decline)
                    .disabled(isWorking)
            }
        }
        .padding(RuulSpacing.lg)
        .background(.thinMaterial)
    }

    private func loadSummary() async {
        guard let uid = placeholderUid, let repo = app.claimRepo else { return }
        isLoadingSummary = true
        defer { isLoadingSummary = false }
        do {
            summary = try await repo.summary(placeholderUid: uid)
        } catch {
            // Summary failures are non-fatal — the user can still accept;
            // the server enforces all guards. Surface a soft message.
            errorMessage = "No pudimos cargar el resumen del historial."
        }
    }

    private func accept() {
        guard let repo = app.claimRepo else {
            errorMessage = "Servicio no disponible."
            return
        }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                if let token {
                    _ = try await repo.acceptByToken(token)
                } else if let placeholderUid {
                    _ = try await repo.acceptByUid(placeholderUid)
                } else {
                    errorMessage = "Falta el token o el id del miembro."
                    return
                }
                await app.refreshPendingPlaceholderClaims()
                await app.refreshProfileAndGroups()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func decline() {
        guard let token, let repo = app.claimRepo else {
            errorMessage = "Servicio no disponible."
            return
        }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await repo.decline(token: token)
                await app.refreshPendingPlaceholderClaims()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
