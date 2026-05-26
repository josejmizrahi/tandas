import SwiftUI
import RuulUI
import RuulCore

/// Contextual member sheet — opened by tapping a single avatar in
/// `GroupPresenceHeader`. Surfaces the FIRST thing the user wants
/// to know about another member in *this* group's context:
///   1. Who they are (avatar + name)
///   2. What role they have here
///   3. Where they stand money-wise with the group
///   4. Quick action surfaces: liquidar (when viewer-relevant),
///      ver perfil completo
///
/// Per `ruul_identity_context_doctrine`: tap a person → contextual
/// participation FIRST, full identity SECOND. This sheet is the
/// "FIRST" — concise, scoped to this group. The "SECOND" (full
/// MemberDetailView) lives behind "Ver perfil completo".
///
/// Scope: V1 wires balance + roles + profile route. Recent
/// participation timeline (system events filtered to this member)
/// is deferred to a follow-up — the architecture supports it via
/// `recentEvents` param without changing call sites.
@MainActor
struct MemberQuickSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let member: MemberWithProfile
    let groupId: UUID
    let groupCurrency: String
    /// Pre-computed balance for this member (from
    /// `coordinator.groupBalances`). nil → "Está al día".
    let memberBalance: MemberGroupBalance?
    /// Optional. When viewer holds a non-zero dyadic position with this
    /// member (or just wants a quick action), the "Liquidar" button
    /// fires this. nil → button hidden.
    var onLiquidar: (() -> Void)?
    /// "Ver perfil completo" — routes to the full MemberDetailView.
    let onOpenProfile: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RuulSpacing.lg) {
                    identityHeader
                    rolesRow
                    balanceCard
                    actionsRow
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.xl)
            }
            .background(Color.ruulBackgroundCanvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    // MARK: - Identity

    private var identityHeader: some View {
        VStack(spacing: RuulSpacing.sm) {
            RuulAvatar(
                name: member.displayName,
                imageURL: member.avatarURL,
                size: .large
            )
            Text(member.displayName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Roles

    @ViewBuilder
    private var rolesRow: some View {
        let visibleRoles = member.member.roles.filter { $0 != .member }
        if !visibleRoles.isEmpty {
            HStack(spacing: RuulSpacing.xxs) {
                ForEach(visibleRoles, id: \.self) { role in
                    Text(roleLabel(role))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ruulTextSecondary)
                        .padding(.horizontal, RuulSpacing.sm)
                        .padding(.vertical, RuulSpacing.xxs)
                        .background(
                            Color.ruulSurface,
                            in: Capsule()
                        )
                }
            }
        }
    }

    private func roleLabel(_ role: MemberRole) -> String {
        switch role {
        case .founder:    return "Fundadora"
        case .admin:      return "Admin"
        case .host:       return "Anfitriona"
        case .treasurer:  return "Tesorera"
        case .observer:   return "Observadora"
        case .arbiter:    return "Árbitra"
        case .member:     return "Miembro"
        }
    }

    // MARK: - Balance

    @ViewBuilder
    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Posición en el grupo")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ruulTextSecondary)

            balanceLine
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ruulCardSurface(.solid)
    }

    @ViewBuilder
    private var balanceLine: some View {
        if let balance = memberBalance, !balance.isSettled {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: balance.isOwed ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(balance.isOwed ? Color.ruulPositive : Color.ruulNegative)
                    .accessibilityHidden(true)
                Text(balance.isOwed
                     ? "El grupo le debe \(formatAmount(abs(balance.netCents)))"
                     : "Le debe \(formatAmount(abs(balance.netCents))) al grupo")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.ruulSemanticSuccess)
                    .accessibilityHidden(true)
                Text("Está al día")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer(minLength: 0)
            }
        }
    }

    private func formatAmount(_ cents: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = groupCurrency
        f.locale = Locale(identifier: "es_MX")
        let decimal = Decimal(cents) / 100
        return f.string(from: decimal as NSDecimalNumber) ?? "\(groupCurrency) \(cents / 100)"
    }

    // MARK: - Actions

    private var actionsRow: some View {
        VStack(spacing: RuulSpacing.xs) {
            if let onLiquidar {
                Button(action: {
                    RuulHaptic.light.trigger()
                    onLiquidar()
                }) {
                    Label("Liquidar con \(member.displayName)", systemImage: "arrow.left.arrow.right.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(Color.ruulPositive)
            }

            Button(action: {
                RuulHaptic.selection.trigger()
                onOpenProfile()
            }) {
                Label("Ver perfil completo", systemImage: "person.crop.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }
}
