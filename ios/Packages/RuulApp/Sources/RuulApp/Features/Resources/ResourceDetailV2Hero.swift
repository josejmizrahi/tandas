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
        Section {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: d.subtype.icon ?? d.class.icon ?? "cube")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.Tint.primary)
                    .frame(width: 56, height: 56)
                    .background(Theme.Tint.primary.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.resource.displayName)
                        .font(.title3.bold())
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        ResourceDetailV2ChipBadge(text: d.subtype.displayName, tint: Theme.Tint.primary)
                        if d.state.archived {
                            RuulStatusBadge(.archived)
                        }
                    }
                    renderer.heroSubtitle(d)
                }
                Spacer(minLength: 0)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))
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
