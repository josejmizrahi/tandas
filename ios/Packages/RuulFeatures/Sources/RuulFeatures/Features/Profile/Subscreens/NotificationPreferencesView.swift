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
    /// tracked uppercase consistente con el rest of Profile/Group).
    private static let groups: [PrefGroup] = [
        PrefGroup(title: "VOTACIONES", types: [
            PrefType(key: "voteOpened",   label: "Votaciones abiertas", icon: "hand.raised"),
            PrefType(key: "voteResolved", label: "Resultados de voto",  icon: "checkmark.seal")
        ]),
        PrefGroup(title: "MULTAS Y DINERO", types: [
            PrefType(key: "fineOfficialized", label: "Multas nuevas",      icon: "creditcard"),
            PrefType(key: "expenseReversed",  label: "Gastos reversados",  icon: "arrow.uturn.backward.circle")
        ]),
        PrefGroup(title: "EVENTOS", types: [
            PrefType(key: "eventCreated",       label: "Eventos nuevos",       icon: "calendar.badge.plus"),
            PrefType(key: "rsvpDeadlinePassed", label: "Recordatorios de RSVP", icon: "clock")
        ])
    ]

    private static let allTypes: [PrefType] = groups.flatMap(\.types)

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                    Text("Activa o desactiva tipos de aviso. Tu dispositivo recibirá solo los tipos activos.")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                    if isLoading {
                        ProgressView()
                    } else {
                        ForEach(Self.groups, id: \.title) { group in
                            prefGroupSection(group)
                        }
                    }
                    if let msg = errorMessage {
                        Text(msg)
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulNegative)
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
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) {
                ForEach(group.types, id: \.key) { entry in
                    prefRow(entry)
                    if entry.key != group.types.last?.key {
                        Divider()
                            .background(Color.ruulSeparator)
                            .padding(.leading, 56)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    private func prefRow(_ entry: PrefType) -> some View {
        let isOn = prefs[entry.key] ?? true  // default ON
        return HStack {
            Image(systemName: entry.icon)
                .foregroundStyle(Color.ruulTextSecondary)
                .frame(width: 28)
            Text(entry.label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
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
        defer { isLoading = false }
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
