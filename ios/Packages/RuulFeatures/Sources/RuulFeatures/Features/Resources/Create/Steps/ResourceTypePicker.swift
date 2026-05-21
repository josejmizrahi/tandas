import SwiftUI
import RuulUI
import RuulCore

/// Step 1 of the new ResourceCreationSheet: "¿Qué estás creando?"
///
/// 2-column adaptive grid of 6 type cards. Cards for resource types
/// the group can host are tappable; types without a registered builder
/// render as disabled "Próximamente" tiles so the user sees the canon
/// without being able to act on the missing pieces.
///
/// Doctrine 2026-05-18: this is the human entry point — no doctrine
/// vocabulary ("capability", "atom", "module") appears in copy. Each
/// type's `humanLabel` + a one-line summary anchor the choice in
/// concrete examples ("partido, junta, cena" beats "event").
struct ResourceTypePicker: View {
    let coordinator: ResourceCreationCoordinator
    /// Optional override for testing. Defaults to the V1 catalog.
    var registry: ResourceBuilderRegistry { coordinator.builders }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                heading
                tileGrid
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.xxl)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("¿Qué estás creando?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("Elige el tipo. Después decides los detalles.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
    }

    private var tileGrid: some View {
        LazyVGrid(
            columns: [.init(.adaptive(minimum: 150), spacing: RuulSpacing.sm)],
            spacing: RuulSpacing.sm
        ) {
            ForEach(ResourceType.allCases, id: \.self) { type in
                typeTile(type)
            }
        }
    }

    @ViewBuilder
    private func typeTile(_ type: ResourceType) -> some View {
        let implemented = registry.isImplemented(type)
        let copy = Self.copy(for: type)
        if implemented {
            Button {
                coordinator.pickType(type)
            } label: {
                tileContent(type: type, copy: copy, isImplemented: true)
            }
            .buttonStyle(.plain)
        } else {
            tileContent(type: type, copy: copy, isImplemented: false)
                .accessibilityLabel("\(type.humanLabel), próximamente")
                .accessibilityHint("Este tipo aún no se puede crear.")
                .allowsHitTesting(false)
                .opacity(0.50)
        }
    }

    private func tileContent(type: ResourceType, copy: TileCopy, isImplemented: Bool) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(alignment: .center, spacing: RuulSpacing.xs) {
                Image(systemName: copy.icon)
                    .font(.body)
                    .foregroundStyle(Color.ruulAccent)
                Spacer()
                if !isImplemented {
                    Text("Pronto")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(.tertiaryLabel))
                        .padding(.horizontal, RuulSpacing.xs)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.ruulSurface)
                        )
                }
            }
            Text(type.humanLabel)
                .font(.headline)
                .foregroundStyle(Color.primary)
            Text(copy.summary)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    // MARK: - Copy

    private struct TileCopy {
        let icon: String
        let summary: String
    }

    /// Human, example-led summaries. No doctrine vocabulary. Keep
    /// each line ≤60 chars so the tile renders 1-2 lines at most.
    private static func copy(for type: ResourceType) -> TileCopy {
        switch type {
        case .event:
            return TileCopy(icon: "calendar.badge.clock",
                            summary: "Un momento en el tiempo. Partido, junta, cena.")
        case .fund:
            return TileCopy(icon: "banknote",
                            summary: "Dinero compartido con propósito y reglas.")
        case .asset:
            return TileCopy(icon: "shippingbox",
                            summary: "Algo con valor, propiedad o custodia.")
        case .space:
            return TileCopy(icon: "building.2",
                            summary: "Un lugar que se usa, ocupa o reserva.")
        case .slot:
            return TileCopy(icon: "ticket",
                            summary: "Una unidad asignable: asiento, turno, boleto.")
        case .right:
            return TileCopy(icon: "key",
                            summary: "Un acceso, equity o prioridad.")
        case .unknown:
            return TileCopy(icon: "questionmark.square", summary: "")
        }
    }
}
