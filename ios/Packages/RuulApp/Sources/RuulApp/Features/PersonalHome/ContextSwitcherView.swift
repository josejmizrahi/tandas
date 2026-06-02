import SwiftUI
import RuulCore

/// R.1A — context switcher rendered inside `PersonalHomeView`'s header.
/// Scope lock: tapping a context only updates `CurrentContextStore`
/// (which persists + emits an Observable change). Navigation is NOT
/// altered in R.1A — that lands in R.1C with `ContextShell`.
public struct ContextSwitcherView: View {
    @Bindable var store: CurrentContextStore

    public init(store: CurrentContextStore) {
        self.store = store
    }

    public var body: some View {
        Menu {
            ForEach(groupedContexts, id: \.kind) { group in
                Section(sectionTitle(for: group.kind)) {
                    ForEach(group.contexts) { ctx in
                        Button {
                            store.switchTo(ctx)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(ctx.displayName)
                                    if let subtitle = ctx.subtitle, !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.caption)
                                    }
                                }
                            } icon: {
                                Image(systemName: ctx.avatarSymbol ?? defaultSymbol(for: ctx.kind))
                            }
                            if store.currentContext == ctx {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            label
        }
        .accessibilityLabel(Text("Cambiar de contexto"))
        .accessibilityValue(Text(store.currentContext?.displayName ?? "Sin contexto"))
    }

    // MARK: - Label

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: currentSymbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Actuando como")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(store.currentContext?.displayName ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Grouping

    private struct ContextGroup {
        let kind: ContextKind
        let contexts: [AppContext]
    }

    private var groupedContexts: [ContextGroup] {
        let order: [ContextKind] = [.person, .group, .legalEntity]
        return order.compactMap { kind in
            let matches = store.availableContexts.filter { $0.kind == kind }
            return matches.isEmpty ? nil : ContextGroup(kind: kind, contexts: matches)
        }
    }

    private func sectionTitle(for kind: ContextKind) -> String {
        switch kind {
        case .person:      return "Persona"
        case .group:       return "Grupos"
        case .legalEntity: return "Entidades"
        }
    }

    private func defaultSymbol(for kind: ContextKind) -> String {
        switch kind {
        case .person:      return "person.crop.circle.fill"
        case .group:       return "person.3.fill"
        case .legalEntity: return "building.2.fill"
        }
    }

    private var currentSymbol: String {
        if let symbol = store.currentContext?.avatarSymbol { return symbol }
        if let kind = store.currentContext?.kind { return defaultSymbol(for: kind) }
        return "person.crop.circle"
    }
}

// MARK: - Previews

#Preview("Populated") {
    let person = AppContext(
        id: UUID(),
        kind: .person,
        displayName: "José Mizrahi",
        subtitle: "Mi mundo",
        avatarSymbol: "person.crop.circle.fill"
    )
    let quimibond = AppContext(
        id: UUID(),
        kind: .legalEntity,
        displayName: "Quimibond",
        subtitle: "Shareholder",
        avatarSymbol: "building.2.fill"
    )
    let cenas = AppContext(
        id: UUID(),
        kind: .group,
        displayName: "Cenas Sábado",
        subtitle: "Admin",
        avatarSymbol: "person.3.fill"
    )
    return ContextSwitcherView(
        store: CurrentContextStore(
            previewContexts: [person, cenas, quimibond],
            current: person
        )
    )
    .padding()
}
