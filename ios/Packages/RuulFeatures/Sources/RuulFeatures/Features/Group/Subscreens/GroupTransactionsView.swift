import SwiftUI
import RuulUI
import RuulCore

/// Full list of every ledger entry for the group (paginated). Pushed
/// from the "Dinero del grupo" dashboard's "Ver todas →" CTA after the
/// Money UX Consolidation 2026-05-24 refactor that split the hub into
/// summary + drill-down pages.
///
/// Loads up to 200 entries server-side (canonical V1 limit) and applies
/// type / member filters client-side. Each row carries the same
/// context-menu corrections (edit note, reverse) the hub preview had,
/// plus the "Para X" / "Compartido entre N" subtitle resolving via the
/// shared `LedgerEntry+Metadata` helpers.
@MainActor
public struct GroupTransactionsView: View {
    public let group: RuulCore.Group

    @Environment(AppState.self) private var app

    @State private var members: [MemberWithProfile] = []
    @State private var entries: [LedgerEntry] = []
    @State private var resourceNamesById: [UUID: String] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    @State private var typeFilter: TypeFilter = .all
    @State private var memberFilter: UUID?

    @State private var entryToReverse: UUID?
    @State private var entryEditingNote: NoteEditTarget?
    @State private var noteEditDraft: String = ""
    @State private var isSavingNote: Bool = false
    @State private var noteEditError: String?
    @State private var reverseError: String?

    public init(group: RuulCore.Group) {
        self.group = group
    }

    private enum TypeFilter: String, CaseIterable, Identifiable {
        case all, contribution, expense, settlement, fine
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:          return "Todo"
            case .contribution: return "Aportes"
            case .expense:      return "Gastos"
            case .settlement:   return "Liquidaciones"
            case .fine:         return "Multas"
            }
        }
        func matches(_ entry: LedgerEntry) -> Bool {
            switch self {
            case .all: return true
            case .contribution:
                return entry.type == LedgerEntry.Kind.contribution
                    || entry.type == LedgerEntry.Kind.reimbursement
            case .expense:
                return entry.type == LedgerEntry.Kind.expense
                    || entry.type == LedgerEntry.Kind.payout
            case .settlement:
                return entry.type == LedgerEntry.Kind.settlement
            case .fine:
                return entry.type == LedgerEntry.Kind.fineIssued
                    || entry.type == LedgerEntry.Kind.finePaid
            }
        }
    }

    private struct NoteEditTarget: Identifiable {
        let id = UUID()
        let entryId: UUID
        let initialNote: String
    }

    private var visibleEntries: [LedgerEntry] {
        entries.filter { entry in
            guard typeFilter.matches(entry) else { return false }
            if let memberFilter {
                return entry.fromMemberId == memberFilter
                    || entry.toMemberId == memberFilter
                    || entry.paidByMemberId == memberFilter
                    || entry.participants.contains(memberFilter)
            }
            return true
        }
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: RuulSpacing.sm) {
                filterStrip
                if visibleEntries.isEmpty && hasLoaded {
                    emptyState
                } else {
                    ForEach(visibleEntries) { entry in
                        movementRow(entry)
                    }
                }
            }
            .padding(RuulSpacing.lg)
        }
        .refreshable { await load() }
        .background(Color.ruulBackgroundRecessed.ignoresSafeArea())
        .navigationTitle("Transacciones")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(
            "¿Revertir esta operación?",
            isPresented: Binding(
                get: { entryToReverse != nil },
                set: { if !$0 { entryToReverse = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revertir", role: .destructive) {
                if let id = entryToReverse {
                    Task { await performReverse(entryId: id) }
                }
            }
            Button("Cancelar", role: .cancel) { entryToReverse = nil }
        } message: {
            Text("Se creará un movimiento de signo opuesto para cancelar el original.")
        }
        .sheet(item: $entryEditingNote, onDismiss: {
            noteEditDraft = ""
            noteEditError = nil
        }) { target in
            noteEditSheet(target: target)
        }
        .alert("No pudimos revertir", isPresented: Binding(
            get: { reverseError != nil },
            set: { if !$0 { reverseError = nil } }
        )) {
            Button("OK", role: .cancel) { reverseError = nil }
        } message: {
            Text(reverseError ?? "")
        }
    }

    // MARK: - Filter strip

    private var filterStrip: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.xs) {
                    ForEach(TypeFilter.allCases) { f in
                        filterChip(label: f.label, isOn: typeFilter == f) {
                            typeFilter = f
                        }
                    }
                }
            }
            if !members.isEmpty {
                memberPicker
            }
        }
        .padding(.bottom, RuulSpacing.xs)
    }

    private func filterChip(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.horizontal, RuulSpacing.md)
                .padding(.vertical, RuulSpacing.xs)
                .background(
                    Capsule().fill(isOn ? Color.ruulAccent : Color.ruulSurface)
                )
                .overlay(
                    Capsule().stroke(Color(.separator), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var memberPicker: some View {
        Menu {
            Button("Todos los miembros") { memberFilter = nil }
            Divider()
            ForEach(members) { mwp in
                Button(mwp.displayName) { memberFilter = mwp.member.id }
            }
        } label: {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "person.circle")
                    .font(.caption)
                Text(memberFilterLabel)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(memberFilter == nil ? Color.secondary : Color.ruulAccent)
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.xs)
            .background(Capsule().fill(Color.ruulSurface))
            .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
        }
    }

    private var memberFilterLabel: String {
        guard let id = memberFilter,
              let name = members.first(where: { $0.member.id == id })?.displayName else {
            return "Todos los miembros"
        }
        return name
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Sin resultados", systemImage: "tray")
        } description: {
            Text("Ningún movimiento coincide con el filtro actual.")
        }
        .padding(.top, RuulSpacing.xl)
    }

    // MARK: - Movement row (mirrors hub, with context menu)

    private func movementRow(_ entry: LedgerEntry) -> some View {
        let amount = Decimal(entry.amountCents) / 100
        let formatted = amount.formatted(.currency(code: entry.currency))
        let icon = movementIcon(entry)
        let primary = movementLabel(entry)
        let secondary = movementSubtitle(entry)
        let canEditNote = entry.recordedBy == app.session?.user.id
        let reversibleId = reversibleId(entry)
        return HStack(spacing: RuulSpacing.md) {
            ColoredIconBadge(systemName: icon, tint: Color.ruulAccent)
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text(primary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                Text(entry.occurredAt.ruulRelative)
                    .font(.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            Spacer(minLength: 0)
            Text(formatted)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.primary)
        }
        .padding(RuulSpacing.md)
        .ruulCardSurface(.solid)
        .contextMenu {
            if canEditNote {
                Button {
                    entryEditingNote = NoteEditTarget(
                        entryId: entry.id,
                        initialNote: entry.note ?? ""
                    )
                } label: {
                    Label("Editar nota", systemImage: "pencil")
                }
            }
            if let id = reversibleId {
                Button(role: .destructive) {
                    entryToReverse = id
                } label: {
                    Label("Revertir operación", systemImage: "arrow.uturn.backward.circle")
                }
            }
        }
    }

    private func movementIcon(_ entry: LedgerEntry) -> String {
        switch entry.type {
        case LedgerEntry.Kind.contribution, LedgerEntry.Kind.reimbursement, LedgerEntry.Kind.finePaid:
            return "arrow.down.circle"
        case LedgerEntry.Kind.expense, LedgerEntry.Kind.payout, LedgerEntry.Kind.fineIssued:
            return "arrow.up.circle"
        case LedgerEntry.Kind.settlement:
            return "arrow.left.arrow.right.circle"
        default:
            return "circle"
        }
    }

    private func movementLabel(_ entry: LedgerEntry) -> String {
        if let note = entry.note { return note }
        switch entry.type {
        case LedgerEntry.Kind.contribution:  return "Aporte"
        case LedgerEntry.Kind.expense:       return "Gasto"
        case LedgerEntry.Kind.payout:        return "Pago del grupo"
        case LedgerEntry.Kind.settlement:    return "Liquidación"
        case LedgerEntry.Kind.reimbursement: return "Reembolso"
        case LedgerEntry.Kind.fineIssued:    return "Multa emitida"
        case LedgerEntry.Kind.finePaid:      return "Multa pagada"
        default:                             return entry.type.capitalized
        }
    }

    private func movementSubtitle(_ entry: LedgerEntry) -> String? {
        var parts: [String] = []
        if let resourceId = entry.sourceResourceId,
           let name = resourceNamesById[resourceId] {
            parts.append("Para \(name)")
        }
        if let count = entry.participantCount {
            parts.append("Compartido entre \(count)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func reversibleId(_ entry: LedgerEntry) -> UUID? {
        guard entry.recordedBy == app.session?.user.id else { return nil }
        if entry.metadata["reversed_ledger_entry_id"]?.stringValue != nil {
            return nil
        }
        return entry.id
    }

    // MARK: - Note edit sheet

    @ViewBuilder
    private func noteEditSheet(target: NoteEditTarget) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Descripción", text: $noteEditDraft, axis: .vertical)
                        .lineLimit(2...6)
                }
                if let err = noteEditError {
                    Section { Text(err).foregroundStyle(.red) }
                }
            }
            .ruulSheetToolbar("Editar nota") {
                entryEditingNote = nil
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSavingNote ? "Guardando…" : "Guardar") {
                        Task { await performNoteEdit(target: target) }
                    }
                    .disabled(
                        isSavingNote
                        || noteEditDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            == target.initialNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }
        }
        .task {
            if noteEditDraft.isEmpty {
                noteEditDraft = target.initialNote
            }
        }
    }

    @MainActor
    private func performReverse(entryId: UUID) async {
        entryToReverse = nil
        do {
            _ = try await app.ledgerRepo.reverseEntry(
                entryId: entryId,
                reason: nil,
                clientId: UUID()
            )
            await load()
        } catch {
            reverseError = error.localizedDescription
        }
    }

    @MainActor
    private func performNoteEdit(target: NoteEditTarget) async {
        isSavingNote = true
        noteEditError = nil
        defer { isSavingNote = false }
        let trimmed = noteEditDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await app.ledgerRepo.updateEntryNote(
                entryId: target.entryId,
                note: trimmed.isEmpty ? nil : trimmed
            )
            entryEditingNote = nil
            await load()
        } catch {
            noteEditError = error.localizedDescription
        }
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        async let membersTask = (try? await app.groupsRepo.membersWithProfiles(of: group.id)) ?? []
        async let entriesTask = (try? await app.ledgerRepo.list(groupId: group.id, limit: 200)) ?? []
        members = await membersTask
        entries = await entriesTask
        await loadResourceNames()
    }

    private func loadResourceNames() async {
        let ids = Set(entries.compactMap { $0.sourceResourceId })
        guard !ids.isEmpty else { return }
        var resolved: [UUID: String] = resourceNamesById
        for id in ids where resolved[id] == nil {
            if let row = try? await app.resourceRepo.resource(id) {
                let name = row.metadata["name"]?.stringValue
                    ?? row.metadata["title"]?.stringValue
                    ?? row.resourceType.humanLabel
                resolved[id] = name
            }
        }
        resourceNamesById = resolved
    }
}
