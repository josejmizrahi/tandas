import SwiftUI

/// Container for a main-app screen with a tab bar and a transparent
/// navigation bar. Pass an array of `MainAppTab` and a builder that returns
/// the view for the selected tab.
public struct MainAppTab<Value: Hashable & Sendable>: Identifiable, Sendable {
    public let id: Value
    public let label: String
    public let systemImage: String

    public init(id: Value, label: String, systemImage: String) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
    }
}

public struct MainAppScreenTemplate<Value: Hashable & Sendable, Content: View>: View {
    private let tabs: [MainAppTab<Value>]
    @Binding private var selection: Value
    private let content: (Value) -> Content

    public init(
        tabs: [MainAppTab<Value>],
        selection: Binding<Value>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.tabs = tabs
        self._selection = selection
        self.content = content
    }

    public var body: some View {
        TabView(selection: $selection) {
            ForEach(tabs) { tab in
                content(tab.id)
                    .tabItem {
                        Label(tab.label, systemImage: tab.systemImage)
                    }
                    .tag(tab.id)
            }
        }
        .tint(Color.ruulAccent)
        // DS v3 §13.2: iOS 26 TabView ya renderiza Liquid Glass nativo.
        // No usar `.toolbarBackground(.ultraThinMaterial)` — overridería
        // el glass con un material plano (antipatrón explícito del DS doc).
        // iOS 26 §6.2: tab bar minimiza al scroll down (gana real estate
        // de contenido) y se expande al scroll up.
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

#if DEBUG
private struct MainAppScreenTemplatePreview: View {
    enum Tab: Hashable, Sendable { case groups, events, rules, fines, me }
    @State var selection: Tab = .groups

    var body: some View {
        MainAppScreenTemplate(
            tabs: [
                .init(id: .groups, label: "Grupos", systemImage: "person.3"),
                .init(id: .events, label: "Eventos", systemImage: "calendar"),
                .init(id: .rules, label: "Reglas", systemImage: "list.bullet.clipboard"),
                .init(id: .fines, label: "Multas", systemImage: "creditcard"),
                .init(id: .me, label: "Yo", systemImage: "person.circle")
            ],
            selection: $selection
        ) { tab in
            ZStack {
                Color.ruulBackground.ignoresSafeArea()
                Text("Tab: \(String(describing: tab))")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
        }
    }
}

#Preview("MainAppScreenTemplate") {
    MainAppScreenTemplatePreview()
}
#endif
