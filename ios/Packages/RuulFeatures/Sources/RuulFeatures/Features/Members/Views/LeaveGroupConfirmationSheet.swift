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
    @State private var loading = true
    @State private var error: String?

    public init(group: RuulCore.Group) { self.group = group }

    private var isSoleAdmin: Bool {
        guard let uid = app.session?.user.id else { return false }
        let admins = members.filter { $0.member.isFounder && $0.member.active }
        return admins.count == 1 && admins.first?.member.userId == uid
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
            .navigationTitle("Salir del grupo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    RuulCloseToolbarButton { dismiss() }
                }
            }
            .task { await loadMembers() }
        }
    }

    private var soleAdminBlocker: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Label("Eres el único admin", systemImage: "exclamationmark.triangle")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulWarning)
            Text("Antes de salir, transfiere admin a otro miembro o archiva el grupo.")
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

    private func loadMembers() async {
        loading = true
        defer { loading = false }
        do {
            members = try await app.groupsRepo.membersWithProfiles(of: group.id)
        } catch {
            self.error = "No pudimos verificar tu rol."
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
