# V27 — Founder Identity vs Founder Role

> **Status:** Doctrinal analysis. Not implementation. Reference for
> Phase 6+ when transferring founder identity becomes a real product
> requirement.
>
> Origin: RolesAudit_2026-05-17.md V27 (DOCTRINAL AMBIGUITY).
> Companion: RolesRemediation_2026-05-17.md final entry.

## The ambiguity

Today "founder" is two different things sharing one name:

| | Field | Semantic | Mutable? | Where it's enforced |
|---|---|---|---|---|
| **Founder as identity** | `groups.created_by uuid` | The single user who created the group | NO (no migration ever updates it) | RLS `groups_select_archived_founder` (mig 00184), `group_members_with_founder.is_founder` view |
| **Founder as role** | `group_members.roles ? 'founder'` | A member who holds the founder role bundle | YES (assign_role, unassign_role, delete_group_role cascade) | `has_permission` resolver, `is_group_admin` (post mig 00301), `actorHasRole` rule condition |

The two are conflated in the V1 default seed:
- `create_group_with_admin` (mig 00128) sets `created_by = auth.uid()` AND inserts the seed membership with `roles = ['founder', 'member']`.
- So at group creation, the founder identity and the founder role are the same user.

But they CAN diverge:
- `assign_role(other_user, 'founder')` + `unassign_role(creator, 'founder')` produces a group whose `created_by` user holds NO 'founder' role, and whose 'founder' role is held by someone else.
- The catalog can drop the 'founder' role entirely via... actually mig 00230 protects 'founder' as a system role that can't be deleted. OK that's safe.
- A custom role re-using id `'founder'`? Also protected.

So the divergence happens via member-level role mutation, not catalog mutation. Today no UI surfaces founder-role transfer; the conflation is invisible to users.

## Why it matters

Three concrete product implications:

1. **Transferring fundamentación**. Founders eventually want to leave a group cleanly. Today `unassign_role(creator, 'founder')` would block via the last-founder safeguard (mig 00229). Even if it didn't, `created_by` still points at the original creator forever — so RLS `groups_select_archived_founder` keeps showing them archived groups they no longer participate in. The current model has no clean "I am no longer this group's founder" pathway.

2. **`is_founder` semantics**. The recreated view (mig 00303) defines `is_founder = roles ? 'founder' AND user_id = created_by`. That's a CONJUNCTION — both must hold. Once the two diverge, the view returns false for both the original creator (no role) AND the new role-holder (not created_by). Nobody is "founder" in the view.

3. **Permission resolution**. `has_permission` reads role permissions. If you transfer the role away from the creator, the creator loses founder-bundle permissions immediately — even though `groups_select_archived_founder` still admits them as the "owner" of archived groups. Inconsistent.

## Three possible models

### Option A — Status quo, document the conflation

- Keep `created_by` as immutable identity record (provenance only)
- Keep `roles ? 'founder'` as the authoritative capability holder
- Document explicitly: `created_by` is NOT a capability check; it's only a historical record. RLS that uses it (only `groups_select_archived_founder` today) should be reconsidered as Phase 6 work.
- `is_founder` view semantic: use `roles ? 'founder'` only (drop the created_by tie-break). The view's name becomes slightly misleading for groups where founder-role-holder ≠ creator, but no production code today actually consults it for capability decisions.

**Effort:** ~1 migration (update `is_founder` view), prose doc updates.
**Risk:** Low — no semantic break for current data.
**Limits:** Doesn't enable founder transfer UX. Original creator still appears in archived-groups view forever. Doctrinal consistency improves but the immutable-identity baggage remains.

### Option B — Materialize founder identity as a Right

Per RightRules + Right.md: anything with identity, lifecycle, transfer/delegate/revoke semantic should be a `resource(type='right')`.

- On group creation, auto-create `right(type='founder_share', holder=creator, target=group, transferable=true, exclusive=true, delegable=false)`.
- The right's holder is the authoritative source for "who is the founder right now".
- `created_by` becomes pure historical record (timestamp + first holder).
- Founder transfer = `transfer_right(founder_share_id, new_member)` — emits `rightTransferred` atom; new holder gains founder bundle (via right-grants-permissions wiring, which today is V7 deferred — `actorHasPermission` reads roles, not rights).
- RLS `groups_select_archived_founder` becomes "I am the current holder of this group's founder_share right" — joined via `right_state_view`.

**Effort:** medium. Requires:
- Mig: backfill `right(type='founder_share')` for every existing group.
- Mig: `create_group_with_admin` also creates the right.
- Mig: update `groups_select_archived_founder` RLS to join right_state_view.
- Mig: `transfer_right` for founder_share triggers cascade to assign/unassign the 'founder' role (or vice versa — pick one as authoritative).
- Doctrine: decide whether the role is auto-derived from the right, or whether they remain orthogonal (right = identity, role = capability bundle).

**Risk:** medium. Touches resources table semantics + RLS + create_group_with_admin. Doable but cascading.

**Wins:**
- Founder transfer becomes a first-class operation with atom emission.
- "Owner" of any resource (group, fund, asset, etc.) can use the same right primitive.
- Eliminates `groups.created_by` as a special-cased authorization input.

### Option C — Keep both, but de-link in code

- `created_by` stays as creator-of-record (mutable=NO).
- `roles ? 'founder'` stays as capability holder (mutable=YES).
- Doctrine declares them ORTHOGONAL: nothing in code should ever check both together (no AND, no OR).
- `is_founder` view dropped or renamed to `is_role_founder`.
- `groups_select_archived_founder` RLS dropped or replaced with `roles ? 'founder'` only.
- Founder transfer = `assign_role(new, 'founder')` + `unassign_role(old, 'founder')` (already possible). No UX yet but the contract is clean.

**Effort:** ~2 migrations (RLS rewrite + view rename), minor iOS update.
**Risk:** Low.
**Wins:** Clean separation without inventing new primitives. Pragmatic.
**Limits:** "Founder" as identity becomes a historical detail (only first creator). Some users may want lifecycle on identity (e.g. "the founder who built this group" — who? the original creator or the current role holder?).

## Recommendation

**Start with Option C.** It's the minimum needed to remove the conflation from doctrine, costs little, and doesn't preclude Option B later.

**Option B is the long-term direction** if founder transfer becomes a real product feature. The right resource model already exists; making founder identity one more right is natural.

**Option A is acceptable if no transfer feature is on the roadmap.** It's the cheapest doctrinal fix.

## Open questions for the founder (the human)

1. Is founder transfer a Beta-2 / V2 / Year-2 feature?
2. When a group's creator leaves, should the group archive automatically, or should it survive with a new admin?
3. Should "founder" be a HUMAN-FACING role label, or is it a system internal? (Today it's user-visible in MembersList badges.)
4. Per V7 condition `actorHasRole`: do we want rule authors to be able to write rules that test "is the founder"? If yes, founder must be label-detectable. If no, we can drop the user-facing label entirely.

## Decision log

| Date | Decision | Author |
|---|---|---|
| 2026-05-17 | Document the ambiguity. No implementation pending product clarity on founder-transfer feature. | (Sprint A→F closeout — implementation deferred) |

---

When the answer to "should founder be transferable?" lands, this doc gets updated with the chosen option and migration plan.
