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
        .tint(Color.ruulAccentPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
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
                Color.ruulBackgroundCanvas.ignoresSafeArea()
                Text("Tab: \(String(describing: tab))")
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
        }
    }
}

#Preview("MainAppScreenTemplate") {
    MainAppScreenTemplatePreview()
}
#endif
