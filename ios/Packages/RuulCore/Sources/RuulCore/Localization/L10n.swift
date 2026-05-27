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

    public enum Profile {
        public static let editTitle             = LocalizedStringResource("profile.edit.title",              defaultValue: "Tu perfil")
        public static let onboardingTitle       = LocalizedStringResource("profile.onboarding.title",        defaultValue: "Completa tu perfil")
        public static let onboardingMessage     = LocalizedStringResource("profile.onboarding.message",      defaultValue: "Agrega tu nombre para que otros miembros sepan quién eres.")
        public static let displayNameLabel      = LocalizedStringResource("profile.display_name.label",      defaultValue: "Nombre")
        public static let displayNamePlaceholder = LocalizedStringResource("profile.display_name.placeholder", defaultValue: "Tu nombre")
        public static let usernameLabel         = LocalizedStringResource("profile.username.label",          defaultValue: "Usuario")
        public static let usernamePlaceholder   = LocalizedStringResource("profile.username.placeholder",    defaultValue: "Opcional")
        public static let bioLabel              = LocalizedStringResource("profile.bio.label",               defaultValue: "Sobre ti")
        public static let bioPlaceholder        = LocalizedStringResource("profile.bio.placeholder",         defaultValue: "Opcional")
        public static let cancel                = LocalizedStringResource("profile.cancel",                  defaultValue: "Cancelar")
        public static let save                  = LocalizedStringResource("profile.save",                    defaultValue: "Guardar")
        public static let later                 = LocalizedStringResource("profile.later",                   defaultValue: "Más tarde")
        public static let complete              = LocalizedStringResource("profile.complete",                defaultValue: "Completar")
        public static let displayNameRequired   = LocalizedStringResource("profile.display_name.required",   defaultValue: "Escribe tu nombre.")
    }

    public enum Purpose {
        public static let title              = LocalizedStringResource("purpose.title",                defaultValue: "Propósito")
        public static let emptyTitle         = LocalizedStringResource("purpose.empty.title",          defaultValue: "Sin propósito todavía")
        public static let emptyDescription   = LocalizedStringResource("purpose.empty.description",    defaultValue: "Define para qué existe este grupo.")
        public static let editTitle          = LocalizedStringResource("purpose.edit.title",           defaultValue: "Editar propósito")
        public static let addButton          = LocalizedStringResource("purpose.add",                  defaultValue: "Agregar")
        public static let save               = LocalizedStringResource("purpose.save",                 defaultValue: "Guardar")
        public static let cancel             = LocalizedStringResource("purpose.cancel",               defaultValue: "Cancelar")
        public static let kindLabel          = LocalizedStringResource("purpose.kind.label",           defaultValue: "Tipo")
        public static let declaredLabel      = LocalizedStringResource("purpose.declared.label",       defaultValue: "Declarado")
        public static let declaredSubtitle   = LocalizedStringResource("purpose.declared.subtitle",    defaultValue: "Lo que decimos que somos.")
        public static let operativeLabel     = LocalizedStringResource("purpose.operative.label",      defaultValue: "Operativo")
        public static let operativeSubtitle  = LocalizedStringResource("purpose.operative.subtitle",   defaultValue: "Cómo lo hacemos cada vez.")
        public static let emotionalLabel     = LocalizedStringResource("purpose.emotional.label",      defaultValue: "Emocional")
        public static let emotionalSubtitle  = LocalizedStringResource("purpose.emotional.subtitle",   defaultValue: "Cómo nos hace sentir.")
        public static let bodyLabel          = LocalizedStringResource("purpose.body.label",           defaultValue: "Propósito")
        public static let bodyPlaceholder    = LocalizedStringResource("purpose.body.placeholder",     defaultValue: "Escribe el propósito…")
        public static let visibilityLabel    = LocalizedStringResource("purpose.visibility.label",     defaultValue: "Visibilidad")
        public static let bodyRequired       = LocalizedStringResource("purpose.body.required",        defaultValue: "Escribe el propósito.")
    }

    public enum Rules {
        public static let title              = LocalizedStringResource("rules.title",                defaultValue: "Reglas")
        public static let emptyTitle         = LocalizedStringResource("rules.empty.title",          defaultValue: "Sin reglas todavía")
        public static let emptyDescription   = LocalizedStringResource("rules.empty.description",    defaultValue: "Agrega las primeras reglas del grupo.")
        public static let addButton          = LocalizedStringResource("rules.add",                  defaultValue: "Agregar")
        public static let editTitle          = LocalizedStringResource("rules.edit.title",           defaultValue: "Editar regla")
        public static let createTitle        = LocalizedStringResource("rules.create.title",         defaultValue: "Nueva regla")
        public static let ruleTitleLabel     = LocalizedStringResource("rules.title.label",          defaultValue: "Título")
        public static let ruleTitlePlaceholder = LocalizedStringResource("rules.title.placeholder",  defaultValue: "Ej. Sin celulares en la mesa")
        public static let bodyLabel          = LocalizedStringResource("rules.body.label",           defaultValue: "Detalles")
        public static let bodyPlaceholder    = LocalizedStringResource("rules.body.placeholder",     defaultValue: "Explica la regla…")
        public static let typeLabel          = LocalizedStringResource("rules.type.label",           defaultValue: "Tipo")
        public static let severityLabel      = LocalizedStringResource("rules.severity.label",       defaultValue: "Severidad")
        public static let save               = LocalizedStringResource("rules.save",                 defaultValue: "Guardar")
        public static let cancel             = LocalizedStringResource("rules.cancel",               defaultValue: "Cancelar")
        public static let archive            = LocalizedStringResource("rules.archive",              defaultValue: "Archivar")
        public static let ruleTitleRequired  = LocalizedStringResource("rules.title.required",       defaultValue: "Escribe el título de la regla.")
        public static let ruleBodyRequired   = LocalizedStringResource("rules.body.required",        defaultValue: "Escribe la regla.")
        public static let normLabel          = LocalizedStringResource("rules.type.norm",            defaultValue: "Norma")
        public static let requirementLabel   = LocalizedStringResource("rules.type.requirement",     defaultValue: "Requisito")
        public static let prohibitionLabel   = LocalizedStringResource("rules.type.prohibition",     defaultValue: "Prohibición")
        public static let processLabel       = LocalizedStringResource("rules.type.process",         defaultValue: "Proceso")
        public static let principleLabel     = LocalizedStringResource("rules.type.principle",       defaultValue: "Principio")
        public static let archiveConfirmTitle = LocalizedStringResource("rules.archive.confirm.title", defaultValue: "Archivar regla")
        public static let archiveConfirmMessage = LocalizedStringResource("rules.archive.confirm.message", defaultValue: "Ya no aparecerá como activa. Puedes crear una nueva después.")
        public static let countSingular      = LocalizedStringResource("rules.count.singular",       defaultValue: "1 regla activa")
    }

    public enum Resources {
        public static let title              = LocalizedStringResource("resources.title",              defaultValue: "Recursos")
        public static let emptyTitle         = LocalizedStringResource("resources.empty.title",        defaultValue: "Sin recursos todavía")
        public static let emptyDescription   = LocalizedStringResource("resources.empty.description",  defaultValue: "Agrega los primeros recursos del grupo.")
        public static let addButton          = LocalizedStringResource("resources.add",                defaultValue: "Agregar")
        public static let createTitle        = LocalizedStringResource("resources.create.title",       defaultValue: "Nuevo recurso")
        public static let nameLabel          = LocalizedStringResource("resources.name.label",         defaultValue: "Nombre")
        public static let namePlaceholder    = LocalizedStringResource("resources.name.placeholder",   defaultValue: "Ej. Fondo del viaje")
        public static let descriptionLabel   = LocalizedStringResource("resources.description.label",  defaultValue: "Descripción")
        public static let descriptionPlaceholder = LocalizedStringResource("resources.description.placeholder", defaultValue: "Detalles opcionales…")
        public static let typeLabel          = LocalizedStringResource("resources.type.label",         defaultValue: "Tipo")
        public static let visibilityLabel    = LocalizedStringResource("resources.visibility.label",   defaultValue: "Visibilidad")
        public static let ownershipLabel     = LocalizedStringResource("resources.ownership.label",    defaultValue: "Propiedad")
        public static let save               = LocalizedStringResource("resources.save",               defaultValue: "Guardar")
        public static let cancel             = LocalizedStringResource("resources.cancel",             defaultValue: "Cancelar")
        public static let archive            = LocalizedStringResource("resources.archive",            defaultValue: "Archivar")
        public static let nameRequired       = LocalizedStringResource("resources.name.required",      defaultValue: "Ponle un nombre al recurso.")
        public static let fundLabel          = LocalizedStringResource("resources.type.fund",          defaultValue: "Fondo")
        public static let spaceLabel         = LocalizedStringResource("resources.type.space",         defaultValue: "Espacio")
        public static let assetLabel         = LocalizedStringResource("resources.type.asset",         defaultValue: "Activo")
        public static let documentLabel      = LocalizedStringResource("resources.type.document",      defaultValue: "Documento")
        public static let otherLabel         = LocalizedStringResource("resources.type.other",         defaultValue: "Otro")
        public static let privateLabel       = LocalizedStringResource("resources.visibility.private", defaultValue: "Privado")
        public static let membersLabel       = LocalizedStringResource("resources.visibility.members", defaultValue: "Miembros")
        public static let publicLabel        = LocalizedStringResource("resources.visibility.public",  defaultValue: "Público")
        public static let groupOwnedLabel    = LocalizedStringResource("resources.ownership.group",    defaultValue: "Del grupo")
        public static let memberOwnedLabel   = LocalizedStringResource("resources.ownership.member",   defaultValue: "De un miembro")
        public static let externalOwnedLabel = LocalizedStringResource("resources.ownership.external", defaultValue: "Externo")
        public static let archiveConfirmTitle = LocalizedStringResource("resources.archive.confirm.title", defaultValue: "Archivar recurso")
        public static let archiveConfirmMessage = LocalizedStringResource("resources.archive.confirm.message", defaultValue: "Ya no aparecerá como activo. Puedes crear otro después.")
        public static let countSingular      = LocalizedStringResource("resources.count.singular",     defaultValue: "1 recurso activo")
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
