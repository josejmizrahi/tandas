import SwiftUI
import RuulCore
import RuulUI

/// Universal "Vinculado con…" section. Renders the in/out edges of any
/// resource's polymorphic link graph (mig 00232 + Fase 2).
///
/// Gated by the `links` Tier 0 capability (mig 00233 backfill). Reads
/// `resource_links_view` via `AppState.resourceLinkRepo.linksFor(resource:)`.
///
/// Layout: two sub-sections (USA / USADO POR), each grouped by
/// `LinkKind` so the user sees "Financia: Fondo Bbva" rather than a
/// flat list.
///
/// Writes go through `LinkResourcePolymorphicPickerSheet` (in this
/// file). Unlink is admin-only — server enforces.
public struct ResourceLinksSectionView: View {
    @Environment(AppState.self) private var app
    public let context: ResourceDetailContext

    @State private var incoming: [ResourceLink] = []
    @State private var outgoing: [ResourceLink] = []
    @State private var targetsById: [UUID: ResourceRow] = [:]
    @State private var hasLoaded: Bool = false
    @State private var isMutating: Bool = false
    @State private var errorMessage: String?
    @State private var pickerPresented: Bool = false

    public static let definition = CapabilitySection(
        id: "links",
        priority: 700,
        // Tier 0 cap. The section renders as soon as the capability is
        // present; an empty graph collapses to the "Sin vinculaciones"
        // affordance below.
        isEnabledFor: { caps in caps.contains("links") },
        render: { ctx in AnyView(ResourceLinksSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            header
            content
            if let errorMessage {
                Text(errorMessage)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(.horizontal, RuulSpacing.md)
            }
        }
        .task { await loadIfNeeded() }
        .sheet(isPresented: $pickerPresented) {
            LinkResourcePolymorphicPickerSheet(
                fromResource: context.resource,
                groupId: context.resource.groupId,
                alreadyLinked: alreadyLinkedTuples,
                onLinked: { Task { await refresh() } }
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("VINCULADO CON")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            if totalActive > 0 {
                Text("\(totalActive)")
                    .ruulTextStyle(RuulTypography.statSmall)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Spacer()
            if hasValidLinkCandidates {
                Button {
                    pickerPresented = true
                } label: {
                    Label("Vincular", systemImage: "plus")
                        .ruulTextStyle(RuulTypography.labelSmSemibold)
                        .foregroundStyle(Color.ruulAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Vincular este recurso con otro")
            }
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !hasLoaded {
            EmptyView()
        } else if totalActive == 0 {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                if !outgoing.isEmpty {
                    subsection(title: "Salientes", links: outgoing, direction: .outgoing)
                }
                if !incoming.isEmpty {
                    subsection(title: "Entrantes", links: incoming, direction: .incoming)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasValidLinkCandidates {
            Button {
                pickerPresented = true
            } label: {
                HStack(spacing: RuulSpacing.sm) {
                    iconBadge(systemName: "link")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sin vinculaciones")
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("Conecta este recurso con otros del grupo.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .ruulTextStyle(RuulTypography.captionBold)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .padding(RuulSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardBackground()
        } else {
            // No valid outgoing kinds for this resource type — show a
            // quiet inline note instead of an unactionable card. This
            // resource still appears as the `to` side of any link
            // pointing at it from elsewhere; that's why the section
            // stays visible even here.
            Text("Otros recursos pueden vincularse hacia este.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(.horizontal, RuulSpacing.md)
        }
    }

    @ViewBuilder
    private func subsection(title: String, links: [ResourceLink], direction: LinkDirection) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.horizontal, RuulSpacing.xxs)
            VStack(spacing: RuulSpacing.xs) {
                ForEach(linksByKind(links), id: \.key) { kind, items in
                    kindGroup(kind: kind, links: items, direction: direction)
                }
            }
            .cardBackground()
        }
    }

    @ViewBuilder
    private func kindGroup(kind: LinkKind, links: [ResourceLink], direction: LinkDirection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: iconForKind(kind))
                    .ruulTextStyle(RuulTypography.captionBold)
                    .foregroundStyle(Color.ruulAccent)
                // Active voice for outgoing ("Es dueño de"), passive for
                // incoming ("Es propiedad de") so the relation reads
                // correctly from whichever side the user is viewing.
                Text(kind.displayName(direction: direction).uppercased())
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.top, RuulSpacing.sm)
            .padding(.bottom, RuulSpacing.xs)
            ForEach(links) { link in
                linkRow(link, direction: direction)
            }
        }
    }

    @ViewBuilder
    private func linkRow(_ link: ResourceLink, direction: LinkDirection) -> some View {
        // For an outgoing edge (this resource is the FROM), display the
        // other side as the TO resource. For incoming, the other side
        // is the FROM. This keeps the UI mental model "vinculado con X".
        let otherId = direction == .outgoing ? link.toResourceId : link.fromResourceId
        let target = targetsById[otherId]
        HStack(spacing: RuulSpacing.sm) {
            iconBadge(systemName: iconForType(target?.resourceType))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: target, fallbackId: otherId))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text(typeLabel(target?.resourceType))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
            if viewerIsAdmin {
                Button {
                    Task { await unlink(link) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .ruulTextStyle(RuulTypography.subheadSemibold)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .buttonStyle(.plain)
                .disabled(isMutating)
                .accessibilityLabel("Quitar vinculación")
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    // MARK: - Data

    private var totalActive: Int { incoming.count + outgoing.count }

    private var hasValidLinkCandidates: Bool {
        !LinkKind.candidates(from: context.resource.resourceType).isEmpty
    }

    private var viewerIsAdmin: Bool {
        guard let uid = context.currentUserId,
              let mwp = context.memberDirectory[uid] else { return false }
        return mwp.member.roles.contains(.founder)
    }

    private var alreadyLinkedTuples: Set<LinkTuple> {
        Set(outgoing.map { LinkTuple(toId: $0.toResourceId, kind: $0.linkKind) })
    }

    private func linksByKind(_ links: [ResourceLink]) -> [(key: LinkKind, value: [ResourceLink])] {
        // Group by kind, preserve display order from LinkKind.allCases so
        // the same group always renders in the same order.
        let dict = Dictionary(grouping: links, by: { $0.linkKind })
        return LinkKind.allCases.compactMap { kind in
            guard let items = dict[kind], !items.isEmpty else { return nil }
            return (key: kind, value: items)
        }
    }

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    private func refresh() async {
        guard let repo = app.resourceLinkRepo else {
            hasLoaded = true
            return
        }
        do {
            let (inc, out) = try await repo.linksFor(resource: context.resource.id)
            let otherIds = Set(inc.map { $0.fromResourceId } + out.map { $0.toResourceId })
            var targets: [UUID: ResourceRow] = [:]
            for oid in otherIds {
                if let r = try? await app.resourceRepo.resource(oid) {
                    targets[oid] = r
                }
            }
            await MainActor.run {
                self.incoming = inc
                self.outgoing = out
                self.targetsById = targets
                self.hasLoaded = true
                self.errorMessage = nil
            }
        } catch {
            await MainActor.run {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "No pudimos cargar las vinculaciones."
                self.hasLoaded = true
            }
        }
    }

    private func unlink(_ link: ResourceLink) async {
        guard let repo = app.resourceLinkRepo else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await repo.unlink(from: link.fromResourceId, to: link.toResourceId, kind: link.linkKind)
            await refresh()
        } catch {
            await MainActor.run {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "No se pudo desvincular."
            }
        }
    }

    // MARK: - Presentation helpers

    private func displayName(for target: ResourceRow?, fallbackId: UUID) -> String {
        guard let target else { return "Recurso" }
        if case .string(let title)? = target.metadata["title"], !title.isEmpty { return title }
        if case .string(let name)?  = target.metadata["name"],  !name.isEmpty  { return name }
        return target.resourceType.rawString.capitalized
    }

    private func typeLabel(_ type: ResourceType?) -> String {
        switch type {
        case .event:        return "Evento"
        case .fund:         return "Fondo"
        case .asset:        return "Activo"
        case .space:        return "Espacio"
        case .slot:         return "Turno"
        case .right:        return "Derecho"
        case .unknown, .none: return "Recurso"
        }
    }

    private func iconForType(_ type: ResourceType?) -> String {
        switch type {
        case .event:        return "calendar"
        case .fund:         return "banknote"
        case .asset:        return "shippingbox"
        case .space:        return "mappin.and.ellipse"
        case .slot:         return "ticket"
        case .right:        return "key"
        case .unknown, .none: return "cube"
        }
    }

    private func iconForKind(_ kind: LinkKind) -> String {
        switch kind {
        case .uses:           return "arrow.right"
        case .funds:          return "dollarsign.circle"
        case .governs:        return "shield.lefthalf.filled"
        case .locatedIn:      return "mappin.and.ellipse"
        case .scheduledIn:    return "calendar.badge.clock"
        case .reserves:       return "lock.rotation"
        case .grantsAccessTo: return "key"
        case .owns:           return "checkmark.seal"
        }
    }

    private func iconBadge(systemName: String) -> some View {
        ZStack {
            Circle().fill(Color.ruulAccent.opacity(0.15)).frame(width: 36, height: 36)
            Image(systemName: systemName)
                .ruulTextStyle(RuulTypography.subheadSemibold)
                .foregroundStyle(Color.ruulAccent)
        }
    }
}

/// Identity key used to dedupe candidates in the picker. A given (toId,
/// kind) tuple represents one possible link; the picker hides options
/// that already exist as active links.
struct LinkTuple: Hashable {
    let toId: UUID
    let kind: LinkKind
}

// MARK: - Polymorphic picker sheet

/// Modal sheet to create a new resource link from `fromResource`. The
/// user picks a `LinkKind` from the catalog filtered to candidates
/// valid for `fromResource.resourceType`, then picks a target resource
/// among the group's resources whose type is valid for that kind.
struct LinkResourcePolymorphicPickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let fromResource: ResourceRow
    let groupId: UUID
    let alreadyLinked: Set<LinkTuple>
    let onLinked: () -> Void

    @State private var selectedKind: LinkKind?
    @State private var candidates: [ResourceRow] = []
    @State private var isLoading: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    private var availableKinds: [LinkKind] {
        LinkKind.candidates(from: fromResource.resourceType)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Relación") {
                    if availableKinds.isEmpty {
                        Text("Este recurso no tiene tipos de vínculo salientes en el catálogo V1.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    } else {
                        Picker("Tipo", selection: $selectedKind) {
                            Text("Elegí…").tag(LinkKind?.none)
                            ForEach(availableKinds, id: \.self) { kind in
                                // The picker is always from the source's
                                // perspective → active voice.
                                Text(kind.activeDisplayName).tag(Optional(kind))
                            }
                        }
                    }
                }

                if let kind = selectedKind {
                    Section("Vincular con") {
                        if isLoading {
                            HStack {
                                ProgressView()
                                Text("Cargando recursos…")
                                    .ruulTextStyle(RuulTypography.caption)
                                    .foregroundStyle(Color.ruulTextSecondary)
                            }
                        } else if candidates.isEmpty {
                            Text("No hay recursos del grupo compatibles con \(kind.activeDisplayName).")
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                        } else {
                            ForEach(candidates) { target in
                                Button {
                                    Task { await submit(kind: kind, to: target) }
                                } label: {
                                    HStack {
                                        Image(systemName: iconForType(target.resourceType))
                                            .foregroundStyle(Color.ruulAccent)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(targetName(target))
                                                .foregroundStyle(Color.ruulTextPrimary)
                                            Text(typeLabel(target.resourceType))
                                                .ruulTextStyle(RuulTypography.caption)
                                                .foregroundStyle(Color.ruulTextSecondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .disabled(isSubmitting)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
            }
            .navigationTitle("Vincular")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task(id: selectedKind) {
                guard selectedKind != nil else { return }
                await loadCandidates()
            }
        }
    }

    // MARK: - Data

    private func loadCandidates() async {
        guard let kind = selectedKind else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Server-side re-validates against resource_link_kinds; this
            // client-side filter is UX prefilter only. We pull across
            // all 6 types so the picker shows everything compatible
            // with the chosen kind.
            let all = try await app.resourceRepo.list(
                in: groupId,
                types: ResourceType.allCases,
                statuses: nil,
                limit: 200
            )
            let valid = all.filter { target in
                target.id != fromResource.id
                    && target.archivedAt == nil
                    && kind.isValid(from: fromResource.resourceType, to: target.resourceType)
                    && !alreadyLinked.contains(LinkTuple(toId: target.id, kind: kind))
            }
            await MainActor.run {
                self.candidates = valid
            }
        } catch {
            await MainActor.run {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "No pudimos cargar los recursos del grupo."
            }
        }
    }

    private func submit(kind: LinkKind, to target: ResourceRow) async {
        guard let repo = app.resourceLinkRepo else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await repo.link(from: fromResource.id, to: target.id, kind: kind)
            onLinked()
            dismiss()
        } catch {
            await MainActor.run {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "No pudimos vincular."
            }
        }
    }

    // MARK: - Presentation

    private func targetName(_ row: ResourceRow) -> String {
        if case .string(let title)? = row.metadata["title"], !title.isEmpty { return title }
        if case .string(let name)?  = row.metadata["name"],  !name.isEmpty  { return name }
        return row.resourceType.rawString.capitalized
    }

    private func typeLabel(_ type: ResourceType) -> String {
        switch type {
        case .event: return "Evento"
        case .fund:  return "Fondo"
        case .asset: return "Activo"
        case .space: return "Espacio"
        case .slot:  return "Turno"
        case .right: return "Derecho"
        case .unknown: return "Recurso"
        }
    }

    private func iconForType(_ type: ResourceType) -> String {
        switch type {
        case .event: return "calendar"
        case .fund:  return "banknote"
        case .asset: return "shippingbox"
        case .space: return "mappin.and.ellipse"
        case .slot:  return "ticket"
        case .right: return "key"
        case .unknown: return "cube"
        }
    }
}
