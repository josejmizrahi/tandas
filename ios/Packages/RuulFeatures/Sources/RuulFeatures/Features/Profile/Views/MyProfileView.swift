import SwiftUI
import RuulUI
import RuulCore

/// Tab "Yo" — Nivel 0 (Identity, cross-group). Shows the user's own
/// profile and cross-group activity entry points only. No group-active
/// state leaks into this view.
///
/// Layout:
///   Hero (avatar + name + "Miembro de N grupos")
///   Tu actividad (Mis multas, Mis movimientos, Actividad del grupo)
///   Ajustes (Editar perfil)
///   Apariencia (theme picker, inline)
///   Cerrar sesión
public struct MyProfileView: View {
    @State var coordinator: ProfileCoordinator
    @Environment(AppState.self) private var app
    @AppStorage("ruul_appearance") private var appearanceRaw: String = AppearanceOption.system.rawValue

    public let onOpenMyFines: () -> Void
    public let onOpenHistory: () -> Void
    public let onEditProfile: () -> Void
    public let onSignOut: () -> Void
    public var onOpenMyLedger: (() -> Void)? = nil
    public var onOpenTimeline: (() -> Void)? = nil

    /// Cross-group outstanding fines pill (read from MyFinesCoordinator).
    /// nil while loading or when zero.
    public var outstandingPillAmount: Decimal?

    public var onChangePhone: (() -> Void)?
    public var onChangeEmail: (() -> Void)?
    public var onPickLanguage: (() -> Void)?
    public var onPickTimezone: (() -> Void)?

    public init(
        coordinator: ProfileCoordinator,
        onOpenMyFines: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onEditProfile: @escaping () -> Void,
        onSignOut: @escaping () -> Void,
        onOpenMyLedger: (() -> Void)? = nil,
        onOpenTimeline: (() -> Void)? = nil,
        outstandingPillAmount: Decimal? = nil,
        onChangePhone: (() -> Void)? = nil,
        onChangeEmail: (() -> Void)? = nil,
        onPickLanguage: (() -> Void)? = nil,
        onPickTimezone: (() -> Void)? = nil
    ) {
        self._coordinator = State(initialValue: coordinator)
        self.onOpenMyFines = onOpenMyFines
        self.onOpenHistory = onOpenHistory
        self.onEditProfile = onEditProfile
        self.onSignOut = onSignOut
        self.onOpenMyLedger = onOpenMyLedger
        self.onOpenTimeline = onOpenTimeline
        self.outstandingPillAmount = outstandingPillAmount
        self.onChangePhone = onChangePhone
        self.onChangeEmail = onChangeEmail
        self.onPickLanguage = onPickLanguage
        self.onPickTimezone = onPickTimezone
    }

    private var appearance: Binding<AppearanceOption> {
        Binding(
            get: { AppearanceOption(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.profile == nil {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.lg)
                        .transition(.opacity)
                } else if coordinator.profile == nil && coordinator.isLoading {
                    RuulLoadingState().transition(.opacity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                            hero
                            identitySection
                            preferencesSection
                            activitySection
                            settingsSection
                            appearanceSection
                            signOutButton
                        }
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.xs)
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

    // MARK: Hero (avatar + name + cross-group meta)

    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
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
        .padding(.top, RuulSpacing.md)
    }

    private var membershipMeta: String {
        let count = app.groups.count
        if count == 0 { return "Sin grupos" }
        if count == 1 { return "Miembro de 1 grupo" }
        return "Miembro de \(count) grupos"
    }

    // MARK: Sections

    private var identitySection: some View {
        sectionContainer(title: "IDENTIDAD") {
            navRow(
                icon: "phone",
                label: "Teléfono",
                trailing: { trailingValue(coordinator.profile?.phone ?? "—") },
                action: { onChangePhone?() }
            )
            divider
            navRow(
                icon: "envelope",
                label: "Correo",
                trailing: { trailingValue(app.session?.user.email ?? "—") },
                action: { onChangeEmail?() }
            )
        }
    }

    private var preferencesSection: some View {
        sectionContainer(title: "PREFERENCIAS") {
            navRow(
                icon: "globe",
                label: "Idioma",
                trailing: { trailingValue(localeLabel(coordinator.profile?.locale)) },
                action: { onPickLanguage?() }
            )
            divider
            navRow(
                icon: "clock",
                label: "Zona horaria",
                trailing: { trailingValue(coordinator.profile?.timezone ?? "—") },
                action: { onPickTimezone?() }
            )
        }
    }

    private func trailingValue(_ s: String) -> some View {
        Text(s)
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func localeLabel(_ code: String?) -> String {
        guard let code, let entry = LanguagePickerView.supported.first(where: { $0.code == code }) else { return "—" }
        return entry.label
    }

    private var activitySection: some View {
        sectionContainer(title: "TU ACTIVIDAD") {
            navRow(icon: "creditcard", label: "Mis multas", trailing: { outstandingPill }, action: onOpenMyFines)
            if let onOpenMyLedger {
                divider
                navRow(icon: "arrow.left.arrow.right", label: "Mis movimientos", trailing: { EmptyView() }, action: onOpenMyLedger)
            }
            divider
            navRow(icon: "clock.badge.checkmark", label: "Mi línea de tiempo", trailing: { EmptyView() }, action: { onOpenTimeline?() })
            divider
            navRow(icon: "clock.arrow.circlepath", label: "Actividad del grupo", trailing: { EmptyView() }, action: onOpenHistory)
        }
    }

    private var settingsSection: some View {
        sectionContainer(title: "AJUSTES") {
            navRow(icon: "pencil", label: "Editar perfil", trailing: { EmptyView() }, action: onEditProfile)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("APARIENCIA")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            HStack(spacing: RuulSpacing.xs) {
                ForEach(AppearanceOption.allCases) { option in
                    Button {
                        appearance.wrappedValue = option
                    } label: {
                        VStack(spacing: RuulSpacing.xxs) {
                            Image(systemName: option.systemImage)
                                .ruulTextStyle(RuulTypography.titleMedium)
                                .accessibilityHidden(true)
                            Text(option.label)
                                .ruulTextStyle(RuulTypography.callout)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.md)
                        .foregroundStyle(
                            appearance.wrappedValue == option
                                ? Color.ruulTextPrimary
                                : Color.ruulTextSecondary
                        )
                        .background(
                            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                                .fill(
                                    appearance.wrappedValue == option
                                        ? Color.ruulBackgroundRecessed
                                        : Color.ruulSurface
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                                .stroke(
                                    appearance.wrappedValue == option
                                        ? Color.ruulBorderStrong
                                        : Color.ruulSeparator,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: appearance.wrappedValue)
                }
            }
        }
    }

    @ViewBuilder
    private var outstandingPill: some View {
        if let amount = outstandingPillAmount, amount > 0 {
            Text(amountFormatted(amount))
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulWarning)
        }
    }

    private var signOutButton: some View {
        Button(action: onSignOut) {
            Text("Cerrar sesión")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulNegative)
                .frame(maxWidth: .infinity)
                .padding(.vertical, RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
        .buttonStyle(.ruulPress)
    }

    // MARK: Reusable section + row

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, 56)
    }

    @ViewBuilder
    private func navRow<Trailing: View>(
        icon: String,
        label: String,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void,
        destructive: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: icon)
                    .ruulTextStyle(RuulTypography.subheadMedium)
                    .foregroundStyle(destructive ? Color.ruulNegative : Color.ruulTextSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(label)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(destructive ? Color.ruulNegative : Color.ruulTextPrimary)
                Spacer()
                trailing()
                Image(systemName: "chevron.right")
                    .ruulTextStyle(RuulTypography.captionBold)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func amountFormatted(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }
}
