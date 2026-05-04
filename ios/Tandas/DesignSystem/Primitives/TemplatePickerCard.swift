import SwiftUI

/// Large, single-select card used in onboarding to pick a group template
/// (e.g. "Cena recurrente", "Recurso compartido", "Tanda de ahorro").
///
/// Visual: tile-style monochrome card following Apple Sports / Luma —
/// icon top-left, title large, subtitle, bulleted feature list, selected
/// state via a thicker border + checkmark badge (NEVER a tinted fill).
/// Coming-soon variant adds a "PRÓXIMAMENTE" sectionLabel pill and dims
/// the surface so the user perceives the card as preview-only.
public struct TemplatePickerCard: View {
    private let icon: String
    private let title: String
    private let subtitle: String
    private let bullets: [String]
    private let isSelected: Bool
    private let isComingSoon: Bool
    private let onSelect: () -> Void

    public init(
        icon: String,
        title: String,
        subtitle: String,
        bullets: [String] = [],
        isSelected: Bool = false,
        isComingSoon: Bool = false,
        onSelect: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.bullets = bullets
        self.isSelected = isSelected
        self.isComingSoon = isComingSoon
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: { if !isComingSoon { onSelect() } }) {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                header
                if !bullets.isEmpty {
                    bulletList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RuulSpacing.s5)
            .background(Color.ruulBackgroundElevated, in: shape)
            .overlay(borderOverlay)
            .overlay(alignment: .topTrailing) { selectionBadge }
            .opacity(isComingSoon ? 0.55 : 1.0)
        }
        .buttonStyle(.ruulPress)
        .disabled(isComingSoon)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    // MARK: - Header (icon + title + subtitle)

    private var header: some View {
        HStack(alignment: .top, spacing: RuulSpacing.s3) {
            ZStack {
                Circle()
                    .fill(Color.ruulBackgroundCanvas)
                    .frame(width: 44, height: 44)
                    .overlay(Circle().stroke(Color.ruulBorderSubtle, lineWidth: 0.5))
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: RuulSpacing.s2) {
                    Text(title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if isComingSoon {
                        Text("PRÓXIMAMENTE")
                            .ruulTextStyle(RuulTypography.sectionLabel)
                            .foregroundStyle(Color.ruulTextTertiary)
                            .padding(.horizontal, RuulSpacing.s2)
                            .padding(.vertical, 2)
                            .overlay(
                                Capsule()
                                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
                            )
                    }
                }
                Text(subtitle)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Bullet list (feature highlights)

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            ForEach(bullets, id: \.self) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.s2) {
                    Circle()
                        .fill(Color.ruulTextTertiary)
                        .frame(width: 4, height: 4)
                        .alignmentGuide(.firstTextBaseline) { _ in 4 }
                    Text(bullet)
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Selection chrome

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if isSelected {
            shape.stroke(Color.ruulTextPrimary, lineWidth: 2)
        } else {
            shape.stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            ZStack {
                Circle()
                    .fill(Color.ruulTextPrimary)
                    .frame(width: 24, height: 24)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.ruulTextInverse)
            }
            .padding(RuulSpacing.s3)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var accessibilityLabel: String {
        if isComingSoon {
            return "\(title), próximamente. \(subtitle)"
        }
        let state = isSelected ? "seleccionado" : "no seleccionado"
        return "\(title), \(state). \(subtitle)"
    }
}

#if DEBUG
#Preview("TemplatePickerCard") {
    struct Demo: View {
        @State var selected: String = "dinner"
        var body: some View {
            ScrollView {
                VStack(spacing: RuulSpacing.s3) {
                    TemplatePickerCard(
                        icon: "fork.knife.circle.fill",
                        title: "Cena recurrente",
                        subtitle: "Cenas, juntas, reuniones que se repiten con el mismo grupo",
                        bullets: [
                            "Rotación de host automática",
                            "RSVP con check-in",
                            "Multas por reglas que ustedes definen"
                        ],
                        isSelected: selected == "dinner",
                        onSelect: { selected = "dinner" }
                    )
                    TemplatePickerCard(
                        icon: "ticket.fill",
                        title: "Recurso compartido",
                        subtitle: "Palco, casa de fin de semana, suscripción que rotan",
                        bullets: ["Asignación rotativa", "Cascada al saltar"],
                        isComingSoon: true,
                        onSelect: {}
                    )
                    TemplatePickerCard(
                        icon: "banknote.fill",
                        title: "Tanda de ahorro",
                        subtitle: "Sistema de aportes y cobros programados",
                        bullets: ["Aportes mensuales", "Cobro por turno"],
                        isComingSoon: true,
                        onSelect: {}
                    )
                }
                .padding(RuulSpacing.s5)
            }
            .background(Color.ruulBackgroundCanvas)
        }
    }
    return Demo()
}
#endif
