import SwiftUI
import RuulUI
import RuulCore

/// "Activos" — group-scoped asset list, pushed from the GroupSpace
/// "Activos" tile. Reads `public.resources` (resource_type='asset') via
/// `ResourceRepository.list(in:types:statuses:limit:)`.
///
/// SharedMoney Phase 4 brick C.2: Asset is the canonical surface for
/// capital-bearing resources (warehouse, vehicle, inversión per the
/// `AssetVariants` registry). Tap → opens the universal `ResourceDetailSheet`
/// where the Money Block (Phase 4 brick C.1) renders contributions /
/// expenses attributed via `source_resource_id`, including in-kind
/// capital contributions per `doctrine_in_kind_contributions.md`.
@MainActor
public struct GroupAssetsListView: View {
    public let group: RuulCore.Group
    public let onOpenAsset: (ResourceRow) -> Void

    @Environment(AppState.self) private var app

    @State private var assets: [ResourceRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    public init(group: RuulCore.Group, onOpenAsset: @escaping (ResourceRow) -> Void) {
        self.group = group
        self.onOpenAsset = onOpenAsset
    }

    private var phase: LoadPhase<[ResourceRow]> {
        let coordError: CoordinatorError? = errorMessage.map {
            CoordinatorError(title: "No pudimos cargar los activos", message: $0, isRetryable: true)
        }
        return LoadPhase.fromCollection(
            value: assets,
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
                    Label("Aún no hay activos", systemImage: "shippingbox")
                } description: {
                    Text("Los activos son cosas con valor que el grupo posee — un terreno, un vehículo, una inversión. Créalos desde el botón \"+\".")
                }
            },
            loaded: { rows in
                ScrollView {
                    LazyVStack(spacing: RuulSpacing.sm) {
                        ForEach(rows, id: \.id) { asset in
                            row(asset)
                        }
                    }
                    .padding(RuulSpacing.lg)
                }
                .refreshable { await load() }
            }
        )
        .background(Color.ruulBackgroundRecessed.ignoresSafeArea())
        .navigationTitle("Activos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func row(_ asset: ResourceRow) -> some View {
        Button {
            onOpenAsset(asset)
        } label: {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: "shippingbox")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroupColorRamp.purple.accent)
                    .frame(width: 36, height: 36)
                    .background(GroupColorRamp.purple.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(assetName(asset))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(assetSubtitle(asset))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
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

    private func assetName(_ asset: ResourceRow) -> String {
        asset.metadata["name"]?.stringValue ?? "Activo"
    }

    private func assetSubtitle(_ asset: ResourceRow) -> String {
        // Show the variant label when set (Inmueble / Vehículo /
        // Inversión per AssetVariants), else the canonical status.
        if let variant = asset.metadata["variant"]?.stringValue, !variant.isEmpty {
            return variant.capitalized
        }
        return asset.status.capitalized
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            assets = try await app.resourceRepo.list(
                in: group.id,
                types: [.asset],
                statuses: nil,
                limit: 200
            )
        } catch {
            errorMessage = "No pudimos cargar los activos."
        }
    }
}
