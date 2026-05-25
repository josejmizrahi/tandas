import SwiftUI
import RuulUI
import RuulCore

/// "Recursos del grupo" — polimórfica. Una sola superficie donde el
/// usuario ve TODO lo que el grupo tiene (eventos, activos, fondos
/// protegidos, espacios, accesos) sin per-type silos.
///
/// Doctrine fix V7 (2026-05-25): la versión anterior tenía 3 filas
/// separadas en Ajustes (Eventos / Activos / Fondos) que reintroducían
/// el patrón silo-por-tipo. Esta vista los colapsa en una lista
/// polimórfica ordenada por recencia. La tipología vive en el icon
/// (`ResourceTypeChrome.resolve`) + el sub-label, no en categorías de
/// navegación.
@MainActor
public struct GroupResourcesView: View {
    public let group: RuulCore.Group
    public let onSelect: (ResourceRow) -> Void

    @Environment(AppState.self) private var app

    @State private var resources: [ResourceRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    public init(group: RuulCore.Group, onSelect: @escaping (ResourceRow) -> Void) {
        self.group = group
        self.onSelect = onSelect
    }

    private var phase: LoadPhase<[ResourceRow]> {
        let coordError: CoordinatorError? = errorMessage.map {
            CoordinatorError(
                title: "No pudimos cargar los recursos",
                message: $0,
                isRetryable: true
            )
        }
        return LoadPhase.fromCollection(
            value: resources,
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
                    Label("Sin recursos todavía", systemImage: "cube.box")
                } description: {
                    Text("Cuando el grupo cree eventos, active activos o reserve espacios, todo aparecerá acá.")
                }
            },
            loaded: { rows in
                ScrollView {
                    LazyVStack(spacing: RuulSpacing.sm) {
                        ForEach(rows, id: \.id) { row in
                            ResourceTile(row: row, onTap: { onSelect(row) })
                        }
                    }
                    .padding(RuulSpacing.lg)
                }
                .refreshable { await load() }
            }
        )
        .background(Color.ruulBackgroundRecessed.ignoresSafeArea())
        .navigationTitle("Recursos del grupo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            // Polymorphic fetch — all 5 canonical persistent types.
            // Slot excluded because slots are sub-units of assets and
            // surface via the parent asset detail, not standalone.
            let rows = try await app.resourceRepo.list(
                in: group.id,
                types: [.event, .fund, .asset, .space, .right],
                statuses: nil,
                limit: 200
            )
            resources = rows.sorted { $0.createdAt > $1.createdAt }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct ResourceTile: View {
    let row: ResourceRow
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.md) {
                let chrome = ResourceTypeChrome.resolve(row.resourceType)
                Image(systemName: chrome.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chrome.semanticColor)
                    .frame(width: 40, height: 40)
                    .background(chrome.semanticColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(row.resourceType.humanLabel)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Polymorphic title — assets/spaces store `metadata.name`,
    /// events store `metadata.title`. Same pattern as
    /// `LiveResourceRepository.title(of:fallback:)`.
    private var title: String {
        if let name = row.metadata["name"]?.stringValue, !name.isEmpty {
            return name
        }
        if let titleText = row.metadata["title"]?.stringValue, !titleText.isEmpty {
            return titleText
        }
        return row.resourceType.humanLabel
    }
}
