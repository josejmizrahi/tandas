import SwiftUI
import RuulCore
import RuulUI

/// "Grupo" tab — Ruul Canonical UX Doctrine + Wave 3 scope
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

    /// Drill-in destinations inside the group context view. Each row
    /// becomes a `NavigationLink(value:)` that pushes the canonical
    /// surface for that section.
    public enum GroupSection: Hashable {
        case personas
        case movimientos
        case acuerdos
        case historia
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(navTitle)
                .navigationBarTitleDisplayMode(navDisplayMode)
                .toolbar { toolbarContent }
                .navigationDestination(for: GroupSection.self) { section in
                    destinationView(for: section)
                }
        }
    }

    private var navTitle: String {
        if case let .group(id) = app.homeScope,
           let group = app.groups.first(where: { $0.id == id }) {
            return group.name
        }
        return "Grupo"
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

                // Drill-in subsections per doctrine §9. Each pushes
                // the canonical surface for that aspect of the group.
                VStack(spacing: 8) {
                    sectionRow(value: .personas, icon: "person.2", label: "Personas")
                    sectionRow(value: .movimientos, icon: "arrow.left.arrow.right", label: "Movimientos")
                    sectionRow(value: .acuerdos, icon: "list.bullet.clipboard", label: "Acuerdos")
                    sectionRow(value: .historia, icon: "clock.arrow.circlepath", label: "Historia")
                }
                .padding(.top, 24)
                .padding(.horizontal, 16)

                Spacer(minLength: 32)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    /// Drill-in subsection row with chevron — pushes the canonical
    /// surface via the navigation stack's `navigationDestination`.
    private func sectionRow(value: GroupSection, icon: String, label: String) -> some View {
        NavigationLink(value: value) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    /// Per-subsection destination. Coordinators constructed inline
    /// from `app.*` repos; Rules reuses the cached `router.state.
    /// rulesCoordinator` because RootShell.rebuildCoordinators is the
    /// canonical builder (handles currentMember resolution + lifecycle).
    @ViewBuilder
    private func destinationView(for section: GroupSection) -> some View {
        if let group = app.activeGroup {
            switch section {
            case .personas:
                MembersListView(coordinator: MembersCoordinator(
                    group: group,
                    actorUserId: app.session?.user.id ?? UUID(),
                    groupsRepo: app.groupsRepo
                ))
                .environment(app)

            case .movimientos:
                MyLedgerView(coordinator: MyLedgerCoordinator(
                    userId: app.session?.user.id ?? UUID(),
                    allGroups: [group],
                    ledgerRepo: app.ledgerRepo,
                    groupsRepo: app.groupsRepo
                ))
                .environment(app)

            case .acuerdos:
                if let coord = router.state.rulesCoordinator {
                    RulesView(
                        coordinator: coord,
                        voteRepo: app.voteRepo,
                        policyRepo: app.policyRepo,
                        actorUserId: app.session?.user.id ?? UUID(),
                        userActionRepo: app.userActionRepo,
                        ruleTemplates: app.ruleTemplates,
                        ruleTemplateRepo: app.ruleTemplateRepo
                    )
                    .environment(app)
                } else {
                    ProgressView()
                }

            case .historia:
                ActivityView(coordinator: ActivityCoordinator(
                    groupId: group.id,
                    repo: app.systemEventRepo,
                    groupsRepo: app.groupsRepo
                ))
                .environment(app)
            }
        } else {
            // Defensive: should not happen since the parent gate
            // requires `app.activeGroup` to be non-nil before showing
            // the group context view at all.
            ContentUnavailableView(
                "No hay grupo activo",
                systemImage: "exclamationmark.triangle"
            )
        }
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
