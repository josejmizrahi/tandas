import SwiftUI
import RuulCore

/// R.8.MiMundo.S1 (2026-06-10) — Founder firma "Yo = mi mundo completo":
/// el espacio personal deja de ser una lista plana de bookmarks y pasa a la
/// doctrina canónica Detail §0.2 (Hero / Atención / Dashboard / Mi mundo /
/// Configuración / Cerrar sesión).
///
/// Slice 1: shell + cross-context aggregators existentes (Calendario, Actividad,
/// Recursos, Suscripciones, Red de confianza). Slice 2 conecta las acciones
/// personales (Subir recurso, Crear compromiso, etc.) con el contexto personal
/// preselected. Slices 3-7 agregan MyObligationsView, MyDecisionsView,
/// MyDocumentsView, MyReservationsView, MyRulesView + balance neto derivado.
///
/// Por qué el title es "Mi mundo" y la tab "Yo": la tab es pronombre corto;
/// el título describe el contenido (todo lo que toco en Ruul cross-context).
public struct MeView: View {
    let container: DependencyContainer
    /// F.NAV.6 — jump al tab Contextos desde la sección "Mis contextos".
    let goToContexts: () -> Void

    @State private var world: MyWorld?
    @State private var isShowingSettings = false
    @State private var isShowingEditProfile = false
    @State private var presentedAttention: AttentionDestination?

    public init(container: DependencyContainer, goToContexts: @escaping () -> Void) {
        self.container = container
        self.goToContexts = goToContexts
    }

    public var body: some View {
        NavigationStack {
            List {
                heroSection
                attentionSection
                dashboardSection
                myWorldSection
                configurationSection
                signOutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Mi mundo")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadWorld()
                await container.attentionInboxStore.load()
            }
            .refreshable {
                await loadWorld()
                await container.attentionInboxStore.load()
            }
            .sheet(isPresented: $isShowingSettings) {
                PersonalSettingsView(container: container)
            }
            .sheet(isPresented: $isShowingEditProfile) {
                EditProfileView(container: container)
            }
            .sheet(item: $presentedAttention) { destination in
                AttentionDestinationSheet(destination: destination, container: container)
            }
        }
    }

    // MARK: - 1. Hero (avatar + nombre + métricas chips)

    @ViewBuilder
    private var heroSection: some View {
        let displayName = container.currentActorStore.actor?.displayName ?? "—"
        let contextCount = container.contextStore.availableContexts
            .filter { $0.isRoot && !$0.isPersonal }
            .count
        let resourcesCount = world?.resources.count ?? 0

        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    ActorInitialsView(name: displayName, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(1)
                        Text("Mi mundo en Ruul")
                            .font(.subheadline)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        isShowingEditProfile = true
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.Tint.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Editar perfil")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        metricChip(
                            value: "\(contextCount)",
                            label: contextCount == 1 ? "contexto" : "contextos",
                            systemImage: "square.grid.2x2.fill",
                            tint: Theme.Tint.primary
                        )
                        metricChip(
                            value: "\(resourcesCount)",
                            label: resourcesCount == 1 ? "recurso" : "recursos",
                            systemImage: "shippingbox.fill",
                            tint: Theme.Tint.warning
                        )
                        // Slice 3 popula desde MyObligationsView fan-out.
                        metricChip(
                            value: "—",
                            label: "compromisos",
                            systemImage: "checklist",
                            tint: Theme.Tint.info
                        )
                        // Slice 7 popula desde balance neto derivado.
                        metricChip(
                            value: "—",
                            label: "balance",
                            systemImage: "scalemass.fill",
                            tint: Theme.Tint.success
                        )
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func metricChip(value: String, label: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.Text.primary)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.Text.secondary)
        }
        .frame(minWidth: 78, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 2. Atención (cross-context inbox)

    @ViewBuilder
    private var attentionSection: some View {
        let items = container.attentionInboxStore.items
        Section {
            if items.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Todo al día").font(.callout.weight(.medium))
                        Text("Sin pendientes en este momento")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Tint.success)
                }
            } else {
                ForEach(items.prefix(5)) { item in
                    Button {
                        presentedAttention = AttentionDispatcher.destination(for: item)
                    } label: {
                        attentionRow(item)
                    }
                }
                if items.count > 5 {
                    Text("\(items.count - 5) pendientes más en Home")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        } header: {
            Text("Atención")
        }
    }

    @ViewBuilder
    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: AttentionPresentation.symbol(for: item.kind))
                .foregroundStyle(AttentionPresentation.tint(for: item.kind))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Text(item.contextDisplayName)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
        }
    }

    // MARK: - 3. Dashboard (widgets cross-context)

    @ViewBuilder
    private var dashboardSection: some View {
        Section {
            NavigationLink {
                MyCalendarView(container: container)
            } label: {
                Label("Mi calendario", systemImage: "calendar")
            }
            NavigationLink {
                MyActivityFeedView(container: container)
            } label: {
                Label("Mi actividad", systemImage: "antenna.radiowaves.left.and.right")
            }
            // Slice 7 reemplaza por SettlementView agregada cross-context.
            comingSoonRow(label: "Mi balance neto", systemImage: "scalemass.fill")
        } header: {
            Text("Dashboard")
        } footer: {
            Text("Todo lo que tienes en tus contextos, agregado en un solo lugar.")
        }
    }

    // MARK: - 4. Mi mundo (agregadores cross-context)

    @ViewBuilder
    private var myWorldSection: some View {
        Section {
            Button {
                goToContexts()
            } label: {
                HStack {
                    Label("Mis contextos", systemImage: "square.grid.2x2.fill")
                        .foregroundStyle(Theme.Text.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            .buttonStyle(.plain)
            NavigationLink {
                MyResourcesView(container: container)
            } label: {
                Label("Mis recursos", systemImage: "shippingbox.fill")
            }
            // Slice 3 reemplaza por MyObligationsView.
            comingSoonRow(label: "Mis compromisos", systemImage: "checklist")
            // Slice 6 reemplaza por MyReservationsView.
            comingSoonRow(label: "Mis reservaciones", systemImage: "calendar.badge.clock")
            // Slice 4 reemplaza por MyDecisionsView.
            comingSoonRow(label: "Mis decisiones", systemImage: "checkmark.bubble.fill")
            // Slice 6 reemplaza por MyRulesView.
            comingSoonRow(label: "Mis reglas", systemImage: "sparkles")
            // Slice 5 reemplaza por MyDocumentsView.
            comingSoonRow(label: "Mis documentos", systemImage: "doc.text.fill")
            NavigationLink {
                MySubscriptionsView(container: container)
            } label: {
                Label("Mis suscripciones", systemImage: "bookmark.fill")
            }
            NavigationLink {
                MyTrustNetworkView(container: container)
            } label: {
                Label("Mi red de confianza", systemImage: "person.line.dotted.person")
            }
        } header: {
            Text("Mi mundo")
        }
    }

    @ViewBuilder
    private func comingSoonRow(label: String, systemImage: String) -> some View {
        HStack {
            Label(label, systemImage: systemImage)
                .foregroundStyle(Theme.Text.secondary)
            Spacer()
            Text("Próximamente")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary)
        }
    }

    // MARK: - 5. Configuración

    @ViewBuilder
    private var configurationSection: some View {
        Section {
            Button {
                isShowingEditProfile = true
            } label: {
                HStack {
                    Label("Editar perfil", systemImage: "pencil")
                        .foregroundStyle(Theme.Text.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            .buttonStyle(.plain)
            Button {
                isShowingSettings = true
            } label: {
                HStack {
                    Label("Ajustes", systemImage: "gearshape")
                        .foregroundStyle(Theme.Text.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Configuración")
        }
    }

    // MARK: - 6. Cerrar sesión

    @ViewBuilder
    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await container.signOut() }
            } label: {
                Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    // MARK: - Data

    private func loadWorld() async {
        do {
            world = try await container.rpc.myWorld()
        } catch {
            // Métricas se degradan gracefully a "—". No bloqueamos la UI por
            // un fallo de myWorld() — el resto del shell sigue siendo útil.
            world = nil
        }
    }
}

#Preview("Mi mundo (demo)") {
    MeView(container: .demo(), goToContexts: {})
}
