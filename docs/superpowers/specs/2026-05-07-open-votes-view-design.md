# OpenVotesView V1 — design

**Status**: brainstormed, ready for implementation plan
**Author**: Claude (session 2026-05-07, post-APNs sprint)
**Roadmap item**: Plans/Audit-2026-05-06.md §5.2 #3 ("OpenVotesView — último P0; desbloquea general_proposal + rule_change")
**Backend assumptions**: prod has 00022_notifications_outbox, 00023_appeal_voting_v2, 00031_claim_outbox_rpcs aplicadas (verificadas vía MCP 2026-05-07)
**Scope**: V1 = list + cast + 2 creation sheets (`general_proposal`, `rule_change`). Refactor mínimo de `VoteOnAppealSheet` para extraer body. Cero cambios al rule engine, RPCs, o schema.

## Goal

Habilitar UI para los 7 `vote_type`s declarados en `Platform/Models/Vote.swift` que hoy no tienen entry point. V1 ships funcional para 3 (`fine_appeal` ya shipped + `general_proposal` + `rule_change` nuevos) y "lista pero no implementa creation" para los otros 4 (`rule_repeal`, `member_removal`, `fund_withdrawal`, `role_assignment`, `slot_dispute` — más uno: `rule_repeal` listado en enum). Después de V1:

- `OpenVotesListView` muestra todos los votes con `status='open'` para el grupo activo, cross-vote_type.
- `VoteDetailView` router dispatchea por `vote.voteType` a un body component dedicado.
- `FineAppealVoteBody` extraído del existing `VoteOnAppealSheet` (paridad pixel-perfect garantizada por snapshot test).
- `GeneralProposalVoteBody` y `RuleChangeVoteBody` son nuevos.
- `GenericVoteBody` actúa como fallback para los vote_types sin body dedicado.
- `CreateGeneralProposalSheet` permite a cualquier miembro proponer (governance.whoCanCreateVotes = anyMember por default).
- `CreateRuleChangeSheet` permite proponer cambio de regla (mismo gate; el server rule engine es quien aplica el cambio si pasa).
- Inbox renderiza `ActionType.votePending` (ya en enum, no renderizado hoy).
- RulesView agrega sección "Votos abiertos" con count + link al list.

## Out of scope

- **EditRuleSheet → CreateRuleChangeSheet auto-route** cuando `GovernanceService.canPerform(.modifyRules) == .requiresVote` — V1.5 / V2. Toca el flow de edit existente y arriesga regresión que no vale para este sprint.
- **Vote results history** (votes con `status` ∈ `closed | resolved | quorum_failed | cancelled`) — `OpenVotesListView` solo muestra `status='open'`. Historial se ve en `GroupHistoryView` ya existente.
- **Per-context creation entries** desde RulesView per-rule context menu, etc. — V2.
- **Anonymity opt-out per-vote** — usa `governance.votesAreAnonymous` global.
- **Notifications de "tu vote cierra en N horas"** — el outbox + dispatch-notifications path ya está, pero los emisores SQL no programan deadline-warning para votes. Out of V1.
- **Body dedicados para los 4 vote_types restantes** (`rule_repeal`, `member_removal`, `fund_withdrawal`, `role_assignment`, `slot_dispute`) — `GenericVoteBody` fallback es suficiente para listarlos. Cada uno tendrá body propio cuando su feature shippee.
- **`VoteCastSection.realtime` updates** — V1 re-fetcha counts en cada cast/refresh; no suscribe a cambios. Realtime es V2.

## Backend assumptions verified

V1 es **iOS-only**. Cero migrations nuevas, cero RPC changes, cero edge function changes. La infra de votes ya existe en prod.

**`votes` table** (00020 + 00023): polimórfica vía `vote_type`, `payload jsonb`, `quorum_min_absolute`. Confirmado vía MCP `list_tables`.

**`start_vote(...)` RPC** (00023 v2): acepta `p_group_id, p_vote_type, p_reference_id, p_title, p_description, p_payload, p_duration_hours, p_quorum_percent, p_threshold_percent, p_is_anonymous, p_quorum_min_absolute`. Inserta `votes` row + seed `vote_casts` pending para todos los miembros activos (excluye infractor en `fine_appeal`) + emite `voteOpened` SystemEvent + escribe N rows a `notifications_outbox`.

**`cast_vote(p_vote_id, p_choice)` RPC** (00006/00020): SECURITY DEFINER. Updates the caller's existing pending cast (seeded by `start_vote`). Emits `voteCast` event. Throws si vote.status != 'open'.

**`finalize_vote(p_vote_id)` RPC** (00023 v2): cron `finalize-votes` la dispara cuando `closes_at < now()`. Computa quorum + threshold, escribe outbox para todos los voters.

**`vote_counts_view`**: vista agregada anonimizada. Cualquier miembro del grupo puede SELECT. Devuelve `(vote_id, in_favor, against, abstained, pending, total_eligible)`.

**`VoteRepository`** y **`VoteCastRepository`**: protocols + Live + Mock ya existen (`Platform/Repositories/`). Sin cambios.

**`GovernanceService`**: ya existe. Para `.createVotes` el default per `recurring_dinner` template es `.anyMember`. Para `.modifyRules` (relevante en `rule_change` semantics) default es `.founder` — si caller no es founder, `canPerform` retorna `.requiresVote(...)` que es exactamente lo que `rule_change` significa. Pero V1 no auto-routea desde EditRuleSheet — la creación de `rule_change` siempre va via `CreateRuleChangeSheet` directamente.

## §1 — Architecture

```
ios/Tandas/Features/Votes/
├── Coordinator/
│   ├── OpenVotesCoordinator.swift                ← @Observable @MainActor
│   ├── VoteDetailCoordinator.swift               ← @Observable @MainActor
│   ├── CreateGeneralProposalCoordinator.swift    ← @Observable @MainActor
│   └── CreateRuleChangeCoordinator.swift         ← @Observable @MainActor
├── Views/
│   └── OpenVotesListView.swift                   ← top-level list
├── Detail/
│   ├── VoteDetailView.swift                      ← router container
│   └── Bodies/
│       ├── FineAppealVoteBody.swift              ← extracted from VoteOnAppealSheet
│       ├── GeneralProposalVoteBody.swift         ← new
│       ├── RuleChangeVoteBody.swift              ← new
│       └── GenericVoteBody.swift                 ← fallback for unimplemented types
├── Sheets/
│   ├── CreateVoteSheet.swift                     ← vote_type picker
│   ├── CreateGeneralProposalSheet.swift          ← title + description form
│   └── CreateRuleChangeSheet.swift               ← rule picker + new amount form
└── Components/
    └── VoteCastSection.swift                     ← shared in_favor/against/abstain UI
```

**Touches existentes (mínimos)**:
- `Features/Inbox/Views/ActionInboxView.swift` — render `ActionType.votePending` rows. Tap → push `VoteDetailView`. ~20 LOC adicionales.
- `Features/Rules/RulesView.swift` — sección "Votos abiertos" (count + link a `OpenVotesListView` filtered por type=ruleChange si aplica). ~30 LOC adicionales.
- `Features/Fines/Sheets/VoteOnAppealSheet.swift` — refactor: extrae body a `FineAppealVoteBody`, sheet preserva entry point existente envolviendo el body. Pixel-paridad garantizada por snapshot test.

**Decisión clave 1 — Container + body sub-components** (delta vs design original "switch inline"): `VoteDetailView` es router puro; cada vote_type tiene su body en archivo separado. Permite polish individual sin que el router crezca. Mismo patrón que `ResourceDetailView` (Sub-fase A).

**Decisión clave 2 — `OpenVotesListView` solo muestra `status='open'`**: votes resueltos viven en `GroupHistoryView`. List sirve a "qué decisiones están abiertas ahora", history sirve a "qué pasó". Separación de surface por intent.

**Decisión clave 3 — Single creation entry** (delta vs per-context): "+ button" en `OpenVotesListView` → `CreateVoteSheet` (picker de vote_type) → sheet específico. Para V1 no agregamos creation en RulesView per-rule context. Reduces invasión en surfaces existentes a cero (out of `RulesView` "Votos abiertos" section que es read-only).

## §2 — Components

### 1. `OpenVotesCoordinator`

```swift
@Observable @MainActor
final class OpenVotesCoordinator {
    let group: Group
    private let voteRepo: any VoteRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "votes")

    private(set) var openVotes: [Vote] = []
    private(set) var isLoading: Bool = false
    private(set) var error: String?
    private(set) var lastRefreshedAt: Date?

    init(group: Group, voteRepo: any VoteRepository) { ... }

    func refresh(force: Bool = false) async { ... }

    /// Sectioned view for OpenVotesListView: "Cierran pronto" (next 24h) vs "Abiertos".
    func sectioned() -> [(Section, [Vote])] { ... }

    enum Section: Hashable { case closingSoon, open }
}
```

Read-only del lado coordinator — la creación va por sheets independientes con sus propios coordinators.

### 2. `VoteDetailCoordinator`

```swift
@Observable @MainActor
final class VoteDetailCoordinator {
    let vote: Vote
    let group: Group
    private let userMemberId: UUID
    private let voteRepo: any VoteRepository
    private let castRepo: any VoteCastRepository

    private(set) var myCast: VoteCast?    // patrón existente — populated en refresh
    private(set) var counts: VoteCounts?
    private(set) var isCasting: Bool = false
    private(set) var error: String?

    var alreadyVoted: Bool { (myCast?.choice ?? .pending) != .pending }
    var voteIsClosed: Bool { vote.status != .open }

    init(...) { ... }
    func refresh() async { /* parallel myCast + counts */ }
    func cast(_ choice: VoteChoice) async { ... }
}
```

### 3. `VoteDetailView` (router)

```swift
struct VoteDetailView: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                VoteHeader(vote: coordinator.vote)
                bodyForType
                VoteCastSection(coordinator: coordinator)
            }
        }
        .task { await coordinator.refresh() }
    }

    @ViewBuilder
    private var bodyForType: some View {
        switch coordinator.vote.voteType {
        case .fineAppeal:      FineAppealVoteBody(coordinator: coordinator)
        case .generalProposal: GeneralProposalVoteBody(coordinator: coordinator)
        case .ruleChange:      RuleChangeVoteBody(coordinator: coordinator)
        default:               GenericVoteBody(coordinator: coordinator)
        }
    }
}
```

### 4. Bodies (V1 ships 4)

- **`FineAppealVoteBody`**: extraído de `VoteOnAppealSheet`. Muestra fine details (amount, reason, member, original event). Reusa rendering que ya pasa Apple-grade UX bar.
- **`GeneralProposalVoteBody`**: muestra `vote.title` + `vote.description` como markdown-ish. Sin payload structurado adicional.
- **`RuleChangeVoteBody`**: lee `vote.payload` con shape `{ "rule_id": uuid, "current_amount": int, "proposed_amount": int, "reason": text }`. Renderiza diff visual: regla actual (read-only del repo) vs propuesta. Cuando vote `passed`, server-side el rule engine aplica el cambio (no V1 client responsibility).
- **`GenericVoteBody`**: title + description + raw payload as JSON in monospace `RuulCard` (debug-style). Para V1 vote_types sin UI dedicada.

### 5. `VoteCastSection` (shared)

```swift
struct VoteCastSection: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        if coordinator.voteIsClosed {
            VoteResolvedView(counts: coordinator.counts)
        } else if coordinator.alreadyVoted {
            VoteAlreadyCastView(myChoice: coordinator.myCast?.choice)
        } else {
            VoteCastButtons(coordinator: coordinator)
        }
        if let counts = coordinator.counts, !coordinator.vote.isAnonymous || coordinator.alreadyVoted {
            VoteCountsBar(counts: counts)   // existing primitive
        }
    }
}
```

Tres estados mutuamente exclusivos. Counts se muestran solo si no anonymous OR el caller ya votó (transparencia post-cast).

**Sub-views privadas**: `VoteResolvedView`, `VoteAlreadyCastView`, `VoteCastButtons`, `VoteHeader` son `private struct` dentro de su archivo padre (ej. `VoteCastSection.swift`, `VoteDetailView.swift`). No archivos separados — solo el VoteCastSection top-level y los 4 bodies son top-level files. `VoteCountsBar` ya existe como primitive (`Features/Fines/Components/VoteCountsBar.swift`) y se reusa.

### 6. Creation sheets

**`CreateVoteSheet`**: picker simple. V1 enabled = `.generalProposal | .ruleChange`. V1 disabled = los otros 5 (gris + "coming soon" badge). Tap en enabled → push corresponding sheet.

**`CreateGeneralProposalSheet`**:
```
Title (required, 5-100 chars)
Description (optional, 0-500 chars)
Duration (default = governance.votingDurationHours, slider/picker)
[Submit]
```
Submit → `voteRepo.startVote(group.id, .generalProposal, UUID(), title, description, payload: .empty, durationHours: …)`. `referenceId` es un UUID sintético (no apunta a otro objeto). Server seedeará vote_casts pending para todos los miembros activos.

**`CreateRuleChangeSheet`**:
```
Pick rule (list of group rules with current state)
Reason (required, 5-200 chars — qué cambio + por qué)
Proposed amount (required, currency input — V1 solo permite cambiar amount, no la regla entera)
Duration (default = governance.votingDurationHours)
[Submit]
```
Submit → `voteRepo.startVote(group.id, .ruleChange, rule.id, title: "Cambio: \(rule.name)", description: reason, payload: .object(["proposed_amount": .int(...), "current_amount": .int(...)]))`.

**Por qué V1 solo permite cambio de amount**: el rule engine solo evalúa rules con shape estable. Cambiar trigger/conditions/consequences es V2. Amount es el cambio más común y bajo riesgo. Si pasa el vote, V1.5 implementa server-side application; por ahora `rule_change` que pasa solo emite `voteResolved` y el resultado queda en `votes.payload.resolution='passed'` — el founder tiene que aplicar manualmente desde EditRuleSheet. Documentado en spec.

## §3 — Data flow

### List flow

```
OpenVotesListView.onAppear
  → coordinator.refresh()
     → voteRepo.openVotes(for: group.id)        // SELECT * FROM votes WHERE group_id=X AND status='open'
     → coordinator.openVotes = result
     → coordinator.sectioned()                   // closing-soon vs other
  → render
```

### Detail flow + already-voted detection

Patrón existente verificado en `VoteCastRepository.myCast(voteId:userMemberId:)` (línea 14, 32, 72) y replicado de `AppealRepository.myVote(...)`.

```
VoteDetailView.task
  → coordinator.refresh()
     → async let myCastTask = castRepo.myCast(voteId: vote.id, userMemberId: ...)
     → async let countsTask = castRepo.counts(voteId: vote.id)
     → coordinator.myCast = await myCastTask
     → coordinator.counts = await countsTask
  → bodyForType renders based on vote.voteType
  → VoteCastSection renders based on voteIsClosed/alreadyVoted derived state
```

`alreadyVoted` deriva de `myCast?.choice != .pending`. `VoteChoice` enum tiene `.pending | .inFavor | .against | .abstained`. RLS de `vote_casts` retorna solo el ballot del caller (anonymity garantizada).

### Cast flow

```
User taps in_favor
  → coordinator.cast(.inFavor)
     → optimistic UI update (myCast = pending → inFavor temp local)
     → castRepo.cast(voteId: vote.id, choice: .inFavor)
        → throws if vote closed (mid-cast race condition — see §4)
     → coordinator.refresh()                     // re-fetch myCast + counts
  → VoteCastSection re-renders with VoteAlreadyCastView
```

### Create general_proposal flow

```
User taps "+" en OpenVotesListView
  → CreateVoteSheet
  → User picks .generalProposal
  → CreateGeneralProposalSheet
  → User fills + submits
     → coordinator.submit()
        → governance.canPerform(.createVotes, member, in: group) check
           → if .denied → surface error, abort
           → if .allowed → continue
           → if .requiresVote → not applicable for createVotes path; doc as unreachable
        → voteRepo.startVote(...)
        → returns vote_id
     → dismiss sheet
     → onCreated(voteId) → push VoteDetailView for fresh visibility
  → background: server emits voteOpened SystemEvent + outbox fan-out → push notifications a todos los miembros
```

### Create rule_change flow

```
User taps "+" en OpenVotesListView
  → CreateVoteSheet
  → User picks .ruleChange
  → CreateRuleChangeSheet
  → User picks rule + reason + proposed_amount + submits
     → coordinator.submit()
        → governance.canPerform(.createVotes, member, in: group) check (same gate)
        → voteRepo.startVote(group.id, .ruleChange, rule.id, title, reason, payload: { proposed_amount, current_amount })
     → dismiss + push VoteDetailView
  → background: same fan-out
```

## §4 — Error handling

### Standard errors

| Origen | Manifestación | UI response |
|---|---|---|
| `voteRepo.openVotes` network | `URLError`/`PostgrestError` | `ErrorStateView` (existing primitive) con retry |
| `castRepo.cast` 42501 (not authenticated) | RPC error | "Sesión expirada — re-loguea" + dismiss |
| `castRepo.cast` 42501 (not member) | RPC error | "No sos miembro elegible para este voto" |
| `governance.canPerform == .denied` | `GovernanceDecision` value | Sheet renderiza `RuulInfoCallout` con reason; submit button disabled |
| `governance.canPerform == .requiresVote` | Para `.createVotes` no aplica (sería loop infinito) — documentado como unreachable | n/a |
| `voteRepo.startVote` general error | RPC error | Toast `RuulToast` (existing primitive) "No pudimos abrir el voto" + log |

### Edge case — vote finalizes mid-cast

**Cuándo**: user abre `VoteDetailView`, el cron `finalize-votes` corre antes de que tappee in_favor, vote pasa a `resolved`. User tap → `cast_vote` RPC throws.

**Server contract**: `cast_vote` RPC verifica `vote.status = 'open'`. Si no, throws `vote_closed` (error code SQLSTATE).

**UI response**:
```swift
do {
    try await castRepo.cast(voteId: vote.id, choice: choice)
    await coordinator.refresh()
} catch let err as PostgrestError where err.code == "vote_closed" || err.message?.contains("not open") == true {
    coordinator.error = "Este voto ya cerró. Refrescamos resultados."
    // Refresh refreshes vote.status + counts. UI re-renders en VoteResolvedView path.
    await coordinator.refreshFromServer()  // re-fetch the Vote object too
}
```

UX: toast warning + automatic refresh. User ve resultado final inmediato sin perder navegación. Es decisión de UX, no requiere código nuevo del lado server.

### Edge case — already voted (race con otro device del mismo user)

**Cuándo**: user tiene 2 devices, vota desde uno, abre detail en el otro antes de que se sincronice. Tap cast → `cast_vote` actualiza el row.

**Server behavior**: idempotente. RPC permite re-cast (updates existing row). UX: nuestra cast wins. No special handling V1.

## §5 — Testing

### Coordinator tests (Swift Testing, mismo pattern que `EditRulesCoordinatorTests`)

```
TandasTests/Votes/
├── OpenVotesCoordinatorTests.swift
│   - testRefreshEmptyGroup
│   - testRefreshPopulatedSorting
│   - testSectionedClosingSoonVsOther
│   - testRefreshErrorSurfacesString
├── VoteDetailCoordinatorTests.swift
│   - testRefreshFetchesMyCastAndCountsInParallel
│   - testAlreadyVotedDerivesFromChoiceNotPending
│   - testCastFlowOptimisticThenRefresh
│   - testCastVoteClosedSurfacesEdgeMessage
│   - testCastNotAuthenticatedSurfacesError
│   - testAnonymousVoteHidesCountsBeforeCast
├── CreateGeneralProposalCoordinatorTests.swift
│   - testTitleValidationMinChars
│   - testTitleValidationMaxChars
│   - testGovernanceDeniedAbortsSubmit
│   - testSubmitSuccessReturnsVoteId
│   - testSubmitErrorSurfacesUserFacingMessage
└── CreateRuleChangeCoordinatorTests.swift
    - testRulePickerRequired
    - testProposedAmountValidationPositive
    - testPayloadCompositionShape
    - testSubmitWiresStartVoteWithRuleChangeType
```

### Snapshot tests del refactor `VoteOnAppealSheet → FineAppealVoteBody`

**Riesgo del refactor**: extraer el body puede romper bindings (mismo riesgo que Sub-fase C de Fase 0.5 con `EventDetailView`). Mitigación: snapshot test pixel-paridad antes/después.

**Cobertura**:
- VoteOnAppealSheet con `.pending` myCast — snapshot pre-refactor + post-refactor idénticos.
- VoteOnAppealSheet con `.inFavor` (already voted) — idem.
- VoteOnAppealSheet con vote `resolved` (closed) — idem.

Si snapshot fail, abortar refactor y reabrir conversación.

### E2E test flow (manual, documentado en plan)

1. Founder abre app → "+" en OpenVotesListView → general_proposal con title "Test" → submit.
2. Otro miembro recibe push (verificado con APNs sandbox).
3. Otro miembro abre app → ve vote en su Inbox `votePending` row.
4. Tap → VoteDetailView with GeneralProposalVoteBody.
5. Tap "in_favor" → cast → counts update.
6. Cron `finalize-votes` corre cuando `closes_at` pasa (test acelera setting `votingDurationHours=0` para snapshot).

## §6 — DoD

- [ ] `Features/Votes/` directory creado con 14 archivos según §1 (4 coordinators + 1 list view + 1 router + 4 bodies + 3 sheets + 1 shared cast section).
- [ ] `OpenVotesListView` consume `voteRepo.openVotes(for:)`, sectioned por urgencia (closing-soon < 24h vs other).
- [ ] `VoteDetailView` router dispatch funciona para los 4 vote_type cases (3 specific bodies + 1 generic fallback).
- [ ] `FineAppealVoteBody` extraído de `VoteOnAppealSheet`; sheet existente preserva entry point envolviendo el nuevo body; snapshot test verde para 3 estados (pending myCast / inFavor cast / vote resolved).
- [ ] `CreateGeneralProposalSheet` y `CreateRuleChangeSheet` shippean funcional con `GovernanceService.canPerform(.createVotes, ...)` gating.
- [ ] `CreateVoteSheet` (vote_type picker) habilita solo `.generalProposal | .ruleChange`; los otros 5 disabled con "coming soon" badge.
- [ ] `ActionInboxView` renderiza `ActionType.votePending` (pre-existing enum case) y navega a `VoteDetailView`.
- [ ] `RulesView` muestra sección "Votos abiertos" con count + link a `OpenVotesListView`.
- [ ] Tests verdes: 4 coordinator test files (Swift Testing) + snapshot tests del refactor `VoteOnAppealSheet`.
- [ ] Build clean: `xcodebuild build` (main target) + `xcodebuild build-for-testing` (test target).
- [ ] Manual smoke: founder crea general_proposal, otro miembro recibe push (verifica via outbox SQL `SELECT * FROM notifications_outbox WHERE notification_type='voteOpened'`), cast → counts update, finalize cron resuelve.

## §7 — Riesgos y mitigación

| Riesgo | Severidad | Mitigación |
|---|---|---|
| Refactor `VoteOnAppealSheet` rompe bindings/navigation | Alta | Snapshot test obligatorio pre/post; si fail, abortar y discutir |
| `vote_counts_view` tiene forma distinta a la asumida | Media | Verificada en `VoteCastRepository.swift:84-99` — shape `(vote_id, in_favor, against, abstained, pending, total_eligible)` ✓ |
| `cast_vote` RPC throws cuando vote ya cerró pero código de error es ambiguo | Baja | El `catch let err as PostgrestError` matchea por message string como fallback además de SQLSTATE |
| Generic body con payload-as-JSON se ve feo | Baja | Es debug-style intencional para V1. V2 ships per-type bodies |
| `governance.canPerform` no captura el caso "founder no, miembros sí" para createVotes | Media | Default per template es `.anyMember` para createVotes — verificado en `Platform/Models/GovernanceRules.swift:25-27`. Si user override governance a `.founder` only y try crear como member, surface clear error message |
| `notifications_outbox` se llena con vote rows sin que la app las consuma | Baja | Dispatcher cron las dispatcha automáticamente. iOS recibe push. Si app está closed iOS guarda. No hay leak |

## §8 — Cómo arrancar

Spec → user approval → invocar `superpowers:writing-plans` skill para producir el plan de implementación con tasks TDD-style. El plan dividirá las 13 archivos en tasks atómicos por commit, con tests primero donde aplique. Estimado 5-7h focused work.
