# Events Robustness V1

**Goal**: Make ruul events feel as solid as Luma before moving to the rule
engine (multas) prompt. Focus is on the bits that make a `social events`
app feel "alive": real-time updates, calendar integration, capacity +
waitlist + plus-ones (the "logistics" Luma got right), and curated
loading/error states across every screen.

## Scope (this commit batch)

### A. Real-time RSVP updates (highest "wow")
Subscribe to `event_attendance` row changes for the active event via
Supabase Realtime. When ANY user changes their RSVP, the
EventDetailCoordinator updates immediately — no refresh needed.
- New `RSVPRealtimeService` actor wrapping `client.realtimeV2.channel(...)`.
- `EventDetailCoordinator.refresh()` starts the subscription on appear,
  cancels on disappear.
- Optimistic updates already in place; realtime + optimistic compose
  cleanly because optimistic writes go through the repo which fires the
  same realtime event back (idempotent).

### B. Apple Calendar integration
- `CalendarExportService` with two modes:
  - `EKEvent` direct (preferred): asks for calendar access, creates
    calendar event with title + date + location + alarms, returns id.
  - `.ics` file fallback: generates RFC 5545 calendar string, presents
    `.ics` via share sheet (works without calendar permission).
- "Add to Calendar" button in `EventRSVPStateView` confirmed-going state
  (alongside Wallet button when available).
- Stored EKEvent id keeps "remove from calendar" workable on RSVP change.

### C. Schema: capacity + plus-ones + waitlist (migration 00013)
- `events.capacity_max int null` — null = unlimited.
- `events.allow_plus_ones boolean default false`.
- `events.max_plus_ones_per_member int default 0`.
- `event_attendance.plus_ones int default 0` — how many extras THIS member
  is bringing.
- `event_attendance.rsvp_status` gets a new value: `waitlisted`.
- `event_attendance.waitlist_position int null` — assigned by trigger
  when capacity is reached.
- New RPCs:
  - `set_rsvp_v2(event_id, status, plus_ones, reason)` — extends
    existing set_rsvp to handle plus-ones and auto-waitlist.
  - `promote_from_waitlist(event_id)` — host can manually promote next
    waitlisted, or auto-trigger when someone declines.

### D. Plus-ones UI
- `EventRSVPStateView` shows a stepper "+1, +2, +3" when group/event has
  `allow_plus_ones && member can bring up to N`.
- `AttendeesListSection` shows "John (+2)" inline when applicable.

### E. Capacity + waitlist UI
- `EventDetailView` title block shows `"12 / 20"` with `RuulProgressBar`
  when `capacity_max != nil`.
- `EventRSVPStateView` "Voy" button switches to "Anotarme en lista de
  espera" when at capacity.
- `EventCard` cover badge: "LLENO" pill (red) when at capacity.
- Waitlist gets its own `AttendeesListSection` collapsible section with
  "EN LISTA DE ESPERA" label.

### F. Event share QR (not check-in QR)
- New `ShareEventSheet` shows event title + date + a QR encoding the
  deep link `ruul://event/<id>` (or `https://ruul.app/event/<id>` once
  AASA is live). Below the QR: `ShareLink` for Mensajes / WhatsApp / etc.
- Triggered from EventDetailView top nav (host) and from a "Compartir"
  button in the going state of `EventRSVPStateView` (any attendee can
  share with friends not yet in the group).

### G. Open in Apple Maps polish
Existing: opens https://maps.apple.com/?ll=lat,lng&q=name.
Improvement: switch to MKMapItem so:
- Apple Maps picks "Get directions" mode
- Falls back to Google Maps if installed (via URL scheme detection)
- Uses event title as the place name

### H. Skeleton + error state audit
Every event screen needs:
- Loading: `LoadingStateView` skeleton (NOT just `ProgressView`)
- Error: `ErrorStateView` with retry action
- Empty: `EmptyStateView` with curated copy + primary action

Audit list:
- `EventDetailView`: missing skeleton when initial fetch is loading
  (currently shows the cover with no content underneath until refresh
  completes). Add full-screen skeleton with cover placeholder.
- `PastEventsView`: ✅ already has all 3 states.
- `HomeView`: ✅ has empty state + loading; double-check error path.
- `MainTabView`: bootstrapping screen is plain ProgressView — fine for
  splash, no change needed.

## Out of scope (deferred)

- **Co-hosts**: requires `event_hosts` join table + RLS overhaul + UI
  for managing host list. Deferred — V1 has single host_id on events.
- **Comments / discussion**: separate `event_comments` table + per-comment
  RLS + sub-screen + push notifications. Big enough to be its own prompt.
- **Geofence notifications**: requires `NSLocationAlwaysUsageDescription`
  + background CoreLocation + region monitoring. Cost > benefit for V1.
- **Multi-cover carousel**: single cover is sufficient; multi-cover adds
  complexity to the catalog + storage.
- **Polls per event**: cool but niche. V2.

## Plan execution order (commits)

1. `db: 00013 events robustness — capacity, plus_ones, waitlist`
2. `feat(repos): RSVPRepository.setRSVP_v2 + plus_ones support`
3. `feat(realtime): RSVPRealtimeService — Supabase channel subscription`
4. `feat(calendar): CalendarExportService — EKEvent + .ics fallback`
5. `feat(events): plus-ones stepper + capacity progress + waitlist UI`
6. `feat(events): ShareEventSheet with QR + ShareLink`
7. `feat(events): MapItem-based open-in-Maps + skeleton audit`
8. `docs: EventsRobustnessV1-FollowUp.md with config + testing notes`

## Why this is the right priority

The user said "robust like Luma". Luma's perceived robustness comes from:
1. **Real-time** — when 8 friends are deciding "voy/tal vez", you see the
   group converging in real time. Without this, ruul feels static.
2. **Calendar parity** — every event app has Add to Calendar. Not having
   it feels broken.
3. **Capacity / plus-ones** — the actual logistics Luma solves: "we have
   8 spots", "can I bring my partner?". Multas without these feels
   premature.
4. **Sharing** — events that can't be shared outside the app are dead.
   Event QR + shareable deep link is table stakes.
5. **Polish in loading/error states** — what separates "alpha" from
   "ship-ready" perception.

Rule engine (Prompt 4) lands on top of these and feels much more
substantial when the underlying event surface is solid.
