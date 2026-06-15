import SwiftUI
import RuulCore

/// R.10.A — Información section + Estado/Subtipo header rows + capability catalog.
///
/// Doctrina: R.5V native-first · "Section is the card".
///
/// **R.10.F.1–F.7 (2026-06-15)**: filas específicas por `class_key` migraron al
/// protocolo polimórfico `ResourceSubtypeRenderer`. Este section ahora delega
/// 100% al registry — solo conserva las dos filas universales (Estado/Subtipo)
/// y el footer de Descripción. Agregar un nuevo subtype = registrar renderer
/// en `ResourceSubtypeRegistry`, cero cambios aquí.

struct ResourceDetailV2InfoSection: View {
    let descriptor: ResourceDetailDescriptor

    var body: some View {
        let d = descriptor
        Section {
            LabeledContent("Estado", value: estadoLabel(d))
            LabeledContent("Subtipo", value: d.subtype.displayName)

            ResourceSubtypeRegistry.renderer(for: d.class.classKey)
                .informationFields(d)

            if let description = d.resource.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Descripción")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(Theme.Text.primary)
                }
            }
        } header: {
            Text("Información")
        }
    }

    private func estadoLabel(_ d: ResourceDetailDescriptor) -> String {
        if d.state.archived { return "Archivado" }
        switch d.state.status {
        case "active":    return "Activo"
        case "inactive":  return "Inactivo"
        case "pending":   return "Pendiente"
        case "completed": return "Completado"
        case "cancelled": return "Cancelado"
        default:          return d.state.status.capitalized
        }
    }

}

// MARK: - Capability catalog (snapshot estático, movido del monolito 1290–1350)
//
// Slice 7.A.5 (audit 2026-06-14) — copy conversacional: cero jerga `right USE`,
// `right OWN`, `actor`, `rules`, `lifecycle`, `settlement batches`. Lo que ve el
// usuario es lo que el recurso puede hacer en lenguaje humano.

enum ResourceDetailV2CapabilityCatalog {
    private static let catalog: [String: (displayName: String, description: String)] = [
        "access_controlled":     ("Acceso controlado", "Tiene cerradura, llave o código de acceso."),
        "approvable":            ("Aprobable", "Algunos cambios necesitan que alguien los apruebe."),
        "approval_required":     ("Requiere aprobación", "Cualquier cambio importante necesita aprobación primero."),
        "assignable":            ("Asignable", "Puedes asignárselo a una persona específica."),
        "auditable":             ("Con historial", "Cada movimiento queda registrado y es consultable."),
        "beneficiary_supported": ("Con beneficiarios", "Puedes designar beneficiarios formales."),
        "chargeable":            ("Cobrable", "Puede generar cargos a sus usuarios."),
        "closeable":             ("Cerrable", "Puedes cerrarlo cuando termine su uso."),
        "condition_trackable":   ("Estado registrable", "Puedes anotar su estado físico o de conservación."),
        "custodiable":           ("Con responsable", "Puedes asignar a alguien como responsable temporal."),
        "depreciable":           ("Se deprecia", "Pierde valor con el tiempo."),
        "disputable":            ("Disputable", "Puedes reportar un problema o reclamación formal."),
        "documentable":          ("Documentable", "Puedes guardar documentos asociados (contratos, fotos)."),
        "expirable":             ("Caduca", "Tiene fecha de caducidad."),
        "governable":            ("Sujeto a votación", "Algunos cambios se deciden por votación del espacio."),
        "income_generating":     ("Genera ingreso", "Produce dinero recurrente (renta, dividendos)."),
        "insurable":             ("Asegurable", "Puedes registrar un seguro asociado."),
        "inventory_tracked":     ("En inventario", "Forma parte de un inventario con stock contado."),
        "leasable":              ("Arrendable", "Puedes arrendarlo a alguien externo."),
        "location_bound":        ("Con ubicación", "Tiene ubicación física relevante."),
        "maintainable":          ("Con mantenimiento", "Puedes registrar mantenimientos y servicios."),
        "monetary":              ("Maneja dinero", "Puede registrar y mover dinero."),
        "notifiable":            ("Manda avisos", "Genera notificaciones cuando algo cambia."),
        "ownable":               ("Tiene propietarios", "Puede tener propietarios formales."),
        "ownership_trackable":   ("Propiedad por partes", "Su propiedad se reparte en porcentajes."),
        "payable":               ("Cobra pagos", "Puede recibir pagos directos."),
        "quantity_tracked":      ("Cantidad contada", "Tiene una cantidad que puedes consultar."),
        "recurring":             ("Recurrente", "Se repite cada cierto tiempo."),
        "rentable":              ("Rentable", "Puedes rentarlo a alguien externo."),
        "reservable":            ("Reservable", "Puedes apartarlo en bloques de tiempo."),
        "rule_bound":            ("Sujeto a reglas", "Algunas reglas del espacio aplican sobre él."),
        "schedulable":           ("Agendable", "Puedes agendarlo en el calendario."),
        "sellable":              ("Vendible", "Puede venderse a alguien más."),
        "settleable":            ("Se liquida", "Sus saldos entran al ciclo de liquidaciones."),
        "shareable":             ("Compartible", "Puedes darle acceso a varias personas."),
        "signable":              ("Se firma", "Puedes firmarlo digitalmente."),
        "splittable":            ("Divisible", "Sus montos pueden repartirse entre varias personas."),
        "taxable":               ("Con impuestos", "Puede generar obligaciones fiscales."),
        "transferable":          ("Transferible", "Puedes pasarle la propiedad a alguien más."),
        "usable":                ("Usable sin reservar", "Puedes usarlo sin necesidad de apartarlo primero."),
        "versionable":           ("Con versiones", "Guarda versiones anteriores de su contenido."),
        "votable":               ("Sujeto a votación", "Algunos cambios se deciden por votación.")
    ]

    static func displayName(_ key: String) -> String {
        catalog[key]?.displayName ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func description(_ key: String) -> String {
        catalog[key]?.description ?? "Capacidad del recurso \"\(key)\"."
    }
}
