import SwiftUI
import RuulCore

/// R.10.A — Hero section del Resource Detail (code move, zero behavior change).
///
/// Doctrina: R.5V native-first · "Section is the card".
/// Layout idéntico al monolito previo (`heroSection` 324–376 + `chipBadge` 1468–1478).
struct ResourceDetailV2HeroSection: View {
    let descriptor: ResourceDetailDescriptor
    @Binding var explainedCapability: String?
    let capabilityDisplayName: (String) -> String

    var body: some View {
        let d = descriptor
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
                        ResourceDetailV2ChipBadge(text: d.class.displayName, tint: Theme.Text.secondary)
                    }
                    if d.state.archived {
                        Text("Archivado")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.Tint.warning)
                    }
                }
                Spacer(minLength: 0)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))

            if !d.effectiveCapabilities.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(d.effectiveCapabilities, id: \.self) { cap in
                            Button {
                                explainedCapability = cap
                            } label: {
                                ResourceDetailV2ChipBadge(text: capabilityDisplayName(cap), tint: Theme.Tint.info)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
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
