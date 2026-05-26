import SwiftUI
import RuulUI
import RuulCore

/// Money UX Consolidation 2026-05-24: single "Registrar movimiento"
/// entry point that supersedes the dual "Aportar" + "Registrar gasto"
/// CTAs on `SharedMoneyCard` and `ResourceMoneySlot`. The user picks a
/// movement kind here; the caller then mounts the matching form sheet.
///
/// Why one entry: every action this sheet routes to writes to the same
/// `ledger_entries` table — making the user choose between "Aportar"
/// and "Registrar gasto" before they even open the sheet was forcing
/// a categorization decision up front. The unified entry lists the
/// canonical kinds so the user picks once, then fills the form for
/// that kind.
public struct RegisterMovementSheet: View {
    public let onPick: (Kind) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(onPick: @escaping (Kind) -> Void) {
        self.onPick = onPick
    }

    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case contribution
        case expense
        case settlement
        /// FASE 4 Wave 4 (2026-05-25): cuando el pool ya pagó a un
        /// miembro por algún gasto fronteado, este movimiento cancela
        /// el saldo a favor del miembro sin tocar el balance del pool
        /// (el `expense` original ya lo contó).
        case reimbursement
        /// FASE 4 Wave 4 Phase 3 Tier 2 (2026-05-25): capital flow del
        /// pool al miembro SIN receivable previo — dividendos, retorno
        /// de capital, stipends, devolución al salir del grupo. RPC
        /// canónica `record_payout`.
        case payout
        /// Phase 4.4 (2026-05-26): cuota / buy-in / aportación
        /// esperada. Marca a uno o varios miembros como deudores hacia
        /// el pool, sin mover dinero todavía. Cuando paguen, se cierra
        /// vía `pay_pool_charge` (RPC mig 20260526040000) que emite un
        /// `contribution` ledger entry + cierra la obligación.
        case poolCharge

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .contribution:  return "Registrar un aporte"
            case .expense:       return "Registrar un gasto"
            case .settlement:    return "Pagar a un miembro"
            case .reimbursement: return "Reembolsar a alguien"
            case .payout:        return "Pagar desde el pool"
            case .poolCharge:    return "Cobrar cuota al grupo"
            }
        }

        public var subtitle: String {
            switch self {
            case .contribution:  return "Yo o alguien aportó dinero al grupo."
            case .expense:       return "Alguien pagó algo del grupo (con o sin reparto)."
            case .settlement:    return "Cerrar una deuda entre dos miembros."
            case .reimbursement: return "El pool le devuelve dinero a alguien que pagó del grupo."
            case .payout:        return "Dividendo, retorno de capital, stipend, devolución al salir."
            case .poolCharge:    return "Cuota de poker, tanda, mensualidad. Cada miembro queda con deuda al pool hasta que paga."
            }
        }

        public var icon: String {
            switch self {
            case .contribution:  return "arrow.down.circle.fill"
            case .expense:       return "arrow.up.circle.fill"
            case .settlement:    return "arrow.left.arrow.right.circle.fill"
            case .reimbursement: return "arrow.uturn.left.circle.fill"
            case .payout:        return "banknote"
            case .poolCharge:    return "person.2.badge.minus"
            }
        }

        public var tint: Color {
            switch self {
            case .contribution:  return .ruulPositive
            case .expense:       return .ruulNegative
            case .settlement:    return .ruulAccent
            case .reimbursement: return .ruulAccent
            case .payout:        return .ruulPositive
            case .poolCharge:    return .ruulAccent
            }
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                    Text("¿Qué quieres registrar?")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.bottom, RuulSpacing.xs)
                    ForEach(Kind.allCases) { kind in
                        card(for: kind)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .ruulSheetToolbar("Registrar movimiento")
        }
        // 2026-05-25: detents baked into the sheet so every call site
        // (ResourceMoneySlot, ResourceDetailSheet, EventDetailSheets)
        // gets a quick-picker, not a full-screen takeover. With 6
        // cards (Phase 4.4 added poolCharge), `.medium` shows enough
        // and `.large` is available if the user scrolls.
        .presentationDetents([.medium, .large])
        // Glass sheet to match the rest of the app's sheets per
        // `doctrine_post_v2_consolidation_phase` § sheet standardization.
        // Replaces the opaque `.background(Color.ruulBackgroundRecessed)`
        // that made this picker look heavy vs the other ultraThinMaterial
        // sheets.
        .presentationBackground(.ultraThinMaterial)
    }

    private func card(for kind: Kind) -> some View {
        Button {
            dismiss()
            onPick(kind)
        } label: {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: kind.icon)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(kind.tint)
                    .frame(width: 44, height: 44)
                    .background(Color.ruulSurface, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(kind.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
