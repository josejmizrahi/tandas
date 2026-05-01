import SwiftUI

struct GroupsListView: View {
    @Environment(AppState.self) private var app
    @State private var selected: Group?
    @State private var showCreate: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                MeshBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: Brand.Spacing.l) {
                        header
                        ForEach(app.groups) { g in
                            WalletGroupCard(group: g) { selected = g }
                                .sensoryFeedback(.impact(weight: .medium), trigger: selected?.id == g.id)
                        }
                    }
                    .padding(.horizontal, Brand.Spacing.xl)
                    .padding(.top, Brand.Spacing.l)
                    .padding(.bottom, Brand.Spacing.xxl * 2)
                }
                .refreshable { await app.refreshProfileAndGroups() }
                floatingButton
            }
            .navigationDestination(item: $selected) { g in GroupSummaryView(group: g) }
            .navigationDestination(isPresented: $showCreate) { NewGroupWizard() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.xs) {
            Text("Hola, \(app.profile?.displayName ?? "")")
                .font(.tandaTitle).foregroundStyle(.white.opacity(0.7))
            Text("Mis grupos")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var floatingButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    showCreate = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Nuevo")
                    }
                    .font(.tandaTitle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Brand.Spacing.l)
                    .padding(.vertical, Brand.Spacing.m)
                    .adaptiveGlass(Capsule(), tint: Brand.accent, interactive: true)
                }
                .padding(.trailing, Brand.Spacing.xl)
                .padding(.bottom, Brand.Spacing.xl)
            }
        }
    }
}

// GroupSummaryView stub — implemented in T17
struct GroupSummaryView: View {
    let group: Group
    var body: some View { Text("\(group.name) summary (stub)").foregroundStyle(.white) }
}
