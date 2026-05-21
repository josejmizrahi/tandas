import SwiftUI
import RuulCore
import RuulUI

/// "Mis grupos" tab — Ruul Canonical UX Doctrine 2026-05-20 (Tab 2 of 3).
///
/// Lists every group the user belongs to. Tapping a row switches
/// `app.activeGroupId` and jumps the shell to the Home tab, where the
/// existing `HomeView` then renders for that group. Header actions for
/// "Crear grupo" and "Unirme a uno" live in the toolbar.
///
/// MVP version: structural placeholder for the new 3-tab shell. Future
/// passes (per doctrine §9) will rebuild this view to drill into a
/// dedicated `GroupHomeView` (Personas / Movimientos / Acuerdos /
/// Historia subsections) instead of switching the global active group.
@MainActor
public struct MyGroupsTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router

    public init() {}

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Mis grupos")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                router.present(.createGroup)
                            } label: {
                                Label("Crear grupo", systemImage: "plus")
                            }
                            Button {
                                router.present(.joinGroup)
                            } label: {
                                Label("Unirme con código", systemImage: "qrcode")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Agregar grupo")
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if app.groups.isEmpty {
            ContentUnavailableView {
                Label("Empieza un grupo", systemImage: "person.3")
            } description: {
                Text("Crea uno tuyo o únete con un código para coordinar con tus amigos.")
            } actions: {
                Button("Crear grupo") { router.present(.createGroup) }
                    .buttonStyle(.borderedProminent)
                Button("Unirme con código") { router.present(.joinGroup) }
            }
        } else {
            List {
                Section {
                    ForEach(app.groups, id: \.id) { group in
                        Button {
                            tap(group)
                        } label: {
                            groupRow(group)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await app.refreshProfileAndGroups() }
        }
    }

    @ViewBuilder
    private func groupRow(_ group: RuulCore.Group) -> some View {
        HStack(spacing: 12) {
            RuulGroupAvatar(group: group, size: .lg)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let subtitle = subtitle(for: group) {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if app.activeGroup?.id == group.id {
                Text("Activo")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: .capsule)
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func subtitle(for group: RuulCore.Group) -> String? {
        if let desc = group.description, !desc.trimmingCharacters(in: .whitespaces).isEmpty {
            return desc
        }
        return nil
    }

    private func tap(_ group: RuulCore.Group) {
        if app.activeGroupId != group.id {
            app.activeGroupId = group.id
        }
        router.selectTab(.home)
    }
}
