import SwiftUI

/// The "Yo" tab content. Replaces the old MyFinesView-as-tab pattern that
/// surfaced fines under a "Profile" label (confusing UX). Now MyFinesView
/// is a navigation destination accessible from here.
///
/// Layout (Apple Wallet × Apple Sports):
///   ┌───────────────────────────────────────┐
///   │  [Avatar]   José Mizrahi              │  hero
///   │             Miembro de 2 grupos        │
///   ├───────────────────────────────────────┤
///   │  TODO AL CORRIENTE  /  $300 PENDIENTE │  status hero
///   │                                        │
///   │  ┌──────┐  ┌──────┐  ┌──────┐          │  3 stat tiles
///   │  │ $300 │  │ $200 │  │  3   │          │
///   │  │ pend.│  │ pagas│  │multas│          │
///   │  └──────┘  └──────┘  └──────┘          │
///   ├───────────────────────────────────────┤
///   │  Mis multas                       →    │  nav row
///   │  Historia del grupo               →    │
///   ├───────────────────────────────────────┤
///   │  Ajustes                          →    │
///   ├───────────────────────────────────────┤
///   │  Cerrar sesión                         │  destructive
///   └───────────────────────────────────────┘
struct ProfileView: View {
    @State var coordinator: ProfileCoordinator
    @Environment(AppState.self) private var app

    let onOpenMyFines: () -> Void
    let onOpenHistory: () -> Void
    let onOpenSettings: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.profile == nil {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s5)
                        .transition(.opacity)
                } else if coordinator.profile == nil && coordinator.isLoading {
                    RuulLoadingState()
                        .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: RuulSpacing.s7) {
                            hero
                            statusHero
                            if !coordinator.isAllClear {
                                statTiles
                            }
                            activitySection
                            settingsSection
                            signOutButton
                        }
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s2)
                        .padding(.bottom, RuulSpacing.s12)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await coordinator.refresh() }
                    .transition(.opacity)
                }
            }
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.isLoading)
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.profile?.id)
        }
        .task { await coordinator.refresh() }
    }

    // MARK: - Hero (avatar + name + group meta)

    private var hero: some View {
        HStack(spacing: RuulSpacing.s4) {
            RuulAvatar(
                name: coordinator.profile?.displayName ?? "?",
                imageURL: coordinator.profile?.avatarUrl.flatMap(URL.init(string:)),
                size: .large
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.profile?.displayName ?? "—")
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text(membershipMeta)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, RuulSpacing.s4)
    }

    private var membershipMeta: String {
        let count = app.groups.count
        if count == 0 { return "Sin grupos" }
        if count == 1 { return "Miembro de 1 grupo" }
        return "Miembro de \(count) grupos"
    }

    // MARK: - Status hero (the big "you're caught up" or "you owe X")

    private var statusHero: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            HStack(spacing: RuulSpacing.s2) {
                Circle()
                    .fill(coordinator.isAllClear ? Color.ruulSemanticSuccess : Color.ruulSemanticWarning)
                    .frame(width: 8, height: 8)
                Text(coordinator.isAllClear ? "TODO AL CORRIENTE" : "PENDIENTE DE PAGO")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Text(coordinator.isAllClear ? "Sin deudas" : amountFormatted(coordinator.totalOutstanding))
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }

    // MARK: - Stat tiles (only when there's something to track)

    private var statTiles: some View {
        HStack(spacing: RuulSpacing.s3) {
            statTile(
                value: amountFormatted(coordinator.totalOutstanding),
                label: "Pendiente"
            )
            statTile(
                value: amountFormatted(coordinator.paidThisMonth),
                label: "Pagaste este mes"
            )
            statTile(
                value: "\(coordinator.totalFineCount)",
                label: "Multas totales"
            )
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s1) {
            Text(value)
                .ruulTextStyle(RuulTypography.statMedium)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Sections

    private var activitySection: some View {
        sectionContainer(title: "ACTIVIDAD") {
            navRow(icon: "creditcard", label: "Mis multas", trailing: { outstandingPill }, action: onOpenMyFines)
            divider
            navRow(icon: "clock.arrow.circlepath", label: "Historia del grupo", trailing: { EmptyView() }, action: onOpenHistory)
        }
    }

    private var settingsSection: some View {
        sectionContainer(title: "AJUSTES") {
            navRow(icon: "gearshape", label: "Ajustes", trailing: { EmptyView() }, action: onOpenSettings)
        }
    }

    @ViewBuilder
    private var outstandingPill: some View {
        if !coordinator.isAllClear {
            Text(amountFormatted(coordinator.totalOutstanding))
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulSemanticWarning)
        }
    }

    private var signOutButton: some View {
        Button(action: onSignOut) {
            Text("Cerrar sesión")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulSemanticError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, RuulSpacing.s4)
                .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                        .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
                )
        }
        .buttonStyle(.ruulPress)
    }

    // MARK: - Reusable section + row

    @ViewBuilder
    private func sectionContainer<Content: View>(
        title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.s1)
            VStack(spacing: 0) {
                content()
            }
            .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func navRow<Trailing: View>(
        icon: String,
        label: String,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.s3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.ruulTextSecondary)
                    .frame(width: 24)
                Text(label)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
                trailing()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(RuulSpacing.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Divider()
            .background(Color.ruulBorderSubtle)
            .padding(.leading, 56)  // align with text after icon column
    }

    private func amountFormatted(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }
}
