import SwiftUI
import RuulUI
import RuulCore

/// "Multas" — group-scoped fines list, pushed from the GroupSpace
/// "Multas" tile. V1 caveat: `FineRepository` exposes only
/// `myFines(userId:)` (per-user, cross-group), so we filter to this
/// group client-side. This means the surface shows "tus multas en
/// este grupo" — admin/founder visibility into other members' fines
/// requires a backend RPC that doesn't exist yet.
@MainActor
public struct GroupFinesListView: View {
    public let group: RuulCore.Group
    public let onOpenFine: (Fine) -> Void

    @Environment(AppState.self) private var app

    @State private var fines: [Fine] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    public init(group: RuulCore.Group, onOpenFine: @escaping (Fine) -> Void) {
        self.group = group
        self.onOpenFine = onOpenFine
    }

    private var phase: LoadPhase<[Fine]> {
        let coordError: CoordinatorError? = errorMessage.map {
            CoordinatorError(title: "No pudimos cargar las multas", message: $0, isRetryable: true)
        }
        return LoadPhase.fromCollection(
            value: fines,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: coordError
        )
    }

    public var body: some View {
        AsyncContentView(
            phase: phase,
            onRetry: { await load() },
            empty: {
                ContentUnavailableView {
                    Label("Sin multas", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Cuando alguien reciba una multa en este grupo aparecerá acá.")
                }
            },
            loaded: { rows in
                ScrollView {
                    LazyVStack(spacing: RuulSpacing.sm) {
                        ForEach(rows, id: \.id) { fine in
                            FineCard(
                                fine: fine,
                                ruleName: nil,
                                eventTitle: nil,
                                onTap: { onOpenFine(fine) }
                            )
                        }
                    }
                    .padding(RuulSpacing.lg)
                }
                .refreshable { await load() }
            }
        )
        .background(Color.ruulBackgroundRecessed.ignoresSafeArea())
        .navigationTitle("Multas")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let userId = app.session?.user.id else {
            errorMessage = "Sesión no encontrada."
            isLoading = false
            hasLoaded = true
            return
        }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let all = try await app.fineRepo.myFines(userId: userId)
            fines = all.filter { $0.groupId == group.id }
        } catch {
            errorMessage = "No pudimos cargar las multas."
        }
    }
}
