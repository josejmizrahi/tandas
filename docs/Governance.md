# Governance

Each group carries a `governance` jsonb that determines who can do what.
Founder default ≠ permanent default — the founder can reconfigure via
`GovernanceConfigView` (Bloque 6) at any time.

## Permission levels

Defined in `Platform/Models/PermissionLevel.swift`.

| Level | Who passes | When to use |
|---|---|---|
| `founder` | Members with `MemberRole.founder` | Default for sensitive ops |
| `anyMember` | Any active member | Open / democratic groups |
| `majorityVote` | Successful vote with ≥50% threshold | Decisions that require consensus |
| `supermajorityVote` | Successful vote with ≥66% threshold | Member removal, governance changes |
| `host` | Host of the contextual event | `closeEvents` action |
| `treasurer` | Members with `MemberRole.treasurer` (V2) | Fund actions |

`GovernanceService.canPerform` returns:
- `.allowed` — perform immediately
- `.requiresVote(quorum, threshold)` — caller opens a Vote, acts on resolution
- `.denied(reason)` — show error

## Actions

Defined in `Platform/Models/GovernanceAction.swift`. Each maps to one
`whoCan*` key in `groups.governance`.

| Action | Default for `recurring_dinner` |
|---|---|
| `modifyRules` | `founder` |
| `inviteMembers` | `founder` |
| `removeMembers` | `majorityVote` |
| `closeEvents` | `host` |
| `createVotes` | `anyMember` |
| `modifyGovernance` | `founder` |

## Voting parameters

Live in `governance` alongside the action permissions:

| Key | Default | Range | Purpose |
|---|---|---|---|
| `votingQuorumPercent` | 50 | 25–100 | Min % of group that must vote |
| `votingThresholdPercent` | 50 | 50–75 | % in_favor to pass |
| `votingDurationHours` | 72 | 24–168 | How long votes stay open |
| `votesAreAnonymous` | true | bool | Hide individual ballots in views |

The `start_vote` RPC reads these defaults if the caller doesn't override.
The `finalize_vote` RPC computes resolution against quorum + threshold.

## Wiring permission checks at action sites

Don't hardcode `member.role == "admin"`. Always go through
`GovernanceService`:

```swift
let governance = GovernanceService()
let decision = await governance.canPerform(
    .modifyRules,
    member: currentMember,
    in: activeGroup
)
switch decision {
case .allowed:
    // proceed
case .requiresVote(let quorum, let threshold):
    // open vote with these params, return — wait for vote_resolved
case .denied(let reason):
    // show "Solo el founder puede cambiar las reglas" or similar
}
```

For `.closeEvents`, pass `.event(hostId: event.hostId)` as `context`.

## Updating governance

`GroupsRepository.updateGovernance(groupId:rules:)` writes the full
`governance` jsonb. RLS policy `groups_update_admin` gates direct UPDATE
to founders. Future: add `update_group_governance(p_group_id, p_governance)`
RPC that consults `whoCanModifyGovernance` and either applies directly or
opens a `governance_change` vote.

## Governance-change governance (the meta layer)

Governance itself is governable. The key `whoCanModifyGovernance` is
**self-referential**: changing it requires whoever the *current* value
permits.

**Default for `recurring_dinner`**: `founder` — the founder can rewrite
the social contract unilaterally. Pragmatic for V1 since groups start
small with high trust in the founder.

**Recommended migration once a group is mature**:

```swift
// Founder upgrades governance to require supermajority for future
// changes — this is the irreversibility safeguard.
let next = current.with(\.whoCanModifyGovernance, .supermajorityVote)
try await groupsRepo.updateGovernance(groupId: g.id, rules: next)
```

After this update, **the founder can no longer reset** `whoCanModifyGovernance`
back to `founder` without a successful supermajority vote — `GovernanceService`
returns `.requiresVote(quorum, threshold)` for `.modifyGovernance`.

**Vote flow when `modifyGovernance` requires a vote**:

1. Caller invokes `GovernanceService.canPerform(.modifyGovernance, …)`.
2. Result `.requiresVote(quorum, threshold)` → caller opens
   `start_vote(vote_type='governance_change', reference_id=group_id, payload={proposedRules})`.
3. Members vote within `votingDurationHours`.
4. `finalize_vote` checks quorum + threshold; on pass, applies the
   proposed `governance` jsonb to the group atomically.

**Anti-tyranny rationale**: founders who keep `whoCanModifyGovernance =
founder` are explicitly choosing dictator-of-friends mode. Groups that
want collective ownership should set this to `supermajorityVote` early
and accept that they're locking themselves out of fast iteration.

> Phase 2+ work: ship the `governance_change` vote_type case in
> `start_vote` (today only `fine_appeal` and `rule_change` are wired).
> Until then, the doctrinal stance is that the column is permission-
> gated but the vote-opening UI doesn't exist for non-founder paths.

## Why configurable governance is the platform's USP

Hardcoded "founder edits" makes ruul a single-leader app. The point of
the platform is that **every group writes its own social contract**.
Some groups want full democracy, others want a founder dictator, others
want a treasurer with fund control. Governance is the lever that lets all
those shapes coexist on the same primitives.
