import SwiftUI
import RuulCore

/// F.NAV.5 — Sheet intent-first "¿Qué quieres hacer?". El tab Crear no tiene
/// pantalla propia: tap → sheet → pick intent → pick contexto (si aplica) →
/// abrir el flow correspondiente.
///
/// Doctrina: el botón Crear NO expone primitivas. El usuario eligió una
/// intención (Programar algo / Registrar movimiento / Crear propuesta /
/// Subir documento / Crear contexto). El backend ya tiene los flows; iOS
/// sólo conecta intención → form.
public struct CreateIntentSheet: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    intentRow(.event,     icon: "calendar.badge.plus",     tint: .orange, label: "Programar algo",
                              detail: "Crear un evento del contexto.")
                    intentRow(.expense,   icon: "dollarsign.circle.fill",  tint: .green,  label: "Registrar movimiento",
                              detail: "Anotar un gasto o ingreso.")
                    intentRow(.decision,  icon: "checkmark.bubble.fill",   tint: .purple, label: "Crear propuesta",
                              detail: "Abrir una decisión para votar.")
                    intentRow(.document,  icon: "paperclip",               tint: .secondary, label: "Subir documento",
                              detail: "Adjuntar un archivo a un recurso.")
                } header: {
                    Text("¿Qué quieres hacer?")
                        .font(.subheadline.weight(.semibold))
                }

                Section {
                    Button {
                        path.append(.createContext)
                    } label: {
                        intentLabel(icon: "rectangle.split.2x1.fill", tint: .blue,
                                    label: "Crear contexto",
                                    detail: "Una familia, viaje, proyecto, comunidad…")
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Espacio nuevo")
                }
            }
            .navigationTitle("Crear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                routeDestination(route)
            }
            .task {
                await container.contextStore.load()
                await container.contextPreferencesStore.load()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func intentRow(_ intent: Intent, icon: String, tint: Color, label: String, detail: String) -> some View {
        Button {
            path.append(.pickContext(intent: intent))
        } label: {
            intentLabel(icon: icon, tint: tint, label: label, detail: detail)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func intentLabel(icon: String, tint: Color, label: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Navigation

    @ViewBuilder
    private func routeDestination(_ route: Route) -> some View {
        switch route {
        case .pickContext(let intent):
            ContextPickerView(container: container, intent: intent) { ctx in
                path.append(.form(intent: intent, contextId: ctx.id))
            }
        case .form(let intent, let contextId):
            if let ctx = container.contextStore.availableContexts.first(where: { $0.id == contextId }) {
                FormDestination(intent: intent, context: ctx, container: container, onClose: { dismiss() })
            }
        case .createContext:
            // CreateContextView trae su propia UI/navegación.
            CreateContextView(container: container)
        }
    }

    // MARK: - Tipos

    enum Intent: Hashable {
        case event, expense, decision, document
    }

    enum Route: Hashable {
        case pickContext(intent: Intent)
        case form(intent: Intent, contextId: UUID)
        case createContext
    }
}

// MARK: - Context picker

private struct ContextPickerView: View {
    let container: DependencyContainer
    let intent: CreateIntentSheet.Intent
    let onPick: (AppContext) -> Void

    var body: some View {
        List {
            if !container.contextPreferencesStore.recents.isEmpty {
                Section("Recientes") {
                    ForEach(container.contextPreferencesStore.recents) { pref in
                        if let ctx = container.contextStore.availableContexts.first(where: { $0.id == pref.contextActorId }),
                           !ctx.isPersonal {
                            row(ctx)
                        }
                    }
                }
            }
            Section("Todos") {
                let recentIds = Set(container.contextPreferencesStore.recents.map(\.contextActorId))
                let rest = container.contextStore.availableContexts.filter {
                    !$0.isPersonal && !recentIds.contains($0.id)
                }
                ForEach(rest) { ctx in
                    row(ctx)
                }
            }
        }
        .navigationTitle("Elige el contexto")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ ctx: AppContext) -> some View {
        Button {
            onPick(ctx)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: ctx.symbolName)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.displayName).font(.callout.weight(.medium))
                    Text("\(ctx.memberCount) miembros").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Form destination

/// Conecta el intent + contexto al form real. Cada flow trae su propio store.
private struct FormDestination: View {
    let intent: CreateIntentSheet.Intent
    let context: AppContext
    let container: DependencyContainer
    let onClose: () -> Void

    @State private var eventsStore: EventsStore?
    @State private var moneyStore: MoneyStore?

    var body: some View {
        Group {
            switch intent {
            case .event:
                if let store = eventsStore {
                    CreateEventView(context: context, store: store, container: container)
                } else {
                    ProgressView().task {
                        eventsStore = EventsStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId)
                    }
                }
            case .expense:
                if let store = moneyStore {
                    RecordExpenseView(context: context, store: store, container: container)
                } else {
                    ProgressView().task {
                        moneyStore = MoneyStore(rpc: container.rpc)
                    }
                }
            case .decision:
                CreateDecisionView(context: context, container: container)
            case .document:
                DocumentIntentLanding(context: context, container: container, onClose: onClose)
            }
        }
    }
}

/// F.NAV.5 — landing para el intent "Subir documento". Como `AttachDocumentView`
/// requiere un `Resource`, mostramos un mensaje y un CTA para ir al contexto
/// a elegir el recurso. F.NAV.5+ puede agregar resource picker inline.
private struct DocumentIntentLanding: View {
    let context: AppContext
    let container: DependencyContainer
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "paperclip")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Subir documento")
                .font(.title3.weight(.semibold))
            Text("Los documentos se adjuntan a un recurso específico (casa, cuenta, contrato…). Abre el recurso y usa \"Adjuntar documento\" desde su detalle.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                container.contextStore.switchTo(context)
                onClose()
            } label: {
                Label("Abrir \(context.displayName)", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Subir documento")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("CreateIntentSheet (demo)") {
    Color.clear.sheet(isPresented: .constant(true)) {
        CreateIntentSheet(container: .demo())
    }
}
