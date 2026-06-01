import SwiftUI
import RuulCore

/// V3-D.23 — Create-event sheet. Minimal MVP form:
/// título / tipo / fecha y hora / duración / lugar / repetir / visibilidad.
struct CreateCalendarEventView: View {
    @Bindable var store: CalendarEventsStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Detalles") {
                    TextField("Título", text: $store.draftTitle)
                        .textInputAutocapitalization(.sentences)
                    TextField("Descripción (opcional)", text: $store.draftDescription, axis: .vertical)
                        .lineLimit(2...5)
                    Picker("Tipo", selection: $store.draftEventType) {
                        ForEach(CalendarEventType.allCases) { type in
                            Label(type.label, systemImage: type.systemImageName).tag(type)
                        }
                    }
                }

                Section("Cuándo") {
                    DatePicker(
                        "Inicia",
                        selection: $store.draftStartsAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Picker("Duración", selection: $store.draftDuration) {
                        Text("30 min").tag(TimeInterval(60 * 30))
                        Text("1 hora").tag(TimeInterval(60 * 60))
                        Text("2 horas").tag(TimeInterval(60 * 60 * 2))
                        Text("3 horas").tag(TimeInterval(60 * 60 * 3))
                        Text("Todo el día").tag(TimeInterval(60 * 60 * 24))
                    }
                    Picker("Se repite", selection: $store.draftRecurrence) {
                        ForEach(CalendarEventRecurrenceKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                }

                Section("Dónde") {
                    TextField("Lugar (opcional)", text: $store.draftLocationName)
                        .textInputAutocapitalization(.words)
                }

                Section("Quién lo ve") {
                    Picker("Visibilidad", selection: $store.draftVisibility) {
                        ForEach(CalendarEventVisibility.allCases) { v in
                            Text(v.label).tag(v)
                        }
                    }
                    visibilityFootnote
                }

                if let error = store.draftErrorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Nuevo evento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            isSaving = true
                            _ = await store.saveDraft(groupId: groupId)
                            isSaving = false
                        }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Crear") }
                    }
                    .disabled(!store.canCreateDraft || isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var visibilityFootnote: some View {
        let text: String = {
            switch store.draftVisibility {
            case .group:      return "Todos los miembros activos pueden verlo."
            case .invited:    return "Solo quienes invites pueden verlo y responder."
            case .admins:     return "Sólo admins ven este evento."
            case .publicLink: return "Cualquier miembro con el enlace puede verlo."
            }
        }()
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
