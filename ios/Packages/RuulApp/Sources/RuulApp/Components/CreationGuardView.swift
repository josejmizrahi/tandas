import SwiftUI
import RuulCore

/// R.2V.4 — guard inline para sheets de creación de contextos/recursos.
/// Llama a `context_creation_candidates` (o `resource_creation_candidates`)
/// con debounce al cambiar el nombre, y muestra una sección compacta
/// "¿Querías usar alguno de estos?" si el backend devolvió matches.
///
/// El consumer es responsable de proveer un closure `loader` que ejecuta la RPC.
/// `onSelect` lo invoca el caller para "usar" un candidato existente en lugar
/// de crear uno nuevo (típicamente dismiss + switch).
public struct CreationGuardView: View {
    let candidates: [CreationGuardCandidate]
    let onSelect: (CreationGuardCandidate) -> Void

    public init(
        candidates: [CreationGuardCandidate],
        onSelect: @escaping (CreationGuardCandidate) -> Void
    ) {
        self.candidates = candidates
        self.onSelect = onSelect
    }

    public var body: some View {
        if !candidates.isEmpty {
            Section {
                ForEach(candidates) { c in
                    Button {
                        onSelect(c)
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: c.symbolName)
                                .foregroundStyle(c.isHighConfidence ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(c.displayName)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.primary)
                                HStack(spacing: Theme.Spacing.xs + 2) {
                                    Text("\(Int((c.score * 100).rounded()))% parecido")
                                    if c.isHighConfidence {
                                        StatusBadge("Muy parecido", color: .orange)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("¿Querías usar alguno de estos?")
            } footer: {
                Text("Ruul detectó nombres parecidos. Toca para abrir el existente y evitar duplicados.")
            }
        }
    }
}

/// Wrapper unificado para contexto/recurso candidate en el guard view.
public struct CreationGuardCandidate: Identifiable, Equatable {
    public let id: UUID
    public let displayName: String
    public let score: Double
    public let isHighConfidence: Bool
    public let symbolName: String

    public init(
        id: UUID,
        displayName: String,
        score: Double,
        isHighConfidence: Bool,
        symbolName: String
    ) {
        self.id = id
        self.displayName = displayName
        self.score = score
        self.isHighConfidence = isHighConfidence
        self.symbolName = symbolName
    }

    public static func from(_ c: ContextCreationCandidate) -> CreationGuardCandidate {
        let symbol = AppContext(id: c.contextId, kind: c.actorKind, subtype: c.actorSubtype, displayName: c.displayName).symbolName
        return .init(
            id: c.contextId,
            displayName: c.displayName,
            score: c.score,
            isHighConfidence: c.highConfidence,
            symbolName: symbol
        )
    }

    public static func from(_ c: ResourceCreationCandidate) -> CreationGuardCandidate {
        let symbol = (ResourceType(rawValue: c.resourceType) ?? .other).symbolName
        return .init(
            id: c.resourceId,
            displayName: c.displayName,
            score: c.score,
            isHighConfidence: c.highConfidence,
            symbolName: symbol
        )
    }
}
