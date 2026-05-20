import SwiftUI
import UIKit
import RuulCore
import RuulUI

/// Thin tab wrapper for "Yo" (Nivel 0). Embeds MyProfileView inside a
/// NavigationStack and forwards navigation to the RootRouter.
@MainActor
public struct ProfileTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    let profileCoordinator: ProfileCoordinator?
    let myFinesCoordinator: MyFinesCoordinator?

    @State private var path = NavigationPath()
    @State private var showChangePhone = false
    @State private var showChangeEmail = false
    @State private var showTimeline = false
    @State private var showDevices = false
    @State private var showNotificationPreferences = false
    @State private var showDeleteConfirm = false
    @State private var isExporting = false
    @State private var exportShareItem: ExportShareItem?
    @State private var accountError: String?
    /// V2 Slice 4A: edit-profile sheet lives local to ProfileTab now.
    /// Was a root `.editProfile` cover routed through RootRouter — moved
    /// inline since ProfileTab is the only entry point and the global
    /// route added no value (V2 Plan §B.1: "one entry per destination").
    @State private var showEditProfile = false
    /// V2 Slice 4D: Mis multas cover also lives local to ProfileTab.
    /// Triggered (a) directly by ProfileTab's "Mis multas" row, and
    /// (b) by cross-tab deep link from Group sheet via the router's
    /// `requestOpenMyFines()` which sets `state.pendingOpenMyFines`.
    @State private var showMyFines = false

    private enum ProfileNav: Hashable { case language, timezone }

    /// Identifiable wrapper para fullScreenCover(item:) — el share sheet
    /// necesita el archivo concreto, no solo un bool.
    private struct ExportShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    public init(profile: ProfileCoordinator?, myFines: MyFinesCoordinator?) {
        self.profileCoordinator = profile
        self.myFinesCoordinator = myFines
    }

    public var body: some View {
        NavigationStack(path: $path) {
            if let coord = profileCoordinator {
                MyProfileView(
                    coordinator: coord,
                    onOpenMyFines: { showMyFines = true },
                    onOpenHistory: { router.selectTab(.home) },
                    onEditProfile: { showEditProfile = true },
                    onSignOut: { Task { try? await app.signOut() } },
                    onOpenTimeline: { showTimeline = true },
                    outstandingPillAmount: myFinesCoordinator?.totalOutstanding,
                    onChangePhone: { showChangePhone = true },
                    onChangeEmail: { showChangeEmail = true },
                    onPickLanguage: { path.append(ProfileNav.language) },
                    onPickTimezone: { path.append(ProfileNav.timezone) },
                    onOpenNotificationPreferences: { showNotificationPreferences = true },
                    onOpenDevices: { showDevices = true },
                    onOpenGroupSwitcher: { router.openGroupSwitcher() },
                    onExportData: { Task { await exportMyData() } },
                    onDeleteAccount: { showDeleteConfirm = true }
                )
                .navigationDestination(for: ProfileNav.self) { dest in
                    switch dest {
                    case .language: LanguagePickerView()
                    case .timezone: TimezonePickerView()
                    }
                }
                .fullScreenCover(isPresented: $showEditProfile, onDismiss: {
                    Task { await profileCoordinator?.refresh() }
                }) {
                    if let coord = profileCoordinator {
                        EditProfileSheet(coordinator: coord)
                    }
                }
                .fullScreenCover(isPresented: $showMyFines) {
                    if let coord = myFinesCoordinator {
                        MyFinesScreenHost(coordinator: coord) {
                            showMyFines = false
                        }
                        .environment(app)
                    }
                }
                .onChange(of: router.state.pendingOpenMyFines) { _, newValue in
                    // V2 Slice 4D cross-tab signal: Group sheet (or any
                    // future caller) raised the flag via
                    // `router.requestOpenMyFines()`; present the local
                    // cover and clear the flag so a subsequent open
                    // re-triggers the listener.
                    if newValue {
                        showMyFines = true
                        router.state.pendingOpenMyFines = false
                    }
                }
                .fullScreenCover(isPresented: $showChangePhone) { ChangePhoneFlow() }
                .fullScreenCover(isPresented: $showChangeEmail) { ChangeEmailFlow() }
                .fullScreenCover(isPresented: $showTimeline) { MyTimelineView().environment(app) }
                .fullScreenCover(isPresented: $showDevices) { DevicesView().environment(app) }
                .fullScreenCover(isPresented: $showNotificationPreferences) {
                    NotificationPreferencesView().environment(app)
                }
                .sheet(item: $exportShareItem) { item in
                    ShareSheet(activityItems: [item.url])
                }
                .confirmationDialog(
                    "¿Eliminar tu cuenta?",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Eliminar cuenta", role: .destructive) {
                        Task { await deleteMyAccount() }
                    }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("Tu identidad personal se borra y dejas todos los grupos. Tu historia en cada grupo permanece como auditoría con el nombre \"Cuenta eliminada\". Esto no se puede deshacer.")
                }
                .alert("No pudimos completar la acción", isPresented: Binding(
                    get: { accountError != nil },
                    set: { if !$0 { accountError = nil } }
                )) {
                    Button("OK", role: .cancel) { accountError = nil }
                } message: {
                    Text(accountError ?? "")
                }
                .overlay(alignment: .top) {
                    if isExporting {
                        HStack(spacing: RuulSpacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Preparando export…")
                                .font(.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                        }
                        .padding(.horizontal, RuulSpacing.md)
                        .padding(.vertical, RuulSpacing.xs)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, RuulSpacing.sm)
                    }
                }
                .environment(app)
                .task { await myFinesCoordinator?.refresh() }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// LFPDPPP/CCPA portability. Llama export_my_data RPC, escribe el
    /// JSON a un archivo temporal, presenta UIActivityViewController
    /// para que el usuario lo guarde a Files / Mail / iCloud Drive.
    private func exportMyData() async {
        guard !isExporting else { return }
        isExporting = true
        defer { Task { @MainActor in isExporting = false } }
        do {
            let data = try await app.profileRepo.exportMyData()
            let ts = ISO8601DateFormatter().string(from: .now)
                .replacingOccurrences(of: ":", with: "-")
            let filename = "ruul-export-\(ts).json"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            await MainActor.run { exportShareItem = ExportShareItem(url: url) }
        } catch {
            await MainActor.run {
                accountError = "No pudimos generar tu export. \(error.ruulUserMessage)"
            }
        }
    }

    /// LFPDPPP/CCPA erasure. Llama delete_my_account RPC (que pseudonimiza
    /// profile, desactiva memberships, purga tokens + preferences, emite
    /// memberLeft events) y luego cierra sesión local. La próxima vez que
    /// el usuario abra la app caerá en SignInView.
    private func deleteMyAccount() async {
        do {
            _ = try await app.profileRepo.deleteAccount()
            try? await app.signOut()
        } catch {
            await MainActor.run {
                accountError = "No pudimos eliminar tu cuenta. \(error.ruulUserMessage)"
            }
        }
    }
}

/// UIActivityViewController bridge. SwiftUI no tiene equivalent nativo
/// para compartir un archivo arbitrario aún.
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
