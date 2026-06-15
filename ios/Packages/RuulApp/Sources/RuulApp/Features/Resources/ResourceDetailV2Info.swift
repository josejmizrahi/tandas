import SwiftUI
import RuulCore

/// R.10.A — Información section + per-class fields + capability catalog
/// (code move, zero behavior change).
///
/// Doctrina: R.5V native-first · "Section is the card".
///
/// **R.10.B target**: el `switch d.class.classKey` aquí se reemplaza por un
/// protocolo `ResourceSubtypeRenderer` en el siguiente slice. R.10.A NO mete
/// polimorfismo todavía — sólo relocaliza el código tal cual (427–675 +
/// 1290–1350 del monolito previo).

struct ResourceDetailV2InfoSection: View {
    let descriptor: ResourceDetailDescriptor

    var body: some View {
        let d = descriptor
        Section {
            LabeledContent("Estado", value: estadoLabel(d))
            LabeledContent("Subtipo", value: d.subtype.displayName)

            switch d.class.classKey {
            case "financial":
                financialFields(d)
            case "real_estate":
                realEstateFields(d)
            case "vehicle":
                vehicleFields(d)
            case "equipment":
                equipmentFields(d)
            case "document":
                documentFields(d)
            case "trip":
                tripFields(d)
            case "digital_asset":
                digitalAssetFields(d)
            default:
                genericFields(d)
            }

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

    @ViewBuilder
    private func financialFields(_ d: ResourceDetailDescriptor) -> some View {
        if let balance = d.metrics.balance, let currency = d.metrics.currency {
            LabeledContent("Saldo") {
                Text(balance.compactCurrencyLabel(currency))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Tint.success)
            }
        }
        if let institution = d.resource.metadataString("institution") {
            LabeledContent("Institución", value: institution)
        }
        if let accountNumber = d.resource.metadataString("account_number") {
            LabeledContent("Cuenta") {
                Text(maskedAccountNumber(accountNumber))
                    .font(.callout.monospaced())
            }
        }
        if let walletAddress = d.resource.metadataString("wallet_address") {
            LabeledContent("Dirección") {
                Text(maskedAccountNumber(walletAddress))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if let lastMovement = d.metrics.lastMovementAt {
            LabeledContent("Último movimiento",
                value: lastMovement.formatted(date: .abbreviated, time: .shortened))
        }
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency,
           d.metrics.balance == nil {
            LabeledContent("Valor estimado", value: value.compactCurrencyLabel(currency))
        }
    }

    @ViewBuilder
    private func realEstateFields(_ d: ResourceDetailDescriptor) -> some View {
        if let location = d.resource.locationText, !location.isEmpty {
            LabeledContent("Ubicación", value: location)
        }
        if let area = d.resource.metadataString("area_sqm") {
            LabeledContent("Superficie", value: "\(area) m²")
        }
        if let bedrooms = d.resource.metadataString("bedrooms") {
            LabeledContent("Habitaciones", value: bedrooms)
        }
        if let bathrooms = d.resource.metadataString("bathrooms") {
            LabeledContent("Baños", value: bathrooms)
        }
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
            LabeledContent("Valor estimado", value: value.compactCurrencyLabel(currency))
        }
    }

    @ViewBuilder
    private func vehicleFields(_ d: ResourceDetailDescriptor) -> some View {
        if let make = d.resource.metadataString("make"),
           let model = d.resource.metadataString("model") {
            LabeledContent("Modelo", value: "\(make) \(model)")
        } else if let model = d.resource.metadataString("model") {
            LabeledContent("Modelo", value: model)
        }
        if let year = d.resource.metadataString("year") {
            LabeledContent("Año", value: year)
        }
        if let plate = d.resource.metadataString("license_plate") {
            LabeledContent("Placa") {
                Text(plate)
                    .font(.callout.monospaced())
            }
        }
        if let vin = d.resource.metadataString("vin") {
            LabeledContent("VIN") {
                Text(vin)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if let location = d.resource.locationText, !location.isEmpty {
            LabeledContent("Ubicación", value: location)
        }
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
            LabeledContent("Valor estimado", value: value.compactCurrencyLabel(currency))
        }
    }

    @ViewBuilder
    private func equipmentFields(_ d: ResourceDetailDescriptor) -> some View {
        if let make = d.resource.metadataString("make"),
           let model = d.resource.metadataString("model") {
            LabeledContent("Modelo", value: "\(make) \(model)")
        }
        if let serial = d.resource.metadataString("serial_number") {
            LabeledContent("Serie") {
                Text(serial)
                    .font(.callout.monospaced())
            }
        }
        if let location = d.resource.locationText, !location.isEmpty {
            LabeledContent("Ubicación", value: location)
        }
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
            LabeledContent("Valor estimado", value: value.compactCurrencyLabel(currency))
        }
    }

    @ViewBuilder
    private func documentFields(_ d: ResourceDetailDescriptor) -> some View {
        if let partyA = d.resource.metadataString("party_a") {
            LabeledContent("Parte A", value: partyA)
        }
        if let partyB = d.resource.metadataString("party_b") {
            LabeledContent("Parte B", value: partyB)
        }
        if let effective = d.resource.metadataString("effective_date") {
            LabeledContent("Vigencia", value: effective)
        }
        if let expiration = d.resource.metadataString("expiration_date") {
            LabeledContent("Vence", value: expiration)
        }
        if let created = d.resource.createdAt {
            LabeledContent("Creado", value: created.formatted(date: .abbreviated, time: .omitted))
        }
        if d.state.lockedForGovernance {
            LabeledContent("Bloqueado") {
                Label("Decisión abierta", systemImage: "lock.fill")
                    .foregroundStyle(.purple)
            }
        }
    }

    @ViewBuilder
    private func tripFields(_ d: ResourceDetailDescriptor) -> some View {
        if let location = d.resource.locationText, !location.isEmpty {
            LabeledContent("Destino", value: location)
        }
        if let startDate = d.resource.metadataString("start_date") {
            LabeledContent("Inicio", value: startDate)
        }
        if let endDate = d.resource.metadataString("end_date") {
            LabeledContent("Fin", value: endDate)
        }
    }

    @ViewBuilder
    private func digitalAssetFields(_ d: ResourceDetailDescriptor) -> some View {
        if let platform = d.resource.metadataString("platform") {
            LabeledContent("Plataforma", value: platform)
        }
        if let url = d.resource.metadataString("url") {
            LabeledContent("URL") {
                Text(url)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
            LabeledContent("Valor estimado", value: value.compactCurrencyLabel(currency))
        }
    }

    @ViewBuilder
    private func genericFields(_ d: ResourceDetailDescriptor) -> some View {
        LabeledContent("Categoría", value: d.class.displayName)
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
            LabeledContent("Valor estimado", value: value.compactCurrencyLabel(currency))
        }
    }

    /// Enmascara account numbers / wallet addresses para evitar exponer todos
    /// los dígitos en pantalla. Muestra primeros 2 + últimos 4.
    private func maskedAccountNumber(_ raw: String) -> String {
        guard raw.count > 8 else { return raw }
        let prefix = raw.prefix(2)
        let suffix = raw.suffix(4)
        return "\(prefix)••••\(suffix)"
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
