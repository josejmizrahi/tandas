import SwiftUI
import RuulCore

/// R.10.A — Relations + Linked Events/Obligations/Decisions/Documents + Activity
/// sections + JSONValue parsers (code move, zero behavior change).
///
/// Doctrina: R.5V native-first · "Section is the card".
/// Movido del monolito previo (994–1213 + 1215–1288 parsers + 1123–1180 docs).

// MARK: - Relations

struct ResourceDetailV2RelationsSection: View {
    let relations: ResourceRelationsBundle
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        Section {
            ForEach(relations.outbound + relations.inbound) { rel in
                NavigationLink {
                    ResourceDetailViewV2(resourceId: rel.otherResourceId, context: context, container: container)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rel.other.displayName)
                            Text(rel.relationType.replacingOccurrences(of: "_", with: " "))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    } icon: {
                        Image(systemName: rel.isOutbound ? "arrow.right" : "arrow.left")
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
            }
        } header: {
            Text("Relaciones")
        }
    }
}

// MARK: - Linked Events

struct ResourceDetailV2LinkedEventsSection: View {
    let raw: [JSONValue]
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let items = ResourceDetailV2LinkedParsers.parseEvents(raw)
        if !items.isEmpty {
            // R.10.F.10.b (founder firmado 2026-06-15) — Apple Music header
            // pattern: "Ver todos" trailing → EventsListView context-level
            // (no resource-filtered, consistente con Activity y Documents).
            Section {
                ForEach(Array(items.prefix(3))) { ev in
                    NavigationLink {
                        EventDetailView(eventId: ev.id, context: context, container: container)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ev.title).lineLimit(1)
                                if let when = ev.startsAt {
                                    Text(when.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.tertiary)
                                }
                            }
                        } icon: {
                            Image(systemName: "calendar").foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Eventos relacionados")
                    Spacer()
                    if items.count > 3 {
                        NavigationLink {
                            EventsListView(context: context, container: container)
                        } label: {
                            HStack(spacing: 2) {
                                Text("Ver todos")
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(Theme.Tint.primary)
                        }
                        .font(.subheadline.weight(.regular))
                    }
                }
                .textCase(nil)
            }
        }
    }
}

// MARK: - Linked Obligations

struct ResourceDetailV2LinkedObligationsSection: View {
    let raw: [JSONValue]
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let items = ResourceDetailV2LinkedParsers.parseObligations(raw)
        if !items.isEmpty {
            // R.10.F.10.b — header trailing "Ver todas" → LedgerBrowserView.
            Section {
                ForEach(Array(items.prefix(3))) { o in
                    NavigationLink {
                        ObligationDetailView(obligationId: o.id, context: context, container: container)
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(o.title ?? o.kind ?? "Obligación").lineLimit(1)
                                    if let status = o.status {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundStyle(Theme.Text.tertiary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "doc.text").foregroundStyle(Theme.Text.secondary)
                            }
                            Spacer()
                            if let amount = o.amount, let cur = o.currency {
                                Text("\(Int(amount)) \(cur)")
                                    .font(.callout.bold())
                                    .foregroundStyle(Theme.Text.primary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Obligaciones relacionadas")
                    Spacer()
                    if items.count > 3 {
                        NavigationLink {
                            LedgerBrowserView(context: context, container: container)
                        } label: {
                            HStack(spacing: 2) {
                                Text("Ver todas")
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(Theme.Tint.primary)
                        }
                        .font(.subheadline.weight(.regular))
                    }
                }
                .textCase(nil)
            }
        }
    }
}

// MARK: - Linked Decisions

struct ResourceDetailV2LinkedDecisionsSection: View {
    let raw: [JSONValue]
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let items = ResourceDetailV2LinkedParsers.parseDecisions(raw)
        if !items.isEmpty {
            // R.10.F.10.b — header trailing "Ver todas" → DecisionsListView.
            Section {
                ForEach(Array(items.prefix(3))) { dx in
                    NavigationLink {
                        DecisionDetailView(decisionId: dx.id, context: context, container: container)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dx.title).lineLimit(1)
                                HStack(spacing: 4) {
                                    if let tmpl = dx.templateKey {
                                        Text(tmpl)
                                    }
                                    if let st = dx.status {
                                        Text("· \(st)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                            }
                        } icon: {
                            Image(systemName: "questionmark.circle").foregroundStyle(.purple)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Decisiones relacionadas")
                    Spacer()
                    if items.count > 3 {
                        NavigationLink {
                            DecisionsListView(context: context, container: container)
                        } label: {
                            HStack(spacing: 2) {
                                Text("Ver todas")
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(Theme.Tint.primary)
                        }
                        .font(.subheadline.weight(.regular))
                    }
                }
                .textCase(nil)
            }
        }
    }
}

// MARK: - Linked Documents (Documents V2 inline)

struct ResourceDetailV2LinkedDocumentsSection: View {
    let documents: [Document]
    @Binding var pushedDocumentId: UUID?
    @Binding var isShowingAllDocuments: Bool

    var body: some View {
        let docs = documents
        if !docs.isEmpty {
            // R.10.E.10 (founder firmado 2026-06-15) — Apple Music header
            // pattern: "Ver todos" trailing (conditional on docs.count > 3).
            // Body sólo muestra DATA — affordances en header.
            Section {
                ForEach(Array(docs.prefix(3))) { doc in
                    Button {
                        pushedDocumentId = doc.id
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title)
                                        .foregroundStyle(Theme.Text.primary)
                                        .lineLimit(1)
                                    Text(doc.documentType.label)
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.secondary)
                                }
                            } icon: {
                                Image(systemName: doc.documentType.symbolName)
                                    .foregroundStyle(Self.documentTint(doc.documentType))
                            }
                            Spacer()
                            if doc.isArchived {
                                RuulStatusBadge(.archived)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Documentos")
                    Spacer()
                    if docs.count > 3 {
                        Button {
                            isShowingAllDocuments = true
                        } label: {
                            HStack(spacing: 2) {
                                Text("Ver todos")
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(Theme.Tint.primary)
                        }
                        .font(.subheadline.weight(.regular))
                    }
                }
                .textCase(nil)
            }
        }
    }

    static func documentTint(_ type: DocumentType) -> Color {
        switch type {
        case .contract:  return Theme.Tint.info
        case .receipt:   return Theme.Tint.success
        case .id:        return .purple
        case .statement: return Theme.Tint.primary
        case .photo:     return Theme.Tint.warning
        case .other:     return Theme.Text.tertiary
        }
    }
}

// MARK: - Activity

struct ResourceDetailV2ActivitySection: View {
    let events: [ActivityPreviewEvent]
    let context: AppContext
    let container: DependencyContainer

    // R.10.E.10 (founder firmado 2026-06-15) — Apple Music header pattern:
    // "Ver todo" trailing → ActivityFeedView. Body sólo muestra rows de
    // actividad (max 5).

    var body: some View {
        Section {
            ForEach(events.prefix(5)) { ev in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bolt.circle")
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ev.eventType.replacingOccurrences(of: ".", with: " · "))
                            .font(.callout)
                            .foregroundStyle(Theme.Text.primary)
                        if let when = ev.occurredAt {
                            Text(when.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                    Spacer()
                }
            }
        } header: {
            HStack {
                Text("Actividad reciente")
                Spacer()
                NavigationLink {
                    ActivityFeedView(context: context, container: container)
                } label: {
                    HStack(spacing: 2) {
                        Text("Ver todo")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Theme.Tint.primary)
                }
                .font(.subheadline.weight(.regular))
            }
            .textCase(nil)
        }
    }
}

// MARK: - JSONValue parsers (B.6.1)

enum ResourceDetailV2LinkedParsers {
    struct LinkedEventItem: Identifiable {
        let id: UUID
        let title: String
        let startsAt: Date?
        let status: String?
    }

    struct LinkedObligationItem: Identifiable {
        let id: UUID
        let title: String?
        let kind: String?
        let status: String?
        let amount: Double?
        let currency: String?
    }

    struct LinkedDecisionItem: Identifiable {
        let id: UUID
        let title: String
        let status: String?
        let templateKey: String?
    }

    static func parseEvents(_ raw: [JSONValue]) -> [LinkedEventItem] {
        raw.compactMap { v in
            guard case .object(let o) = v,
                  case .string(let idStr)? = o["event_id"], let id = UUID(uuidString: idStr),
                  case .string(let title)? = o["title"]
            else { return nil }
            var startsAt: Date?
            if case .string(let s)? = o["starts_at"] {
                startsAt = ISO8601DateFormatter().date(from: s)
            }
            var status: String?
            if case .string(let s)? = o["status"] { status = s }
            return LinkedEventItem(id: id, title: title, startsAt: startsAt, status: status)
        }
    }

    static func parseObligations(_ raw: [JSONValue]) -> [LinkedObligationItem] {
        raw.compactMap { v in
            guard case .object(let o) = v,
                  case .string(let idStr)? = o["obligation_id"], let id = UUID(uuidString: idStr)
            else { return nil }
            var title: String?
            if case .string(let s)? = o["title"] { title = s }
            var kind: String?
            if case .string(let s)? = o["obligation_kind"] { kind = s }
            else if case .string(let s)? = o["obligation_type"] { kind = s }
            var status: String?
            if case .string(let s)? = o["status"] { status = s }
            var amount: Double?
            if case .number(let n)? = o["amount"] { amount = n }
            var currency: String?
            if case .string(let s)? = o["currency"] { currency = s }
            return LinkedObligationItem(id: id, title: title, kind: kind, status: status, amount: amount, currency: currency)
        }
    }

    static func parseDecisions(_ raw: [JSONValue]) -> [LinkedDecisionItem] {
        raw.compactMap { v in
            guard case .object(let o) = v,
                  case .string(let idStr)? = o["decision_id"], let id = UUID(uuidString: idStr),
                  case .string(let title)? = o["title"]
            else { return nil }
            var status: String?
            if case .string(let s)? = o["status"] { status = s }
            var tmpl: String?
            if case .string(let s)? = o["template_key"] { tmpl = s }
            return LinkedDecisionItem(id: id, title: title, status: status, templateKey: tmpl)
        }
    }
}
