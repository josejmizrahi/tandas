import SwiftUI

/// Luma-style root container: 3 tabs con bottom floating pill nav.
struct MainTabView: View {
    @State private var tab: Tab = .home

    enum Tab: Hashable {
        case home, discover, chat
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Brand.Surface.canvas.ignoresSafeArea()

            // Active tab content
            SwiftUI.Group {
                switch tab {
                case .home:     RootHomeView()
                case .discover: DiscoverStubView()
                case .chat:     ChatStubView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Floating pill nav (al estilo Luma)
            FloatingTabBar(selected: $tab)
                .padding(.horizontal, 60)
                .padding(.bottom, 8)
        }
    }
}

// Wraps GroupsListView/EmptyGroupsView based on app state.
private struct RootHomeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.groups.isEmpty {
            EmptyGroupsView()
        } else {
            GroupsListView()
        }
    }
}

private struct DiscoverStubView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Brand.Surface.textTertiary)
            Text("Descubrir")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Brand.Surface.textPrimary)
            Text("Próximamente")
                .font(.system(size: 13))
                .foregroundStyle(Brand.Surface.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.Surface.canvas)
    }
}

private struct ChatStubView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Brand.Surface.textTertiary)
            Text("Chat")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Brand.Surface.textPrimary)
            Text("Próximamente")
                .font(.system(size: 13))
                .foregroundStyle(Brand.Surface.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.Surface.canvas)
    }
}

private struct FloatingTabBar: View {
    @Binding var selected: MainTabView.Tab

    var body: some View {
        HStack(spacing: 0) {
            tabButton(.home, label: "Inicio", systemImage: "house.fill")
            tabButton(.discover, label: "Descubrir", systemImage: "safari.fill")
            tabButton(.chat, label: "Chat", systemImage: "bubble.left.fill")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .overlay(
            Capsule().stroke(Brand.Surface.border, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 4)
    }

    private func tabButton(_ tab: MainTabView.Tab, label: String, systemImage: String) -> some View {
        let isActive = selected == tab
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selected = tab
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isActive ? Brand.Surface.textPrimary : Brand.Surface.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isActive ? Brand.Surface.cardPressed : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isActive)
    }
}
