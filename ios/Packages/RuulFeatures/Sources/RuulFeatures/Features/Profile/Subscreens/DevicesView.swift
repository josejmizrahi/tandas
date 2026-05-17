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

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    if isLoading {
                        ProgressView().padding(RuulSpacing.lg)
                    } else if devices.isEmpty {
                        Text("Aún no hay dispositivos registrados.")
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextTertiary)
                            .padding(RuulSpacing.lg)
                    } else {
                        if let current = currentDevice {
                            deviceSection(title: "ESTA SESIÓN") { row(current, isCurrent: true) }
                        }
                        let others = devices.filter { $0.id != currentDevice?.id }
                        if !others.isEmpty {
                            deviceSection(title: "OTRAS SESIONES") {
                                VStack(spacing: 0) {
                                    ForEach(others) { device in
                                        row(device, isCurrent: false)
                                        if device.id != others.last?.id {
                                            Divider()
                                                .background(Color.ruulSeparator)
                                                .padding(.leading, 56)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let msg = errorMessage {
                        Text(msg)
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulNegative)
                            .padding(.horizontal, RuulSpacing.lg)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle("Dispositivos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task { await load() }
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
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            content()
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
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
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if isCurrent {
                        Text("(este)")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
                Text("Último uso: \(relativeTime(device.updatedAt))")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            if !isCurrent {
                Button("Revocar", role: .destructive) {
                    Task { await revoke(device.id) }
                }
                .ruulTextStyle(RuulTypography.captionBold)
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
        defer { isLoading = false }
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
