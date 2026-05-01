import SwiftUI

struct GroupSummaryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let group: Group

    @State private var members: [Member] = []
    @State private var isLeaving: Bool = false
    @State private var showLeaveConfirm: Bool = false
    @State private var copied: Int = 0

    var body: some View {
        ZStack {
            MeshBackground()
            ScrollView {
                VStack(spacing: Brand.Spacing.xl) {
                    header
                    inviteCard
                    membersCard
                    leaveButton
                }
                .padding(.horizontal, Brand.Spacing.xl)
                .padding(.top, Brand.Spacing.xl)
                .padding(.bottom, Brand.Spacing.xxl * 2)
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMembers() }
        .sensoryFeedback(.success, trigger: copied)
        .confirmationDialog(
            "¿Salir de \(group.name)?",
            isPresented: $showLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Salir del grupo", role: .destructive) { Task { await leave() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Vas a perder acceso al grupo. Puedes volver a unirte con el invite code.")
        }
    }

    private var header: some View {
        VStack(spacing: Brand.Spacing.xs) {
            Image(systemName: group.groupType.symbolName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Brand.accent)
            Text(group.groupType.displayName)
                .font(.tandaCaption).foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    private var inviteCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Brand.Spacing.s) {
                Text("Invite code").font(.tandaCaption).foregroundStyle(.white.opacity(0.6))
                HStack {
                    Text(group.inviteCode)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = group.inviteCode
                        copied &+= 1
                    } label: {
                        Label("Copiar", systemImage: "doc.on.doc")
                            .font(.tandaBody)
                            .padding(.horizontal, Brand.Spacing.m)
                            .padding(.vertical, Brand.Spacing.s)
                            .adaptiveGlass(Capsule(), interactive: true)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                Text("Compártelo con quien quieras invitar al grupo.")
                    .font(.tandaCaption).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var membersCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Brand.Spacing.m) {
                Text("Miembros (\(members.count))")
                    .font(.tandaTitle).foregroundStyle(.white)
                if members.isEmpty {
                    Text("Tú eres el primero del grupo.")
                        .font(.tandaBody).foregroundStyle(.white.opacity(0.7))
                } else {
                    ForEach(members) { m in
                        Text(m.displayNameOverride ?? m.userId.uuidString.prefix(8).description)
                            .font(.tandaBody).foregroundStyle(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var leaveButton: some View {
        Button {
            showLeaveConfirm = true
        } label: {
            Text(isLeaving ? "Saliendo…" : "Salir del grupo")
                .font(.tandaBody)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Brand.Spacing.m)
                .adaptiveGlass(Capsule())
        }
        .disabled(isLeaving)
    }

    private func loadMembers() async {
        members = (try? await app.groupsRepo.members(of: group.id)) ?? []
    }

    private func leave() async {
        isLeaving = true
        defer { isLeaving = false }
        try? await app.groupsRepo.leave(group.id)
        await app.refreshProfileAndGroups()
        dismiss()
    }
}
