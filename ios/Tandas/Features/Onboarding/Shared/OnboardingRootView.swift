import SwiftUI
import SwiftData

/// Root view for the onboarding feature. Routes to the appropriate flow
/// (founder vs invited) based on `pendingInviteCode` and existing
/// `OnboardingProgress` state.
struct OnboardingRootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var coordinatorBundle: CoordinatorBundle?
    let pendingInviteCode: String?
    var onCompleted: (CompletionDestination) -> Void

    enum CompletionDestination: Sendable, Hashable {
        case home
        case createFirstEvent
        case inviteMore
    }

    private struct CoordinatorBundle: Identifiable {
        let id = UUID()
        var founder: FounderOnboardingCoordinator?
        var invited: InvitedOnboardingCoordinator?
    }

    var body: some View {
        SwiftUI.Group {
            if let bundle = coordinatorBundle {
                if let founder = bundle.founder {
                    FounderFlow(coordinator: founder, onCompleted: onCompleted)
                } else if let invited = bundle.invited {
                    InvitedFlow(coordinator: invited, walletGen: StubWalletPassGenerator()) {
                        onCompleted(.home)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task { await bootstrap() }
    }

    @MainActor
    private func bootstrap() async {
        let manager = OnboardingProgressManager(context: modelContext)
        let analytics = LogAnalyticsService()

        // Check if there's an in-progress flow to restore.
        if let progress = try? manager.loadActive() {
            switch progress.flowType {
            case .founder:
                let coord = FounderOnboardingCoordinator(
                    groupRepo: app.groupsRepo,
                    inviteRepo: app.inviteRepo,
                    ruleRepo: app.ruleRepo,
                    otp: app.otp,
                    analytics: analytics,
                    progress: manager
                )
                await coord.restore(from: progress)
                coordinatorBundle = CoordinatorBundle(founder: coord)
                return
            case .invited:
                if let code = progress.inviteCode {
                    let coord = InvitedOnboardingCoordinator(
                        inviteCode: code,
                        groupRepo: app.groupsRepo,
                        inviteRepo: app.inviteRepo,
                        otp: app.otp,
                        analytics: analytics,
                        progress: manager
                    )
                    await coord.restore(from: progress)
                    coordinatorBundle = CoordinatorBundle(invited: coord)
                    return
                }
            }
        }

        // No restoration. Decide founder vs invited from inbound link.
        if let code = pendingInviteCode {
            let coord = InvitedOnboardingCoordinator(
                inviteCode: code,
                groupRepo: app.groupsRepo,
                inviteRepo: app.inviteRepo,
                otp: app.otp,
                analytics: analytics,
                progress: manager
            )
            await coord.start()
            coordinatorBundle = CoordinatorBundle(invited: coord)
        } else {
            let coord = FounderOnboardingCoordinator(
                groupRepo: app.groupsRepo,
                inviteRepo: app.inviteRepo,
                ruleRepo: app.ruleRepo,
                otp: app.otp,
                analytics: analytics,
                progress: manager
            )
            await coord.start()
            coordinatorBundle = CoordinatorBundle(founder: coord)
        }
    }
}

// MARK: - Founder NavigationStack

private struct FounderFlow: View {
    @State var coordinator: FounderOnboardingCoordinator
    var onCompleted: (OnboardingRootView.CompletionDestination) -> Void

    var body: some View {
        NavigationStack {
            stepView
                .environment(coordinator)
                .animation(.ruulMorph, value: coordinator.currentStep)
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
        case .vocabulary:
            GroupVocabularyView()
        case .rules:
            InitialRulesView()
        case .invite:
            InviteMembersView()
        case .phoneVerify:
            PhoneVerifyView()
        case .otp:
            OTPVerifyView()
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
    var walletGen: any WalletPassGenerator
    var onCompleted: () -> Void

    var body: some View {
        NavigationStack {
            stepView
                .environment(coordinator)
                .animation(.ruulMorph, value: coordinator.currentStep)
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
                Color.ruulBackgroundCanvas.ignoresSafeArea()
                GroupTourOverlay(walletGen: walletGen, onDismiss: onCompleted)
            }
        }
    }
}
