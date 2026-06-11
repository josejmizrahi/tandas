import SwiftUI
import RuulCore

// MARK: - R.2T Reserve Resource for Event Sheet
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).
//
// Flow: NavigationStack root es ResourcePicker (List de context resources),
// tap en uno empuja RequestReservationView con `preselectedEventId`.

struct ReserveResourceForEventSheet: View {
    let event: CalendarEvent?
    let eventId: UUID
    let context: AppContext
    let container: DependencyContainer
    let onDone: () -> Void

    @State private var resources: [ContextResource] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reservationsStore = ReservationsStore(rpc: MockRuulRPCClient.demo())
    @State private var hasInitializedStore = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    RuulLoadingState()
                } else if let loadError {
                    RuulErrorState(message: loadError) {
                        Task { await load() }
                    }
                } else if resources.isEmpty {
                    ContentUnavailableView(
                        "Sin recursos",
                        systemImage: "shippingbox",
                        description: Text("Este contexto no tiene recursos para reservar.")
                    )
                } else {
                    pickerList
                }
            }
            .navigationTitle("Elegir recurso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task {
                if !hasInitializedStore {
                    reservationsStore = ReservationsStore(rpc: container.rpc)
                    hasInitializedStore = true
                }
                await load()
            }
        }
        .ruulSheet()
    }

    @ViewBuilder
    private var pickerList: some View {
        List {
            Section {
                ForEach(resources) { r in
                    NavigationLink {
                        RequestReservationView(
                            resource: resourceFromContextResource(r),
                            context: context,
                            preselectedEventId: eventId,
                            store: reservationsStore,
                            container: container
                        )
                        .onDisappear {
                            // Cuando la view de request se cierra (por dismiss interno
                            // del Form), no podemos distinguir success vs cancel —
                            // llamamos onDone para refrescar de todas formas.
                            onDone()
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.displayName)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(Theme.Text.primary)
                                Text(resourceTypeLabel(r.resourceType))
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                        } icon: {
                            Image(systemName: resourceTypeIcon(r.resourceType))
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            } header: {
                Text("Recursos del contexto (\(resources.count))")
            } footer: {
                if let event {
                    Text("La reserva quedará asociada a “\(event.title)”.")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func resourceFromContextResource(_ r: ContextResource) -> Resource {
        Resource(
            id: r.resourceId,
            resourceType: r.resourceType,
            displayName: r.displayName,
            status: r.status,
            estimatedValue: r.estimatedValue,
            currency: r.currency,
            canonicalOwnerActorId: r.canonicalOwnerActorId
        )
    }

    private func resourceTypeIcon(_ raw: String) -> String {
        ResourceType(rawValue: raw)?.symbolName ?? "shippingbox.fill"
    }

    private func resourceTypeLabel(_ raw: String) -> String {
        ResourceType(rawValue: raw)?.label ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            let list = try await container.rpc.listContextResources(contextId: context.id)
            resources = list
                .filter { $0.status == "active" }
                .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
            await reservationsStore.loadByContext(context: context)
        } catch {
            loadError = UserFacingError.from(error).message
        }
        isLoading = false
    }
}
