import SwiftUI
import MapKit
import RuulCore
import RuulUI

/// Sheet that lets any group member set or update the event's location
/// with Apple Maps autocomplete + coordinate resolution. The host can
/// additionally tick "save as my default when I host" to persist the
/// place on their profile so future events they host land prefilled
/// (mig 00340).
///
/// Submit path:
///   `EventRepository.updateEvent(id, EventPatch(locationName:lat:lng:))`
///   → `update_event_metadata` RPC → resources.metadata.location_*.
///   Optional follow-up `ProfileRepository.setHostDefaultLocation(...)`
///   → `set_host_default_location` RPC (only when the host ticks the
///   checkbox).
public struct LocationEditorSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let eventId: UUID
    public let initialLocationName: String?
    public let viewerIsEventHost: Bool
    public var onSaved: (() -> Void)?

    @State private var query: String = ""
    @State private var pickedCoordinate: CLLocationCoordinate2D?
    @State private var saveAsDefault: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var searchModel = LocationSearchModel()

    public init(
        eventId: UUID,
        initialLocationName: String? = nil,
        viewerIsEventHost: Bool,
        onSaved: (() -> Void)? = nil
    ) {
        self.eventId = eventId
        self.initialLocationName = initialLocationName
        self.viewerIsEventHost = viewerIsEventHost
        self.onSaved = onSaved
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Buscar lugar o dirección", text: $query, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .onChange(of: query) { _, newValue in
                            // Keep the picked coord aligned with the
                            // text: if the user edits manually after
                            // picking a suggestion, the lat/lng no
                            // longer matches → drop it so we don't
                            // save stale coords.
                            if newValue != lastPickedLabel {
                                pickedCoordinate = nil
                            }
                            searchModel.updateQuery(newValue)
                        }
                } header: {
                    Text("Lugar")
                } footer: {
                    if pickedCoordinate != nil {
                        Label("Ubicación verificada con Apple Maps", systemImage: "checkmark.seal.fill")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulPositive)
                    } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Sin coordenadas todavía. Elige una sugerencia para que abra Maps al tappear.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    } else {
                        Text("Empieza a escribir el nombre del lugar o una dirección.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }

                if !searchModel.suggestions.isEmpty && pickedCoordinate == nil {
                    Section("Sugerencias") {
                        ForEach(searchModel.suggestions, id: \.id) { suggestion in
                            Button {
                                Task { await pick(suggestion) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .ruulTextStyle(RuulTypography.body)
                                        .foregroundStyle(Color.ruulTextPrimary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .ruulTextStyle(RuulTypography.caption)
                                            .foregroundStyle(Color.ruulTextSecondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if viewerIsEventHost {
                    Section {
                        Toggle("Guardar como mi predeterminada cuando soy anfitrión", isOn: $saveAsDefault)
                    } footer: {
                        Text("Próximos eventos donde te toque ser anfitrión arrancarán con este lugar precargado. Lo puedes cambiar por evento.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
            }
            .ruulSheetToolbar("Ubicación")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Guardando…" : "Guardar") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || trimmedQuery.isEmpty)
                }
            }
        }
        .onAppear {
            query = initialLocationName ?? ""
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The exact label produced by the last accepted suggestion. Used
    /// to detect whether the user has edited the text since picking —
    /// if so, we drop the stored coordinate (no stale lat/lng).
    @State private var lastPickedLabel: String?

    @MainActor
    private func pick(_ suggestion: LocationSearchModel.Suggestion) async {
        // Re-issue a search using a natural-language query built from
        // title + subtitle. We can't keep the original
        // MKLocalSearchCompletion across actor hops under strict
        // concurrency (not Sendable), so we transit text only.
        let label = composedLabel(title: suggestion.title, subtitle: suggestion.subtitle)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = label
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            if let item = response.mapItems.first {
                query = label
                lastPickedLabel = label
                pickedCoordinate = item.placemark.coordinate
                searchModel.clear()
            } else {
                query = label
                lastPickedLabel = label
                pickedCoordinate = nil
                searchModel.clear()
            }
        } catch {
            query = label
            lastPickedLabel = label
            pickedCoordinate = nil
        }
    }

    private func composedLabel(title: String, subtitle: String) -> String {
        if subtitle.isEmpty { return title }
        return "\(title), \(subtitle)"
    }

    @MainActor
    private func submit() async {
        let name = trimmedQuery
        guard !name.isEmpty else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await app.eventRepo.updateEvent(
                eventId,
                patch: EventPatch(
                    locationName: name,
                    locationLat:  pickedCoordinate?.latitude,
                    locationLng:  pickedCoordinate?.longitude
                )
            )
            if viewerIsEventHost && saveAsDefault {
                try? await app.profileRepo.setHostDefaultLocation(
                    name: name,
                    lat:  pickedCoordinate?.latitude,
                    lng:  pickedCoordinate?.longitude
                )
            }
            onSaved?()
            dismiss()
        } catch {
            errorMessage = CoordinatorError
                .from(error, fallback: "No pudimos guardar la ubicación")
                .title
        }
    }
}

// MARK: - LocationSearchModel

/// SwiftUI-friendly wrapper around `MKLocalSearchCompleter`. Streams
/// address/POI suggestions as the user types — used by
/// `LocationEditorSheet` to mirror Apple Maps' picker experience.
@Observable
@MainActor
final class LocationSearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var suggestions: [Suggestion] = []

    /// SwiftUI-safe snapshot of an MKLocalSearchCompletion. Title +
    /// subtitle are crossable across actor boundaries (MKLocalSearchCompletion
    /// itself isn't Sendable under strict concurrency). `pick(_:)`
    /// reconstructs an MKLocalSearch.Request from the natural-language
    /// "title, subtitle" so coords still resolve.
    struct Suggestion: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let subtitle: String
    }

    private let completer: MKLocalSearchCompleter

    override init() {
        self.completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func updateQuery(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            suggestions = []
            return
        }
        completer.queryFragment = trimmed
    }

    func clear() {
        suggestions = []
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Snapshot to Sendable values before crossing the actor
        // boundary — MKLocalSearchCompletion itself is not Sendable.
        let snapshot: [Suggestion] = completer.results.map {
            Suggestion(
                id: "\($0.title)|\($0.subtitle)",
                title: $0.title,
                subtitle: $0.subtitle
            )
        }
        Task { @MainActor in
            self.suggestions = snapshot
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}

