import SwiftUI
import Contacts
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
    @State private var showAddPlaceholder = false
    @State private var showContactPicker = false
    @State private var prefillName: String?
    @State private var prefillPhone: String?

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
            .ruulSheetToolbar("Invitar miembros")
            .task { await loadPending() }
            .sheet(isPresented: $showAddPlaceholder, onDismiss: clearPrefill) {
                AddPlaceholderSheet(
                    group: group,
                    prefillName: prefillName,
                    prefillPhone: prefillPhone
                ) { _ in
                    Task { await loadPending() }
                }
            }
            .sheet(isPresented: $showContactPicker) {
                PlaceholderContactPicker(
                    onSelection: { contact, phoneNumber in
                        showContactPicker = false
                        applyContactSelection(contact: contact, phoneNumber: phoneNumber)
                    },
                    onCancel: {
                        showContactPicker = false
                    }
                )
                .ignoresSafeArea()  // CNContactPickerViewController owns chrome
            }
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
            // Placeholder member: cuenta para turnos/RSVP/fines/votos antes
            // de que la persona acepte (mig 00310-00319 + edge fn
            // create-placeholder-member). Solo visible cuando el repo está
            // wireado (live builds) — mocks/previews lo ocultan.
            if app.placeholderMemberRepo != nil {
                HStack(spacing: RuulSpacing.sm) {
                    // Native Apple Contacts picker — handles permission grant
                    // prompt automatically. Best practice: don't rebuild the
                    // picker, use the system one.
                    Button {
                        showContactPicker = true
                    } label: {
                        Label("De mis contactos", systemImage: "person.crop.circle.badge.plus")
                            .ruulTextStyle(RuulTypography.footnote)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        clearPrefill()
                        showAddPlaceholder = true
                    } label: {
                        Label("Manual", systemImage: "square.and.pencil")
                            .ruulTextStyle(RuulTypography.footnote)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, RuulSpacing.xs)

                Text("Las personas que agregues cuentan desde ya para turnos, RSVPs, fines y votos. Reciben WhatsApp para activar su cuenta.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .padding(.top, RuulSpacing.xxs)
            }
        }
    }

    private func clearPrefill() {
        prefillName = nil
        prefillPhone = nil
    }

    private func applyContactSelection(contact: CNContact, phoneNumber: CNPhoneNumber) {
        let name = ContactPickerExtraction.displayName(for: contact)
        let rawPhone = phoneNumber.stringValue
        let normalized = PhoneFormatter.smartE164(rawPhone) ?? rawPhone
        prefillName = name.isEmpty ? nil : name
        prefillPhone = normalized
        // Defer the placeholder sheet present until the contact picker
        // sheet has had a chance to fully dismiss. SwiftUI sheets don't
        // chain reliably otherwise — iOS shows the dismiss animation
        // ending right before the new sheet appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showAddPlaceholder = true
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
