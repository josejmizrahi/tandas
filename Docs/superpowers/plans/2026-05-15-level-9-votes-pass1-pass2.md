# Level 9 Workflow/Votes — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Enable member_removal vote flow + manual finalize + cancel vote.

**Architecture:** Pass 1 wires the member_removal creation path (FE-only since `MemberRemovalVoteBody.swift` already exists). Pass 2 adds `cancel_vote` BE RPC + manual finalize/cancel buttons.

**Tech Stack:** SwiftUI iOS 26+, Swift 6, Supabase RPC.

**Source spec:** `docs/superpowers/specs/2026-05-15-level-9-workflow-votes.md`.

---

## Verified facts

- `MemberRemovalVoteBody.swift` ALREADY EXISTS — Pass 1 skips creating it.
- `VoteRepository` has `startVote(...)` + `finalizeVote(...)` — needs `cancelVote(...)`.
- `CreateVoteSheet` has memberRemoval card already, but disabled. Enable it + wire to new create flow.
- `VoteType.memberRemoval` enum case exists.
- `start_vote` BE excludes `payload.target_member_id` from eligible voters (mismo pattern como fine_appeal infractor — confirmar en mig).
- `app.voteRepo: any VoteRepository`, `app.groupsRepo`, modal policy `.fullScreenCover`.

---

## Pass 1 — Member removal flow (3 tasks)

### Task 1: `CreateMemberRemovalCoordinator` + `CreateMemberRemovalSheet`

**Files:** create both in `Features/Votes/Coordinator/` and `Features/Votes/Sheets/`.

Coordinator (~100 L):

```swift
import Foundation
import Observation
import OSLog
import RuulCore

@Observable
@MainActor
public final class CreateMemberRemovalCoordinator {
    public let group: RuulCore.Group
    public let creatorMemberId: UUID
    private let voteRepo: any VoteRepository
    private let groupsRepo: any GroupsRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote.member-removal")

    public var members: [MemberWithProfile] = []
    public var target: MemberWithProfile?
    public var reason: String = ""
    public var durationHours: Int = 72
    public var isLoading: Bool = false
    public var isSubmitting: Bool = false
    public var error: CoordinatorError?
    public var createdVoteId: UUID?

    /// Pre-filled target (when opened from MembersAdminView swipe).
    public init(
        group: RuulCore.Group,
        creatorMemberId: UUID,
        prefilledTarget: MemberWithProfile? = nil,
        voteRepo: any VoteRepository,
        groupsRepo: any GroupsRepository
    ) {
        self.group = group
        self.creatorMemberId = creatorMemberId
        self.target = prefilledTarget
        self.voteRepo = voteRepo
        self.groupsRepo = groupsRepo
    }

    public func loadMembers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let all = try await groupsRepo.membersWithProfiles(of: group.id)
            members = all.filter { $0.member.active && $0.member.id != creatorMemberId }
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar los miembros")
        }
    }

    public var isReadyToSubmit: Bool {
        target != nil && reason.trimmingCharacters(in: .whitespaces).count >= 30
    }

    public func submit() async {
        guard let target, isReadyToSubmit else { return }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        let title = "Quitar a \(target.displayName)"
        let payload: JSONConfig = .object([
            "target_member_id": .string(target.member.id.uuidString.lowercased()),
            "reason": .string(reason)
        ])
        do {
            let voteId = try await voteRepo.startVote(
                groupId: group.id,
                voteType: .memberRemoval,
                referenceId: target.member.userId,
                title: title,
                description: reason,
                payload: payload,
                durationHours: durationHours
            )
            createdVoteId = voteId
        } catch {
            log.warning("memberRemoval submit failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos iniciar el voto")
        }
    }
}
```

NOTE: confirm `VoteRepository.startVote` signature with `grep -n "func startVote" ios/Packages/RuulCore/Sources/RuulCore/Repositories/VoteRepository.swift`. The signature above is plausible; if different (e.g., `payload` is named `payload` vs `voteContext`), adapt.

Sheet (~180 L):

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct CreateMemberRemovalSheet: View {
    @Bindable var coordinator: CreateMemberRemovalCoordinator
    @Environment(\.dismiss) private var dismiss

    public init(coordinator: CreateMemberRemovalCoordinator) {
        self._coordinator = Bindable(wrappedValue: coordinator)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    warning
                    targetPicker
                    reasonInput
                    durationPicker
                    if let err = coordinator.error {
                        Text(err.message ?? err.title)
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle("Proponer remoción")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(coordinator.isSubmitting ? "Enviando…" : "Iniciar voto") {
                        Task {
                            await coordinator.submit()
                            if coordinator.createdVoteId != nil { dismiss() }
                        }
                    }
                    .disabled(!coordinator.isReadyToSubmit || coordinator.isSubmitting)
                }
            }
            .task { if coordinator.members.isEmpty { await coordinator.loadMembers() } }
        }
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.ruulWarning)
            Text("Si el voto pasa, el admin deberá ejecutar la remoción manualmente desde la pantalla de Miembros.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("¿A QUIÉN?").ruulTextStyle(RuulTypography.sectionLabel).foregroundStyle(Color.ruulTextTertiary)
            if coordinator.isLoading {
                ProgressView()
            } else if coordinator.target != nil {
                Button {
                    coordinator.target = nil
                } label: {
                    HStack {
                        RuulAvatar(name: coordinator.target!.displayName, imageURL: coordinator.target!.avatarURL, size: .medium)
                        Text(coordinator.target!.displayName)
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer()
                        Text("Cambiar").ruulTextStyle(RuulTypography.caption).foregroundStyle(Color.ruulAccent)
                    }
                    .padding(RuulSpacing.md)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(coordinator.members, id: \.id) { m in
                        Button(m.displayName) { coordinator.target = m }
                    }
                } label: {
                    HStack {
                        Text("Elegir miembro")
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextSecondary)
                        Spacer()
                        Image(systemName: "chevron.down")
                    }
                    .padding(RuulSpacing.md)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
                }
            }
        }
    }

    private var reasonInput: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("RAZÓN").ruulTextStyle(RuulTypography.sectionLabel).foregroundStyle(Color.ruulTextTertiary)
            TextField("Por qué propones esta remoción…", text: $coordinator.reason, axis: .vertical)
                .lineLimit(4...8)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
            Text("Mínimo 30 caracteres (actual: \(coordinator.reason.trimmingCharacters(in: .whitespaces).count))")
                .ruulTextStyle(RuulTypography.footnote)
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("DURACIÓN").ruulTextStyle(RuulTypography.sectionLabel).foregroundStyle(Color.ruulTextTertiary)
            Picker("Duración", selection: $coordinator.durationHours) {
                Text("48h").tag(48)
                Text("72h").tag(72)
                Text("1 semana").tag(168)
            }
            .pickerStyle(.segmented)
        }
    }
}
```

Build + commit.

### Task 2: Enable memberRemoval in CreateVoteSheet

Modify `Features/Votes/Sheets/CreateVoteSheet.swift` — find the memberRemoval card with `.disabled(!enabled)` (line ~104). Set its `enabled = true` for the case `.memberRemoval`. Tap action should present `CreateMemberRemovalSheet` (via `@State` flag or callback to parent).

Inspect the existing structure first:
```bash
sed -n '90,120p' ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Votes/Sheets/CreateVoteSheet.swift
```

Add `@State private var showMemberRemoval = false` + `.fullScreenCover(isPresented: $showMemberRemoval) { CreateMemberRemovalSheet(coordinator: ...) }`. Wire the card's button action.

Build + commit.

### Task 3: MembersAdminView swipe action

Modify `Features/Members/Views/MembersAdminView.swift`. Add a new swipe action "Proponer remoción" alongside the existing "Echar" — opens `CreateMemberRemovalSheet` with `prefilledTarget: row`.

```swift
.swipeActions(edge: .trailing) {
    if row.member.userId != coordinator.actorUserId {
        Button(role: .destructive) {
            memberToKick = row
        } label: {
            Label("Echar", systemImage: "trash")
        }
        Button {
            proposeRemovalFor = row
        } label: {
            Label("Proponer voto", systemImage: "checkmark.bubble")
        }
        .tint(Color.ruulWarning)
    }
}
```

Add `@State private var proposeRemovalFor: MemberWithProfile?` + `.fullScreenCover(item: $proposeRemovalFor) { row in ... CreateMemberRemovalSheet ... }`.

Build + commit + tag `level9-pass1-complete`.

---

## Pass 2 — Cancel vote + manual finalize (3 tasks)

### Task 4: BE migration `cancel_vote` RPC

Create `supabase/migrations/00207_cancel_vote.sql`:

```sql
-- Mig 00207: cancel_vote RPC — creator can cancel an open vote that
-- has no real casts yet (only pre-seeded `pending` rows allowed).
-- Once anyone has actually cast (in_favor/against/abstained), the
-- vote must run to finalization.

create or replace function public.cancel_vote(p_vote_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_vote votes%rowtype;
    v_caller_member uuid;
    v_real_casts int;
begin
    select * into v_vote from votes where id = p_vote_id;
    if not found then
        raise exception 'vote_not_found' using errcode = 'P0001';
    end if;
    if v_vote.status <> 'open' then
        raise exception 'vote_not_open' using errcode = 'P0001';
    end if;

    select id into v_caller_member
    from group_members
    where group_id = v_vote.group_id and user_id = auth.uid() and active = true;
    if v_caller_member is null then
        raise exception 'not_member' using errcode = 'P0001';
    end if;

    if v_vote.created_by_member_id is distinct from v_caller_member then
        raise exception 'not_creator' using errcode = 'P0001';
    end if;

    -- Use the same DISTINCT ON pattern as vote_counts_view: latest per
    -- (vote, member). If any latest is non-pending, the vote can't be
    -- cancelled.
    select count(*) into v_real_casts
    from (
        select distinct on (member_id) choice
        from vote_casts
        where vote_id = p_vote_id
        order by member_id, created_at desc
    ) latest
    where choice in ('in_favor', 'against', 'abstained');

    if v_real_casts > 0 then
        raise exception 'votes_already_cast' using errcode = 'P0001';
    end if;

    update votes
    set status = 'cancelled', resolved_at = now()
    where id = p_vote_id;

    perform public.record_system_event(
        v_vote.group_id,
        'voteResolved',
        jsonb_build_object(
            'vote_id', p_vote_id,
            'vote_type', v_vote.vote_type,
            'resolution', 'cancelled',
            'cancelled_by_member_id', v_caller_member
        )
    );
end;
$$;

grant execute on function public.cancel_vote(uuid) to authenticated;
```

Apply via `mcp__supabase__apply_migration` or local CLI. Confirm the `record_system_event` function name (may be `emit_system_event` — adapt).

### Task 5: VoteRepository.cancelVote

Add to `Repositories/VoteRepository.swift`:

```swift
// In protocol:
func cancelVote(_ voteId: UUID) async throws

// In LiveVoteRepository:
public func cancelVote(_ voteId: UUID) async throws {
    try await client
        .rpc("cancel_vote", params: ["p_vote_id": voteId.uuidString.lowercased()])
        .execute()
}

// In MockVoteRepository:
public func cancelVote(_ voteId: UUID) async throws {
    // Mark as cancelled in mock state if you track state. Otherwise no-op.
}
```

Build + commit.

### Task 6: Manual finalize + cancel buttons in VoteDetailView

Modify `Features/Votes/Detail/VoteDetailView.swift`. Add at the bottom of body:

```swift
adminActionsSection

@ViewBuilder
private var adminActionsSection: some View {
    if coordinator.vote.status == "open" {
        VStack(spacing: RuulSpacing.sm) {
            if shouldShowFinalize {
                Button("Finalizar voto ahora") {
                    Task { await coordinator.finalizeManually() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.ruulAccent)
            }
            if shouldShowCancel {
                Button("Cancelar voto", role: .destructive) {
                    Task { await coordinator.cancelVote() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, RuulSpacing.xl)
    }
}

private var shouldShowFinalize: Bool {
    // Admin only + deadline passed
    isCurrentUserAdmin && Date.now > coordinator.vote.closesAt
}

private var shouldShowCancel: Bool {
    // Creator only + no real casts yet
    isCurrentUserCreator && (coordinator.counts?.inFavor ?? 0) + (coordinator.counts?.against ?? 0) + (coordinator.counts?.abstained ?? 0) == 0
}
```

Add `finalizeManually()` and `cancelVote()` methods to `VoteDetailCoordinator`:

```swift
public func finalizeManually() async {
    do {
        _ = try await voteRepo.finalizeVote(voteId: vote.id)
        await refresh()
    } catch {
        self.error = CoordinatorError.from(error, fallback: "No pudimos finalizar el voto")
    }
}

public func cancelVote() async {
    do {
        try await voteRepo.cancelVote(vote.id)
        await refresh()
    } catch {
        self.error = CoordinatorError.from(error, fallback: "No pudimos cancelar el voto")
    }
}
```

The `isCurrentUserAdmin` / `isCurrentUserCreator` checks need the user's member id + groupDetail.myRole. Likely already available on the coordinator or app state — adapt.

Build + commit + tag `level9-pass2-complete`.

---

## Done When

- 6 tasks committed.
- CreateVoteSheet has memberRemoval enabled and tappable.
- MembersAdminView swipe shows "Proponer voto".
- VoteDetailView for open votes shows admin "Finalizar" when deadline passed + creator "Cancelar" when no casts.
- BE has `cancel_vote` RPC deployed.
- Build clean.
- Two tags: `level9-pass1-complete`, `level9-pass2-complete`.

---

## Out of Scope

- `apply_member_removal_on_pass` trigger (Pass 3)
- Auto-finalize cron (Pass 4)
- rule_repeal / fund_withdrawal / role_assignment / slot_dispute bodies + flows
- Anonymous toggle UI
- Vote extension
