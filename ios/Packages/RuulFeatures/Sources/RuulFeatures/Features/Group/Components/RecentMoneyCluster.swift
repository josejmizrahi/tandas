import SwiftUI
import RuulUI
import RuulCore

/// "Dinero reciente" — cluster #3 de la doctrina situacional.
/// Filas humanas tipo "José pagó $300" derivadas de LedgerEntry.
/// El header expone un `+` con menú contextual (Registrar gasto /
/// Aportar / Liquidar pendiente) — decisión founder 2026-05-25: las
/// CTAs del antiguo SharedMoneyCard viven aquí, no en ComposeBar.
///
/// Cap a 5 rows. Auto-oculta si `entries.isEmpty` (la decisión vive
/// en `GroupClusterStream`).
@MainActor
struct RecentMoneyCluster: View {
    let entries: [LedgerEntry]
    let members: [MemberWithProfile]
    let currency: String
    let locale: String
    var onRegisterExpense: () -> Void
    var onContribute: () -> Void
    var onSettle: () -> Void

    private var visible: [LedgerEntry] {
        Array(entries.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack {
                Text("Dinero reciente")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                Spacer()
                composeMenu
            }
            .padding(.horizontal, RuulSpacing.xxs)

            VStack(spacing: 0) {
                ForEach(visible) { entry in
                    RecentMoneyRow(
                        entry: entry,
                        members: members,
                        currency: currency,
                        locale: locale
                    )
                    if entry.id != visible.last?.id {
                        Divider()
                            .background(Color(.separator))
                            .padding(.leading, 54)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
    }

    private var composeMenu: some View {
        Menu {
            Button {
                onRegisterExpense()
            } label: {
                Label("Registrar gasto", systemImage: "arrow.up.right.circle")
            }
            Button {
                onContribute()
            } label: {
                Label("Aportar", systemImage: "plus.circle")
            }
            Button {
                onSettle()
            } label: {
                Label("Liquidar pendiente", systemImage: "checkmark.circle")
            }
        } label: {
            Image(systemName: "plus")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.ruulAccent)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Registrar movimiento")
    }
}

@MainActor
private struct RecentMoneyRow: View {
    let entry: LedgerEntry
    let members: [MemberWithProfile]
    let currency: String
    let locale: String

    var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            RuulAvatar(
                name: actorName,
                imageURL: actorAvatarURL,
                size: .small
            )

            VStack(alignment: .leading, spacing: 2) {
                streamText
                Text(relativeTime(entry.occurredAt))
                    .font(.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
    }

    private var actor: MemberWithProfile? {
        guard let id = entry.fromMemberId else { return nil }
        return members.first(where: { $0.member.id == id })
    }

    private var actorName: String {
        actor?.displayName ?? "Alguien"
    }

    private var actorAvatarURL: URL? {
        actor?.avatarURL
    }

    private struct Composition {
        let verb: String
        let isPositive: Bool
    }

    private var composition: Composition {
        // Mapeo desde LedgerEntry.Kind a verbos humanos. Mantiene
        // el listado de kinds canónicos (mig 00078); cualquier kind
        // futuro cae al fallback "registró un movimiento de".
        switch entry.type {
        case LedgerEntry.Kind.expense:
            return Composition(verb: "pagó", isPositive: false)
        case LedgerEntry.Kind.contribution:
            return Composition(verb: "aportó", isPositive: true)
        case LedgerEntry.Kind.settlement:
            return Composition(verb: "liquidó", isPositive: false)
        case LedgerEntry.Kind.finePaid:
            return Composition(verb: "pagó multa de", isPositive: false)
        case LedgerEntry.Kind.reimbursement:
            return Composition(verb: "reembolsó", isPositive: true)
        case LedgerEntry.Kind.payout:
            return Composition(verb: "retiró", isPositive: false)
        case LedgerEntry.Kind.fineIssued:
            return Composition(verb: "recibió una multa de", isPositive: false)
        default:
            return Composition(verb: "registró un movimiento de", isPositive: false)
        }
    }

    private var streamText: Text {
        let parts = composition
        let amountText = Text(formattedAmount).fontWeight(.semibold)
        let coloredAmount = parts.isPositive
            ? amountText.foregroundColor(Color.ruulPositive)
            : amountText.foregroundColor(Color.ruulNegative)
        return (
            Text(actorName).fontWeight(.semibold)
            + Text(" \(parts.verb) ").foregroundColor(.secondary)
            + coloredAmount
        )
        .font(.subheadline)
    }

    private var formattedAmount: String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = currency
        fmt.maximumFractionDigits = 0
        fmt.locale = Locale(identifier: locale)
        let amount = abs(Double(entry.amountCents)) / 100.0
        return fmt.string(from: NSNumber(value: amount)) ?? "\(currency) \(amount)"
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: locale)
        return f.localizedString(for: date, relativeTo: .now)
    }
}
