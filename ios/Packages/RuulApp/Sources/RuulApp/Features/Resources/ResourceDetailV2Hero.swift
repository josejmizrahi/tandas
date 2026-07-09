import SwiftUI
import RuulCore

/// R.10.A — Hero section del Resource Detail.
///
/// Doctrina: R.5V native-first · "Section is the card".
///
/// **R.10.F.f (2026-06-15)**: invoca `renderer.heroSubtitle(d)` debajo del
/// chip subtype + status badge. Cada renderer aporta info crítica (Financial
/// balance prominent · Trip date range · Document locked badge); default es
/// EmptyView. Estilo Apple Wallet.
/// **R.10.F.10.e**: Drop class chip (redundante con subtype) + Archivado pasa
/// a `RuulStatusBadge` canónico.
/// **R.10.F.10.d**: Capabilities scroll horizontal removido — vive en
/// `ResourceDetailV2CapabilitiesSection` dedicada.
struct ResourceDetailV2HeroSection: View {
    let descriptor: ResourceDetailDescriptor

    var body: some View {
        let d = descriptor
        let renderer = ResourceSubtypeRegistry.renderer(for: d.class.classKey)
        // Chip de subtipo + (R.10.F.h) badge de bloqueo UNIVERSAL — cualquier
        // resource (vehicle/property/financial) muestra el state al-vuelo.
        var chips: [RuulHeroChip] = [RuulHeroChip(d.subtype.displayName)]
        if d.state.lockedForGovernance {
            chips.append(RuulHeroChip("Bloqueado", symbol: "lock.fill", tint: .purple))
        }
        return Section {
            // R.17 — hero canónico. `renderer.heroSubtitle(d)` (Financial balance /
            // Trip date range / etc.) va en el accessory, debajo de los chips.
            // Sólo se monta cuando el renderer aporta contenido (evita gap fantasma).
            if let subtitle = renderer.heroSubtitle(d) {
                RuulDetailHero(
                    title: d.resource.displayName,
                    systemImage: d.subtype.icon ?? d.class.icon ?? "cube",
                    tint: Theme.Tint.primary,
                    status: d.state.archived ? .archived : nil,
                    chips: chips
                ) {
                    subtitle
                }
                .ruulHeroRow()
            } else {
                RuulDetailHero(
                    title: d.resource.displayName,
                    systemImage: d.subtype.icon ?? d.class.icon ?? "cube",
                    tint: Theme.Tint.primary,
                    status: d.state.archived ? .archived : nil,
                    chips: chips
                )
                .ruulHeroRow()
            }
        }
    }
}

/// Chip pequeño reutilizable. Movido del monolito (1468–1478).
struct ResourceDetailV2ChipBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
