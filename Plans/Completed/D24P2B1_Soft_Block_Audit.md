# D.24 P2B-1 — `group_resources` Direct Insert Soft Block + Audit

**Status:** Shipped 2026-06-01. Audit-only — NO enforcement.
**Mig:** `20260601212435_d24_p2b1_group_resources_direct_insert_audit.sql`
**Founder firm:** "Mi firma actual: P2B-1, no enforcement ciego."

---

## Goal

Detect / log any INSERT into `public.group_resources` that bypasses the 3 authorized creator RPCs, without blocking. Provide live evidence to graduate to enforcement (P2B-2) once the audit table shows zero unauthorized inserts for a usage window.

---

## Audit findings (pre-implementation)

### Backend functions that INSERT directly into `group_resources`
| Function | Authorized? | Notes |
|---|---|---|
| `create_group_resource(8-arg)` | Yes (legacy overload) | Pre-P2A signature |
| `create_group_resource(10-arg)` | Yes (current) | P2A added `p_metadata + p_client_id` |
| `create_event` | Yes (D.24 P1) | Event-specific: host wiring + auto-RSVP + roster metadata |
| `create_resource` | Yes (legacy polymorphic) | Older atomic creator with `p_subtype_payload jsonb` |
| `_smoke_global_search` | Smoke (test fixture) | Direct INSERT; acceptable noise in audit |

### iOS callers
| iOS surface | RPC | Notes |
|---|---|---|
| Calendar create | `create_event` | Via `CanonicalCalendarEventsRepository.create` |
| Resource create (asset/fund/space/etc.) | `create_group_resource` | Envelope-only — iOS does NOT yet use the 6 P2A atomic wrappers |
| Direct table inserts | None | iOS goes through RPCs exclusively |

### Adoption gap
The 6 P2A atomic wrappers (`create_event_resource`, `create_asset_resource`, `create_fund_resource`, `create_space_resource`, `create_slot_resource`, `create_right_resource`) exist backend but iOS has not migrated to them. Switching iOS is a precondition for P2B-2 enforcement — otherwise enforcement would block legitimate iOS flows.

---

## Soft block design

### 1. Session GUC convention
Authorized RPCs set a transaction-scoped GUC at the top of their body:

```sql
PERFORM set_config('ruul.resource_create_intent', '<rpc_name>', true);
--                                                              ^^^^
--                                              true = SET LOCAL (transaction-scoped)
```

The `true` argument scopes the value to the current transaction; nested calls inherit it; rollback unsets it.

### 2. Audit table
`public.group_resources_direct_insert_audit` — append-only by trigger.
Columns:
- `id bigserial PK`
- `occurred_at timestamptz DEFAULT now()`
- `resource_id uuid NOT NULL`
- `group_id uuid`
- `resource_type text`
- `created_by uuid`
- `intent_marker text` — value of the GUC at INSERT time. **NULL = unauthorized direct insert.**
- `notes text` — free-form annotation slot for future enforcement work.

Indices:
- `occurred_at DESC` for tail queries.
- Partial `(occurred_at DESC) WHERE intent_marker IS NULL` for "unauthorized only" scans.

RLS: enabled, no policies — only `service_role` can read/write directly. The trigger writes via `SECURITY DEFINER` so it always succeeds.

### 3. Trigger
`AFTER INSERT ON public.group_resources FOR EACH ROW`. Reads the GUC, inserts one audit row, returns NEW. **Never raises.**

### 4. Authorized RPCs updated
| RPC | Intent marker set |
|---|---|
| `create_group_resource(10-arg)` | `'create_group_resource'` |
| `create_event` | `'create_event'` |
| `create_resource` | `'create_resource'` |

The 8-arg legacy `create_group_resource` overload was NOT updated — if iOS or any caller still hits it, the audit row will show `intent_marker=NULL` (treated as unauthorized direct), giving us a signal to deprecate the overload before P2B-2.

The 6 P2A subtype wrappers (`create_event_resource` et al.) call `create_group_resource(10-arg)` internally, so the GUC inherits automatically through the nested call — no separate update needed.

### 5. Smoke test fixtures
`_smoke_global_search` does a direct INSERT and will show up as unauthorized in the audit. **This is acceptable noise** for P2B-1. Before flipping to P2B-2 enforcement, the smoke should either:
- Set the GUC explicitly: `PERFORM set_config('ruul.resource_create_intent', '_smoke_global_search', true);`
- OR refactor to call `create_resource` / `create_group_resource`.

---

## How to monitor

### Query all unauthorized direct inserts (latest first)
```sql
SELECT id, occurred_at, resource_id, group_id, resource_type, created_by
FROM public.group_resources_direct_insert_audit
WHERE intent_marker IS NULL
ORDER BY occurred_at DESC
LIMIT 100;
```

### Summary by intent marker
```sql
SELECT
  COALESCE(intent_marker, '<unauthorized>') AS path,
  count(*),
  min(occurred_at) AS first_seen,
  max(occurred_at) AS last_seen
FROM public.group_resources_direct_insert_audit
GROUP BY 1
ORDER BY count(*) DESC;
```

### Drill into a specific suspicious row
Cross-reference the audit row's `resource_id` with `group_events` for that resource — if there's no `resource.created` event, the INSERT also bypassed `record_system_event`, which is a second smell.

```sql
SELECT a.*, e.event_type, e.summary, e.payload
FROM public.group_resources_direct_insert_audit a
LEFT JOIN public.group_events e
  ON e.entity_kind='resource' AND e.entity_id=a.resource_id AND e.event_type='resource.created'
WHERE a.intent_marker IS NULL
ORDER BY a.occurred_at DESC
LIMIT 20;
```

---

## Graduation criteria for P2B-2 (enforcement)

Before flipping to enforcement, all of the following must be true:

1. **iOS migrates off `create_group_resource(10-arg)` to the 6 P2A atomic wrappers** — verified by `intent_marker = 'create_group_resource'` rows going to ~0 in the audit table for normal user activity.
2. **Smoke functions updated** — either set the GUC or refactored to call authorized RPCs. Expected: `intent_marker IS NULL` rows in the audit table approach zero outside of intentional admin scripts.
3. **8-arg `create_group_resource` legacy overload dropped** — no longer reachable.
4. **Watch window of at least 1 weeks** with the trigger live in production, confirming `unauthorized=0` in the summary query above.

When ready, P2B-2 will modify `_log_group_resources_direct_insert` to `RAISE EXCEPTION 'unauthorized_direct_insert'` when `intent_marker IS NULL`, instead of just logging. Single line change.

---

## Rollback

If the trigger causes issues:

```sql
DROP TRIGGER IF EXISTS trg_log_group_resources_direct_insert ON public.group_resources;
```

The audit table can stay (read-only evidence). The RPCs that now `set_config` are no-ops without the trigger — safe to keep.

---

## Related

- P2A — `d24_p2a_atomic_resource_creation_rpcs.sql` (6 subtype wrappers + client_id)
- P3A — `d24_p3a_ownership_v2_backend.sql` (group_resource_owners)
- P3B — Drop `group_resources.owner_membership_id` (pending; orthogonal to P2B)
- `Plans/Completed/D24_Final_Report.md` — operational close for the audit.
