import SwiftUI
import RuulCore

/// R.0H.3 — feature-flag namespace para el pivote opcional del root
/// hacia `PersonalHomeView`. Convive con `GroupListView` /
/// `GroupTabsHost` durante toda R.0H: si el flag está OFF (default)
/// el shell renderiza la v1 sin cambios. Toggle en
/// `PersonalSettingsView` (solo en builds DEBUG).
enum PersonalHomeFeatureFlag {
    static let storageKey = "personal_home_root_enabled"
}

/// R.0H.2 — primer skeleton del "My World" personal. Consume
/// `MyWorldStore` (R.0H.1) sin tocar todavía la navegación root: esta
/// vista NO es root hasta R.0H.3 (feature flag) y NO reemplaza
/// `GroupListView` durante todo R.0H (founder lock).
///
/// 6 secciones mínimas, todas opcionales — la pantalla sigue
/// renderizando aunque My World venga vacío:
/// - Header con nombre del actor
/// - Net Worth (consumido de `actor_net_worth` vía my_world_summary)
/// - My Resources (owned/managed/used/beneficiary unidos por sección)
/// - Groups
/// - Pending Decisions
/// - Recent Activity
///
/// Loading / failed / empty / content están explícitos en `body`.
public struct PersonalHomeView: View {
    @Bindable var store: MyWorldStore

    public init(store: MyWorldStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading where store.summary == nil:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message) where store.summary == nil:
                ContentUnavailableView {
                    Label("No pudimos cargar tu Ruul", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Reintentar") {
                        Task { await store.load() }
                    }
                    .buttonStyle(.glassProminent)
                }

            default:
                if let summary = store.summary {
                    contentList(summary: summary)
                } else {
                    emptyState
                }
            }
        }
        .navigationTitle("Mi mundo")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await store.load() }
        .task {
            if store.summary == nil { await store.load() }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView(
            "Tu Ruul está empezando",
            systemImage: "sparkles",
            description: Text("Cuando registres recursos, derechos u obligaciones, aparecerán aquí.")
        )
    }

    // MARK: - Content

    @ViewBuilder
    private func contentList(summary: MyWorldSummary) -> some View {
        List {
            headerSection(actor: summary.actor)
            netWorthSection(netWorth: summary.netWorth)
            myResourcesSection(summary: summary)
            groupsSection(groups: summary.groups)
            pendingDecisionsSection(decisions: summary.pendingDecisions)
            recentActivitySection(events: summary.recentActivity)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Sections

    private func headerSection(actor: MyWorldActor) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(actor.displayName)
                    .font(.title2.weight(.semibold))
                Text(actor.actorKind.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func netWorthSection(netWorth: MyWorldNetWorth?) -> some View {
        Section("Patrimonio") {
            if let netWorth, !netWorth.ownedByCurrency.isEmpty {
                ForEach(netWorth.ownedByCurrency, id: \.currency) { entry in
                    HStack {
                        Text(entry.currency)
                            .font(.body.weight(.medium))
                        Spacer()
                        Text(formatted(entry.ownedValue, currency: entry.currency))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                if !netWorth.beneficiaryByCurrency.isEmpty {
                    ForEach(netWorth.beneficiaryByCurrency, id: \.currency) { entry in
                        HStack {
                            Image(systemName: "heart.text.square")
                                .foregroundStyle(.tint)
                            Text("Beneficiario (\(entry.currency))")
                                .font(.subheadline)
                            Spacer()
                            Text(formatted(entry.value, currency: entry.currency))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            } else {
                Text("Sin patrimonio registrado todavía.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func myResourcesSection(summary: MyWorldSummary) -> some View {
        let owned = summary.ownedResources
        let managed = summary.managedResources
        let used = summary.usedResources
        let beneficiary = summary.beneficiaryResources

        if owned.isEmpty && managed.isEmpty && used.isEmpty && beneficiary.isEmpty {
            Section("Mis recursos") {
                Text("Aún no tienes recursos vinculados.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Mis recursos") {
                ForEach(owned) { res in
                    valuedResourceRow(res, badge: "Dueño")
                }
                ForEach(managed) { res in
                    plainResourceRow(res, badge: "Administra")
                }
                ForEach(used) { res in
                    plainResourceRow(res, badge: "Usa")
                }
                ForEach(beneficiary) { res in
                    valuedResourceRow(res, badge: "Beneficiario")
                }
            }
        }
    }

    @ViewBuilder
    private func groupsSection(groups: [MyWorldGroup]) -> some View {
        Section("Grupos") {
            if groups.isEmpty {
                Text("No perteneces a ningún grupo activo.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups) { group in
                    HStack {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.body.weight(.medium))
                            if let kind = group.membershipType {
                                Text(kind.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pendingDecisionsSection(decisions: [MyWorldPendingDecision]) -> some View {
        Section("Decisiones pendientes") {
            if decisions.isEmpty {
                Text("Sin decisiones abiertas que requieran tu voto.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(decisions) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.title ?? "Decisión sin título")
                            .font(.body.weight(.medium))
                        Text(d.status.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentActivitySection(events: [MyWorldActivityEvent]) -> some View {
        Section("Actividad reciente") {
            if events.isEmpty {
                Text("Cuando hagas algo, aparecerá aquí.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.eventType)
                            .font(.subheadline.weight(.medium))
                        if let createdAt = event.createdAt {
                            Text(createdAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row helpers

    private func valuedResourceRow(_ res: MyWorldValuedResource, badge: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(res.name)
                    .font(.body.weight(.medium))
                Text("\(res.resourceType.capitalized) · \(badge)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if res.estimatedValue > 0 {
                Text(formatted(res.estimatedValue, currency: res.currency))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func plainResourceRow(_ res: MyWorldResourceRef, badge: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(res.name)
                .font(.body.weight(.medium))
            Text("\(res.resourceType.capitalized) · \(badge)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Formatting

    private func formatted(_ amount: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let number = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
        return "\(number) \(currency.uppercased())"
    }
}

// MARK: - Previews

#Preview("Content") {
    NavigationStack {
        PersonalHomeView(
            store: MyWorldStore(previewSummary: PersonalHomePreviewData.populated)
        )
    }
}

#Preview("Empty") {
    NavigationStack {
        PersonalHomeView(
            store: MyWorldStore(previewSummary: PersonalHomePreviewData.empty)
        )
    }
}

#Preview("Loading") {
    NavigationStack {
        PersonalHomeView(
            store: MyWorldStore(previewSummary: nil, phase: .loading)
        )
    }
}

#Preview("Failed") {
    NavigationStack {
        PersonalHomeView(
            store: MyWorldStore(previewSummary: nil, phase: .failed(message: "Sin conexión."))
        )
    }
}
