import SwiftUI

public protocol RuulTabItem: Identifiable, Hashable, Sendable {
    var label: String { get }
    var symbol: String { get }
    /// Pending count badge. Nil or `0` hides the badge. Positive renders a
    /// red capsule overlay on the icon. Default is `nil` so existing tab
    /// items don't have to opt in.
    var badgeCount: Int? { get }
}

public extension RuulTabItem {
    var badgeCount: Int? { nil }
}

/// Tab bar flotante con Liquid Glass. Reemplaza TabView default — Fase C
/// hace el swap real en `MainTabView`.
///
/// La selección se modela por `Tab.ID` (en lugar de `Tab` directo) para que
/// callsites puedan usar wrappers con datos derivados (e.g. badge runtime)
/// sin romper la identidad del tab subyacente.
public struct RuulTabBar<Tab: RuulTabItem>: View {
    @Binding private var selectedID: Tab.ID
    private let tabs: [Tab]

    public init(selected: Binding<Tab.ID>, tabs: [Tab]) {
        self._selectedID = selected
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
        // DS v3 §13: chrome surface — Liquid Glass auténtico iOS 26.
        // `interactive: true` no aplica acá: el bar es contenedor, los taps
        // van a los `Button`s internos. Dejarlo en true intercepta los taps
        // en iOS 26.x antes de que lleguen a los buttons (mismo bug que
        // hizo no-op el X de EventDetailView).
        .ruulGlass(Capsule(), material: .regular)
        .padding(.horizontal, RuulSpacing.xl)
        .padding(.bottom, RuulSpacing.sm)
    }

    private func tabButton(for tab: Tab) -> some View {
        let isSelected = selectedID == tab.id
        return Button {
            withAnimation(.ruulTap) { selectedID = tab.id }
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 20, weight: .regular))
                    if let count = tab.badgeCount, count > 0 {
                        Text("\(min(count, 99))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.ruulOnImage)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.ruulNegative))
                            .offset(x: 8, y: -6)
                    }
                }
                Text(tab.label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(isSelected ? Color.ruulAccent : Color.ruulTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule().fill(Color.ruulAccent.opacity(0.14))
                }
            }
            .animation(.ruulSnappy, value: isSelected)
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
    var badgeCount: Int? = nil
}

#Preview("RuulTabBar") {
    @Previewable @State var selectedID: String = "home"
    let tabs: [PreviewTab] = [
        .init(id: "home", label: "Inicio", symbol: "house"),
        .init(id: "inbox", label: "Pendientes", symbol: "tray", badgeCount: 3),
        .init(id: "history", label: "Historial", symbol: "clock.arrow.circlepath"),
        .init(id: "settings", label: "Ajustes", symbol: "gear"),
    ]
    return ZStack(alignment: .bottom) {
        Color.ruulBackground.ignoresSafeArea()
        RuulTabBar(selected: $selectedID, tabs: tabs)
    }
}
#endif
