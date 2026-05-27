import Foundation

/// Centralised SwiftUI string namespace. Backed by `LocalizedStringResource`
/// so each constant resolves through the app's Localizable / .xcstrings
/// catalog when one is added. Default values are Mexican Spanish — the
/// founder locale — and serve as the on-disk source until a catalog is
/// generated.
///
/// Slice 6 introduces the first two namespaces (`Members`, `Invite`).
/// Add new feature namespaces here rather than scattering raw strings
/// through Views.
public enum L10n {

    public enum Members {
        public static let title              = LocalizedStringResource("members.title",              defaultValue: "Miembros")
        public static let searchPrompt       = LocalizedStringResource("members.search_prompt",      defaultValue: "Buscar miembros")
        public static let sectionYou         = LocalizedStringResource("members.section.you",        defaultValue: "Tú")
        public static let sectionActive      = LocalizedStringResource("members.section.active",     defaultValue: "Activos")
        public static let sectionProvisional = LocalizedStringResource("members.section.provisional",defaultValue: "Provisionales")
        public static let sectionInvited     = LocalizedStringResource("members.section.invited",    defaultValue: "Invitados")
        public static let sectionSuspended   = LocalizedStringResource("members.section.suspended",  defaultValue: "Suspendidos")
        public static let inviteButton       = LocalizedStringResource("members.invite_button",      defaultValue: "Invitar")
        public static let emptyTitle         = LocalizedStringResource("members.empty.title",        defaultValue: "Aún no hay miembros")
        public static let emptyDescription   = LocalizedStringResource("members.empty.description",  defaultValue: "Invita a alguien para empezar a coordinar.")
        public static let errorTitle         = LocalizedStringResource("members.error.title",        defaultValue: "No pudimos cargar los miembros")
        public static let retryButton        = LocalizedStringResource("members.error.retry",        defaultValue: "Reintentar")
    }

    public enum Invite {
        public static let title                = LocalizedStringResource("invite.title",                 defaultValue: "Invitar a alguien")
        public static let contactSection       = LocalizedStringResource("invite.section.contact",       defaultValue: "Contacto")
        public static let emailPlaceholder     = LocalizedStringResource("invite.placeholder.email",     defaultValue: "Correo electrónico")
        public static let phonePlaceholder     = LocalizedStringResource("invite.placeholder.phone",     defaultValue: "Teléfono")
        public static let membershipTypeSection = LocalizedStringResource("invite.section.type",         defaultValue: "Tipo de membresía")
        public static let messageSection       = LocalizedStringResource("invite.section.message",       defaultValue: "Mensaje")
        public static let messagePlaceholder   = LocalizedStringResource("invite.placeholder.message",   defaultValue: "Agrega un mensaje…")
        public static let cancel               = LocalizedStringResource("invite.cancel",                defaultValue: "Cancelar")
        public static let send                 = LocalizedStringResource("invite.send",                  defaultValue: "Enviar")
    }
}
