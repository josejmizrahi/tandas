import SwiftUI

/// Template-driven tab bar — the same shape as `MainAppScreenTemplate` but
/// with first-class support for unread/pending badges per tab. Used as the
/// app shell once the user is past onboarding: Inicio, Inbox, Reglas, Yo
/// for the "Cena recurrente" template; future templates declare their own
/// tab set.
///
/// The tab inventory is owned by the template layer (e.g. `Templates/
/// DinnerRecurring/Tabs.swift`) — this primitive only renders.
public struct ResourceTab<Value: Hashable & Sendable>: Identifiable, Sendable {
    public let id: Value
    public let label: String
    public let systemImage: String
    /// Unread / pending count for the tab. `nil` hides the badge; `0` also
    /// hides; positive integers render `.badge(count)`. Strings render
    /// `.badge(text)` for non-numeric indicators ("!", "•").
    public let badge: ResourceTabBadge?

    public init(
        id: Value,
        label: String,
        systemImage: String,
        badge: ResourceTabBadge? = nil
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.badge = badge
    }
}

public enum ResourceTabBadge: Sendable, Hashable {
    case count(Int)
    case text(String)
}

public struct ResourceTabBar<Value: Hashable & Sendable, Content: View>: View {
    private let tabs: [ResourceTab<Value>]
    @Binding private var selection: Value
    private let content: (Value) -> Content

    public init(
        tabs: [ResourceTab<Value>],
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
                    .tabItem { Label(tab.label, systemImage: tab.systemImage) }
                    .tag(tab.id)
                    .modifier(TabBadgeModifier(badge: tab.badge))
            }
        }
        .tint(Color.ruulTextPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

private struct TabBadgeModifier: ViewModifier {
    let badge: ResourceTabBadge?

    @ViewBuilder
    func body(content: Content) -> some View {
        switch badge {
        case .none:
            content
        case .count(let n):
            if n > 0 {
                content.badge(n)
            } else {
                content
            }
        case .text(let s):
            if !s.isEmpty {
                content.badge(s)
            } else {
                content
            }
        }
    }
}

#if DEBUG
private struct ResourceTabBarPreview: View {
    enum Tab: Hashable, Sendable { case home, inbox, rules, me }
    @State var selection: Tab = .home

    var body: some View {
        ResourceTabBar(
            tabs: [
                .init(id: .home,  label: "Inicio", systemImage: "house.fill"),
                .init(id: .inbox, label: "Inbox",  systemImage: "tray.fill",
                      badge: .count(3)),
                .init(id: .rules, label: "Reglas", systemImage: "list.bullet.clipboard.fill"),
                .init(id: .me,    label: "Yo",     systemImage: "person.crop.circle.fill")
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

#Preview("ResourceTabBar") {
    ResourceTabBarPreview()
}
#endif
