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
        // Plataforma intencionalmente NO va aquí — vive en `heroSubtitle`
        // (E.4 dedup). Es el campo identity (Netflix / Apple Music / dominio).
        AnyView(
            Group {
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

    /// R.10.F.f Hero subtitle — plataforma como identity (App Store style).
    func heroSubtitle(_ d: ResourceDetailDescriptor) -> AnyView {
        guard let platform = d.resource.metadataString("platform") else {
            return AnyView(EmptyView())
        }
        return AnyView(
            Text(platform)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Text.secondary)
        )
    }
}
