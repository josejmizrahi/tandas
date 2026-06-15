import SwiftUI
import RuulCore

/// R.10.F.5 — `class_key="digital_asset"` renderer (cuenta digital /
/// suscripción / dominio / membership / NFT).
///
/// Migra `case "digital_asset":` inline en `ResourceDetailV2InfoSection` al
/// protocolo polimórfico. Cero cambio visual respecto al monolito previo.
@MainActor
struct DigitalAssetRenderer: ResourceSubtypeRenderer {
    static let classKey = "digital_asset"

    func informationFields(_ d: ResourceDetailDescriptor) -> AnyView {
        AnyView(
            Group {
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
        )
    }
}
