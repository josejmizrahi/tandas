import SwiftUI
import RuulUI
import RuulCore

// MARK: - valuation

public struct ValuationSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "valuation",
        priority: 500,
        tabId: "money",
        isEnabledFor: { caps in caps.contains(CapabilityID.valuation) },
        render: { ctx in AnyView(ValuationSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "VALUACIÓN") {
            if let formatted = valuationDisplay {
                StubMetadataRow(label: "Valor estimado", value: formatted)
                if let updated = context.resource.metadata["valuation_updated_at"]?.stringValue {
                    StubDivider()
                    StubMetadataRow(label: "Actualizado", value: TimingDate.short(updated))
                }
            } else {
                StubPlaceholderRow(
                    symbol: "tag",
                    subtitle: "Sin valuación registrada todavía."
                )
            }
        }
    }

    private var valuationDisplay: String? {
        let cents = context.resource.metadata["valuation_cents"]?.intValue
            ?? context.resource.metadata["value_cents"]?.intValue
        let currency = context.resource.metadata["currency"]?.stringValue
            ?? context.resource.metadata["valuation_currency"]?.stringValue
        guard let cents else { return nil }
        return AssetMoneyFormatter.format(cents: Int64(cents), currency: currency)
    }
}

// MARK: - inventory

public struct InventorySectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "inventory",
        priority: 510,
        isEnabledFor: { caps in caps.contains(CapabilityID.inventory) },
        render: { ctx in AnyView(InventorySectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "INVENTARIO") {
            if let qty = quantity {
                StubMetadataRow(label: "Cantidad", value: "\(qty)")
                if let unit = context.resource.metadata["unit"]?.stringValue {
                    StubDivider()
                    StubMetadataRow(label: "Unidad", value: unit)
                }
            } else {
                StubPlaceholderRow(
                    symbol: "shippingbox",
                    subtitle: "Sin conteo de inventario."
                )
            }
        }
    }

    private var quantity: Int? {
        context.resource.metadata["quantity"]?.intValue
            ?? context.resource.metadata["inventory_count"]?.intValue
    }
}

// MARK: - access

public struct AccessSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "access",
        priority: 530,
        isEnabledFor: { caps in caps.contains(CapabilityID.access) },
        render: { ctx in AnyView(AccessSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "ACCESO") {
            if let scopeLabel {
                StubMetadataRow(label: "Visibilidad", value: scopeLabel)
            } else {
                StubPlaceholderRow(
                    symbol: "lock",
                    subtitle: "Control de acceso por miembro llegará pronto."
                )
            }
        }
    }

    private var scopeLabel: String? {
        guard let raw = context.resource.metadata["access_scope"]?.stringValue
            ?? context.resource.metadata["visibility"]?.stringValue
        else { return nil }
        switch raw.lowercased() {
        case "public", "group": return "Todo el grupo"
        case "private":         return "Privado"
        case "members":         return "Miembros invitados"
        default:                return raw.capitalized
        }
    }
}

// MARK: - delegation

public struct DelegationSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "delegation",
        priority: 540,
        tabId: "people",
        isEnabledFor: { caps in caps.contains(CapabilityID.delegation) },
        render: { ctx in AnyView(DelegationSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "DELEGACIÓN") {
            if let name = delegateName {
                StubMetadataRow(label: "Delegado a", value: name)
            } else {
                StubPlaceholderRow(
                    symbol: "arrow.uturn.right",
                    subtitle: "Sin delegación activa."
                )
            }
        }
    }

    private var delegateName: String? {
        guard
            let raw = context.resource.metadata["delegate_id"]?.stringValue
                ?? context.resource.metadata["delegated_to"]?.stringValue,
            let id = UUID(uuidString: raw),
            let member = context.memberDirectory[id]
        else { return nil }
        return member.displayName
    }
}
