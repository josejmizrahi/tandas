import SwiftUI
import RuulUI
import RuulCore

/// "Summary" zone — 2-3 key facts about the resource. Distinct from
/// the header (identity) and distinct from the dynamic sections (deep
/// data per capability). What the user wants to know at a glance:
///
///   Event  → next occurrence, host, location
///   Asset  → owners, capacity, next booking
///   Fund   → balance, pending payouts, last contribution
///
/// V1 reads what we can find in metadata. Anything missing simply
/// drops out of the row stack — empty summary just means we have
/// nothing to summarize yet.
public struct DetailSummaryView: View {
    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                sectionHeader("RESUMEN")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        summaryRow(row)
                        if idx < rows.count - 1 { divider }
                    }
                }
                .cardBackground()
            }
        }
    }

    // MARK: - Rows

    private struct SummaryRow: Identifiable {
        let id: String
        let icon: String
        let label: String
        let value: String
    }

    private var rows: [SummaryRow] {
        switch context.resource.resourceType {
        case .event:        return eventRows
        case .asset:        return assetRows
        case .fund:         return fundRows
        case .slot:         return slotRows
        default:            return genericRows
        }
    }

    private var eventRows: [SummaryRow] {
        var out: [SummaryRow] = []
        if let host = stringMeta("host_name") ?? stringMeta("hostName") {
            out.append(.init(id: "host", icon: "star.fill", label: "Host", value: host))
        }
        if let loc = stringMeta("location_name") ?? stringMeta("locationName") {
            out.append(.init(id: "location", icon: "mappin.and.ellipse", label: "Lugar", value: loc))
        }
        if let cap = intMeta("capacity_max") ?? intMeta("capacityMax") {
            out.append(.init(id: "capacity", icon: "person.3.fill", label: "Capacidad", value: "\(cap) personas"))
        }
        return out
    }

    private var assetRows: [SummaryRow] {
        var out: [SummaryRow] = []
        if let owners = intMeta("owners_count") ?? intMeta("ownersCount") {
            out.append(.init(id: "owners", icon: "person.2.fill", label: "Owners", value: "\(owners)"))
        }
        if let cap = stringMeta("capacity") {
            out.append(.init(id: "cap", icon: "person.3.fill", label: "Capacidad", value: cap))
        }
        return out
    }

    private var fundRows: [SummaryRow] {
        var out: [SummaryRow] = []
        if let balance = intMeta("balance_cents") ?? intMeta("balanceCents") {
            out.append(.init(id: "bal", icon: "banknote", label: "Balance", value: formatCents(Int64(balance))))
        }
        return out
    }

    private var slotRows: [SummaryRow] {
        var out: [SummaryRow] = []
        if let capacity = intMeta("capacity") {
            out.append(.init(id: "cap", icon: "person.3.fill", label: "Capacidad", value: "\(capacity)"))
        }
        return out
    }

    private var genericRows: [SummaryRow] {
        []
    }

    // MARK: - Helpers

    private func stringMeta(_ key: String) -> String? {
        if case let .string(s) = context.resource.metadata[key], !s.isEmpty { return s }
        return nil
    }

    private func intMeta(_ key: String) -> Int? {
        if case let .int(n) = context.resource.metadata[key] { return n }
        return nil
    }

    private func formatCents(_ cents: Int64) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSDecimalNumber(value: cents / 100)) ?? "$\(cents/100)"
    }

    private func summaryRow(_ row: SummaryRow) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: row.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ruulTextSecondary)
                .frame(width: 24)
            Text(row.label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Text(row.value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, 48)
    }
}
