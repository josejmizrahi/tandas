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
    /// FASE 3 Action Warmth (B.2 variant — sin dismiss): la vista no es
    /// modal por sí misma, así que en lugar de "respirar antes del
    /// dismiss" mostramos un confirm transient ("Invitaste a +52…")
    /// durante 1.5s mientras el pending list reload completa.
    @State private var successPhrase: String?

    public init(group: RuulCore.Group) { self.group = group }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    shareCard
                    addManualSection
                    if let successPhrase {
                        HStack(spacing: RuulSpacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.ruulSemanticSuccess)
                                .accessibilityHidden(true)
                            Text(successPhrase)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                        }
                        .padding(RuulSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .ruulCardSurface(.solid, radius: RuulRadius.md)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if !pending.isEmpty { pendingSection }
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }
                .padding(RuulSpacing.lg)
                .animation(.snappy(duration: 0.22), value: successPhrase)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .ruulSheetToolbar("Invitar miembros")
            .sensoryFeedback(.success, trigger: successPhrase)
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
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            HStack {
                Text(group.inviteCode)
                    .font(.body.monospaced())
                    .foregroundStyle(Color.primary)
                Spacer()
                ShareLink(item: "Únete a \(group.name): \(group.inviteCode)") {
                    Label("Compartir", systemImage: "square.and.arrow.up")
                        .font(.footnote)
                }
            }
            .padding(RuulSpacing.md)
            .ruulCardSurface(.solid, radius: RuulRadius.md)
        }
    }

    private var addManualSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Invitar por teléfono")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            HStack {
                TextField("+52 55 ...", text: $newPhone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .padding(RuulSpacing.md)
                    .ruulCardSurface(.solid, radius: RuulRadius.md)
                Button(sending ? "Enviando…" : "Enviar") {
                    RuulHaptic.light.trigger()
                    Task { await sendInvite() }
                }
                .buttonStyle(.glassProminent)
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
                            .font(.footnote)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        clearPrefill()
                        showAddPlaceholder = true
                    } label: {
                        Label("Manual", systemImage: "square.and.pencil")
                            .font(.footnote)
                    }
                    .buttonStyle(.glass)
                }
                .padding(.top, RuulSpacing.xs)

                Text("Las personas que agregues cuentan desde ya para turnos, RSVPs, fines y votos. Reciben WhatsApp para activar su cuenta.")
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
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
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            VStack(spacing: 0) {
                ForEach(pending) { invite in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.phoneE164 ?? "Sin teléfono")
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                            Text(relativeDateLabel(invite.createdAt))
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        Text("Pendiente")
                            .font(.footnote)
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                    .padding(RuulSpacing.md)
                    if invite.id != pending.last?.id {
                        Divider().background(Color(.separator))
                    }
                }
            }
            .ruulCardSurface(.solid, radius: RuulRadius.md)
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
        error = nil
        do {
            _ = try await app.inviteRepo.createInvite(groupId: group.id, phoneE164: trimmed)
            sending = false
            // FASE 3 D.2 + D.3: confirm transient con teléfono atribuido.
            // 1.5s para coincidir con el pending list reload completo.
            successPhrase = "Invitaste a \(trimmed)"
            newPhone = ""
            await loadPending()
            try? await Task.sleep(for: .milliseconds(1500))
            successPhrase = nil
        } catch {
            sending = false
            self.error = "No pudimos enviar la invitación."
            RuulHaptic.error.trigger()
        }
    }
}
