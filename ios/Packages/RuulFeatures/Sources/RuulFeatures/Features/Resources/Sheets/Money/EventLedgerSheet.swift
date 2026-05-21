import SwiftUI
import RuulUI
import RuulCore

/// Money surface for a single event. Top: per-member balance summary +
/// running total. Body: append-only feed of ledger entries scoped to
/// `resource_id = event.id`. Footer CTA opens AddLedgerEntrySheet for a
/// new entry.
///
/// The coordinator is owned by EventDetailView; this sheet only binds.
// File name kept for git continuity; the type is `ResourceLedgerSheet`,
// polymorphic over Resource (event, asset, fund).
struct ResourceLedgerSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: ResourceLedgerCoordinator
    let groupVocabulary: String

    public init(
        isPresented: Binding<Bool>,
        coordinator: ResourceLedgerCoordinator,
        groupVocabulary: String
    ) {
        self._isPresented = isPresented
        self.coordinator = coordinator
        self.groupVocabulary = groupVocabulary
    }

    var body: some View {
        ModalSheetTemplate(
            title: "Movimientos",
            dismissAction: { isPresented = false }
        ) {
            if coordinator.isLoading && coordinator.entries.isEmpty {
                RuulLoadingState()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                summaryCard
                if !coordinator.memberBalances.isEmpty {
                    balanceSection
                }
                entriesSection
            }
            addEntryCTA
                .padding(.top, RuulSpacing.sm)
        }
        .task { await coordinator.load() }
        .sheet(isPresented: $coordinator.addSheetPresented) {
            AddLedgerEntrySheet(
                isPresented: $coordinator.addSheetPresented,
                coordinator: coordinator
            )
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("TOTAL REGISTRADO")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.xs) {
                Text(format(cents: coordinator.totalSpentCents))
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text(currencyLabel)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                Spacer()
                Text("\(coordinator.entries.count) \(coordinator.entries.count == 1 ? "movimiento" : "movimientos")")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(RuulSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    // MARK: - Balance section

    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("BALANCE NETO")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            RuulSeparatedRows(items: coordinator.memberBalances) { balance in
                balanceRow(balance)
            }
            Text("Positivo: el grupo le debe. Negativo: le debe al grupo.")
                .font(.footnote)
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.top, 2)
        }
    }

    private func balanceRow(_ balance: ResourceLedgerCoordinator.MemberBalance) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            RuulAvatar(name: balance.displayName, imageURL: balance.avatarURL, size: .small)
            Text(balance.displayName)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Spacer()
            Text(formatSigned(cents: balance.netCents))
                .font(.subheadline)
                .foregroundStyle(balance.netCents >= 0 ? Color.green : Color.red)
                .monospacedDigit()
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    // MARK: - Entries feed

    @ViewBuilder
    private var entriesSection: some View {
        if coordinator.entries.isEmpty {
            ContentUnavailableView {
                Label("Sin movimientos", systemImage: "tray")
            } description: {
                Text("Registra el primer gasto o aportación de esta \(groupVocabulary.lowercased()).")
            }
            .padding(.vertical, RuulSpacing.md)
        } else {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("HISTORIAL")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                RuulSeparatedRows(items: coordinator.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    private func entryRow(_ entry: LedgerEntry) -> some View {
        let kindLabel = displayLabel(for: entry.type)
        let icon = iconName(for: entry.type)
        let payerName = coordinator.displayName(for: entry.fromMemberId)
        let receiverName = coordinator.displayName(for: entry.toMemberId)
        let note: String? = {
            guard let value = entry.metadata["note"],
                  case let .string(s) = value, !s.isEmpty else { return nil }
            return s
        }()

        return HStack(spacing: RuulSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.ruulAccent.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.footnote)
                    .foregroundStyle(Color.ruulAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(kindLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                Text(contextLine(payer: payerName, receiver: receiverName))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                if let note {
                    Text("“\(note)”")
                        .font(.footnote)
                        .foregroundStyle(Color(.tertiaryLabel))
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(format(cents: entry.amountCents))
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var addEntryCTA: some View {
        RuulButton(
            "Registrar movimiento",
            style: .primary,
            size: .large,
            fillsWidth: true
        ) {
            coordinator.resetForm()
            coordinator.addSheetPresented = true
        }
    }

    // MARK: - Display helpers

    private var currencyLabel: String {
        if let first = coordinator.entries.first { return first.currency }
        return "MXN"
    }

    private func contextLine(payer: String?, receiver: String?) -> String {
        switch (payer, receiver) {
        case let (.some(p), .some(r)): return "\(p) → \(r)"
        case let (.some(p), .none):    return "Pagado por \(p)"
        case let (.none, .some(r)):    return "Recibido por \(r)"
        default:                       return ""
        }
    }

    private func displayLabel(for type: String) -> String {
        switch type {
        case LedgerEntry.Kind.expense:       return "Gasto"
        case LedgerEntry.Kind.contribution:  return "Aportación"
        case LedgerEntry.Kind.settlement:    return "Pago a miembro"
        case LedgerEntry.Kind.reimbursement: return "Reembolso"
        case LedgerEntry.Kind.payout:        return "Payout"
        case LedgerEntry.Kind.fineIssued:    return "Multa emitida"
        case LedgerEntry.Kind.finePaid:      return "Multa pagada"
        default:                             return type.capitalized
        }
    }

    private func iconName(for type: String) -> String {
        switch type {
        case LedgerEntry.Kind.expense:       return "cart.fill"
        case LedgerEntry.Kind.contribution:  return "arrow.up.bin.fill"
        case LedgerEntry.Kind.settlement:    return "arrow.left.arrow.right"
        case LedgerEntry.Kind.reimbursement: return "arrow.uturn.left"
        case LedgerEntry.Kind.fineIssued,
             LedgerEntry.Kind.finePaid:      return "exclamationmark.triangle.fill"
        default:                             return "circle.fill"
        }
    }

    private func format(cents: Int64) -> String {
        let pesos = Double(cents) / 100.0
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return "$\(f.string(from: NSNumber(value: pesos)) ?? "0")"
    }

    private func formatSigned(cents: Int64) -> String {
        let prefix: String = cents >= 0 ? "+" : "−"
        return "\(prefix)\(format(cents: abs(cents)))"
    }
}
