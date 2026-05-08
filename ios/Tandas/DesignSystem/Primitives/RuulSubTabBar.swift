import SwiftUI
import RuulUI

/// Pills horizontales scrollables para sub-tabs. Usado dentro de la tab
/// "Grupo" (Fase 4) para alternar entre Events / Rules / Fines / etc según
/// el template del grupo activo. Per DS v3 §3.7.
public struct RuulSubTabBar<Tab: RuulSubTabItem>: View {
    @Binding private var selected: Tab
    private let tabs: [Tab]

    public init(selected: Binding<Tab>, tabs: [Tab]) {
        self._selected = selected
        self.tabs = tabs
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.xs) {
                ForEach(tabs) { tab in
                    Button {
                        RuulHaptic.light.trigger()
                        withAnimation(.ruulTap) {
                            selected = tab
                        }
                    } label: {
                        let isSelected = (selected.id == tab.id)
                        Text(tab.label)
                            .font(.ruulLabel)
                            .foregroundStyle(isSelected ? Color.white : Color.ruulTextPrimary)
                            .padding(.horizontal, RuulSpacing.md)
                            .padding(.vertical, RuulSpacing.xs)
                            .background {
                                if isSelected {
                                    Capsule().fill(Color.ruulAccent)
                                } else {
                                    Capsule().fill(Color.ruulSurface)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
        }
    }
}

public protocol RuulSubTabItem: Identifiable, Hashable, Sendable {
    var label: String { get }
}

#if DEBUG
private struct PreviewSubTab: RuulSubTabItem {
    let id: String
    let label: String
}

#Preview("RuulSubTabBar") {
    @Previewable @State var selected = PreviewSubTab(id: "events", label: "Eventos")
    let tabs: [PreviewSubTab] = [
        .init(id: "events", label: "Eventos"),
        .init(id: "rotation", label: "Rotación"),
        .init(id: "rules", label: "Reglas"),
        .init(id: "fines", label: "Multas"),
        .init(id: "history", label: "Historial"),
    ]
    return VStack {
        RuulSubTabBar(selected: $selected, tabs: tabs)
        Spacer()
    }
    .padding(.top, RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
