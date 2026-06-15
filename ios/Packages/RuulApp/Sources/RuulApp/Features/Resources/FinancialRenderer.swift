import SwiftUI
import RuulCore

/// R.10.F.2 — `class_key="financial"` renderer (cuenta bancaria / billetera /
/// fondo / cripto / crédito).
///
/// Migra `case "financial":` inline en `ResourceDetailV2InfoSection` al
/// protocolo polimórfico. Cero cambio visual respecto al monolito previo.
/// `maskedAccountNumber` se localiza aquí — antes era privado del Info section.
///
/// E.3 consolidación "Dinero" Section (balance + obligaciones + acciones
/// financieras en 1 Section) queda pendiente — requiere filter del global
/// `LinkedObligationsSection` a nivel orquestador. Se aborda en F.10 cleanup
/// cross-subtype.
@MainActor
struct FinancialRenderer: ResourceSubtypeRenderer {
    static let classKey = "financial"

    func informationFields(_ d: ResourceDetailDescriptor) -> AnyView {
        AnyView(
            Group {
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
                        Text(Self.maskedAccountNumber(accountNumber))
                            .font(.callout.monospaced())
                    }
                }
                if let walletAddress = d.resource.metadataString("wallet_address") {
                    LabeledContent("Dirección") {
                        Text(Self.maskedAccountNumber(walletAddress))
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let lastMovement = d.metrics.lastMovementAt {
                    LabeledContent(
                        "Último movimiento",
                        value: lastMovement.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let value = d.metrics.estimatedValue, let currency = d.metrics.currency,
                   d.metrics.balance == nil {
                    LabeledContent("Valor estimado", value: value.compactCurrencyLabel(currency))
                }
            }
        )
    }

    /// Enmascara account numbers / wallet addresses (primeros 2 + últimos 4).
    static func maskedAccountNumber(_ raw: String) -> String {
        guard raw.count > 8 else { return raw }
        let prefix = raw.prefix(2)
        let suffix = raw.suffix(4)
        return "\(prefix)••••\(suffix)"
    }
}
