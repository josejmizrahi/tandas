# Tandas Phase 3: Rules + Votes Implementation Plan

> Builds on Phase 1 + Phase 2. Adds the democratic backbone: members propose rules, vote on them, rules activate on pass. Admins can archive rules. Each rule has per-member exceptions.

**Goal:** Cualquier miembro propone una regla → la app abre votación → si pasa el quórum + umbral, la regla se activa sola y queda lista para que el motor de Phase 4 la aplique en eventos cerrados. Las reglas tienen excepciones por miembro (David exento de la regla X). Las reglas pasadas pueden derogar­se vía vote `rule_repeal`.

**Architecture:** Two new feature modules: `features/rules/` and `features/votes/`. Votes don't have their own tab — they live inside their subject (rule proposal sheet, fine appeal sheet later). One small migration adds a `cast_ballot` RPC for atomic upsert. All other DB ops go through existing `propose_rule`, `create_vote`, `close_vote` RPCs (already in cloud) or direct table writes via RLS.

**Tech stack:** Same as Phase 1+2 (Next 16, Supabase, shadcn). New shadcn primitives: `progress` (for vote tally bar), `radio-group` (for ballot choice), `accordion` (for rule history per group).

---

## Roadmap context

| Phase | Status |
|---|---|
| 1 | ✅ shipped |
| 2 | ✅ shipped |
| **3 (this)** | ⏳ |
| 4 | pending — fines |
| 4.5 | pending — anti-tiranía |
| 4.6 | pending — tipología + onboarding cultural |
| 7+ | notifs/push/cron + PWA + memoria |

---

## File Structure

### Created

```
supabase/migrations/00006_phase3_votes.sql

components/ui/{progress,radio-group,accordion}.tsx              # shadcn add

features/rules/
  presets.ts                  # 7 built-in rule presets (late_arrival, no_confirmation, etc)
  schemas.ts
  queries.ts
  actions.ts
  components/
    RulesList.tsx
    RuleCard.tsx
    RuleStatusBadge.tsx
    RulePresetPicker.tsx
    ProposeRuleForm.tsx
    RuleExceptionsEditor.tsx
    RuleArchiveDialog.tsx
  index.ts

features/votes/
  schemas.ts
  queries.ts
  actions.ts
  components/
    VoteSheet.tsx              # ballot casting + tally bar + close button
    VoteTallyBar.tsx           # progress bar yes/no/abstain
    OpenVotesList.tsx          # for /hoy
  index.ts

app/g/[gid]/reglas/page.tsx              # MODIFY: replace stub with RulesList
app/g/[gid]/reglas/[rid]/page.tsx        # CREATE: RuleCard + VoteSheet + Exceptions
app/g/[gid]/reglas/proponer/page.tsx     # CREATE: ProposeRuleForm

app/g/[gid]/hoy/page.tsx                 # MODIFY: append OpenVotesList
```

### Modified

```
features/rules/index.ts    # barrel for everything
features/votes/index.ts    # barrel for everything
lib/db/types.ts            # regenerated after 00006
```

---

## Conventions

Same as Phase 1+2. `mcp__claude_ai_Supabase__apply_migration` for cloud. ESLint boundaries forbid feature→feature imports — `features/rules/` does NOT import `features/votes/` (and vice versa) directly. Vote-related UI used inside rule pages comes from `features/votes/` via `app/g/[gid]/reglas/[rid]/page.tsx` composing both.

---

## Tasks

### Task 1: Add shadcn progress + radio-group + accordion

```bash
npx shadcn@latest add progress radio-group accordion --yes
```

Verify lint+typecheck+build, commit `chore(ui): add progress, radio-group, accordion primitives`.

### Task 2: Migration 00006 — cast_ballot RPC

```sql
-- Phase 3: votes RPC.
-- cast_ballot: atomic upsert of a user's ballot for an open vote.
-- Replaces a prior ballot from the same user (vote_ballots is UNIQUE on
-- (vote_id, user_id), but we want the cleanest "change my mind" UX).

create or replace function public.cast_ballot(p_vote_id uuid, p_choice text)
returns public.vote_ballots
language plpgsql security definer set search_path = public as $$
declare
  v public.votes;
  ballot public.vote_ballots;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if p_choice not in ('yes','no','abstain') then
    raise exception 'invalid choice: %', p_choice;
  end if;

  select * into v from public.votes where id = p_vote_id;
  if not found then raise exception 'vote not found'; end if;
  if v.status <> 'open' then raise exception 'vote is closed'; end if;
  if not public.is_group_member(v.group_id, auth.uid()) then raise exception 'not a member'; end if;
  if v.committee_only and not public.is_group_committee(v.group_id, auth.uid()) then
    raise exception 'committee only';
  end if;

  insert into public.vote_ballots (vote_id, user_id, choice, cast_at)
  values (p_vote_id, auth.uid(), p_choice, now())
  on conflict (vote_id, user_id)
  do update set choice = excluded.choice, cast_at = now()
  returning * into ballot;
  return ballot;
end;
$$;
revoke execute on function public.cast_ballot(uuid, text) from public, anon;
grant  execute on function public.cast_ballot(uuid, text) to authenticated;
```

Apply via Supabase MCP, regenerate types, commit `feat(db): migration 00006 — cast_ballot RPC` + `chore(db): regenerate types after 00006`.

### Task 3: Rule presets library

Create `features/rules/presets.ts` with 7 presets:

```ts
export type RulePreset = {
  code: string
  title: string
  description: string
  trigger: { type: string; params?: Record<string, unknown> }
  action: { type: 'fine'; params?: { amount?: number } }
}

export const RULE_PRESETS: RulePreset[] = [
  {
    code: 'late_arrival',
    title: 'Llegada tarde',
    description: 'Multa escalonada por llegar tarde después de la hora de inicio.',
    trigger: {
      type: 'late_arrival',
      params: { start_threshold_time: '20:30', step_minutes: 30, base_amount: 200, step_increment: 50, max_amount: 500 },
    },
    action: { type: 'fine', params: { amount: 200 } },
  },
  {
    code: 'no_confirmation',
    title: 'No confirmar a tiempo',
    description: 'Multa fija si no respondes RSVP antes del deadline.',
    trigger: { type: 'no_confirmation', params: { deadline_offset_hours: 24, fixed_amount: 200 } },
    action: { type: 'fine', params: { amount: 200 } },
  },
  {
    code: 'same_day_cancel',
    title: 'Cancelar el mismo día',
    description: 'Multa fija si cancelas tu asistencia el mismo día del evento.',
    trigger: { type: 'same_day_cancel', params: { fixed_amount: 200 } },
    action: { type: 'fine', params: { amount: 200 } },
  },
  {
    code: 'no_show',
    title: 'No-show',
    description: 'Multa fija si confirmaste y no llegaste sin avisar.',
    trigger: { type: 'no_show', params: { fixed_amount: 300 } },
    action: { type: 'fine', params: { amount: 300 } },
  },
  {
    code: 'host_skip_no_notice',
    title: 'Anfitrión sin avisar',
    description: 'Multa al anfitrión que no avisa con tiempo que no puede hostear.',
    trigger: { type: 'host_skip_no_notice', params: { notice_hours: 48, fixed_amount: 300 } },
    action: { type: 'fine', params: { amount: 300 } },
  },
  {
    code: 'host_food_late',
    title: 'Comida tarde del anfitrión',
    description: 'Multa al anfitrión si la comida se sirve después de la hora prometida.',
    trigger: { type: 'host_food_late', params: { fixed_amount: 100 } },
    action: { type: 'fine', params: { amount: 100 } },
  },
  {
    code: 'manual',
    title: 'Manual (a discreción)',
    description: 'Regla sin trigger automático. Las multas se asignan a mano.',
    trigger: { type: 'manual' },
    action: { type: 'fine', params: { amount: 100 } },
  },
]
```

Commit `feat(rules): 7 rule presets library`.

### Task 4: features/rules — schemas + queries + actions + barrel

**schemas.ts**:

```ts
import { z } from 'zod'

const TriggerSchema = z.object({
  type: z.enum(['late_arrival','no_confirmation','same_day_cancel','no_show','host_skip_no_notice','host_food_late','manual']),
  params: z.record(z.string(), z.unknown()).optional(),
})

const ActionSchema = z.object({
  type: z.literal('fine'),
  params: z.object({ amount: z.coerce.number().nonnegative() }).optional(),
})

const ExceptionSchema = z.object({ user_id: z.string().uuid() })

export const ProposeRuleSchema = z.object({
  group_id: z.string().uuid(),
  title: z.string().min(2).max(120),
  description: z.string().max(500).optional(),
  trigger: TriggerSchema,
  action: ActionSchema,
  exceptions: z.array(ExceptionSchema).default([]),
  committee_only: z.union([z.literal('on'),z.literal('off'),z.boolean()]).transform((v)=>v===true||v==='on').optional(),
})
export type ProposeRule = z.infer<typeof ProposeRuleSchema>

export const ArchiveRuleSchema = z.object({ rule_id: z.string().uuid() })

export const UpdateExceptionsSchema = z.object({
  rule_id: z.string().uuid(),
  user_ids: z.array(z.string().uuid()),
})
```

**queries.ts** (server-only): `listActiveRules(gid)`, `listProposedRules(gid)`, `listArchivedRules(gid)`, `getRule(rid)`, `getRuleVote(rid)` (returns the vote row if rule.approved_via_vote_id set).

**actions.ts**:
- `proposeRule` → wraps `propose_rule` RPC, redirects to `/g/[gid]/reglas/[rid]`
- `archiveRule` → direct UPDATE on rules where role=admin (RLS handles it), revalidates
- `updateRuleExceptions` → direct UPDATE on rules, sets `exceptions` jsonb to provided user_ids

**index.ts** barrel.

Commit `feat(rules): schemas, queries, proposeRule/archiveRule/updateRuleExceptions actions + barrel`.

### Task 5: features/votes — schemas + queries + actions + barrel

**schemas.ts**: `CastBallotSchema { vote_id, choice }`, `CloseVoteSchema { vote_id }`.

**queries.ts**:
- `getVote(vote_id)` → vote row
- `getMyBallot(vote_id, user_id)` → ballot row | null
- `getVoteTally(vote_id)` → `{ yes, no, abstain, total, eligible }` (count from vote_ballots + count members)
- `listOpenVotesForUser(group_id, user_id)` → list of open votes the user can vote on (excludes votes they already cast in)
- `listOpenVotesForGroup(group_id)` → all open votes (admin view)

**actions.ts**:
- `castBallot` → wraps `cast_ballot` RPC, revalidates rule detail + /hoy
- `closeVote` → wraps `close_vote` RPC (already exists), revalidates everything

**index.ts** barrel.

Commit `feat(votes): schemas, queries, castBallot/closeVote actions + barrel`.

### Task 6: features/rules — components

**RulesList.tsx** (server component): shows `Tabs` (Activas/Propuestas/Archivadas), each tab renders `RuleCard[]`.

**RuleCard.tsx**: Card with title, description, RuleStatusBadge, action.params.amount, link to `/g/[gid]/reglas/[rid]`.

**RuleStatusBadge.tsx**: `<Badge variant=...>` for active/proposed/archived.

**RulePresetPicker.tsx** (client): RadioGroup of 7 presets + "from scratch", on select exposes the preset's trigger/action params via callback or hidden inputs.

**ProposeRuleForm.tsx** (client): form using shadcn `Form` (RHF + Zod). Has RulePresetPicker + editable Title/Description/Amount. Submits to `proposeRule` action.

**RuleExceptionsEditor.tsx** (client): list of group members with checkboxes; on save calls `updateRuleExceptions` action. Admin only.

**RuleArchiveDialog.tsx** (client): AlertDialog. Admin only.

Commit per component or batch: `feat(rules): UI components (RulesList, RuleCard, presets picker, propose form, exceptions, archive)`.

### Task 7: features/votes — components

**VoteTallyBar.tsx** (server component): renders `Progress` bar split into yes/no/abstain segments with counts above.

**VoteSheet.tsx** (client): `Sheet` (bottom on mobile) that shows the vote subject (rule title + description), my current ballot (RadioGroup), the tally bar (live: TanStack Query fetching every 5s while open). Submit changes via `castBallot`. If user is admin and vote is past `closes_at`, show "Cerrar votación" button calling `closeVote`.

**OpenVotesList.tsx** (server component): for `/hoy`. Shows count badge + list of `RuleCard`-like rows for open votes the user hasn't voted on.

Commit `feat(votes): UI components (VoteSheet with live tally, VoteTallyBar, OpenVotesList)`.

### Task 8: Route /reglas — RulesList

Replace stub `app/g/[gid]/reglas/page.tsx`:

```tsx
import { redirect, notFound } from 'next/navigation'
import { Button } from '@/components/ui/button'
import Link from 'next/link'
import { Plus } from 'lucide-react'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { listActiveRules, listProposedRules, listArchivedRules, RulesList } from '@/features/rules'

export default async function ReglasPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, active, proposed, archived] = await Promise.all([
    getGroup(gid),
    listActiveRules(gid),
    listProposedRules(gid),
    listArchivedRules(gid),
  ])
  if (!group) notFound()

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold">Reglas</h1>
        <Button asChild size="sm">
          <Link href={`/g/${gid}/reglas/proponer`}><Plus className="size-4 mr-1" /> Proponer</Link>
        </Button>
      </div>
      <RulesList groupId={gid} active={active} proposed={proposed} archived={archived} />
    </div>
  )
}
```

Commit `feat(routes): /reglas with RulesList + propose CTA`.

### Task 9: Route /reglas/proponer — ProposeRuleForm

Create `app/g/[gid]/reglas/proponer/page.tsx`:

```tsx
import { redirect, notFound } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { ProposeRuleForm } from '@/features/rules'

export default async function ProponerReglaPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')
  const group = await getGroup(gid)
  if (!group) notFound()

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <Card>
        <CardHeader className="space-y-2">
          <CardTitle>Proponer regla</CardTitle>
          <CardDescription>Elige un preset o crea una desde cero. Se abrirá una votación al guardar.</CardDescription>
        </CardHeader>
        <CardContent>
          <ProposeRuleForm groupId={gid} />
        </CardContent>
      </Card>
    </div>
  )
}
```

Commit `feat(routes): /reglas/proponer wizard page`.

### Task 10: Route /reglas/[rid] — RuleDetail

Create `app/g/[gid]/reglas/[rid]/page.tsx`. Renders RuleCard hero + ProposedVote section (if rule.status='proposed' and approved_via_vote_id set, render VoteSheet) + RuleExceptionsEditor (admin) + RuleArchiveDialog (admin, only for active rules).

Commit `feat(routes): /reglas/[rid] detail with vote sheet + exceptions + archive`.

### Task 11: /hoy — append OpenVotesList

Add OpenVotesList below NextEventCard:

```tsx
const openVotes = await listOpenVotesForUser(gid, user.id)
// ...
<OpenVotesList groupId={gid} votes={openVotes} />
```

Commit `feat(routes): /hoy shows open votes the user hasn't cast yet`.

### Task 12: E2E placeholder + final verification + push

E2E `e2e/03-rules-votes.spec.ts` placeholder (auth-gate test for /reglas + /reglas/proponer). Full `npm run lint && npm run typecheck && npm run build && npm test`. Push.

Commit `test(e2e): rules+votes route auth gate placeholder`.

---

## Definition of Done — Phase 3

- ✓ Migration 00006 applied to cloud (`mcp__claude_ai_Supabase__list_migrations` shows it)
- ✓ `cast_ballot` RPC visible in `pg_proc`
- ✓ `npm run lint && npm run typecheck && npm run build && npm test` all green
- ✓ Smoke flow:
  1. Tap "Proponer regla" → choose `late_arrival` preset → submit → redirects to /reglas/[rid]
  2. Rule shows status=Propuesta, votación abierta
  3. Tap VoteSheet → choose "Sí" → tally bar updates
  4. Logout, login as another member, vote "Sí" → tally updates again
  5. Wait for closes_at OR admin "Cerrar votación" → status=passed, rule status=active, redirect or banner
  6. /hoy no longer shows this vote (closed)
  7. Admin opens active rule → "Archivar" → status=archived → moves to Archivadas tab
- ✓ Per-member exceptions: admin opens rule → toggles "David" → save → DB has exceptions=[{user_id:"david-uuid"}]
