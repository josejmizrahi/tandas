import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct DevicesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [NotificationDevice] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var currentDeviceToken: String?
    /// True después de que `load()` corrió al menos una vez. Permite
    /// distinguir primera carga (sin devices todavía) de "loaded
    /// empty" (cuenta sin push tokens registrados).
    @State private var hasLoaded = false

    public init() {}

    /// `LoadPhase` adapter inline. Errores de revoke siguen como
    /// banner inline below la lista; sólo errores del load inicial
    /// llegarían al phase (no se setean en el load actual, así que
    /// pasamos nil — paralelo a NotificationPreferencesView).
    private var phase: LoadPhase<[NotificationDevice]> {
        return LoadPhase.fromCollection(
            value: devices,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: nil
        )
    }

    public var body: some View {
        NavigationStack {
            AsyncContentView(
                phase: phase,
                onRetry: { await load() },
                empty: { emptyScroll },
                loaded: { _ in loadedScroll }
            )
            .background(Color.ruulBackground.ignoresSafeArea())
            .ruulSheetToolbar("Dispositivos")
            .task { await load() }
        }
    }

    /// Loaded path: secciones "esta sesión" + "otras sesiones".
    /// Errores de revoke se renderean inline below el listado.
    private var loadedScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                if let current = currentDevice {
                    deviceSection(title: "Esta sesión") { row(current, isCurrent: true) }
                }
                let others = devices.filter { $0.id != currentDevice?.id }
                if !others.isEmpty {
                    deviceSection(title: "Otras sesiones") {
                        VStack(spacing: 0) {
                            ForEach(others) { device in
                                row(device, isCurrent: false)
                                if device.id != others.last?.id {
                                    Divider()
                                        .background(Color(.separator))
                                        .padding(.leading, 56)
                                }
                            }
                        }
                    }
                }
                if let msg = errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, RuulSpacing.lg)
                }
            }
            .padding(RuulSpacing.lg)
        }
    }

    /// Empty path: el mensaje original como scroll auto-refrescable.
    private var emptyScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                Text("Aún no hay dispositivos registrados.")
                    .font(.subheadline)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(RuulSpacing.lg)
                if let msg = errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, RuulSpacing.lg)
                }
            }
            .padding(RuulSpacing.lg)
            .frame(maxWidth: .infinity)
        }
    }

    private var currentDevice: NotificationDevice? {
        guard let tok = currentDeviceToken else { return nil }
        return devices.first(where: { $0.token == tok })
    }

    @ViewBuilder
    private func deviceSection<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)
            content()
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
        }
    }

    private func row(_ device: NotificationDevice, isCurrent: Bool) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: device.platform == "ios" ? "iphone" : "questionmark.circle")
                .foregroundStyle(Color.ruulAccent)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(device.platform.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    if isCurrent {
                        Text("(este)")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Text("Último uso: \(relativeTime(device.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            if !isCurrent {
                Button("Revocar", role: .destructive) {
                    Task { await revoke(device.id) }
                }
                .font(.caption.weight(.bold))
            }
        }
        .padding(RuulSpacing.md)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            devices = try await app.notificationTokenRepo.listMyDevices()
            currentDeviceToken = UserDefaults.standard.string(forKey: "ruul.apns.current_token")
        } catch {
            errorMessage = "No pudimos cargar tus dispositivos."
        }
    }

    private func revoke(_ deviceId: UUID) async {
        do {
            try await app.notificationTokenRepo.revoke(deviceId: deviceId)
            await load()
        } catch {
            errorMessage = "No pudimos revocar el dispositivo."
        }
    }
}
