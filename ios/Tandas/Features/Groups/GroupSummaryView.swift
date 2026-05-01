import SwiftUI

/// Luma-style detail page: hero + 3-button action row + sections.
struct GroupSummaryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let group: Group

    @State private var members: [Member] = []
    @State private var isLeaving: Bool = false
    @State private var showLeaveConfirm: Bool = false
    @State private var copied: Int = 0

    var body: some View {
        ZStack(alignment: .top) {
            Brand.Surface.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.Layout.sectionGap) {
                    hero
                    actionRow

                    section(title: "Invite code") {
                        inviteCard
                    }

                    section(title: "Miembros (\(members.count))") {
                        membersList
                    }
                }
                .padding(.horizontal, Brand.Layout.pagePadH)
                .padding(.top, 80)
                .padding(.bottom, Brand.Layout.pageBottomPad)
            }

            // Floating glass back button (Luma style on detail page)
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.Surface.textPrimary)
                        .frame(width: Brand.Layout.headerActionSize, height: Brand.Layout.headerActionSize)
                        .glassEffect(.regular, in: Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    showLeaveConfirm = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.Surface.textPrimary)
                        .frame(width: Brand.Layout.headerActionSize, height: Brand.Layout.headerActionSize)
                        .glassEffect(.regular, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Brand.Layout.pagePadH)
            .padding(.top, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
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

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover icon (mimics IMG_6477's image hero — placeholder while no real cover)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Brand.Surface.card)
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .overlay(
                    Image(systemName: group.groupType.symbolName)
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(Brand.Surface.textTertiary)
                )

            Text(group.groupType.displayName.uppercased())
                .font(Brand.Typography.rowKicker)
                .tracking(0.5)
                .foregroundStyle(Brand.Surface.textSecondary)
                .padding(.top, 8)

            Text(group.name)
                .font(Brand.Typography.heroTitle)
                .foregroundStyle(Brand.Surface.textPrimary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                UIPasteboard.general.string = group.inviteCode
                copied &+= 1
            } label: {
                Text("Compartir")
                    .lumaPrimaryPill()
            }
            .buttonStyle(.plain)

            Button {
                // Future: contact / message group
            } label: {
                Text("Contactar")
                    .frame(maxWidth: .infinity)
                    .lumaSecondaryPill()
            }
            .buttonStyle(.plain)

            Button {
                showLeaveConfirm = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(Brand.Typography.button)
                    .foregroundStyle(Brand.Surface.textPrimary)
                    .frame(width: 50, height: Brand.Layout.secondaryHeight)
                    .background(Capsule().fill(Brand.Surface.card))
                    .overlay(Capsule().stroke(Brand.Surface.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Brand.Typography.label)
                .tracking(0.3)
                .textCase(.uppercase)
                .foregroundStyle(Brand.Surface.textSecondary)
            content()
        }
    }

    private var inviteCard: some View {
        HStack {
            Text(group.inviteCode)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(Brand.Surface.textPrimary)
            Spacer()
            Button {
                UIPasteboard.general.string = group.inviteCode
                copied &+= 1
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Copiar")
                        .font(Brand.Typography.captionEmph)
                }
                .foregroundStyle(Brand.Surface.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Brand.Surface.cardPressed))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                .fill(Brand.Surface.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                .stroke(Brand.Surface.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var membersList: some View {
        if members.isEmpty {
            Text("Tú eres el primero del grupo.")
                .font(Brand.Typography.body)
                .foregroundStyle(Brand.Surface.textSecondary)
        } else {
            VStack(spacing: 0) {
                ForEach(members) { m in
                    HStack(spacing: 12) {
                        LumaAvatar(initial: String(m.displayNameOverride?.prefix(1).uppercased() ?? "?"), size: 40)
                        Text(m.displayNameOverride ?? m.userId.uuidString.prefix(8).description)
                            .font(Brand.Typography.rowTitle)
                            .foregroundStyle(Brand.Surface.textPrimary)
                        Spacer()
                        Text(m.role)
                            .font(Brand.Typography.caption)
                            .foregroundStyle(Brand.Surface.textTertiary)
                    }
                    .padding(.vertical, 8)
                    if m.id != members.last?.id {
                        Divider().background(Brand.Surface.border)
                    }
                }
            }
        }
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
