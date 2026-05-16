import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct InviteMembersFromGroupView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let group: RuulCore.Group

    @State private var newPhone: String = ""
    @State private var pending: [Invite] = []
    @State private var loading = false
    @State private var sending = false
    @State private var error: String?

    public init(group: RuulCore.Group) { self.group = group }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    shareCard
                    addManualSection
                    if !pending.isEmpty { pendingSection }
                    if let error {
                        Text(error)
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle("Invitar miembros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { RuulCloseToolbarButton { dismiss() } }
            }
            .task { await loadPending() }
        }
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Código de invitación")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            HStack {
                Text(group.inviteCode)
                    .ruulTextStyle(RuulTypography.mono)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
                ShareLink(item: "Únete a \(group.name): \(group.inviteCode)") {
                    Label("Compartir", systemImage: "square.and.arrow.up")
                        .ruulTextStyle(RuulTypography.callout)
                }
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
        }
    }

    private var addManualSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Invitar por teléfono")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            HStack {
                TextField("+52 55 ...", text: $newPhone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .padding(RuulSpacing.md)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
                Button("Enviar") { Task { await sendInvite() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || newPhone.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Invitaciones pendientes (\(pending.count))")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            VStack(spacing: 0) {
                ForEach(pending) { invite in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.phoneE164 ?? "Sin teléfono")
                                .ruulTextStyle(RuulTypography.body)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Text(relativeDateLabel(invite.createdAt))
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                        }
                        Spacer()
                        Text("Pendiente")
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .padding(RuulSpacing.md)
                    if invite.id != pending.last?.id {
                        Divider().background(Color.ruulSeparator)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
        }
    }

    private func relativeDateLabel(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return "Enviada \(f.localizedString(for: date, relativeTo: .now))"
    }

    private func loadPending() async {
        loading = true
        defer { loading = false }
        do {
            pending = try await app.inviteRepo.listPending(groupId: group.id)
        } catch {
            self.error = "No pudimos cargar las invitaciones pendientes."
        }
    }

    private func sendInvite() async {
        let trimmed = newPhone.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await app.inviteRepo.createInvite(groupId: group.id, phoneE164: trimmed)
            newPhone = ""
            await loadPending()
        } catch {
            self.error = "No pudimos enviar la invitación."
        }
    }
}
