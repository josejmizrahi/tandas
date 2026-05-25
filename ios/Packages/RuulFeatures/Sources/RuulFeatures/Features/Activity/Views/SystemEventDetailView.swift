import SwiftUI
import RuulUI
import RuulCore

/// Detail sheet for a single SystemEvent. Shows raw payload (formatted,
/// not crude JSON) + metadata. Reached by tapping a `RuulTimelineItem`.
public struct SystemEventDetailView: View {
    public let event: SystemEvent
    public let memberName: String?
    public let dismiss: () -> Void
    /// Mig 00371: resolves member ids in the breakdown payload to
    /// display names so the per-member split card reads "Maria · $33"
    /// instead of "uuid · $33". Returns nil → caller falls back to a
    /// short id prefix. Defaults to nil-returning for back-compat with
    /// surfaces that don't have a coordinator handy.
    public var resolveMemberName: (UUID) -> String? = { _ in nil }
    public var resolveCurrentUserMemberId: () -> UUID? = { nil }
    /// Optional: cuando set, agrega un CTA "Ver detalle" que dispara este
    /// callback. La implementación del padre decide qué destination push
    /// según el `event.eventType` (router en MainTabView/GroupHistory).
    /// Cuando `nil`, el primary CTA queda como "Cerrar" (default).
    public var onOpenRelated: ((SystemEvent) -> Void)? = nil
    /// Label custom si el padre quiere override del default ("Ver multa"
    /// / "Ver voto" / etc., resuelto por `defaultRelatedLabel()` según
    /// `event.eventType`).
    public var relatedActionLabel: String? = nil

    public init(
        event: SystemEvent,
        memberName: String?,
        dismiss: @escaping () -> Void,
        resolveMemberName: @escaping (UUID) -> String? = { _ in nil },
        resolveCurrentUserMemberId: @escaping () -> UUID? = { nil },
        onOpenRelated: ((SystemEvent) -> Void)? = nil,
        relatedActionLabel: String? = nil
    ) {
        self.event = event
        self.memberName = memberName
        self.dismiss = dismiss
        self.resolveMemberName = resolveMemberName
        self.resolveCurrentUserMemberId = resolveCurrentUserMemberId
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
                if !splitBreakdown.isEmpty {
                    splitBreakdownCard
                }
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
        GroupBox {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                row("Tipo", event.eventType.humanLabel)
                row("Cuándo", event.occurredAt.ruulLongDateTime)
                if let name = memberName {
                    row("Miembro", name)
                }
                row("Procesado",
                    event.processedAt.map { $0.ruulLongDateTime } ?? "Pendiente")
            }
        }
    }

    private var payloadCard: some View {
        GroupBox("Datos") {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                ForEach(payloadEntries, id: \.0) { key, value in
                    HStack(alignment: .top) {
                        Text(key)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                        Spacer()
                        Text(value)
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
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
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
        }
    }

    private var payloadEntries: [(String, String)] {
        if case .object(let dict) = event.payload {
            // Hide the split_breakdown raw array — it's rendered by the
            // dedicated card. Leaving it in the generic key/value table
            // would print "[3 items]" with no signal.
            return dict
                .filter { $0.key != "split_breakdown" }
                .sorted(by: { $0.key < $1.key })
                .map { ($0.key, prettyValue($0.value)) }
        }
        return []
    }

    // MARK: - Split breakdown (mig 00370 / 00371)

    /// Per-member rows decoded from `payload.split_breakdown`. Empty
    /// when the entry has no split metadata (legacy entries, fines,
    /// settlements, etc.).
    private var splitBreakdown: [(memberId: UUID, shareCents: Int64)] {
        guard case .array(let rows) = event.payload["split_breakdown"] ?? .null else {
            return []
        }
        return rows.compactMap { row -> (UUID, Int64)? in
            guard case .object(let dict) = row,
                  let memberStr = dict["member_id"]?.stringValue,
                  let memberId = UUID(uuidString: memberStr),
                  let cents = dict["share_cents"]?.intValue else { return nil }
            return (memberId, Int64(cents))
        }
    }

    private var splitMode: SplitMode? {
        event.payload["split_mode"]?.stringValue.flatMap(SplitMode.init(rawValue:))
    }

    private var totalCents: Int64 {
        Int64(event.payload["amount_cents"]?.intValue ?? 0)
    }

    private var currency: String {
        event.payload["currency"]?.stringValue ?? "MXN"
    }

    private var splitBreakdownCard: some View {
        GroupBox(splitBreakdownTitle) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                ForEach(Array(splitBreakdown.enumerated()), id: \.offset) { _, row in
                    splitRow(memberId: row.memberId, shareCents: row.shareCents)
                }
            }
        }
    }

    private var splitBreakdownTitle: String {
        guard let mode = splitMode else { return "Quién paga" }
        switch mode {
        case .equal:   return "Quién paga (igualmente)"
        case .exact:   return "Quién paga (por monto)"
        case .percent: return "Quién paga (por %)"
        case .shares:  return "Quién paga (por partes)"
        }
    }

    private func splitRow(memberId: UUID, shareCents: Int64) -> some View {
        let isMe = memberId == resolveCurrentUserMemberId()
        let name = isMe
            ? "Tú"
            : (resolveMemberName(memberId) ?? "Miembro")
        let pct = totalCents > 0
            ? Int(round(Double(shareCents) * 100.0 / Double(totalCents)))
            : 0
        return HStack(alignment: .firstTextBaseline) {
            Text(name)
                .font(.subheadline.weight(isMe ? .semibold : .regular))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Spacer(minLength: RuulSpacing.xs)
            Text("\(pct)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary)
                .frame(minWidth: 36, alignment: .trailing)
            Text(formattedCents(shareCents))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(minWidth: 80, alignment: .trailing)
        }
    }

    private func formattedCents(_ cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        return f.string(from: amount as NSDecimalNumber) ?? "\(currency) \(cents / 100)"
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
