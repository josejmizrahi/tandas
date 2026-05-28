import Foundation
import Supabase
import RuulCore

/// Single source of long-lived Foundation dependencies. Assembled once at
/// app launch (or per UI test session) and threaded through `RuulAppShell`
/// to every feature view. Construction order is:
///
/// `SupabaseClient` → `AuthService` + `RuulRPCClient`
/// → canonical repositories → @Observable stores.
///
/// Lives at the `RuulApp` boundary because it imports `Supabase` directly
/// (the only place outside `RuulCore/Supabase/`/`RuulCore/API/` allowed to).
/// Views never see it; they get the stores + repos they need.
@MainActor
public final class DependencyContainer {

    // MARK: - Backend wiring

    public let supabaseClient: SupabaseClient
    public let authService: any AuthService
    public let rpcClient: any RuulRPCClient

    /// Kept as a concrete reference so Foundation can call
    /// `signInWithApple(idToken:nonce:)` which lives on
    /// `LiveAuthService` (not on the protocol — the protocol's no-arg
    /// `signInWithApple()` was a placeholder that always throws).
    private let liveAuth: LiveAuthService

    // MARK: - Repositories

    public let groupRepository: CanonicalGroupRepository
    public let inviteRepository: CanonicalInviteRepository
    public let moneyRepository: CanonicalMoneyRepository
    public let profileRepository: CanonicalProfileRepository
    public let membersRepository: CanonicalMembersRepository
    public let purposeRepository: CanonicalPurposeRepository
    public let rulesRepository: CanonicalRulesRepository
    public let resourcesRepository: CanonicalResourcesRepository
    public let foundationStatusRepository: CanonicalFoundationStatusRepository
    public let decisionRulesRepository: CanonicalDecisionRulesRepository
    public let reputationRepository: CanonicalReputationRepository
    public let sanctionsRepository: CanonicalSanctionsRepository
    public let disputesRepository: CanonicalDisputesRepository
    public let eventsRepository: CanonicalEventsRepository
    public let movementsRepository: CanonicalMovementsRepository
    public let culturalNormsRepository: CanonicalCulturalNormsRepository
    public let mandatesRepository: CanonicalMandatesRepository
    public let contributionsRepository: CanonicalContributionsRepository
    public let decisionsRepository: CanonicalDecisionsRepository
    public let ritualsRepository: CanonicalRitualsRepository
    public let boundaryRepository: CanonicalBoundaryRepository
    public let rolesRepository: CanonicalRolesRepository
    public let dissolutionRepository: CanonicalDissolutionRepository
    public let notificationsRepository: CanonicalNotificationsRepository
    public let privacyRepository: CanonicalPrivacyRepository

    // MARK: - Stores

    public let sessionStore: SessionStore
    public let groupsStore: GroupsStore
    public let currentGroupStore: CurrentGroupStore
    public let moneyStore: MoneyStore
    public let profileStore: ProfileStore
    public let membersStore: MembersStore
    public let purposeStore: PurposeStore
    public let rulesStore: RulesStore
    public let resourcesStore: ResourcesStore
    public let foundationStatusStore: FoundationStatusStore
    public let decisionRulesStore: DecisionRulesStore
    public let reputationStore: ReputationStore
    public let sanctionsStore: SanctionsStore
    public let disputesStore: DisputesStore
    public let eventsStore: EventsStore
    public let movementsStore: MoneyMovementsStore
    public let culturalNormsStore: CulturalNormsStore
    public let mandatesStore: MandatesStore
    public let contributionsStore: ContributionsStore
    public let reputationFeedStore: ReputationFeedStore
    public let decisionsStore: DecisionsStore
    public let ritualsStore: RitualsStore
    public let boundaryPolicyStore: BoundaryPolicyStore
    public let rolesStore: RolesStore
    public let dissolutionStore: DissolutionStore
    public let notificationSettingsStore: NotificationSettingsStore
    public let privacyStore: PrivacyStore

    public init() {
        let client = SupabaseEnvironment.shared
        self.supabaseClient = client

        let auth = LiveAuthService(client: client)
        self.authService = auth
        self.liveAuth = auth

        let rpc = SupabaseRuulRPCClient(client: client)
        self.rpcClient = rpc

        self.groupRepository = CanonicalGroupRepository(rpc: rpc)
        let invites = CanonicalInviteRepository(rpc: rpc)
        self.inviteRepository = invites
        self.moneyRepository = CanonicalMoneyRepository(rpc: rpc)
        self.profileRepository = CanonicalProfileRepository(rpc: rpc)
        self.membersRepository = CanonicalMembersRepository(rpc: rpc, invites: invites)
        self.purposeRepository = CanonicalPurposeRepository(rpc: rpc)
        self.rulesRepository = CanonicalRulesRepository(rpc: rpc)
        self.resourcesRepository = CanonicalResourcesRepository(rpc: rpc)
        self.foundationStatusRepository = CanonicalFoundationStatusRepository(rpc: rpc)
        self.decisionRulesRepository = CanonicalDecisionRulesRepository(rpc: rpc)
        self.reputationRepository = CanonicalReputationRepository(rpc: rpc)
        self.sanctionsRepository = CanonicalSanctionsRepository(rpc: rpc)
        self.disputesRepository = CanonicalDisputesRepository(rpc: rpc)
        self.eventsRepository = CanonicalEventsRepository(rpc: rpc)
        self.movementsRepository = CanonicalMovementsRepository(rpc: rpc)
        self.culturalNormsRepository = CanonicalCulturalNormsRepository(rpc: rpc)
        self.mandatesRepository = CanonicalMandatesRepository(rpc: rpc)
        self.contributionsRepository = CanonicalContributionsRepository(rpc: rpc)
        self.decisionsRepository = CanonicalDecisionsRepository(rpc: rpc)
        self.ritualsRepository = CanonicalRitualsRepository(rpc: rpc)
        self.boundaryRepository = CanonicalBoundaryRepository(rpc: rpc)
        self.rolesRepository = CanonicalRolesRepository(rpc: rpc)
        self.dissolutionRepository = CanonicalDissolutionRepository(rpc: rpc)
        self.notificationsRepository = CanonicalNotificationsRepository(rpc: rpc)
        self.privacyRepository = CanonicalPrivacyRepository(rpc: rpc)

        self.sessionStore = SessionStore(authService: auth)
        self.groupsStore = GroupsStore(repository: groupRepository)
        self.currentGroupStore = CurrentGroupStore(repository: groupRepository)
        self.moneyStore = MoneyStore(repository: moneyRepository)
        self.profileStore = ProfileStore(repository: profileRepository)
        self.membersStore = MembersStore(repository: membersRepository)
        self.purposeStore = PurposeStore(repository: purposeRepository)
        self.rulesStore = RulesStore(repository: rulesRepository)
        self.resourcesStore = ResourcesStore(repository: resourcesRepository)
        self.foundationStatusStore = FoundationStatusStore(repository: foundationStatusRepository)
        self.decisionRulesStore = DecisionRulesStore(repository: decisionRulesRepository)
        self.reputationStore = ReputationStore(repository: reputationRepository)
        self.sanctionsStore = SanctionsStore(repository: sanctionsRepository)
        self.disputesStore = DisputesStore(repository: disputesRepository)
        self.eventsStore = EventsStore(repository: eventsRepository)
        self.movementsStore = MoneyMovementsStore(repository: movementsRepository)
        self.culturalNormsStore = CulturalNormsStore(repository: culturalNormsRepository)
        self.mandatesStore = MandatesStore(repository: mandatesRepository)
        self.contributionsStore = ContributionsStore(repository: contributionsRepository)
        self.reputationFeedStore = ReputationFeedStore(repository: reputationRepository)
        self.decisionsStore = DecisionsStore(repository: decisionsRepository)
        self.ritualsStore = RitualsStore(repository: ritualsRepository)
        self.boundaryPolicyStore = BoundaryPolicyStore(repository: boundaryRepository)
        self.rolesStore = RolesStore(repository: rolesRepository)
        self.dissolutionStore = DissolutionStore(repository: dissolutionRepository)
        self.notificationSettingsStore = NotificationSettingsStore(repository: notificationsRepository)
        self.privacyStore = PrivacyStore(repository: privacyRepository)
    }

    /// Kicks off the session subscription so the shell can observe state
    /// transitions. Idempotent; safe to call from `.task`.
    public func bootstrap() {
        sessionStore.bootstrap()
    }

    /// Forwards a completed Sign In with Apple credential to Supabase via
    /// `LiveAuthService`. The view layer owns the `ASAuthorizationController`
    /// dance + nonce generation; it just hands us the verified token + the
    /// matching raw nonce when Apple returns success.
    public func signInWithApple(idToken: String, nonce: String) async throws -> AppSession {
        try await liveAuth.signInWithApple(idToken: idToken, nonce: nonce)
    }
}
