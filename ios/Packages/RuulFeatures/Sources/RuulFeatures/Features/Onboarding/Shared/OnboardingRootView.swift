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
                    progress: manager,
                    profileRepo: app.profileRepo
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
    public var onCompleted: (OnboardingRootView.CompletionDestination) -> Void

    public var body: some View {
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
        case .templateSelect:
            TemplateSelectorView()
        case .group:
            GroupIdentityView()
        case .vocabulary:
            GroupVocabularyView()
        case .rules:
            InitialRulesView()
        case .governance:
            GovernanceConfigView()
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
    public var walletGen: any WalletPassGenerator
    public var onCompleted: () -> Void

    public var body: some View {
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
                Color.ruulBackground.ignoresSafeArea()
                GroupTourOverlay(walletGen: walletGen, onDismiss: onCompleted)
            }
        }
    }
}
