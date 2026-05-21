import SwiftUI
import RuulCore
import RuulUI

/// "Mis grupos" tab — Ruul Canonical UX Doctrine + Wave 3 scope
/// switcher (2026-05-21). Dual-mode driven by `app.homeScope`:
///
///   - `.all` (default) → browser view: list of every group the user
///     belongs to. Tap a row → sets `app.homeScope = .group(id)` so
///     both Inicio AND this tab snap to that group's lens.
///   - `.group(id)` → group context view: hero + "Volver a todos los
///     grupos" affordance. Placeholder for the future Group home
///     (Personas / Movimientos / Acuerdos / Historia subsections).
///
/// Single source of truth = `AppState.homeScope`. The switcher pill
/// in Inicio's toolbar and the row tap here both write to it; the
/// view branches on its value.
@MainActor
public struct MyGroupsTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router

    public init() {}

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(navTitle)
                .navigationBarTitleDisplayMode(navDisplayMode)
                .toolbar { toolbarContent }
        }
    }

    private var navTitle: String {
        if case let .group(id) = app.homeScope,
           let group = app.groups.first(where: { $0.id == id }) {
            return group.name
        }
        return "Mis grupos"
    }

    private var navDisplayMode: NavigationBarItem.TitleDisplayMode {
        if case .group = app.homeScope { return .inline }
        return .large
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // When viewing a specific group, surface a "Todos" back
        // affordance — Apple drill-in pattern (chevron + parent label).
        if case .group = app.homeScope {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    app.homeScope = .all
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                        Text("Todos")
                    }
                }
                .accessibilityLabel("Volver a todos los grupos")
            }
        }
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

    // MARK: - Content (dual-mode)

    @ViewBuilder
    private var content: some View {
        if case let .group(id) = app.homeScope,
           let group = app.groups.first(where: { $0.id == id }) {
            groupContextView(group)
        } else if app.groups.isEmpty {
            emptyHero
        } else {
            groupsList
        }
    }

    // MARK: - .all branch: groups list (browser)

    private var groupsList: some View {
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
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
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
        // Drill into this group: set both the global scope AND the
        // active-group state (so creation flows + ledger context work).
        app.homeScope = .group(group.id)
        if app.activeGroupId != group.id {
            app.activeGroupId = group.id
        }
    }

    // MARK: - .group(id) branch: group context view (placeholder)

    /// V1 placeholder. Future: rebuild as `GroupHomeView` with sub-tabs
    /// (Personas / Movimientos / Acuerdos / Historia) per doctrine §9.
    /// For now: hero + member count + "Volver" CTA. The user can
    /// already coordinate via Inicio (filtered to this group) — this
    /// surface is the eventual drill-in destination for managing the
    /// group's content + governance.
    private func groupContextView(_ group: RuulCore.Group) -> some View {
        ScrollView {
            VStack(alignment: .center, spacing: 16) {
                RuulGroupAvatar(group: group, size: .xl)
                    .padding(.top, 32)
                Text(group.name)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let desc = group.description, !desc.isEmpty {
                    Text(desc)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Sub-tabs placeholder — feature-flagged stub so the
                // structure is visible during founder review without
                // pretending to be functional yet.
                VStack(spacing: 8) {
                    placeholderRow(icon: "person.2", label: "Personas")
                    placeholderRow(icon: "arrow.left.arrow.right", label: "Movimientos")
                    placeholderRow(icon: "list.bullet.clipboard", label: "Acuerdos")
                    placeholderRow(icon: "clock.arrow.circlepath", label: "Historia")
                }
                .padding(.top, 24)
                .padding(.horizontal, 16)

                Spacer(minLength: 32)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func placeholderRow(icon: String, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text("Pronto")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Empty state (no groups at all)

    private var emptyHero: some View {
        ContentUnavailableView {
            Label("Empieza un grupo", systemImage: "person.3")
        } description: {
            Text("Crea uno tuyo o únete con un código para coordinar con tus amigos.")
        } actions: {
            Button("Crear grupo") { router.present(.createGroup) }
                .buttonStyle(.borderedProminent)
            Button("Unirme con código") { router.present(.joinGroup) }
        }
    }
}
