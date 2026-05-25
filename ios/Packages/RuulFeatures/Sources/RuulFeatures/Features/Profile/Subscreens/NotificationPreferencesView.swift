import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct NotificationPreferencesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var prefs: [String: Bool] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// True después de que `load()` corrió al menos una vez. Permite
    /// distinguir "primera carga" (mapa vacío esperando server) de
    /// "loaded con prefs reales" en `LoadPhase.from`.
    @State private var hasLoaded = false

    public init() {}

    private struct PrefType {
        let key: String
        let label: String
        let icon: String
    }

    private struct PrefGroup {
        let title: String
        let types: [PrefType]
    }

    /// Beta-1 notification types agrupados por dominio (UXJourney P1 —
    /// antes era flat list de 6, ahora 3 secciones temáticas con header
    /// sentence-case consistente con el rest of Profile/Group).
    private static let groups: [PrefGroup] = [
        PrefGroup(title: "Votaciones", types: [
            PrefType(key: "voteOpened",   label: "Votaciones abiertas", icon: "hand.raised"),
            PrefType(key: "voteResolved", label: "Resultados de voto",  icon: "checkmark.seal")
        ]),
        PrefGroup(title: "Multas y dinero", types: [
            PrefType(key: "fineOfficialized", label: "Multas nuevas",      icon: "creditcard"),
            PrefType(key: "expenseReversed",  label: "Gastos reversados",  icon: "arrow.uturn.backward.circle")
        ]),
        PrefGroup(title: "Eventos", types: [
            PrefType(key: "eventCreated",       label: "Eventos nuevos",       icon: "calendar.badge.plus"),
            PrefType(key: "rsvpDeadlinePassed", label: "Recordatorios de RSVP", icon: "clock")
        ])
    ]

    private static let allTypes: [PrefType] = groups.flatMap(\.types)

    /// `LoadPhase` adapter inline. Notificaciones es scalar (mapa de
    /// toggles), no aplica `.empty`. Errores de set/save siguen siendo
    /// inline below the form — sólo el load inicial pasa por
    /// `AsyncContentView`.
    private var phase: LoadPhase<[String: Bool]> {
        // El error inline (set/save) NO se eleva al `phase` — se
        // mantiene como banner abajo del form para no desmontar los
        // toggles cuando el usuario falla un cambio. Sólo errores de
        // load inicial llegarían aquí, pero el load actual no setea
        // errorMessage en el catch del load — sólo en set(). Así que
        // pasamos nil siempre.
        return LoadPhase.from(
            value: hasLoaded ? prefs : nil,
            isLoading: isLoading,
            error: nil
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                    Text("Activa o desactiva tipos de aviso. Tu dispositivo recibirá solo los tipos activos.")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    // Form area: `AsyncContentView` maneja loading
                    // (spinner) y loaded (form). No usamos retry: el
                    // load no expone errores al phase, así que las
                    // únicas fases visibles son `.loading` y `.loaded`.
                    AsyncContentView(phase: phase) { _ in
                        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                            ForEach(Self.groups, id: \.title) { group in
                                prefGroupSection(group)
                            }
                        }
                    }
                    if let msg = errorMessage {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .ruulSheetToolbar("Notificaciones")
            .task { await load() }
        }
    }

    @ViewBuilder
    private func prefGroupSection(_ group: PrefGroup) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(group.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) {
                ForEach(group.types, id: \.key) { entry in
                    prefRow(entry)
                    if entry.key != group.types.last?.key {
                        Divider()
                            .background(Color(.separator))
                            .padding(.leading, 56)
                    }
                }
            }
            .ruulCardSurface(.solid)
        }
    }

    private func prefRow(_ entry: PrefType) -> some View {
        let isOn = prefs[entry.key] ?? true  // default ON
        return HStack {
            Image(systemName: entry.icon)
                .foregroundStyle(Color.secondary)
                .frame(width: 28)
            Text(entry.label)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newVal in Task { await set(entry.key, enabled: newVal) } }
            ))
            .labelsHidden()
        }
        .padding(RuulSpacing.md)
    }

    private func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            guard let repo = app.notificationPreferenceRepo else {
                // Repo not wired (mock mode); show defaults.
                prefs = Dictionary(uniqueKeysWithValues: Self.allTypes.map { ($0.key, true) })
                return
            }
            let stored = try await repo.loadMine()
            var map: [String: Bool] = Dictionary(uniqueKeysWithValues: Self.allTypes.map { ($0.key, true) })
            for p in stored { map[p.notificationType] = p.enabled }
            prefs = map
        } catch {
            errorMessage = "No pudimos cargar tus preferencias."
        }
    }

    private func set(_ type: String, enabled: Bool) async {
        prefs[type] = enabled
        do {
            try await app.notificationPreferenceRepo?.set(type: type, enabled: enabled)
        } catch {
            errorMessage = "No pudimos guardar el cambio."
            prefs[type] = !enabled  // revert optimistic update
        }
    }
}
