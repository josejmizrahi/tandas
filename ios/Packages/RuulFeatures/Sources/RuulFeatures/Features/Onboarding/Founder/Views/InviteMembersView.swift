import SwiftUI
import ContactsUI
import RuulUI
import RuulCore

public struct InviteMembersView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var contactsPresented = false
    @State private var manualEntryPresented = false

    public var body: some View {
        OnboardingScreenTemplate(
            progress: progressValue,
            title: "Invita a tu grupo",
            subtitle: "Mínimo 3 personas para empezar.",
            primaryCTA: ("Continuar", coord.isLoading, { Task { await coord.advanceFromInvite() } }),
            secondaryCTA: ("Saltar", { Task { await coord.skipInvite() } }),
            canContinue: true
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                if let group = coord.createdGroup {
                    shareLinkCard(group: group)
                    RuulActionableCard(
                        icon: "person.crop.circle.badge.plus",
                        title: "Importar de contactos",
                        subtitle: "Elige quién va a estar en el grupo desde tu agenda.",
                        accessory: .badge("Recomendado")
                    ) {
                        contactsPresented = true
                    }
                    Button {
                        manualEntryPresented = true
                    } label: {
                        HStack(spacing: RuulSpacing.xs) {
                            Image(systemName: "keyboard")
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Escribirlo a mano")
                                .font(.caption)
                        }
                        .foregroundStyle(Color.ruulAccent)
                        .padding(.top, RuulSpacing.xxs)
                    }
                    .buttonStyle(.plain)
                    if !coord.pendingInvites.isEmpty {
                        pendingList
                    }
                }
            }
        }
        // P1: ContactsUI real (antes el contactsPresented era no-op tras
        // un TODO/comment). El user-flow: tap "Importar de contactos"
        // → sheet nativa iOS → multi-pick → callback agrega cada
        // (name, phone) al pendingInvites. iOS solicita permission la
        // primera vez automáticamente.
        .sheet(isPresented: $contactsPresented) {
            ContactPicker(onPicked: handleContactsPick)
        }
        .sheet(isPresented: $manualEntryPresented) {
            manualEntrySheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
    }

    /// Callback del ContactsUI picker. Por cada contacto seleccionado,
    /// toma el primer phone disponible y normaliza a E.164 vía
    /// PhoneFormatter. Skips silently los contactos sin phone válido
    /// (típicamente solo email) y los duplicados (mismo E.164).
    private func handleContactsPick(_ contacts: [CNContact]) {
        var added = 0
        let existingPhones = Set(coord.pendingInvites.map(\.phoneE164))
        for contact in contacts {
            let displayName = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            for phone in contact.phoneNumbers {
                let raw = phone.value.stringValue
                guard let e164 = PhoneFormatter.smartE164(raw),
                      !existingPhones.contains(e164) else { continue }
                coord.pendingInvites.append(
                    PendingInvite(
                        phoneE164: e164,
                        displayName: displayName.isEmpty ? nil : displayName
                    )
                )
                added += 1
                break  // Solo el primer phone por contacto
            }
        }
        if added > 0 {
            Task { await coord.persistPendingInvites() }
        }
    }

    private var progressValue: Double {
        FounderStep.invite.progressFraction
    }

    private func shareLinkCard(group: RuulCore.Group) -> some View {
        let message = InviteLinkGenerator.shareMessage(groupName: group.name, code: group.inviteCode)
        return ShareLink(item: message) {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: "link")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                    Text("Compartir link")
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text("Mándalo por WhatsApp, SMS, donde sea.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .background(
                Color.ruulSurface,
                in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    private var pendingList: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Por invitar (\(coord.pendingInvites.count))")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            VStack(spacing: RuulSpacing.s0) {
                ForEach(coord.pendingInvites) { pending in
                    HStack {
                        VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                            if let name = pending.displayName {
                                Text(name)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.primary)
                                Text(PhoneFormatter.displayFormat(pending.phoneE164))
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            } else {
                                Text(PhoneFormatter.displayFormat(pending.phoneE164))
                                    .font(.subheadline)
                                    .foregroundStyle(Color.primary)
                            }
                        }
                        Spacer()
                        if pending.sentAt != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                                .accessibilityLabel("Invitación enviada")
                        } else {
                            Button { remove(pending) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color(.tertiaryLabel))
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Quitar invitación")
                        }
                    }
                    .padding(.vertical, RuulSpacing.xs)
                    if pending.id != coord.pendingInvites.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func remove(_ invite: PendingInvite) {
        coord.pendingInvites.removeAll { $0.id == invite.id }
        Task { await coord.persistPendingInvites() }
    }

    @State private var manualPhone = ""
    @State private var manualName = ""

    private var manualEntrySheet: some View {
        ModalSheetTemplate(
            title: "Agregar manual",
            dismissAction: { manualEntryPresented = false },
            primaryCTA: ("Agregar", {
                if let e164 = PhoneFormatter.smartE164(manualPhone) {
                    coord.pendingInvites.append(
                        PendingInvite(phoneE164: e164, displayName: manualName.isEmpty ? nil : manualName)
                    )
                    manualPhone = ""
                    manualName = ""
                    manualEntryPresented = false
                    Task { await coord.persistPendingInvites() }
                }
            })
        ) {
            VStack(spacing: RuulSpacing.sm) {
                RuulTextField("Nombre (opcional)", text: $manualName, label: "Nombre")
                RuulPhoneField(text: $manualPhone, label: "Teléfono")
            }
        }
    }
}

// MARK: - ContactsUI bridge

/// Multi-select picker nativo iOS para agregar miembros desde la agenda
/// del usuario. iOS solicita Contacts authorization la primera vez
/// (Info.plist debe declarar `NSContactsUsageDescription`).
///
/// Restringimos display + selection a contactos con al menos un phone
/// (predicateForEnablingContact). Multi-select habilitado via
/// `predicateForSelectionOfProperty = false` truco: dejamos la default
/// que permite selección múltiple a nivel contacto (no a nivel
/// property — eso quitaría el batch UX).
private struct ContactPicker: UIViewControllerRepresentable {
    let onPicked: ([CNContact]) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Solo contactos con phone (filter al display). Sin esto el
        // user puede picar un contacto solo-email que se ignoraría
        // silenciosamente al procesar.
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        // Display predicate: misma lógica para que el listado se vea
        // limpio (no muestra contactos sin phone como grayed-out).
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPicked: ([CNContact]) -> Void
        init(onPicked: @escaping ([CNContact]) -> Void) { self.onPicked = onPicked }

        // Multi-select callback (iOS 9+). Cuando el user tap "Done"
        // tras seleccionar varios contactos.
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            onPicked(contacts)
        }

        // Single-pick callback (fallback). Algunos usuarios solo
        // pican uno y dismissan — capturamos esa ruta también.
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPicked([contact])
        }
    }
}
