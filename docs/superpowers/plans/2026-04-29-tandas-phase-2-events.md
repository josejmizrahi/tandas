# Tandas Phase 2: Events + RSVP + Check-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the group "alive" — admins create events (one-off or recurring), members RSVP from `/hoy`, check-in IRL, admin closes the event. When a recurring group closes an event, the next one is auto-created with the host rotated.

**Architecture:** New `features/events/` module (server actions + RSC queries + client components). New `components/shell/BottomNav.tsx` makes the 5-tab mobile shell real. Routes `/g/[gid]/hoy` and `/g/[gid]/eventos[/[eid]]` come online. Stubs for `/reglas`, `/plata`, `/mas` so the BottomNav doesn't 404. One new SQL migration adds `set_rsvp` and `close_event` RPCs and a `roll_event_series` helper.

**Tech Stack:** Next.js 16 App Router, React 19, Tailwind v4, shadcn/ui, Supabase (Postgres + RLS + Auth), Zod, React Hook Form. Builds on Phase 1 conventions (see `docs/superpowers/plans/2026-04-29-tandas-phase-1-foundation.md`).

---

## Phase Map (updated 2026-04-29 after rebrainstorm)

| Phase | Scope | Status |
|---|---|---|
| 1 | Auth + groups + members | ✅ shipped |
| **2 (this)** | Events + RSVP + check-in + close + auto-recurrence | ⏳ this plan |
| 3 | Rules + votes (propose, vote, activate) | pending |
| 4 | Fines (auto from rule engine + manual + appeal flow) | pending |
| 4.5 | Anti-tiranía (período de gracia, tope mensual, reset, amnistía, snapshot de reglas) | pending — added per rebrainstorm |
| 4.6 | Tipología del grupo + onboarding cultural del miembro nuevo | pending — added per rebrainstorm |
| 7 | Notifications + web push + pg_cron | pending |
| 8 | PWA polish + tests sweep + e2e expansion | pending |
| 8.5 | Memoria (anuario, wrapped, lore, achievements descriptivos) | pending — added per rebrainstorm |
| v1.5 | Pots + Splitwise (deferred from MVP per rebrainstorm) | post-MVP |

---

## File Structure

### Created

```
supabase/migrations/00005_phase2_events.sql

features/events/
  schemas.ts
  queries.ts
  actions.ts
  components/
    NewEventSheet.tsx
    EventCard.tsx
    NextEventCard.tsx
    EventDetail.tsx
    RsvpToggle.tsx
    CheckInButton.tsx
    AttendanceList.tsx
    CloseEventDialog.tsx
  index.ts

components/shell/BottomNav.tsx
components/ui/{drawer,toggle-group,alert-dialog,select}.tsx   # shadcn add

app/g/[gid]/hoy/page.tsx
app/g/[gid]/eventos/page.tsx
app/g/[gid]/eventos/[eid]/page.tsx
app/g/[gid]/reglas/page.tsx          # stub for BottomNav
app/g/[gid]/plata/page.tsx           # stub for BottomNav
app/g/[gid]/mas/page.tsx             # stub for BottomNav (members link + logout already in ProfileSheet)

lib/dates.ts                          # Date helpers (formatEventDate, eventStatus)
lib/dates.test.ts                     # Unit tests

e2e/02-create-event.spec.ts           # Add to existing e2e dir
```

### Modified

```
app/g/[gid]/layout.tsx                # Add <BottomNav /> at the bottom of AppShell
app/g/[gid]/page.tsx                  # Redirect to ./hoy (was minimal home; home moves to /hoy)
lib/db/types.ts                       # Regenerated after migration adds set_rsvp + close_event RPCs
features/groups/queries.ts            # Optional: add getNextEventForGroup helper
```

---

## Task Index

| # | Task | Outcome |
|---|---|---|
| 1 | Add shadcn drawer + toggle-group + alert-dialog + select | 4 new primitives |
| 2 | Date helpers (`lib/dates.ts` + tests) | formatEventDate, isPastEvent helpers |
| 3 | Migration 00005 — set_rsvp + close_event + roll_event_series RPCs | DB ready |
| 4 | Regenerate `lib/db/types.ts` | RPCs visible in TS |
| 5 | features/events: schemas | Zod for create/rsvp/checkin/close |
| 6 | features/events: queries | listUpcoming/listPast/getEvent/listAttendance/getNextForGroup |
| 7 | features/events: actions | createEvent / setRsvp / checkInAttendee / closeEvent |
| 8 | NewEventSheet component | Admin form (Sheet) |
| 9 | EventCard component | Date, host, status, RSVP-at-a-glance |
| 10 | NextEventCard (for /hoy) | Hero card with RSVP toggle inline |
| 11 | RsvpToggle component | 4-state ToggleGroup |
| 12 | AttendanceList component | List with arrived/cancelled/no-show badges |
| 13 | CheckInButton component | Sticky bottom button |
| 14 | CloseEventDialog component | AlertDialog admin only |
| 15 | EventDetail component | Composes all the above |
| 16 | features/events barrel | index.ts |
| 17 | Route /g/[gid]/hoy | Renders NextEventCard |
| 18 | Route /g/[gid]/eventos | Tabs: Próximos / Histórico |
| 19 | Route /g/[gid]/eventos/[eid] | Renders EventDetail |
| 20 | Stub routes /reglas /plata /mas | Placeholder pages |
| 21 | Update /g/[gid]/page → redirect | Home moves to /hoy |
| 22 | BottomNav component | 5 tabs with active state |
| 23 | AppShell — wire BottomNav | Mobile shell complete |
| 24 | E2E: create event + RSVP + check-in | New playwright spec |
| 25 | Final verification + push | Lint + typecheck + build + test green |

---

## Conventions

- Same as Phase 1: `npm` scripts, paths absolute from repo root, conventional commits.
- All RPC mutations go through `apply_migration` MCP (cloud Supabase). The local SQL file is committed for repo source-of-truth.
- New component files default-export the component, named export the props type if shared.
- All client components import server actions, never the other way around.

---

## Tasks

### Task 1: Add shadcn drawer + toggle-group + alert-dialog + select

**Files:**
- Create: `components/ui/{drawer,toggle-group,alert-dialog,select}.tsx`

- [ ] **Step 1: Add components**

```bash
cd /Users/jj/code/tandas
npx shadcn@latest add drawer toggle-group alert-dialog select --yes
```

Expected: 4 new files in `components/ui/`. `drawer` pulls in `vaul` (already installed in Phase 1).

- [ ] **Step 2: Verify**

```bash
npm run lint && npm run typecheck && npm run build
```

Expected: ✓ all green.

- [ ] **Step 3: Commit**

```bash
git add components/ui/{drawer,toggle-group,alert-dialog,select}.tsx components.json
git commit -m "chore(ui): add drawer, toggle-group, alert-dialog, select primitives"
```

---

### Task 2: Date helpers + unit tests

**Files:**
- Create: `lib/dates.ts`
- Create: `lib/dates.test.ts`

- [ ] **Step 1: Write tests**

```ts
// lib/dates.test.ts
import { describe, it, expect } from 'vitest'
import { formatEventDate, isPastEvent, isToday, isUpcoming } from './dates'

describe('formatEventDate', () => {
  it('formats with day name + day + month + time in es-MX', () => {
    const out = formatEventDate('2026-05-12T20:30:00.000Z', 'America/Mexico_City')
    expect(out).toMatch(/martes/i)
    expect(out).toMatch(/12/)
  })
})

describe('isPastEvent', () => {
  it('returns true for past starts_at', () => {
    expect(isPastEvent('2020-01-01T00:00:00.000Z')).toBe(true)
  })
  it('returns false for future starts_at', () => {
    const future = new Date(Date.now() + 86_400_000).toISOString()
    expect(isPastEvent(future)).toBe(false)
  })
})

describe('isToday', () => {
  it('returns true for today', () => {
    expect(isToday(new Date().toISOString(), 'America/Mexico_City')).toBe(true)
  })
})

describe('isUpcoming', () => {
  it('returns true within next 14 days', () => {
    const soon = new Date(Date.now() + 7 * 86_400_000).toISOString()
    expect(isUpcoming(soon)).toBe(true)
  })
  it('returns false for events more than 14 days out', () => {
    const far = new Date(Date.now() + 30 * 86_400_000).toISOString()
    expect(isUpcoming(far)).toBe(false)
  })
})
```

- [ ] **Step 2: Run to confirm fail**

```bash
npm test
```

Expected: FAIL — `lib/dates.ts` doesn't exist yet.

- [ ] **Step 3: Implement**

```ts
// lib/dates.ts
export function formatEventDate(iso: string, timezone: string): string {
  const d = new Date(iso)
  return new Intl.DateTimeFormat('es-MX', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    hour: '2-digit',
    minute: '2-digit',
    timeZone: timezone,
  }).format(d)
}

export function isPastEvent(iso: string): boolean {
  return new Date(iso).getTime() < Date.now()
}

export function isToday(iso: string, timezone: string): boolean {
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: timezone }).format(new Date())
  const event = new Intl.DateTimeFormat('en-CA', { timeZone: timezone }).format(new Date(iso))
  return today === event
}

export function isUpcoming(iso: string, days = 14): boolean {
  const ms = new Date(iso).getTime() - Date.now()
  return ms > 0 && ms < days * 86_400_000
}
```

- [ ] **Step 4: Run tests**

```bash
npm test
```

Expected: PASS (4 new tests, 13 total).

- [ ] **Step 5: Commit**

```bash
git add lib/dates.ts lib/dates.test.ts
git commit -m "feat(lib): date helpers (formatEventDate, isPastEvent, isToday, isUpcoming) + tests"
```

---

### Task 3: Migration 00005 — set_rsvp + close_event + roll_event_series RPCs

**Files:**
- Create: `supabase/migrations/00005_phase2_events.sql`

- [ ] **Step 1: Write migration SQL**

```sql
-- Phase 2: events RPCs.
-- set_rsvp: member sets their own RSVP for an event (idempotent)
-- close_event: admin marks event completed (Phase 4 will plumb evaluate_event_rules)
-- roll_event_series: idempotent helper that creates the next event in the series

create or replace function public.set_rsvp(
  p_event_id uuid,
  p_status text
)
returns public.event_attendance
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  att public.event_attendance;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if p_status not in ('pending','going','maybe','declined') then
    raise exception 'invalid rsvp_status: %', p_status;
  end if;

  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not public.is_group_member(e.group_id, auth.uid()) then raise exception 'not a member'; end if;

  -- Upsert attendance row for this user (event, user) is unique
  insert into public.event_attendance (event_id, user_id, rsvp_status, rsvp_at)
  values (p_event_id, auth.uid(), p_status, now())
  on conflict (event_id, user_id)
  do update set
    rsvp_status = excluded.rsvp_status,
    rsvp_at     = now(),
    -- If they were marked cancelled and now say going, undo the cancel flag
    cancelled_same_day = case
      when excluded.rsvp_status = 'declined' and (e.starts_at::date = current_date) then true
      else event_attendance.cancelled_same_day
    end
  returning * into att;
  return att;
end;
$$;
revoke execute on function public.set_rsvp(uuid, text) from public, anon;
grant  execute on function public.set_rsvp(uuid, text) to authenticated;

-- close_event: admin marks the event completed.
-- This is the Phase 2 version. Phase 4 will replace it with one that calls
-- evaluate_event_rules and triggers fine creation. For now it just sets status
-- and (if rotation enabled) auto-rolls the next event.
create or replace function public.close_event(p_event_id uuid)
returns public.events
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  next_id uuid;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not public.is_group_admin(e.group_id, auth.uid()) then raise exception 'admin only'; end if;

  update public.events set status = 'completed' where id = p_event_id returning * into e;

  -- Idempotent: only roll if not already rolled
  next_id := public.roll_event_series(p_event_id);
  return e;
end;
$$;
revoke execute on function public.close_event(uuid) from public, anon;
grant  execute on function public.close_event(uuid) to authenticated;

-- roll_event_series: creates the next event after p_event_id, if the group has
-- recurrence configured (default_day_of_week + rotation_enabled). Idempotent
-- via parent_event_id (only creates a child if none exists).
create or replace function public.roll_event_series(p_event_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  g public.groups;
  v_next timestamptz;
  v_next_id uuid;
  v_dow int;
  v_days_to_add int;
  v_event_dow int;
begin
  select * into e from public.events where id = p_event_id;
  if not found then return null; end if;
  select * into g from public.groups where id = e.group_id;

  -- Only roll if rotation is enabled and the group has a default day
  if not g.rotation_enabled or g.default_day_of_week is null then return null; end if;

  -- Idempotency: if a child already exists, return it
  select id into v_next_id from public.events where parent_event_id = p_event_id limit 1;
  if v_next_id is not null then return v_next_id; end if;

  -- Compute next event date: same day of week + 7 days from current event
  -- (uses group timezone for day-of-week math)
  v_event_dow := extract(dow from (e.starts_at at time zone g.timezone))::int;
  v_days_to_add := 7;
  v_next := (e.starts_at at time zone g.timezone + (v_days_to_add || ' days')::interval) at time zone g.timezone;

  -- Insert next event (status defaults to 'scheduled')
  -- Host is intentionally null here; create_event RPC handles rotation, but we
  -- bypass it for the auto-roll case so we don't double-create attendance rows.
  -- Phase 3 will refine this with proper next-host computation.
  insert into public.events (group_id, starts_at, location, cycle_number, parent_event_id, rsvp_deadline, created_by)
  values (
    e.group_id,
    v_next,
    g.default_location,
    coalesce(e.cycle_number, 0) + 1,
    e.id,
    v_next - interval '24 hours',
    e.created_by
  )
  returning id into v_next_id;

  -- Pre-create attendance rows for all active members
  insert into public.event_attendance (event_id, user_id)
  select v_next_id, gm.user_id
  from public.group_members gm
  where gm.group_id = e.group_id and gm.active
  on conflict do nothing;

  return v_next_id;
end;
$$;
revoke execute on function public.roll_event_series(uuid) from public, anon;
grant  execute on function public.roll_event_series(uuid) to authenticated;
```

- [ ] **Step 2: Apply via Supabase MCP**

The session that's running this plan should call `mcp__claude_ai_Supabase__apply_migration` with:
- `project_id`: `fpfvlrwcskhgsjuhrjpz`
- `name`: `00005_phase2_events`
- `query`: the SQL above

If running outside a Claude session: paste the SQL into Supabase Studio SQL editor, run, verify no errors.

- [ ] **Step 3: Verify RPCs exist**

Run via MCP `mcp__claude_ai_Supabase__execute_sql` (or psql):

```sql
select proname from pg_proc
where pronamespace = 'public'::regnamespace
and proname in ('set_rsvp','close_event','roll_event_series')
order by proname;
```

Expected: 3 rows.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/00005_phase2_events.sql
git commit -m "feat(db): migration 00005 — set_rsvp, close_event, roll_event_series RPCs"
```

---

### Task 4: Regenerate `lib/db/types.ts`

**Files:**
- Modify: `lib/db/types.ts`

- [ ] **Step 1: Generate types from cloud project**

The session running this plan should call `mcp__claude_ai_Supabase__generate_typescript_types` with `project_id: fpfvlrwcskhgsjuhrjpz`, then write the resulting `types` field verbatim to `lib/db/types.ts`.

If running outside a Claude session: `npx supabase gen types typescript --project-id fpfvlrwcskhgsjuhrjpz > lib/db/types.ts` (requires `supabase login` first).

- [ ] **Step 2: Verify the new RPCs are in the types**

```bash
grep -E "set_rsvp|close_event|roll_event_series" lib/db/types.ts | head -10
```

Expected: 3 matches.

- [ ] **Step 3: Verify typecheck still passes**

```bash
npm run typecheck
```

Expected: ✓ no errors.

- [ ] **Step 4: Commit**

```bash
git add lib/db/types.ts
git commit -m "chore(db): regenerate Supabase types after 00005 (set_rsvp, close_event, roll_event_series)"
```

---

### Task 5: features/events — schemas

**Files:**
- Create: `features/events/schemas.ts`

- [ ] **Step 1: Write the schemas**

```ts
import { z } from 'zod'
import { RsvpStatusSchema } from '@/lib/schemas/enums'

export const CreateEventSchema = z.object({
  group_id: z.string().uuid(),
  starts_at: z.string().datetime(),       // ISO from <input type="datetime-local"> + timezone
  location: z.string().max(200).optional(),
  title: z.string().max(120).optional(),
  rsvp_deadline: z.string().datetime().optional(),
})
export type CreateEvent = z.infer<typeof CreateEventSchema>

export const SetRsvpSchema = z.object({
  event_id: z.string().uuid(),
  status: RsvpStatusSchema,
})
export type SetRsvp = z.infer<typeof SetRsvpSchema>

export const CheckInSchema = z.object({
  event_id: z.string().uuid(),
  user_id: z.string().uuid(),
})
export type CheckIn = z.infer<typeof CheckInSchema>

export const CloseEventSchema = z.object({
  event_id: z.string().uuid(),
})
export type CloseEvent = z.infer<typeof CloseEventSchema>
```

- [ ] **Step 2: Verify**

```bash
npm run typecheck
```

Expected: ✓ no errors.

- [ ] **Step 3: Commit**

```bash
git add features/events/schemas.ts
git commit -m "feat(events): Zod schemas for create/rsvp/checkin/close"
```

---

### Task 6: features/events — queries

**Files:**
- Create: `features/events/queries.ts`

- [ ] **Step 1: Write the queries**

```ts
import 'server-only'
import { createClient } from '@/lib/supabase/server'

export async function listUpcomingEvents(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('events')
    .select('id, starts_at, location, title, status, host_id, cycle_number')
    .eq('group_id', groupId)
    .gte('starts_at', new Date().toISOString())
    .order('starts_at', { ascending: true })
    .limit(20)
  if (error) throw error
  return data ?? []
}

export async function listPastEvents(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('events')
    .select('id, starts_at, location, title, status, host_id, cycle_number')
    .eq('group_id', groupId)
    .lt('starts_at', new Date().toISOString())
    .order('starts_at', { ascending: false })
    .limit(50)
  if (error) throw error
  return data ?? []
}

export async function getNextEventForGroup(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('events')
    .select('id, starts_at, location, title, status, host_id')
    .eq('group_id', groupId)
    .gte('starts_at', new Date().toISOString())
    .order('starts_at', { ascending: true })
    .limit(1)
    .maybeSingle()
  if (error) throw error
  return data
}

export async function getEvent(eventId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('events')
    .select('id, group_id, starts_at, ends_at, location, title, status, host_id, cycle_number, rsvp_deadline, parent_event_id, auto_no_show_at, rules_evaluated_at')
    .eq('id', eventId)
    .maybeSingle()
  if (error) throw error
  return data
}

export type AttendanceWithProfile = {
  user_id: string
  rsvp_status: string
  rsvp_at: string | null
  arrived_at: string | null
  cancelled_same_day: boolean
  no_show: boolean
  display_name: string | null
}

export async function listAttendance(eventId: string): Promise<AttendanceWithProfile[]> {
  const supabase = await createClient()
  const { data: rows, error } = await supabase
    .from('event_attendance')
    .select('user_id, rsvp_status, rsvp_at, arrived_at, cancelled_same_day, no_show')
    .eq('event_id', eventId)
  if (error) throw error
  if (!rows || rows.length === 0) return []

  const userIds = rows.map((r) => r.user_id)
  const { data: profiles } = await supabase
    .from('profiles')
    .select('id, display_name')
    .in('id', userIds)
  const byId = new Map((profiles ?? []).map((p) => [p.id, p.display_name]))

  return rows.map((r) => ({
    user_id: r.user_id,
    rsvp_status: r.rsvp_status,
    rsvp_at: r.rsvp_at,
    arrived_at: r.arrived_at,
    cancelled_same_day: r.cancelled_same_day,
    no_show: r.no_show,
    display_name: byId.get(r.user_id) ?? null,
  }))
}

export async function getMyAttendance(eventId: string, userId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('event_attendance')
    .select('user_id, rsvp_status, arrived_at, cancelled_same_day, no_show')
    .eq('event_id', eventId)
    .eq('user_id', userId)
    .maybeSingle()
  if (error) throw error
  return data
}

export async function isAdminOfGroup(groupId: string, userId: string): Promise<boolean> {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('group_members')
    .select('role')
    .eq('group_id', groupId)
    .eq('user_id', userId)
    .eq('active', true)
    .maybeSingle()
  if (error) throw error
  return data?.role === 'admin'
}
```

- [ ] **Step 2: Verify**

```bash
npm run typecheck
```

Expected: ✓ no errors.

- [ ] **Step 3: Commit**

```bash
git add features/events/queries.ts
git commit -m "feat(events): queries (listUpcoming/listPast/getEvent/listAttendance + helpers)"
```

---

### Task 7: features/events — actions

**Files:**
- Create: `features/events/actions.ts`

- [ ] **Step 1: Write the actions**

```ts
'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import {
  CreateEventSchema,
  SetRsvpSchema,
  CheckInSchema,
  CloseEventSchema,
} from './schemas'

export type ActionResult = { ok: true } | { error: { _form?: string[]; [k: string]: string[] | undefined } }

export async function createEvent(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = CreateEventSchema.safeParse({
    group_id: formData.get('group_id'),
    starts_at: formData.get('starts_at'),
    location: formData.get('location') || undefined,
    title: formData.get('title') || undefined,
    rsvp_deadline: formData.get('rsvp_deadline') || undefined,
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { data, error } = await supabase.rpc('create_event', {
    p_group_id: parsed.data.group_id,
    p_starts_at: parsed.data.starts_at,
    p_ends_at: parsed.data.starts_at,    // ends_at not collected in v1 form; reuse starts_at
    p_location: parsed.data.location ?? '',
    p_title: parsed.data.title ?? '',
    p_host_id: user.id,                  // creator is host by default; admin can change later
    p_cycle_number: 1,                   // RPC will compute the real cycle
    p_rsvp_deadline: parsed.data.rsvp_deadline ?? parsed.data.starts_at,
  })
  if (error) return { error: { _form: [error.message] } }

  revalidatePath(`/g/${parsed.data.group_id}/eventos`)
  revalidatePath(`/g/${parsed.data.group_id}/hoy`)
  redirect(`/g/${parsed.data.group_id}/eventos/${(data as { id: string }).id}`)
}

export async function setRsvp(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = SetRsvpSchema.safeParse({
    event_id: formData.get('event_id'),
    status: formData.get('status'),
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase.rpc('set_rsvp', {
    p_event_id: parsed.data.event_id,
    p_status: parsed.data.status,
  })
  if (error) return { error: { _form: [error.message] } }

  // Revalidate both the event detail and any list/home pages
  const gid = formData.get('gid') as string | null
  if (gid) {
    revalidatePath(`/g/${gid}/hoy`)
    revalidatePath(`/g/${gid}/eventos`)
    revalidatePath(`/g/${gid}/eventos/${parsed.data.event_id}`)
  }
  return { ok: true }
}

export async function checkInAttendee(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = CheckInSchema.safeParse({
    event_id: formData.get('event_id'),
    user_id: formData.get('user_id'),
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase.rpc('check_in_attendee', {
    p_event_id: parsed.data.event_id,
    p_user_id: parsed.data.user_id,
    p_arrived_at: new Date().toISOString(),
  })
  if (error) return { error: { _form: [error.message] } }

  const gid = formData.get('gid') as string | null
  if (gid) revalidatePath(`/g/${gid}/eventos/${parsed.data.event_id}`)
  return { ok: true }
}

export async function closeEvent(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = CloseEventSchema.safeParse({
    event_id: formData.get('event_id'),
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase.rpc('close_event', { p_event_id: parsed.data.event_id })
  if (error) return { error: { _form: [error.message] } }

  const gid = formData.get('gid') as string | null
  if (gid) {
    revalidatePath(`/g/${gid}/hoy`)
    revalidatePath(`/g/${gid}/eventos`)
    revalidatePath(`/g/${gid}/eventos/${parsed.data.event_id}`)
  }
  return { ok: true }
}
```

- [ ] **Step 2: Verify**

```bash
npm run lint && npm run typecheck && npm run build
```

Expected: ✓ all green (build will list new no-op routes since we haven't added them yet, that's fine).

- [ ] **Step 3: Commit**

```bash
git add features/events/actions.ts
git commit -m "feat(events): server actions (createEvent, setRsvp, checkInAttendee, closeEvent)"
```

---

### Task 8: NewEventSheet component

**Files:**
- Create: `features/events/components/NewEventSheet.tsx`

- [ ] **Step 1: Write the component**

```tsx
'use client'

import { useActionState, useState } from 'react'
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetTrigger, SheetFooter } from '@/components/ui/sheet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Plus } from 'lucide-react'
import { createEvent, type ActionResult } from '../actions'

export default function NewEventSheet({ groupId }: { groupId: string }) {
  const [open, setOpen] = useState(false)
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(createEvent, null)

  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger asChild>
        <Button className="w-full">
          <Plus className="size-4 mr-2" />
          Nuevo evento
        </Button>
      </SheetTrigger>
      <SheetContent side="bottom" className="h-[85dvh]">
        <SheetHeader>
          <SheetTitle>Nuevo evento</SheetTitle>
        </SheetHeader>
        <form action={action} className="space-y-4 px-4 pt-4">
          <input type="hidden" name="group_id" value={groupId} />

          <div className="space-y-2">
            <Label htmlFor="title">Título (opcional)</Label>
            <Input id="title" name="title" placeholder="Cena en casa de Eduardo" maxLength={120} />
          </div>

          <div className="space-y-2">
            <Label htmlFor="starts_at">Fecha y hora</Label>
            <Input id="starts_at" name="starts_at" type="datetime-local" required />
          </div>

          <div className="space-y-2">
            <Label htmlFor="location">Lugar (opcional)</Label>
            <Input id="location" name="location" placeholder="Casa de Eduardo, Polanco" maxLength={200} />
          </div>

          <div className="space-y-2">
            <Label htmlFor="rsvp_deadline">Deadline para confirmar (opcional)</Label>
            <Input id="rsvp_deadline" name="rsvp_deadline" type="datetime-local" />
            <p className="text-xs text-muted-foreground">
              Si lo dejas vacío, usamos 24h antes del evento.
            </p>
          </div>

          {state && 'error' in state && (
            <p className="text-destructive text-sm">{state.error._form?.[0]}</p>
          )}

          <SheetFooter>
            <Button type="submit" disabled={pending} className="w-full">
              {pending ? 'Creando…' : 'Crear evento'}
            </Button>
          </SheetFooter>
        </form>
      </SheetContent>
    </Sheet>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run lint && npm run typecheck
```

Expected: ✓

- [ ] **Step 3: Commit**

```bash
git add features/events/components/NewEventSheet.tsx
git commit -m "feat(events): NewEventSheet (admin form in bottom sheet)"
```

---

### Task 9: EventCard component

**Files:**
- Create: `features/events/components/EventCard.tsx`

- [ ] **Step 1: Write the component**

```tsx
import Link from 'next/link'
import { Card, CardContent } from '@/components/ui/card'
import { Calendar, MapPin } from 'lucide-react'
import { formatEventDate } from '@/lib/dates'

type EventCardProps = {
  groupId: string
  event: {
    id: string
    starts_at: string
    location: string | null
    title: string | null
    status: string
  }
  timezone: string
}

export default function EventCard({ groupId, event, timezone }: EventCardProps) {
  const isCompleted = event.status === 'completed'
  return (
    <Link href={`/g/${groupId}/eventos/${event.id}`}>
      <Card className={isCompleted ? 'opacity-60' : ''}>
        <CardContent className="p-4 space-y-2">
          <div className="flex items-center gap-2 text-sm">
            <Calendar className="size-4 text-muted-foreground" />
            <span className="font-medium">{formatEventDate(event.starts_at, timezone)}</span>
          </div>
          {event.title && <p className="font-semibold">{event.title}</p>}
          {event.location && (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <MapPin className="size-3.5" />
              <span className="truncate">{event.location}</span>
            </div>
          )}
          {isCompleted && (
            <span className="inline-block px-2 py-0.5 rounded text-xs bg-muted">Cerrado</span>
          )}
        </CardContent>
      </Card>
    </Link>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run typecheck
```

- [ ] **Step 3: Commit**

```bash
git add features/events/components/EventCard.tsx
git commit -m "feat(events): EventCard (calendar + location + status badge)"
```

---

### Task 10: NextEventCard for /hoy

**Files:**
- Create: `features/events/components/NextEventCard.tsx`

- [ ] **Step 1: Write the component**

```tsx
import Link from 'next/link'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Calendar, MapPin } from 'lucide-react'
import { formatEventDate } from '@/lib/dates'
import RsvpToggle from './RsvpToggle'

type NextEventCardProps = {
  groupId: string
  timezone: string
  event: {
    id: string
    starts_at: string
    location: string | null
    title: string | null
    status: string
  } | null
  myRsvp: 'pending' | 'going' | 'maybe' | 'declined' | null
}

export default function NextEventCard({ groupId, timezone, event, myRsvp }: NextEventCardProps) {
  if (!event) {
    return (
      <Card>
        <CardContent className="p-6 text-center text-muted-foreground">
          No hay eventos próximos. Si eres admin, créa uno desde la pestaña Eventos.
        </CardContent>
      </Card>
    )
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Próximo evento</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-2">
          <div className="flex items-center gap-2">
            <Calendar className="size-4 text-muted-foreground" />
            <span className="font-medium">{formatEventDate(event.starts_at, timezone)}</span>
          </div>
          {event.title && <p className="text-lg font-semibold">{event.title}</p>}
          {event.location && (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <MapPin className="size-4" />
              <span>{event.location}</span>
            </div>
          )}
        </div>

        <div className="space-y-2">
          <p className="text-sm font-medium">¿Vas a ir?</p>
          <RsvpToggle eventId={event.id} groupId={groupId} currentStatus={myRsvp ?? 'pending'} />
        </div>

        <Link
          href={`/g/${groupId}/eventos/${event.id}`}
          className="block text-center text-sm text-muted-foreground underline pt-2"
        >
          Ver detalle
        </Link>
      </CardContent>
    </Card>
  )
}
```

- [ ] **Step 2: Verify (won't compile yet — RsvpToggle missing)**

```bash
npm run typecheck 2>&1 | head -3
```

Expected: error about `./RsvpToggle`. Continue to Task 11.

- [ ] **Step 3: Commit (skip until Task 11 lands too — combine commit)**

Skip commit; move on.

---

### Task 11: RsvpToggle component

**Files:**
- Create: `features/events/components/RsvpToggle.tsx`

- [ ] **Step 1: Write the component**

```tsx
'use client'

import { useActionState, useState, useTransition } from 'react'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { setRsvp, type ActionResult } from '../actions'

type Status = 'pending' | 'going' | 'maybe' | 'declined'

const OPTIONS: { value: Status; label: string }[] = [
  { value: 'going', label: 'Voy' },
  { value: 'maybe', label: 'Tal vez' },
  { value: 'declined', label: 'No voy' },
]

export default function RsvpToggle({
  eventId, groupId, currentStatus,
}: { eventId: string; groupId: string; currentStatus: Status }) {
  const [optimistic, setOptimistic] = useState<Status>(currentStatus)
  const [, startTransition] = useTransition()
  const [, action] = useActionState<ActionResult | null, FormData>(setRsvp, null)

  function handleChange(value: string) {
    if (!value) return
    const next = value as Status
    setOptimistic(next)
    const fd = new FormData()
    fd.set('event_id', eventId)
    fd.set('status', next)
    fd.set('gid', groupId)
    startTransition(() => action(fd))
  }

  return (
    <ToggleGroup
      type="single"
      value={optimistic === 'pending' ? '' : optimistic}
      onValueChange={handleChange}
      className="w-full"
    >
      {OPTIONS.map((o) => (
        <ToggleGroupItem key={o.value} value={o.value} className="flex-1">
          {o.label}
        </ToggleGroupItem>
      ))}
    </ToggleGroup>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run lint && npm run typecheck
```

Expected: ✓

- [ ] **Step 3: Commit (combine with Task 10)**

```bash
git add features/events/components/NextEventCard.tsx features/events/components/RsvpToggle.tsx
git commit -m "feat(events): NextEventCard + RsvpToggle (3-state Voy/Tal vez/No voy)"
```

---

### Task 12: AttendanceList component

**Files:**
- Create: `features/events/components/AttendanceList.tsx`

- [ ] **Step 1: Write the component**

```tsx
import type { AttendanceWithProfile } from '../queries'

const STATUS_LABEL: Record<string, string> = {
  going: 'Voy',
  maybe: 'Tal vez',
  declined: 'No voy',
  pending: 'Sin responder',
}

export default function AttendanceList({ attendance }: { attendance: AttendanceWithProfile[] }) {
  return (
    <ul className="divide-y rounded-lg border">
      {attendance.map((a) => (
        <li key={a.user_id} className="flex items-center justify-between p-3">
          <div>
            <p className="font-medium">{a.display_name ?? 'Sin nombre'}</p>
            <p className="text-xs text-muted-foreground">
              {STATUS_LABEL[a.rsvp_status] ?? a.rsvp_status}
              {a.arrived_at && ' · llegó'}
              {a.cancelled_same_day && ' · canceló mismo día'}
              {a.no_show && ' · no-show'}
            </p>
          </div>
          {a.arrived_at ? (
            <span className="text-xs px-2 py-0.5 rounded bg-emerald-100 text-emerald-700">✓</span>
          ) : a.no_show ? (
            <span className="text-xs px-2 py-0.5 rounded bg-destructive/10 text-destructive">✗</span>
          ) : null}
        </li>
      ))}
      {attendance.length === 0 && (
        <li className="p-4 text-center text-muted-foreground text-sm">Aún sin RSVPs.</li>
      )}
    </ul>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run typecheck
```

- [ ] **Step 3: Commit**

```bash
git add features/events/components/AttendanceList.tsx
git commit -m "feat(events): AttendanceList component"
```

---

### Task 13: CheckInButton component

**Files:**
- Create: `features/events/components/CheckInButton.tsx`

- [ ] **Step 1: Write the component**

```tsx
'use client'

import { useActionState, useTransition, useState } from 'react'
import { Button } from '@/components/ui/button'
import { CheckCircle2 } from 'lucide-react'
import { checkInAttendee, type ActionResult } from '../actions'

export default function CheckInButton({
  eventId, userId, groupId, alreadyCheckedIn,
}: { eventId: string; userId: string; groupId: string; alreadyCheckedIn: boolean }) {
  const [didIt, setDidIt] = useState(alreadyCheckedIn)
  const [, startTransition] = useTransition()
  const [, action] = useActionState<ActionResult | null, FormData>(checkInAttendee, null)

  function handleClick() {
    setDidIt(true)
    const fd = new FormData()
    fd.set('event_id', eventId)
    fd.set('user_id', userId)
    fd.set('gid', groupId)
    startTransition(() => action(fd))
  }

  return (
    <Button
      onClick={handleClick}
      disabled={didIt}
      size="lg"
      className="w-full"
      variant={didIt ? 'outline' : 'default'}
    >
      <CheckCircle2 className="size-5 mr-2" />
      {didIt ? 'Ya marcaste tu llegada' : 'Marcar mi llegada'}
    </Button>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run typecheck
```

- [ ] **Step 3: Commit**

```bash
git add features/events/components/CheckInButton.tsx
git commit -m "feat(events): CheckInButton (sticky sized button)"
```

---

### Task 14: CloseEventDialog component

**Files:**
- Create: `features/events/components/CloseEventDialog.tsx`

- [ ] **Step 1: Write the component**

```tsx
'use client'

import { useActionState, useState, useTransition } from 'react'
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { Button } from '@/components/ui/button'
import { closeEvent, type ActionResult } from '../actions'

export default function CloseEventDialog({
  eventId, groupId,
}: { eventId: string; groupId: string }) {
  const [open, setOpen] = useState(false)
  const [, startTransition] = useTransition()
  const [, action] = useActionState<ActionResult | null, FormData>(closeEvent, null)

  function confirmClose() {
    const fd = new FormData()
    fd.set('event_id', eventId)
    fd.set('gid', groupId)
    startTransition(() => action(fd))
    setOpen(false)
  }

  return (
    <AlertDialog open={open} onOpenChange={setOpen}>
      <AlertDialogTrigger asChild>
        <Button variant="outline" className="w-full">Cerrar evento</Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>¿Cerrar este evento?</AlertDialogTitle>
          <AlertDialogDescription>
            Marca el evento como completado. Si tu grupo tiene rotación activada,
            se crea automáticamente el siguiente. (Las multas automáticas llegan en Phase 4.)
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancelar</AlertDialogCancel>
          <AlertDialogAction onClick={confirmClose}>Sí, cerrar</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run typecheck
```

- [ ] **Step 3: Commit**

```bash
git add features/events/components/CloseEventDialog.tsx
git commit -m "feat(events): CloseEventDialog (admin AlertDialog confirmation)"
```

---

### Task 15: EventDetail component

**Files:**
- Create: `features/events/components/EventDetail.tsx`

- [ ] **Step 1: Write the component**

```tsx
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Calendar, MapPin } from 'lucide-react'
import { formatEventDate } from '@/lib/dates'
import RsvpToggle from './RsvpToggle'
import AttendanceList from './AttendanceList'
import CheckInButton from './CheckInButton'
import CloseEventDialog from './CloseEventDialog'
import type { AttendanceWithProfile } from '../queries'

type EventDetailProps = {
  groupId: string
  timezone: string
  isAdmin: boolean
  currentUserId: string
  event: {
    id: string
    starts_at: string
    location: string | null
    title: string | null
    status: string
    cycle_number: number | null
  }
  attendance: AttendanceWithProfile[]
  myAttendance: AttendanceWithProfile | undefined
}

export default function EventDetail({
  groupId, timezone, isAdmin, currentUserId, event, attendance, myAttendance,
}: EventDetailProps) {
  const isClosed = event.status === 'completed'
  const myRsvp = (myAttendance?.rsvp_status ?? 'pending') as 'pending' | 'going' | 'maybe' | 'declined'
  const alreadyCheckedIn = !!myAttendance?.arrived_at

  return (
    <div className="p-4 space-y-6 max-w-md mx-auto">
      <Card>
        <CardHeader>
          <CardTitle>{event.title ?? `Evento #${event.cycle_number ?? '?'}`}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <div className="flex items-center gap-2">
            <Calendar className="size-4 text-muted-foreground" />
            <span className="font-medium">{formatEventDate(event.starts_at, timezone)}</span>
          </div>
          {event.location && (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <MapPin className="size-4" />
              <span>{event.location}</span>
            </div>
          )}
          {isClosed && (
            <span className="inline-block px-2 py-0.5 rounded text-xs bg-muted">Cerrado</span>
          )}
        </CardContent>
      </Card>

      {!isClosed && (
        <section className="space-y-2">
          <p className="text-sm font-medium">Mi RSVP</p>
          <RsvpToggle eventId={event.id} groupId={groupId} currentStatus={myRsvp} />
        </section>
      )}

      {!isClosed && myRsvp === 'going' && (
        <section>
          <CheckInButton
            eventId={event.id}
            userId={currentUserId}
            groupId={groupId}
            alreadyCheckedIn={alreadyCheckedIn}
          />
        </section>
      )}

      <section className="space-y-2">
        <h2 className="text-sm font-medium text-muted-foreground px-1">Asistencia</h2>
        <AttendanceList attendance={attendance} />
      </section>

      {isAdmin && !isClosed && (
        <section>
          <CloseEventDialog eventId={event.id} groupId={groupId} />
        </section>
      )}
    </div>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run lint && npm run typecheck
```

- [ ] **Step 3: Commit**

```bash
git add features/events/components/EventDetail.tsx
git commit -m "feat(events): EventDetail composes RsvpToggle + CheckInButton + AttendanceList + CloseEventDialog"
```

---

### Task 16: features/events barrel

**Files:**
- Create: `features/events/index.ts`

- [ ] **Step 1: Write the barrel**

```ts
export * from './schemas'
export * from './queries'
export * from './actions'
export { default as NewEventSheet } from './components/NewEventSheet'
export { default as EventCard } from './components/EventCard'
export { default as NextEventCard } from './components/NextEventCard'
export { default as EventDetail } from './components/EventDetail'
export { default as RsvpToggle } from './components/RsvpToggle'
export { default as AttendanceList } from './components/AttendanceList'
export { default as CheckInButton } from './components/CheckInButton'
export { default as CloseEventDialog } from './components/CloseEventDialog'
```

- [ ] **Step 2: Verify**

```bash
npm run typecheck
```

- [ ] **Step 3: Commit**

```bash
git add features/events/index.ts
git commit -m "feat(events): barrel exports"
```

---

### Task 17: Route /g/[gid]/hoy

**Files:**
- Create: `app/g/[gid]/hoy/page.tsx`

- [ ] **Step 1: Write the page**

```tsx
import { redirect, notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { getNextEventForGroup, getMyAttendance, NextEventCard } from '@/features/events'

export default async function HoyPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const group = await getGroup(gid)
  if (!group) notFound()

  const event = await getNextEventForGroup(gid)
  const myAttendance = event ? await getMyAttendance(event.id, user.id) : null

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <h1 className="text-xl font-bold">Hoy</h1>
      <NextEventCard
        groupId={gid}
        timezone={group.timezone ?? 'America/Mexico_City'}
        event={event}
        myRsvp={(myAttendance?.rsvp_status as 'pending' | 'going' | 'maybe' | 'declined' | undefined) ?? null}
      />
    </div>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run lint && npm run typecheck && npm run build
```

Expected: ✓ /g/[gid]/hoy appears in build output.

- [ ] **Step 3: Commit**

```bash
git add app/g/[gid]/hoy/
git commit -m "feat(routes): /g/[gid]/hoy renders NextEventCard"
```

---

### Task 18: Route /g/[gid]/eventos

**Files:**
- Create: `app/g/[gid]/eventos/page.tsx`

- [ ] **Step 1: Write the page**

```tsx
import { redirect, notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { getGroup } from '@/features/groups'
import { listUpcomingEvents, listPastEvents, EventCard, NewEventSheet } from '@/features/events'
import { isAdminOfGroup } from '@/features/events'

export default async function EventosPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, upcoming, past, isAdmin] = await Promise.all([
    getGroup(gid),
    listUpcomingEvents(gid),
    listPastEvents(gid),
    isAdminOfGroup(gid, user.id),
  ])
  if (!group) notFound()

  const tz = group.timezone ?? 'America/Mexico_City'

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <h1 className="text-xl font-bold">Eventos</h1>

      {isAdmin && <NewEventSheet groupId={gid} />}

      <Tabs defaultValue="upcoming">
        <TabsList className="grid grid-cols-2 w-full">
          <TabsTrigger value="upcoming">Próximos ({upcoming.length})</TabsTrigger>
          <TabsTrigger value="past">Histórico ({past.length})</TabsTrigger>
        </TabsList>
        <TabsContent value="upcoming" className="space-y-2 mt-4">
          {upcoming.map((e) => <EventCard key={e.id} groupId={gid} event={e} timezone={tz} />)}
          {upcoming.length === 0 && (
            <p className="text-center text-muted-foreground text-sm py-8">
              No hay eventos próximos.
            </p>
          )}
        </TabsContent>
        <TabsContent value="past" className="space-y-2 mt-4">
          {past.map((e) => <EventCard key={e.id} groupId={gid} event={e} timezone={tz} />)}
          {past.length === 0 && (
            <p className="text-center text-muted-foreground text-sm py-8">
              Aún no hay eventos pasados.
            </p>
          )}
        </TabsContent>
      </Tabs>
    </div>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run lint && npm run typecheck && npm run build
```

- [ ] **Step 3: Commit**

```bash
git add app/g/[gid]/eventos/page.tsx
git commit -m "feat(routes): /g/[gid]/eventos with Próximos/Histórico tabs + admin NewEventSheet"
```

---

### Task 19: Route /g/[gid]/eventos/[eid]

**Files:**
- Create: `app/g/[gid]/eventos/[eid]/page.tsx`

- [ ] **Step 1: Write the page**

```tsx
import { redirect, notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { getEvent, listAttendance, getMyAttendance, isAdminOfGroup, EventDetail } from '@/features/events'

export default async function EventDetailPage({
  params,
}: { params: Promise<{ gid: string; eid: string }> }) {
  const { gid, eid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, event, attendance, isAdmin] = await Promise.all([
    getGroup(gid),
    getEvent(eid),
    listAttendance(eid),
    isAdminOfGroup(gid, user.id),
  ])
  if (!group) notFound()
  if (!event) notFound()
  if (event.group_id !== gid) notFound()

  const myAttendance = attendance.find((a) => a.user_id === user.id)

  return (
    <EventDetail
      groupId={gid}
      timezone={group.timezone ?? 'America/Mexico_City'}
      isAdmin={isAdmin}
      currentUserId={user.id}
      event={event}
      attendance={attendance}
      myAttendance={myAttendance}
    />
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run lint && npm run typecheck && npm run build
```

- [ ] **Step 3: Commit**

```bash
git add "app/g/[gid]/eventos/[eid]/"
git commit -m "feat(routes): /g/[gid]/eventos/[eid] event detail page"
```

---

### Task 20: Stub routes /reglas /plata /mas

**Files:**
- Create: `app/g/[gid]/reglas/page.tsx`
- Create: `app/g/[gid]/plata/page.tsx`
- Create: `app/g/[gid]/mas/page.tsx`

- [ ] **Step 1: Write 3 stub pages**

`app/g/[gid]/reglas/page.tsx`:

```tsx
export default function ReglasPage() {
  return (
    <div className="p-4 max-w-md mx-auto space-y-4">
      <h1 className="text-xl font-bold">Reglas</h1>
      <p className="text-muted-foreground">
        Próximamente en Phase 3 — propuesta de reglas, votación, motor de aplicación.
      </p>
    </div>
  )
}
```

`app/g/[gid]/plata/page.tsx`:

```tsx
export default function PlataPage() {
  return (
    <div className="p-4 max-w-md mx-auto space-y-4">
      <h1 className="text-xl font-bold">Plata</h1>
      <p className="text-muted-foreground">
        Próximamente en Phase 4–6 — multas, balance unificado, settle up.
      </p>
    </div>
  )
}
```

`app/g/[gid]/mas/page.tsx`:

```tsx
import Link from 'next/link'
import { Users } from 'lucide-react'

export default async function MasPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  return (
    <div className="p-4 max-w-md mx-auto space-y-4">
      <h1 className="text-xl font-bold">Más</h1>
      <ul className="divide-y rounded-lg border">
        <li>
          <Link href={`/g/${gid}`} className="flex items-center gap-3 p-4 hover:bg-accent">
            <Users className="size-5" />
            <span>Miembros del grupo</span>
          </Link>
        </li>
      </ul>
      <p className="text-xs text-muted-foreground">
        Settings, fondo común y switcher de grupos llegan en próximas fases.
      </p>
    </div>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run lint && npm run typecheck && npm run build
```

- [ ] **Step 3: Commit**

```bash
git add app/g/[gid]/reglas/ app/g/[gid]/plata/ app/g/[gid]/mas/
git commit -m "feat(routes): stub pages for /reglas, /plata, /mas (so BottomNav doesn't 404)"
```

---

### Task 21: Update /g/[gid]/page → redirect to /hoy

**Files:**
- Modify: `app/g/[gid]/page.tsx`

- [ ] **Step 1: Replace contents**

```tsx
import { redirect } from 'next/navigation'

export default async function GroupRootRedirect({
  params,
}: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  redirect(`/g/${gid}/hoy`)
}
```

- [ ] **Step 2: Verify**

```bash
npm run lint && npm run typecheck && npm run build
```

- [ ] **Step 3: Commit**

```bash
git add "app/g/[gid]/page.tsx"
git commit -m "feat(routes): /g/[gid] redirects to /g/[gid]/hoy (was minimal home)"
```

---

### Task 22: BottomNav component

**Files:**
- Create: `components/shell/BottomNav.tsx`

- [ ] **Step 1: Write the component**

```tsx
'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { Home, Calendar, Scale, Wallet, MoreHorizontal } from 'lucide-react'
import { cn } from '@/lib/utils'

type Tab = { href: string; label: string; Icon: typeof Home }

export default function BottomNav({ groupId }: { groupId: string }) {
  const pathname = usePathname()
  const tabs: Tab[] = [
    { href: `/g/${groupId}/hoy`,     label: 'Hoy',      Icon: Home },
    { href: `/g/${groupId}/eventos`, label: 'Eventos',  Icon: Calendar },
    { href: `/g/${groupId}/reglas`,  label: 'Reglas',   Icon: Scale },
    { href: `/g/${groupId}/plata`,   label: 'Plata',    Icon: Wallet },
    { href: `/g/${groupId}/mas`,     label: 'Más',      Icon: MoreHorizontal },
  ]

  return (
    <nav className="fixed bottom-0 left-0 right-0 z-30 bg-background/95 backdrop-blur border-t">
      <ul className="flex items-stretch justify-around h-16 max-w-md mx-auto">
        {tabs.map(({ href, label, Icon }) => {
          const active = pathname === href || pathname.startsWith(href + '/')
          return (
            <li key={href} className="flex-1">
              <Link
                href={href}
                className={cn(
                  'flex flex-col items-center justify-center gap-0.5 h-full text-xs',
                  active ? 'text-foreground' : 'text-muted-foreground'
                )}
              >
                <Icon className={cn('size-5', active && 'text-primary')} />
                <span>{label}</span>
              </Link>
            </li>
          )
        })}
      </ul>
    </nav>
  )
}
```

- [ ] **Step 2: Verify**

```bash
npm run typecheck
```

- [ ] **Step 3: Commit**

```bash
git add components/shell/BottomNav.tsx
git commit -m "feat(shell): BottomNav with 5 mobile tabs (Hoy/Eventos/Reglas/Plata/Más)"
```

---

### Task 23: AppShell — wire BottomNav

**Files:**
- Modify: `components/shell/AppShell.tsx`
- Modify: `app/g/[gid]/layout.tsx`

- [ ] **Step 1: Update `AppShell.tsx`**

```tsx
import GroupHeader from './GroupHeader'
import ProfileSheet from './ProfileSheet'
import BottomNav from './BottomNav'

export default function AppShell({
  groupId, groupName, displayName, children,
}: { groupId: string; groupName: string; displayName: string; children: React.ReactNode }) {
  return (
    <div className="min-h-dvh flex flex-col">
      <GroupHeader groupName={groupName}>
        <ProfileSheet displayName={displayName} />
      </GroupHeader>
      <main className="flex-1 pb-20">{children}</main>
      <BottomNav groupId={groupId} />
    </div>
  )
}
```

- [ ] **Step 2: Update `app/g/[gid]/layout.tsx`** to pass groupId

```tsx
import { redirect, notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import AppShell from '@/components/shell/AppShell'

export default async function GroupLayout({
  children, params,
}: { children: React.ReactNode; params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [{ data: group }, { data: profile }] = await Promise.all([
    supabase.from('groups').select('id, name').eq('id', gid).maybeSingle(),
    supabase.from('profiles').select('display_name').eq('id', user.id).maybeSingle(),
  ])
  if (!group) notFound()

  return (
    <AppShell
      groupId={gid}
      groupName={group.name}
      displayName={profile?.display_name ?? 'Tú'}
    >
      {children}
    </AppShell>
  )
}
```

- [ ] **Step 3: Verify**

```bash
npm run lint && npm run typecheck && npm run build
```

Expected: ✓ build lists /g/[gid]/{hoy,eventos,reglas,plata,mas} routes.

- [ ] **Step 4: Commit**

```bash
git add components/shell/AppShell.tsx "app/g/[gid]/layout.tsx"
git commit -m "feat(shell): wire BottomNav into AppShell + pass groupId"
```

---

### Task 24: E2E — create event + RSVP + check-in placeholder

**Files:**
- Create: `e2e/02-events.spec.ts`

- [ ] **Step 1: Write a passing-when-stubbed e2e**

```ts
import { test, expect } from '@playwright/test'

test.describe('Events (placeholder)', () => {
  test('eventos route requires auth', async ({ page }) => {
    await page.goto('/g/00000000-0000-0000-0000-000000000000/eventos')
    await expect(page).toHaveURL(/\/login/)
  })

  // Real flows (create event → RSVP → check-in → close + see auto-rolled next)
  // require Supabase test instance + test user. Wired up in Phase 7 with proper
  // CI auth env. For now, ensure routes don't 500 when unauthenticated.
  test.skip('admin creates event, member RSVPs, admin closes, next event auto-created', async () => {})
})
```

- [ ] **Step 2: Run**

```bash
npm run test:e2e -- --project=iphone
```

Expected: 3 tests (1 from spec 01 + 1 new + 1 skipped). All pass except skipped.

- [ ] **Step 3: Commit**

```bash
git add e2e/02-events.spec.ts
git commit -m "test(e2e): events route auth gate placeholder (full flow deferred to Phase 7 CI env)"
```

---

### Task 25: Final verification + push

- [ ] **Step 1: Full verification**

```bash
cd /Users/jj/code/tandas
npm run lint && npm run typecheck && npm run build && npm test
```

Expected:
- ✓ ESLint clean
- ✓ tsc no errors
- ✓ build with all routes (/login, /onboarding, /, /g/[gid]/{hoy,eventos,eventos/[eid],reglas,plata,mas}, /g/{new,join}, /auth/callback)
- ✓ 13 unit tests pass

- [ ] **Step 2: Manual smoke test**

Spin up dev:

```bash
npm run dev
```

Then in browser at http://localhost:3000:
1. Login with magic link → onboarding → / → /g/[gid] → /g/[gid]/hoy
2. Tap "Eventos" tab → see Próximos / Histórico empty state
3. As admin: tap "Nuevo evento" → fill form → submit → redirect to /eventos/[eid]
4. Tap "Voy" on RSVP toggle → it stays selected
5. Tap "Marcar mi llegada" → button disables
6. Tap "Cerrar evento" → confirm dialog → click yes → status becomes "Cerrado"
7. Go back to "Eventos" → event now in Histórico
8. If group has `default_day_of_week` and `rotation_enabled`, a new event appeared in Próximos (auto-rolled)

- [ ] **Step 3: Push**

```bash
git push
```

- [ ] **Step 4: Verify Vercel preview deploy**

Open the Vercel dashboard → confirm the latest preview build is green and the new routes are reachable.

---

## Definition of Done — Phase 2

- ✓ All 25 tasks completed with commits per the plan
- ✓ Migration 00005 applied to cloud project (verifiable via `mcp__claude_ai_Supabase__list_migrations`)
- ✓ `npm run lint && npm run typecheck && npm run build && npm test` all pass
- ✓ 13+ unit tests pass (4 new from Task 2 + 9 from Phase 1)
- ✓ E2E: 3+ tests pass (existing 2 + 1 new + skipped flow placeholder)
- ✓ Manual smoke test: full create event → RSVP → check-in → close → auto-roll loop works
- ✓ BottomNav visible on all `/g/[gid]/*` routes, active state highlights current tab
- ✓ All 5 BottomNav tabs route to non-404 pages

## What this Phase deliberately leaves out

- Rule engine (Phase 3-4): closing an event does NOT generate fines yet
- Vote system (Phase 3): no propose-rule, no rule_proposal votes
- Notifications (Phase 7): no push when an event is created or closed
- Realtime (Phase 7): event lists are SSR + revalidate-on-action, not live-updating
- Custom hosts: hosts auto-assigned via create_event RPC (creator); manual reassignment is Phase 3
- Logística extra: dirección con mapa, código de acceso, alergias — deferred to v1.5
- Foto del evento + comments + capítulo post-evento — deferred to memory layer (Phase 8.5)
- Eventos especiales con reglamento custom (cumpleaños, viajes) — deferred until rules ship in Phase 3
