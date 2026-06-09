import SwiftUI
import RuulCore
import ContactsUI
import Contacts

/// F.5 + R.5W redesign (2026-06-08) — Invitar personas al contexto.
///
/// **Founder doctrine 2026-06-08:** unificar el flujo. Cero segmented picker.
/// Cero badge categórico. Cualquier persona que agregues queda como "Pendiente
/// de unirse" hasta que efectivamente acepte. Si tiene la app y la conoces de
/// otro contexto → `invite_member`. Si no la tiene → `create_placeholder_person`
/// (Splitwise pattern: aparece igual en members, splits, eventos).
///
/// **Layout best-practice social** (WhatsApp / Apple Family Sharing):
///
/// 1. **Compartir invitación** — ShareLink prominente al top. Cualquier persona
///    con el link se une al instante. Útil para grupos grandes / desconocidos.
/// 2. **Personas en Ruul** — buscable, los que conoces de otros espacios.
///    Tap = invita directo (invite_member).
/// 3. **Agregar persona** — form para gente que no usa la app. Pre-llena vía
///    Contactos. Submit = placeholder + aparece en members list de inmediato.
///
/// Cero menús internos. Cero modos. Una sola pantalla.
public struct InviteMembersView: View {
    let context: AppContext
    let store: MembersStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss

    // Universal share link (lazy — se crea sólo si el founder lo necesita).
    @State private var invite: InviteCreated?
    @State private var isGeneratingInvite = false

    // Personas en Ruul (other contexts)
    @State private var knownActors: [KnownActor] = []
    @State private var isLoadingKnown = false
    @State private var search = ""
    @State private var directlyInvitedNames: Set<String> = []

    // Agregar persona manualmente
    @State private var newName = ""
    @State private var newPhone = ""
    @State private var newEmail = ""
    @State private var isShowingContactPicker = false
    @State private var lastAddedName: String?

    @State private var runner = ActionRunner()

    public init(context: AppContext, store: MembersStore, container: DependencyContainer) {
        self.context = context
        self.store = store
        self.container = container
    }

    public var body: some View {
        NavigationStack {
            List {
                shareSection
                personasEnRuulSection
                agregarPersonaSection
            }
            .navigationTitle("Invitar a \(context.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar persona")
            .task {
                await loadKnown()
                await ensureInvite()
            }
            .sheet(isPresented: $isShowingContactPicker) {
                ContactPickerSheet { picked in
                    isShowingContactPicker = false
                    // R.5W UX fix 2026-06-08 — auto-add: si el picker retorna
                    // nombre, inmediatamente crea el placeholder. Sin paso de
                    // confirmación manual (Splitwise / WhatsApp pattern).
                    // El feedback aparece en la sección "Compartir" al top.
                    guard let name = picked.name, !name.isEmpty else { return }
                    Task {
                        await autoAddFromContact(
                            name: name,
                            phone: picked.phone,
                            email: picked.email
                        )
                    }
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    // MARK: - 1. Compartir invitación + feedback de personas agregadas

    @ViewBuilder
    private var shareSection: some View {
        // Si acabas de agregar alguien (manual o desde contactos), se muestra
        // toast inline aquí. Mantiene visible el feedback sin perder de vista
        // el share link de arriba.
        if let lastAddedName {
            Section {
                Label(
                    "\(lastAddedName) agregado como pendiente. Comparte el link de abajo para que se una.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(Theme.Tint.success)
            }
        }

        Section {
            if let invite {
                ShareLink(
                    item: inviteURL(invite),
                    subject: Text("Invitación a \(context.displayName)"),
                    message: Text(shareMessage(invite))
                ) {
                    Label("Compartir invitación", systemImage: "square.and.arrow.up")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Si falló, mostramos un botón de reintentar siempre tappable.
                Button {
                    Task { await ensureInvite(force: true) }
                } label: {
                    HStack {
                        if isGeneratingInvite {
                            ProgressView().controlSize(.small)
                            Text("Generando link…")
                                .font(.callout)
                                .foregroundStyle(Theme.Text.secondary)
                        } else {
                            Label("Generar link de invitación", systemImage: "link")
                                .font(.callout.weight(.semibold))
                        }
                        Spacer()
                    }
                }
                .disabled(isGeneratingInvite)
            }
        } header: {
            Text("Compartir invitación")
        } footer: {
            Text("Cualquier persona que abra el link se une a \(context.displayName) al instante. Compártelo por WhatsApp, Mensajes o cualquier app.")
        }
    }

    private func ensureInvite(force: Bool = false) async {
        if force { invite = nil }
        guard invite == nil, !isGeneratingInvite else { return }
        isGeneratingInvite = true
        defer { isGeneratingInvite = false }
        invite = try? await store.createInvite(contextId: context.id, maxUses: nil)
    }

    /// R.5W UX fix — auto-add desde el contact picker. Crea el placeholder
    /// inmediatamente, refresca members store y muestra toast en la section
    /// "Compartir" al top.
    private func autoAddFromContact(name: String, phone: String?, email: String?) async {
        await runner.run {
            _ = try await container.rpc.createPlaceholderPerson(
                contextId: context.id,
                displayName: name,
                phone: phone?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                email: email?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                membershipType: "member"
            )
            await store.load(context: context)
            lastAddedName = name
        }
    }

    private func inviteURL(_ invite: InviteCreated) -> URL {
        URL(string: "https://ruul.mx/invite/\(invite.code)") ?? URL(string: "https://ruul.mx")!
    }

    private func shareMessage(_ invite: InviteCreated) -> String {
        "Únete a \(context.displayName) en Ruul. Abre el link o usa el código \(invite.code)."
    }

    // MARK: - 2. Personas en Ruul

    @ViewBuilder
    private var personasEnRuulSection: some View {
        if isLoadingKnown {
            Section {
                HStack { ProgressView(); Text("Buscando personas…").font(.callout) }
            } header: { Text("Personas en Ruul") }
        } else if !knownActors.isEmpty {
            Section {
                ForEach(filteredKnown) { actor in
                    Button {
                        Task { await inviteDirect(actor) }
                    } label: {
                        knownActorRow(actor)
                    }
                    .disabled(runner.isRunning || directlyInvitedNames.contains(actor.displayName))
                }
                if filteredKnown.isEmpty && !search.isEmpty {
                    Text("Sin coincidencias para “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(Theme.Text.secondary)
                }
            } header: {
                Text("Personas en Ruul")
            } footer: {
                Text("Personas con quien compartes otros espacios. Tap para invitarlas — les llega como invitación pendiente.")
            }
        }
    }

    @ViewBuilder
    private func knownActorRow(_ actor: KnownActor) -> some View {
        HStack(spacing: 12) {
            ActorInitialsView(name: actor.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(actor.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                if !actor.sharedContexts.isEmpty {
                    Text(actor.sharedContexts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if directlyInvitedNames.contains(actor.displayName) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Tint.success)
            } else {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Theme.Tint.primary)
            }
        }
    }

    private var filteredKnown: [KnownActor] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return knownActors }
        return knownActors.filter { $0.displayName.lowercased().contains(q) }
    }

    private func loadKnown() async {
        guard knownActors.isEmpty else { return }
        isLoadingKnown = true
        defer { isLoadingKnown = false }
        do {
            let myWorld = try await container.rpc.myWorld()
            knownActors = await store.loadKnownActors(
                myWorld: myWorld,
                excludingContext: context.id,
                myActorId: container.currentActorStore.actorId
            )
        } catch {
            knownActors = []
        }
    }

    private func inviteDirect(_ actor: KnownActor) async {
        await runner.run {
            _ = try await store.inviteMember(context: context, memberActorId: actor.actorId)
            directlyInvitedNames.insert(actor.displayName)
        }
    }

    // MARK: - 3. Agregar persona (placeholder)

    @ViewBuilder
    private var agregarPersonaSection: some View {
        // Contactos: row prominente que abre el picker. Tap a un contacto =
        // se agrega automáticamente (sin pasos manuales).
        Section {
            Button {
                isShowingContactPicker = true
            } label: {
                Label("Elegir de Contactos", systemImage: "person.crop.circle.badge.plus")
                    .font(.callout.weight(.semibold))
            }
        } header: {
            Text("Desde tus contactos")
        } footer: {
            Text("Toca para abrir tu app de Contactos. La persona se agrega como miembro pendiente al instante.")
        }

        Section {
            TextField("Nombre", text: $newName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textContentType(.name)
            TextField("Teléfono (opcional)", text: $newPhone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            TextField("Email (opcional)", text: $newEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.emailAddress)
        } header: {
            Text("O escribir manualmente")
        } footer: {
            Text("Para gente que aún no usa Ruul. Aparece de inmediato en miembros, eventos y gastos. Cuando se registre con su teléfono o email, su historia se vincula automáticamente.")
        }

        Section {
            Button {
                Task { await createPlaceholder() }
            } label: {
                if runner.isRunning {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Agregar a \(context.displayName)", systemImage: "person.fill.badge.plus")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!canCreatePlaceholder)
        }
    }

    private var canCreatePlaceholder: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty && !runner.isRunning
    }

    private func createPlaceholder() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let phone = newPhone.trimmingCharacters(in: .whitespaces)
        let email = newEmail.trimmingCharacters(in: .whitespaces)
        await runner.run {
            _ = try await container.rpc.createPlaceholderPerson(
                contextId: context.id,
                displayName: name,
                phone: phone.isEmpty ? nil : phone,
                email: email.isEmpty ? nil : email,
                membershipType: "member"
            )
            await store.load(context: context)
            lastAddedName = name
            newName = ""
            newPhone = ""
            newEmail = ""
        }
    }
}

// MARK: - Contact picker wrapper

/// SwiftUI wrap de `CNContactPickerViewController`. Requiere
/// `NSContactsUsageDescription` en Info.plist (ya presente).
private struct ContactPickerSheet: UIViewControllerRepresentable {
    struct ImportedContact {
        let name: String?
        let phone: String?
        let email: String?
    }

    let onPick: (ImportedContact) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey
        ]
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (ImportedContact) -> Void

        init(onPick: @escaping (ImportedContact) -> Void) {
            self.onPick = onPick
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let phone = contact.phoneNumbers.first.map { $0.value.stringValue }
            let email = contact.emailAddresses.first.map { $0.value as String }
            onPick(ImportedContact(
                name: name.isEmpty ? nil : name,
                phone: phone,
                email: email
            ))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onPick(ImportedContact(name: nil, phone: nil, email: nil))
        }
    }
}

#Preview("Invitar") {
    InviteMembersView(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        ),
        store: MembersStore(rpc: MockRuulRPCClient.demo()),
        container: .demo()
    )
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
