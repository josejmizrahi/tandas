import SwiftUI
import SwiftData
import RuulUI
import RuulCore

/// Root view for the onboarding feature. Routes to the appropriate flow
/// (founder vs invited) based on `pendingInviteCode` and existing
/// `OnboardingProgress` state.
public struct OnboardingRootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var coordinatorBundle: CoordinatorBundle?
    @State private var bootstrapped = false
    @State private var showPathPicker = false
    public let pendingInviteCode: String?
    public var onCompleted: (CompletionDestination) -> Void

    public init(pendingInviteCode: String?, onCompleted: @escaping (CompletionDestination) -> Void) {
        self.pendingInviteCode = pendingInviteCode
        self.onCompleted = onCompleted
    }

    public enum CompletionDestination: Sendable, Hashable {
        case home
        case createFirstEvent
        case inviteMore
    }

    private struct CoordinatorBundle: Identifiable {
        let id = UUID()
        var founder: FounderOnboardingCoordinator?
        var invited: InvitedOnboardingCoordinator?
    }

    public var body: some View {
        SwiftUI.Group {
            if let bundle = coordinatorBundle {
                if let founder = bundle.founder {
                    FounderFlow(coordinator: founder, onCompleted: onCompleted)
                } else if let invited = bundle.invited {
                    InvitedFlow(coordinator: invited, walletGen: StubWalletPassGenerator()) {
                        onCompleted(.home)
                    }
                }
            } else if showPathPicker {
                OnboardingPathPickerView(
                    onCreate: { Task { await startFounder() } },
                    onJoin: { code in Task { await startInvited(code: code) } }
                )
            } else {
                RuulLoadingState()
            }
        }
        .task { await bootstrap() }
    }

    @MainActor
    private func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true

        let manager = OnboardingProgressManager(context: modelContext)
        let analytics = LogAnalyticsService()

        // 1) Restore an in-progress flow (founder o invited) si existe.
        if let progress = try? manager.loadActive() {
            switch progress.flowType {
            case .founder:
                let coord = makeFounderCoordinator(manager: manager, analytics: analytics)
                await coord.restore(from: progress)
                coordinatorBundle = CoordinatorBundle(founder: coord)
                return
            case .invited:
                if let code = progress.inviteCode {
                    let coord = makeInvitedCoordinator(code: code, manager: manager, analytics: analytics)
                    await coord.restore(from: progress)
                    coordinatorBundle = CoordinatorBundle(invited: coord)
                    return
                }
            }
        }

        // 2) Deeplink llegó con invite — saltarse picker, ir directo a invited.
        if let code = pendingInviteCode {
            await startInvited(code: code)
            return
        }

        // 3) Sin restore y sin invite: mostrar path picker. El usuario
        //    decide en Step 0 si crear o unirse — antes los caía sin
        //    ofrecerle la rama "unirme con código".
        showPathPicker = true
    }

    @MainActor
    private func startFounder() async {
        let manager = OnboardingProgressManager(context: modelContext)
        let analytics = LogAnalyticsService()
        let coord = makeFounderCoordinator(manager: manager, analytics: analytics)
        await coord.start()
        showPathPicker = false
        coordinatorBundle = CoordinatorBundle(founder: coord)
    }

    @MainActor
    private func startInvited(code: String) async {
        let manager = OnboardingProgressManager(context: modelContext)
        let analytics = LogAnalyticsService()
        let coord = makeInvitedCoordinator(code: code, manager: manager, analytics: analytics)
        await coord.start()
        showPathPicker = false
        coordinatorBundle = CoordinatorBundle(invited: coord)
    }

    private func makeFounderCoordinator(
        manager: OnboardingProgressManager,
        analytics: LogAnalyticsService
    ) -> FounderOnboardingCoordinator {
        FounderOnboardingCoordinator(
            groupRepo: app.groupsRepo,
            inviteRepo: app.inviteRepo,
            ruleRepo: app.ruleRepo,
            otp: app.otp,
            analytics: analytics,
            progress: manager,
            profileRepo: app.profileRepo
        )
    }

    private func makeInvitedCoordinator(
        code: String,
        manager: OnboardingProgressManager,
        analytics: LogAnalyticsService
    ) -> InvitedOnboardingCoordinator {
        InvitedOnboardingCoordinator(
            inviteCode: code,
            groupRepo: app.groupsRepo,
            inviteRepo: app.inviteRepo,
            otp: app.otp,
            analytics: analytics,
            progress: manager
        )
    }
}

// MARK: - Founder NavigationStack

private struct FounderFlow: View {
    @State var coordinator: FounderOnboardingCoordinator
    public var onCompleted: (OnboardingRootView.CompletionDestination) -> Void

    public var body: some View {
        NavigationStack {
            stepView
                .environment(coordinator)
                .animation(.smooth, value: coordinator.currentStep)
        }
    }

    @ViewBuilder
    private var stepView: some View {
        switch coordinator.currentStep {
        case .welcome:
            WelcomeView()
        case .identity:
            FounderIdentityView()
        case .group:
            GroupIdentityView()
        case .preset:
            PresetPickerView()
        case .consent:
            ConsentRulesView()
        case .invite:
            InviteMembersView()
        case .confirm:
            ConfirmationView(
                onCreateFirstEvent: { onCompleted(.createFirstEvent) },
                onInviteMore: { onCompleted(.inviteMore) },
                onGoHome: { onCompleted(.home) }
            )
        }
    }
}

// MARK: - Invited NavigationStack

private struct InvitedFlow: View {
    @State var coordinator: InvitedOnboardingCoordinator
    public var walletGen: any WalletPassGenerator
    public var onCompleted: () -> Void

    public var body: some View {
        NavigationStack {
            stepView
                .environment(coordinator)
                .animation(.smooth, value: coordinator.currentStep)
        }
    }

    @ViewBuilder
    private var stepView: some View {
        switch coordinator.currentStep {
        case .welcome:
            InviteWelcomeView { onCompleted() }
        case .identity:
            InvitedIdentityView()
        case .phoneVerify:
            InvitedVerifyView()
        case .otp:
            InvitedOTPView()
        case .tour:
            ZStack {
                Color.ruulBackground.ignoresSafeArea()
                GroupTourOverlay(walletGen: walletGen, onDismiss: onCompleted)
            }
        }
    }
}
