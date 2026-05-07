import SwiftUI

/// Detail sheet for a single SystemEvent. Shows raw payload (formatted,
/// not crude JSON) + metadata. Reached by tapping a `RuulTimelineItem`.
struct SystemEventDetailView: View {
    let event: SystemEvent
    let memberName: String?
    let dismiss: () -> Void

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ModalSheetTemplate(
            title: titleText,
            primaryCTA: ("Cerrar", dismiss)
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                metadataCard
                if !payloadEntries.isEmpty {
                    payloadCard
                }
            }
        }
    }

    private var metadataCard: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                row("Tipo", event.eventType.rawString)
                row("Cuándo", Self.absoluteFormatter.string(from: event.occurredAt))
                if let name = memberName {
                    row("Miembro", name)
                }
                if let resourceId = event.resourceId {
                    row("Recurso", resourceId.uuidString.prefix(8) + "…")
                }
                row("Procesado",
                    event.processedAt.map { Self.absoluteFormatter.string(from: $0) } ?? "Pendiente")
            }
        }
    }

    private var payloadCard: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Datos")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                ForEach(payloadEntries, id: \.0) { key, value in
                    HStack(alignment: .top) {
                        Text(key)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                        Spacer()
                        Text(value)
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private var titleText: String {
        switch event.eventType {
        case .eventClosed:    return "Evento cerrado"
        case .voteOpened:     return "Votación abierta"
        case .voteCast:       return "Voto emitido"
        case .voteResolved:   return "Votación cerrada"
        case .appealCreated:  return "Apelación abierta"
        case .appealResolved: return "Apelación resuelta"
        case .fineOfficialized: return "Multa oficializada"
        case .fineVoided:     return "Multa anulada"
        case .finePaid:       return "Multa pagada"
        case .checkInRecorded: return "Check-in"
        default: return event.eventType.rawString
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }

    private var payloadEntries: [(String, String)] {
        if case .object(let dict) = event.payload {
            return dict
                .sorted(by: { $0.key < $1.key })
                .map { ($0.key, prettyValue($0.value)) }
        }
        return []
    }

    private func prettyValue(_ v: JSONConfig) -> String {
        switch v {
        case .null: return "—"
        case .bool(let b): return b ? "sí" : "no"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array(let a): return "[\(a.count) items]"
        case .object: return "{ … }"
        }
    }
}
