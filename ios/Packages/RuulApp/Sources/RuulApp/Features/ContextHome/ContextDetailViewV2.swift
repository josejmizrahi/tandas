import SwiftUI
import RuulCore

/// R.5A.F.3 — ContextDetailView v2 backed by `context_detail_descriptor`.
///
/// Tabs Overview / People / Resources / Money / More. Cada tab se hace
/// visible sólo si la sección correspondiente está en `descriptor.sections`
/// (que ya viene filtrada por `my_permissions` desde B.7).
///
/// Mantener `ContextHomeView` (legacy) hasta paridad con 8 founder-canon
/// actor_subtypes (family/company/trip/project/community/trust/generic/friend_group).
public struct ContextDetailViewV2: View {
    let contextId: UUID
    let container: DependencyContainer

    @State private var store: ContextDescriptorStore
    @State private var selectedTab: Tab = .overview
    /// R.5A.F.4 — sub-tab dentro de More (Calendar / Governance / Documents /
    /// Activity / Settings). Auto-select del primero disponible si la actual
    /// no aplica al subtype del context.
    @State private var selectedMoreSubTab: MoreSubTab = .calendar

    public init(contextId: UUID, container: DependencyContainer) {
        self.contextId = contextId
        self.container = container
        _store = State(initialValue: ContextDescriptorStore(rpc: container.rpc))
    }

    /// Categorías de tabs founder spec §11. "More" agrupa governance/documents/
    /// activity/settings — F.4 las expandirá como sub-tabs.
    private enum Tab: String, CaseIterable, Identifiable {
        case overview, people, resources, money, more
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview:  return "Resumen"
            case .people:    return "Personas"
            case .resources: return "Recursos"
            case .money:     return "Dinero"
            case .more:      return "Más"
            }
        }
        /// Sections del descriptor que pertenecen a esta tab.
        var sectionKeys: Set<String> {
            switch self {
            case .overview:  return ["overview"]
            case .people:    return ["people"]
            case .resources: return ["resources"]
            case .money:     return ["money", "obligations"]
            case .more:      return ["calendar", "governance", "documents", "activity", "settings"]
            }
        }
    }

    /// R.5A.F.4 — sub-tabs dentro de More. Cada uno mapea a un section_key
    /// específico del descriptor B.4C.
    private enum MoreSubTab: String, CaseIterable, Identifiable {
        case calendar, governance, documents, activity, settings
        var id: String { rawValue }
        var sectionKey: String { rawValue }
        var label: String {
            switch self {
            case .calendar:   return "Calendario"
            case .governance: return "Gobernanza"
            case .documents:  return "Documentos"
            case .activity:   return "Actividad"
            case .settings:   return "Config"
            }
        }
        var icon: String {
            switch self {
            case .calendar:   return "calendar"
            case .governance: return "building.columns"
            case .documents:  return "doc"
            case .activity:   return "bolt"
            case .settings:   return "gearshape"
            }
        }
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                LoadingStateView()
            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await store.load(contextId: contextId) }
                }
            case .loaded:
                if let d = store.descriptor {
                    descriptorContent(d)
                }
            }
        }
        .navigationTitle(store.descriptor?.contextDisplayName ?? "Contexto")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Label("R.5A", systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.purple)
                    .font(.caption)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(Color.purple.badgeFillSubtle, in: Capsule())
            }
        }
        .task { await store.load(contextId: contextId) }
        .refreshable { await store.load(contextId: contextId) }
    }

    @ViewBuilder
    private func descriptorContent(_ d: ContextDetailDescriptor) -> some View {
        let availableTabs = Tab.allCases.filter { tab in
            tab.sectionKeys.contains { sectionKey in
                d.sections.contains { $0.sectionKey == sectionKey && $0.visible }
            }
        }
        VStack(spacing: Theme.Spacing.md) {
            if availableTabs.count > 1 {
                Picker("Vista", selection: $selectedTab) {
                    ForEach(availableTabs) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.sm)
            }
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    tabContent(d, tab: effectiveTab(availableTabs))
                    Spacer(minLength: Theme.Spacing.xl)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.sm)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear {
            if !availableTabs.contains(selectedTab), let first = availableTabs.first {
                selectedTab = first
            }
        }
    }

    private func effectiveTab(_ available: [Tab]) -> Tab {
        available.contains(selectedTab) ? selectedTab : (available.first ?? .overview)
    }

    // MARK: - Tab content router

    @ViewBuilder
    private func tabContent(_ d: ContextDetailDescriptor, tab: Tab) -> some View {
        switch tab {
        case .overview:  overviewTab(d)
        case .people:    peopleTab(d)
        case .resources: resourcesTab(d)
        case .money:     moneyTab(d)
        case .more:      moreTab(d)
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private func overviewTab(_ d: ContextDetailDescriptor) -> some View {
        VStack(spacing: Theme.Spacing.xl) {
            metricsCard(d.metrics)
            if !d.widgets.isEmpty { widgetsRow(d.widgets) }
            if !d.activityPreview.isEmpty {
                activityCard(d.activityPreview)
            }
        }
    }

    @ViewBuilder
    private func metricsCard(_ m: ContextMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.lg) {
                metricItem(value: "\(m.memberCount)", label: "Miembros", icon: "person.2.fill")
                Divider().frame(height: 36)
                metricItem(value: "\(m.pendingDecisions)", label: "Decisiones", icon: "questionmark.circle.fill")
                Divider().frame(height: 36)
                metricItem(value: "\(m.openObligations)", label: "Obligaciones", icon: "doc.text.below.ecg.fill")
            }
            if !m.resourceCountByClass.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(m.resourceCountByClass.sorted(by: { $0.value > $1.value }), id: \.key) { (key, count) in
                            chipBadge("\(count) \(key.replacingOccurrences(of: "_", with: " "))", tint: .blue)
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.cardHero))
    }

    @ViewBuilder
    private func metricItem(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title3.bold())
        }
    }

    @ViewBuilder
    private func widgetsRow(_ widgets: [ContextWidget]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Dashboard")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(widgets) { widget in
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Image(systemName: widget.icon ?? "rectangle.stack")
                                .font(.system(size: Theme.IconSize.md))
                                .foregroundStyle(Color.accentColor)
                            Text(widget.displayName).font(.subheadline.bold())
                            if let src = widget.dataSourceKey {
                                Text(src).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        .frame(width: 140, alignment: .leading)
                        .padding(Theme.Spacing.md)
                        .background(Theme.Surface.card, in: Theme.cardShape())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func activityCard(_ events: [ActivityPreviewEvent]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Actividad reciente")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                let take = Array(events.prefix(5))
                ForEach(take.enumerated().map { ($0, $1) }, id: \.1.id) { idx, ev in
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Image(systemName: "bolt.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: Theme.IconSize.sm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ev.eventType.replacingOccurrences(of: ".", with: " · "))
                                .font(.subheadline)
                            if let when = ev.occurredAt {
                                Text(when.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.md)
                    if idx < take.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    // MARK: - People

    @ViewBuilder
    private func peopleTab(_ d: ContextDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("\(d.metrics.memberCount) miembros")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            if d.membersPreview.isEmpty {
                EmptyCard(icon: "person.2", label: "Sin miembros para mostrar")
            } else {
                VStack(spacing: 0) {
                    ForEach(d.membersPreview.enumerated().map { ($0, $1) }, id: \.1.id) { idx, m in
                        HStack(alignment: .center, spacing: Theme.Spacing.md) {
                            Circle()
                                .fill(Color.accentColor.badgeFillSubtle)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text(m.displayName.first.map { String($0) } ?? "?")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(Color.accentColor)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.displayName).font(.body)
                                Text(m.membershipType).font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.md)
                        if idx < d.membersPreview.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
            if !d.roles.isEmpty {
                Text("Roles").font(.subheadline.bold()).foregroundStyle(.secondary).padding(.top, Theme.Spacing.md)
                VStack(spacing: 0) {
                    ForEach(d.roles.enumerated().map { ($0, $1) }, id: \.1.id) { idx, role in
                        HStack {
                            Image(systemName: "person.badge.key")
                                .foregroundStyle(.secondary)
                                .frame(width: Theme.IconSize.sm)
                            Text(role.displayName).font(.body)
                            Spacer()
                            Text("\(role.memberCount)").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.md)
                        if idx < d.roles.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    // MARK: - Resources

    @ViewBuilder
    private func resourcesTab(_ d: ContextDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("\(d.resourcesPreview.count) recursos · \(d.metrics.resourceCountByClass.values.reduce(0, +)) en total")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            if d.resourcesPreview.isEmpty {
                EmptyCard(icon: "cube", label: "Sin recursos en este contexto")
            } else {
                let byClass = Dictionary(grouping: d.resourcesPreview) { $0.classKey ?? "generic" }
                ForEach(byClass.keys.sorted(), id: \.self) { classKey in
                    if let items = byClass[classKey] {
                        Text(classKey.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        VStack(spacing: 0) {
                            ForEach(items.enumerated().map { ($0, $1) }, id: \.1.id) { idx, r in
                                HStack(alignment: .center, spacing: Theme.Spacing.md) {
                                    Image(systemName: "cube")
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: Theme.IconSize.sm)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.displayName).font(.body)
                                        if let sub = r.subtypeKey {
                                            Text(sub.replacingOccurrences(of: "_", with: " "))
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.md)
                                if idx < items.count - 1 { Divider().padding(.leading, 56) }
                            }
                        }
                        .background(Theme.Surface.card, in: Theme.cardShape())
                    }
                }
            }
        }
    }

    // MARK: - Money

    @ViewBuilder
    private func moneyTab(_ d: ContextDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Liquidaciones abiertas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(d.moneyPreview.openSettlements)")
                    .font(.title2.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.lg)
            .background(Theme.Surface.card, in: Theme.cardShape())

            if d.obligationsPreview.isEmpty {
                EmptyCard(icon: "doc.text.below.ecg", label: "Sin obligaciones pendientes")
            } else {
                Text("Obligaciones recientes")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(d.obligationsPreview.enumerated().map { ($0, $1) }, id: \.1.id) { idx, o in
                        HStack(alignment: .center, spacing: Theme.Spacing.md) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .frame(width: Theme.IconSize.sm)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.kind ?? "Obligación").font(.body)
                                if let s = o.status {
                                    Text(s).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if let amount = o.amount, let cur = o.currency {
                                Text("\(Int(amount)) \(cur)").font(.subheadline.bold())
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.md)
                        if idx < d.obligationsPreview.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    // MARK: - More (sub-tabs F.4)

    @ViewBuilder
    private func moreTab(_ d: ContextDetailDescriptor) -> some View {
        let availableSubTabs = availableMoreSubTabs(d)
        if availableSubTabs.isEmpty {
            EmptyCard(icon: "ellipsis.circle", label: "Sin más secciones")
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                // Sub-tab picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(availableSubTabs) { sub in
                            subTabChip(sub, selected: effectiveMoreSubTab(availableSubTabs) == sub)
                                .onTapGesture { selectedMoreSubTab = sub }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                // Render del sub-tab activo
                moreSubTabContent(d, sub: effectiveMoreSubTab(availableSubTabs))
            }
            .onAppear {
                if !availableSubTabs.contains(selectedMoreSubTab),
                   let first = availableSubTabs.first {
                    selectedMoreSubTab = first
                }
            }
        }
    }

    private func availableMoreSubTabs(_ d: ContextDetailDescriptor) -> [MoreSubTab] {
        MoreSubTab.allCases.filter { sub in
            d.sections.contains { $0.sectionKey == sub.sectionKey && $0.visible }
        }
    }

    private func effectiveMoreSubTab(_ available: [MoreSubTab]) -> MoreSubTab {
        available.contains(selectedMoreSubTab) ? selectedMoreSubTab : (available.first ?? .activity)
    }

    @ViewBuilder
    private func subTabChip(_ sub: MoreSubTab, selected: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: sub.icon)
                .font(.caption)
            Text(sub.label)
                .font(.subheadline)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            selected ? Color.accentColor : Theme.Surface.card,
            in: Capsule()
        )
        .contentShape(Capsule())
    }

    @ViewBuilder
    private func moreSubTabContent(_ d: ContextDetailDescriptor, sub: MoreSubTab) -> some View {
        switch sub {
        case .calendar:   calendarSubTab(d)
        case .governance: governanceSubTab(d)
        case .documents:  documentsSubTab(d)
        case .activity:   activitySubTab(d)
        case .settings:   settingsSubTab(d)
        }
    }

    @ViewBuilder
    private func calendarSubTab(_ d: ContextDetailDescriptor) -> some View {
        if d.eventsPreview.isEmpty {
            EmptyCard(icon: "calendar", label: "Sin eventos próximos")
        } else {
            VStack(spacing: 0) {
                ForEach(d.eventsPreview.enumerated().map { ($0, $1) }, id: \.1.id) { idx, ev in
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Image(systemName: "calendar.circle")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: Theme.IconSize.sm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ev.title).font(.body)
                            if let starts = ev.startsAt {
                                Text(starts.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if let type = ev.eventType {
                                Text(type).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let status = ev.status {
                            chipBadge(status, tint: status == "open" ? .green : .secondary)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.md)
                    if idx < d.eventsPreview.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func governanceSubTab(_ d: ContextDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if d.decisionsPreview.isEmpty {
                EmptyCard(icon: "questionmark.circle", label: "Sin decisiones abiertas")
            } else {
                Text("Decisiones abiertas")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(d.decisionsPreview.enumerated().map { ($0, $1) }, id: \.1.id) { idx, dec in
                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            Image(systemName: "questionmark.circle.fill")
                                .foregroundStyle(.orange)
                                .frame(width: Theme.IconSize.sm)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dec.title).font(.body)
                                if let type = dec.decisionType {
                                    Text(type.replacingOccurrences(of: "_", with: " "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let closes = dec.closesAt {
                                    Text("Cierra \(closes.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if let status = dec.status {
                                chipBadge(status, tint: .orange)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.md)
                        if idx < d.decisionsPreview.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
            if !d.roles.isEmpty {
                Text("Roles del contexto")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .padding(.top, Theme.Spacing.sm)
                VStack(spacing: 0) {
                    ForEach(d.roles.enumerated().map { ($0, $1) }, id: \.1.id) { idx, role in
                        HStack {
                            Image(systemName: "person.badge.key")
                                .foregroundStyle(.secondary)
                                .frame(width: Theme.IconSize.sm)
                            Text(role.displayName).font(.body)
                            Spacer()
                            Text("\(role.memberCount) miembros")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.md)
                        if idx < d.roles.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    @ViewBuilder
    private func documentsSubTab(_ d: ContextDetailDescriptor) -> some View {
        if d.documentsPreview.isEmpty {
            EmptyCard(icon: "doc", label: "Sin documentos")
        } else {
            VStack(spacing: 0) {
                ForEach(d.documentsPreview.enumerated().map { ($0, $1) }, id: \.1.id) { idx, doc in
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: Theme.IconSize.sm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title).font(.body)
                            if let type = doc.documentType {
                                Text(type.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let created = doc.createdAt {
                                Text(created.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.md)
                    if idx < d.documentsPreview.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func activitySubTab(_ d: ContextDetailDescriptor) -> some View {
        if d.activityPreview.isEmpty {
            EmptyCard(icon: "bolt", label: "Sin actividad reciente")
        } else {
            VStack(spacing: 0) {
                ForEach(d.activityPreview.enumerated().map { ($0, $1) }, id: \.1.id) { idx, ev in
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Image(systemName: "bolt.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: Theme.IconSize.sm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ev.eventType.replacingOccurrences(of: ".", with: " · "))
                                .font(.subheadline)
                            if let when = ev.occurredAt {
                                Text(when.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if let actor = ev.actorId {
                                Text("Actor: \(actor.uuidString.prefix(8))…")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.md)
                    if idx < d.activityPreview.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func settingsSubTab(_ d: ContextDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Identidad del contexto")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    settingsRow(icon: "person.text.rectangle",
                                label: "Nombre",
                                value: d.contextDisplayName ?? "—")
                    Divider().padding(.leading, 56)
                    settingsRow(icon: "tag",
                                label: "Subtype",
                                value: d.actorSubtype ?? "—")
                    Divider().padding(.leading, 56)
                    settingsRow(icon: "eye",
                                label: "Visibilidad",
                                value: d.context["visibility"]?.stringValue ?? "—")
                    Divider().padding(.leading, 56)
                    settingsRow(icon: "person.3",
                                label: "Miembros",
                                value: "\(d.metrics.memberCount)")
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
            if !d.permissions.isEmpty {
                Text("Mis permisos (\(d.permissions.count))")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .padding(.top, Theme.Spacing.sm)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(d.permissions, id: \.self) { p in
                            chipBadge(p, tint: .purple)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settingsRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: Theme.IconSize.sm)
            Text(label).font(.body)
            Spacer()
            Text(value).font(.body).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func chipBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(tint.badgeFillSubtle, in: Capsule())
    }
}

// MARK: - EmptyCard helper

private struct EmptyCard: View {
    let icon: String
    let label: String
    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: Theme.IconSize.lg))
                .foregroundStyle(.tertiary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xl)
        .background(Theme.Surface.card, in: Theme.cardShape())
    }
}
