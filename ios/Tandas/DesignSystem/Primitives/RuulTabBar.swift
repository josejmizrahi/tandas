import SwiftUI

public protocol RuulTabItem: Identifiable, Hashable, Sendable {
    var label: String { get }
    var symbol: String { get }
}

/// Tab bar flotante con Liquid Glass. Reemplaza TabView default — Fase C
/// hace el swap real en `MainTabView`.
public struct RuulTabBar<Tab: RuulTabItem>: View {
    @Binding private var selected: Tab
    private let tabs: [Tab]

    public init(selected: Binding<Tab>, tabs: [Tab]) {
        self._selected = selected
        self.tabs = tabs
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .padding(.horizontal, RuulSpacing.xl)
        .padding(.bottom, RuulSpacing.sm)
    }

    private func tabButton(for tab: Tab) -> some View {
        let isSelected = selected.id == tab.id
        return Button {
            withAnimation(.ruulTap) { selected = tab }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 20, weight: .regular))
                Text(tab.label)
                    .font(.ruulLabelSmall)
            }
            .foregroundStyle(isSelected ? Color.ruulTextPrimary : Color.ruulTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule().fill(.quaternary)
                }
            }
        }
        .buttonStyle(.plain)
        .ruulHaptic(.light, trigger: isSelected)
    }
}

#if DEBUG
private struct PreviewTab: RuulTabItem {
    let id: String
    let label: String
    let symbol: String
}

#Preview("RuulTabBar") {
    @Previewable @State var selected = PreviewTab(id: "home", label: "Inicio", symbol: "house")
    let tabs: [PreviewTab] = [
        .init(id: "home", label: "Inicio", symbol: "house"),
        .init(id: "inbox", label: "Pendientes", symbol: "tray"),
        .init(id: "history", label: "Historial", symbol: "clock.arrow.circlepath"),
        .init(id: "settings", label: "Ajustes", symbol: "gear"),
    ]
    return ZStack(alignment: .bottom) {
        Color.ruulBackground.ignoresSafeArea()
        RuulTabBar(selected: $selected, tabs: tabs)
    }
}
#endif
