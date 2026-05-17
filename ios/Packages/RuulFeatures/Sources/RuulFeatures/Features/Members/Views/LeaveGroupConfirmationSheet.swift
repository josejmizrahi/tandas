import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct LeaveGroupConfirmationSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let group: RuulCore.Group

    @State private var leaving = false
    @State private var members: [MemberWithProfile] = []
    @State private var pendingFinesInGroup: [Fine] = []
    @State private var loading = true
    @State private var error: String?

    public init(group: RuulCore.Group) { self.group = group }

    private var isSoleAdmin: Bool {
        guard let uid = app.session?.user.id else { return false }
        // Mig 00262: admin ahora es un rol separado de founder. Checkeamos
        // admin (que cubre founders + admins explícitos) en vez de solo
        // founder — el grupo puede quedarse sin admin operativo aunque
        // el founder siga existiendo como identity badge.
        let admins = members.filter { $0.member.isAdmin && $0.member.active }
        return admins.count == 1 && admins.first?.member.userId == uid
    }

    private var pendingFinesTotal: Decimal {
        pendingFinesInGroup.reduce(Decimal(0)) { $0 + $1.amount }
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                if loading {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity)
                } else if isSoleAdmin {
                    soleAdminBlocker
                } else {
                    confirmation
                }
                if let error {
                    Text(error)
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulNegative)
                }
                Spacer()
            }
            .padding(RuulSpacing.lg)
            .ruulSheetToolbar("Salir del grupo")
            .task { await loadContext() }
        }
    }

    private var soleAdminBlocker: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Label("Eres el único admin", systemImage: "exclamationmark.triangle")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulWarning)
            Text("Antes de salir, asigna el rol de admin a otro miembro o archiva el grupo. Tu badge de fundador permanece como historia del grupo.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Button("Entendido") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("¿Salir de \(group.name)?")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Perderás acceso a este grupo y a su actividad.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            pendingFinesWarning
            Button(role: .destructive) {
                Task { await leave() }
            } label: {
                if leaving {
                    ProgressView()
                } else {
                    Text("Salir del grupo")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.ruulNegative)
            .disabled(leaving)
        }
    }

    /// Surfaces unresolved fines the user owes IN THIS GROUP before they
    /// leave. Salir no las cancela — siguen apareciendo en "Mis multas"
    /// cross-group. Hacer esto explícito evita que el founder asuma que
    /// "salirme borra lo que debo".
    @ViewBuilder
    private var pendingFinesWarning: some View {
        if !pendingFinesInGroup.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Label("Tienes multas pendientes aquí", systemImage: "exclamationmark.triangle.fill")
                    .ruulTextStyle(RuulTypography.subheadSemibold)
                    .foregroundStyle(Color.ruulWarning)
                let count = pendingFinesInGroup.count
                Text("\(count == 1 ? "1 multa" : "\(count) multas") por \(formatCurrency(pendingFinesTotal)). Salir no las cancela — siguen visibles en Mis multas.")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: RuulRadius.md))
        }
    }

    private func formatCurrency(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }

    private func loadContext() async {
        loading = true
        defer { loading = false }
        guard let uid = app.session?.user.id else {
            self.error = "No pudimos verificar tu rol."
            return
        }
        async let membersTask = (try? app.groupsRepo.membersWithProfiles(of: group.id)) ?? []
        async let finesTask = (try? app.fineRepo.myFines(userId: uid)) ?? []
        let (loadedMembers, allFines) = await (membersTask, finesTask)
        members = loadedMembers
        pendingFinesInGroup = allFines.filter {
            $0.groupId == group.id
                && !$0.paid
                && !$0.waived
                && ($0.status == .proposed || $0.status == .officialized || $0.status == .inAppeal)
        }
    }

    private func leave() async {
        leaving = true
        defer { leaving = false }
        do {
            try await app.groupsRepo.leave(group.id)
            await app.refreshProfileAndGroups()
            dismiss()
        } catch {
            self.error = "No pudimos salir. Intenta de nuevo."
        }
    }
}
