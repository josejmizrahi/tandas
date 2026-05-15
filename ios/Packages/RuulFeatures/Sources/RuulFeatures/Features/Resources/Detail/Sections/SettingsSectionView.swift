import SwiftUI
import RuulCore
import RuulUI

/// Collapsed accordion at the bottom of the detail v2 scroll. Owns:
///   - capability toggles (when caller provides onPresentEnableCapability)
///   - archive (caller-provided callback; absent when the viewer can't
///     archive)
///
/// Renders zero-cost when no items apply.
@MainActor
public struct SettingsSectionView: View {
    public let onPresentEnableCapability: (() -> Void)?
    public let onArchive: (() -> Void)?

    @State private var isExpanded: Bool = false

    public init(
        onPresentEnableCapability: (() -> Void)?,
        onArchive: (() -> Void)?
    ) {
        self.onPresentEnableCapability = onPresentEnableCapability
        self.onArchive = onArchive
    }

    public var body: some View {
        if hasAnyAction {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                    if let onPresentEnableCapability {
                        actionRow(
                            label: "Activar / desactivar capabilities",
                            symbol: "switch.2",
                            action: onPresentEnableCapability,
                            isDestructive: false
                        )
                    }
                    if let onArchive {
                        actionRow(
                            label: "Archivar este recurso",
                            symbol: "archivebox",
                            action: onArchive,
                            isDestructive: true
                        )
                    }
                }
                .padding(.top, RuulSpacing.s2)
            } label: {
                HStack(spacing: RuulSpacing.s2) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color.ruulTextSecondary)
                    Text("Ajustes")
                        .ruulTextStyle(RuulTypography.subheadSemibold)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .padding(RuulSpacing.s6)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .fill(Color.ruulSurface)
            )
            .padding(.horizontal, RuulSpacing.s6)
        }
    }

    private var hasAnyAction: Bool {
        onPresentEnableCapability != nil || onArchive != nil
    }

    private func actionRow(
        label: String,
        symbol: String,
        action: @escaping () -> Void,
        isDestructive: Bool
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: symbol)
                    .frame(width: 24)
                Text(label)
                    .ruulTextStyle(RuulTypography.body)
                Spacer()
            }
            .foregroundStyle(isDestructive ? Color.red : Color.ruulTextPrimary)
        }
        .buttonStyle(.ruulPress)
    }
}

#if DEBUG
#Preview("Settings — both actions") {
    ScrollView {
        SettingsSectionView(
            onPresentEnableCapability: {},
            onArchive: {}
        )
    }
    .background(Color.ruulBackgroundCanvas)
}

#Preview("Settings — only archive") {
    ScrollView {
        SettingsSectionView(
            onPresentEnableCapability: nil,
            onArchive: {}
        )
    }
    .background(Color.ruulBackgroundCanvas)
}

#Preview("Settings — empty (renders zero-cost)") {
    SettingsSectionView(
        onPresentEnableCapability: nil,
        onArchive: nil
    )
    .background(Color.ruulBackgroundCanvas)
}
#endif
