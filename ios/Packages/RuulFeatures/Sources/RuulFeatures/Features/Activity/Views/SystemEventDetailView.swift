import SwiftUI
import RuulUI
import RuulCore

/// Detail sheet for a single SystemEvent. Shows raw payload (formatted,
/// not crude JSON) + metadata. Reached by tapping a `RuulTimelineItem`.
public struct SystemEventDetailView: View {
    public let event: SystemEvent
    public let memberName: String?
    public let dismiss: () -> Void
    /// Optional: cuando set, agrega un CTA "Ver detalle" que dispara este
    /// callback. La implementación del padre decide qué destination push
    /// según el `event.eventType` (router en MainTabView/GroupHistory).
    /// Cuando `nil`, el primary CTA queda como "Cerrar" (default).
    public var onOpenRelated: ((SystemEvent) -> Void)? = nil
    /// Label custom si el padre quiere override del default ("Ver multa"
    /// / "Ver voto" / etc., resuelto por `defaultRelatedLabel()` según
    /// `event.eventType`).
    public var relatedActionLabel: String? = nil

    public init(event: SystemEvent, memberName: String?, dismiss: @escaping () -> Void, onOpenRelated: ((SystemEvent) -> Void)? = nil, relatedActionLabel: String? = nil) {
        self.event = event
        self.memberName = memberName
        self.dismiss = dismiss
        self.onOpenRelated = onOpenRelated
        self.relatedActionLabel = relatedActionLabel
    }

    public var body: some View {
        ModalSheetTemplate(
            title: titleText,
            primaryCTA: relatedCTA() ?? ("Cerrar", dismiss)
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                metadataCard
                if !payloadEntries.isEmpty {
                    payloadCard
                }
            }
        }
    }

    /// Returns a `(label, perform)` tuple cuando hay related detail
    /// disponible. ModalSheetTemplate solo soporta un primaryCTA, así que
    /// cuando hay related-detail prima el "Ver X" — la sheet hace dismiss
    /// en el padre on push del navigationDestination.
    private func relatedCTA() -> (String, () -> Void)? {
        guard let onOpenRelated else { return nil }
        let label = relatedActionLabel ?? defaultRelatedLabel()
        return (label, { onOpenRelated(event) })
    }

    /// Default CTA label per event type. Mapped to the canonical
    /// destination labels usadas en el resto de la app (es-MX).
    private func defaultRelatedLabel() -> String {
        switch event.eventType {
        case .fineOfficialized, .fineVoided, .finePaid, .fineReminderSent:
            return "Ver multa"
        case .voteOpened, .voteCast, .voteResolved:
            return "Ver voto"
        case .appealCreated, .appealResolved:
            return "Ver apelación"
        case .eventClosed, .eventCreated, .checkInRecorded:
            return "Ver evento"
        case .ruleEnabledChanged, .ruleAmountChanged:
            return "Ver regla"
        default:
            return "Ver detalle"
        }
    }

    private var metadataCard: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                // W2-C3: humanLabel covers every case; rawString stays internal.
                row("Tipo", event.eventType.humanLabel)
                row("Cuándo", event.occurredAt.ruulLongDateTime)
                if let name = memberName {
                    row("Miembro", name)
                }
                // W2-C3: uuidString.prefix(8) leak removed — a hash
                // fragment doesn't identify a resource to the user. If
                // the parent has a resolved name it should pass it
                // through (future hookup); for now we omit the row
                // when we can't show a meaningful identifier.
                row("Procesado",
                    event.processedAt.map { $0.ruulLongDateTime } ?? "Pendiente")
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

    // W2-C3: single source of truth — humanLabel covers every case
    // with Spanish-MX copy. No more partial switches falling through
    // to rawString.
    private var titleText: String { event.eventType.humanLabel }

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
