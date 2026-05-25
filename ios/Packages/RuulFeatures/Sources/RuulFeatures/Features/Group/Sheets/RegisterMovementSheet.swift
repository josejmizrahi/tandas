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

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .contribution: return "Registrar un aporte"
            case .expense:      return "Registrar un gasto"
            case .settlement:   return "Pagar a un miembro"
            }
        }

        public var subtitle: String {
            switch self {
            case .contribution: return "Yo o alguien aportó dinero al grupo."
            case .expense:      return "Alguien pagó algo del grupo (con o sin reparto)."
            case .settlement:   return "Cerrar una deuda entre dos miembros."
            }
        }

        public var icon: String {
            switch self {
            case .contribution: return "arrow.down.circle.fill"
            case .expense:      return "arrow.up.circle.fill"
            case .settlement:   return "arrow.left.arrow.right.circle.fill"
            }
        }

        public var tint: Color {
            switch self {
            case .contribution: return .ruulPositive
            case .expense:      return .ruulNegative
            case .settlement:   return .ruulAccent
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
            .background(Color.ruulBackgroundRecessed)
            .ruulSheetToolbar("Registrar movimiento")
        }
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
