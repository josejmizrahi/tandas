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

    /// Beta-1 notification types (matches BE emit list).
    private static let types: [(key: String, label: String, icon: String)] = [
        ("voteOpened",           "Votaciones abiertas",     "hand.raised"),
        ("voteResolved",         "Resultados de voto",      "checkmark.seal"),
        ("fineOfficialized",     "Multas nuevas",           "creditcard"),
        ("eventCreated",         "Eventos nuevos",          "calendar.badge.plus"),
        ("rsvpDeadlinePassed",   "Recordatorios de RSVP",   "clock"),
        ("expenseReversed",      "Gastos reversados",       "arrow.uturn.backward.circle")
    ]

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    Text("Activa o desactiva tipos de aviso. Tu dispositivo recibirá solo los tipos activos.")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                    if isLoading {
                        ProgressView()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Self.types, id: \.key) { entry in
                                prefRow(entry)
                                if entry.key != Self.types.last?.key {
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

    private func prefRow(_ entry: (key: String, label: String, icon: String)) -> some View {
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
                prefs = Dictionary(uniqueKeysWithValues: Self.types.map { ($0.key, true) })
                return
            }
            let stored = try await repo.loadMine()
            var map: [String: Bool] = Dictionary(uniqueKeysWithValues: Self.types.map { ($0.key, true) })
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
