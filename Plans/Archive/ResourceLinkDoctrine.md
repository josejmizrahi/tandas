# Ruul — Resource Link Doctrine

**Status:** Canónico desde 2026-05-17. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (Artículo 2 — resource enum), `Plans/Active/EventResource.md` §12 (event puede usar spaces/assets/funds), `Plans/Active/Asset.md` §11-12 (asset puede tener rights y bookings), `Plans/Active/AtomProjection.md`, `Plans/Active/ConsistencyAudit_2026-05-17.md` (findings F6, F12 — link kind narrow + no guard).

> Un **resource_link** es una **relación estructural** entre dos resources. Es declarativa: dice "este event USA este palco". Es **inerte**: NO ejecuta automation, NO transfiere permisos, NO concede acceso, NO crea otros atoms más allá del link/unlink.

> El error doctrinal en Ruul al 2026-05-17: la tabla `resource_links` se creó con un solo link kind (`'uses'`) pero la doctrina demandaba al menos 4 (`owns`, `funds`, `scheduled_in`, `grants_access_to`). Además la tabla no tiene atom guard y se trata como truth (es queryada directamente, no como projection).

---

## §1 — Las 6 reglas cardinales

### 1. Links Are Structural Relationships

Un link expresa una **relación entre dos resources**. Nada más. No es:
- automatización (no ejecuta side effect)
- permission grant (no concede acceso por sí solo)
- ownership change (no transfiere)
- workflow (no abre votos ni approvals)

Si el "link" hace algo más que registrar la relación, **no es un link — es un atom de otro tipo**.

### 2. Links Are Not Automations

`link_resource_to_event(event, palco)` registra "este event usa este palco". **NO** automáticamente:
- concede `space_access` a los confirmed RSVPs del event
- transfiere ownership del palco
- agenda mantenimiento del palco
- envía push a custodian del palco
- ajusta capacidad del palco según event

Si quieres cualquiera de esos efectos, lo modela como una **rule** sobre el event o el palco que **lee el link** y dispara la consequence. La rule emite atoms; el link queda inerte.

### 3. Link Atoms Are Truth

Cada link/unlink debe emitir un atom canónico:
- `resourceLinked` con payload `{from_resource_id, to_resource_id, kind, linked_by, linked_at}`
- `resourceUnlinked` con `{link_id, unlinked_by, unlinked_at, reason?}`

Estos atoms son la verdad histórica. La tabla `resource_links` es projection/cache de estos atoms.

### 4. resource_links Table Is Cache/Projection

Hoy (pre-fix P1/P2): `resource_links` se queryha directamente como truth (`WHERE unlinked_at IS NULL`). El atom es decoración.

**Post-P2:** `resource_links` queda como fast-path cache. La verdad operativa es `resource_links_active_view` derivada de `system_events`. Si la tabla se corrompe, rebuild from atoms es trivial.

### 5. Link Kind Catalog Is Closed

Solo los kinds en este catálogo son aceptados. Adding new kind requires:
1. Filter ontológico §13 (Constitution).
2. Migration que ALTER el CHECK constraint.
3. Update a este doc §3.
4. Tests for the new kind.

**Catálogo canónico:**

| kind | from type | to type | Significado | Status |
|---|---|---|---|---|
| `uses` | event | space, asset, fund, right | event coordina/utiliza el target durante su window | stable (mig 00202) |
| `owns` | group, asset | asset, fund | ownership relationship | planned P1 |
| `funds` | fund | event, asset, project (futuro) | fund finances/backs the target | planned P1 |
| `scheduled_in` | event | space, slot | event toma place en target | planned P1 |
| `grants_access_to` | right | space, asset, fund, event | right concede acceso/uso del target | planned P1 |
| `depends_on` | any | any | dependency declarada para coordination (futuro) | post-P1 |
| `replaces` | any | any | resource sucede a otro (recurrence/migration) | post-P1 |

### 6. owns ≠ funds; funds ≠ owns; scheduled_in ≠ uses

Distinciones que el catálogo debe preservar:

- **owns** = ownership legal/social. Permanente hasta transfer atom. Es estructural.
- **funds** = money relationship. El fund "respalda" el target. NO implica ownership.
- **scheduled_in** = el event toma place físicamente en el target. Implica time-binding del target.
- **uses** = generic "este resource es relevante para este event" — sin claims más fuertes.
- **grants_access_to** = SOLO `right → resource`. El right es lo que entitled al holder a acceder.

**Validators kind-specific:** mig P1 debe enforce en CHECK o en RPC:
- `grants_access_to` ⇒ `from.resource_type = 'right'`.
- `funds` ⇒ `from.resource_type = 'fund'`.
- `owns` ⇒ `from.resource_type IN ('group', 'asset')` (groups own things; assets can own funds/subassets).
- `scheduled_in` ⇒ `from.resource_type = 'event'` AND `to.resource_type IN ('space', 'slot')`.

---

## §7 — Unlink Semantics

`unlink_resources(link_id, reason?)`:

1. Verify link exists and is active (`unlinked_at IS NULL`).
2. Stamp `unlinked_at = now()` + `unlinked_by = uid` + `unlink_reason = reason` (soft delete).
3. Emit `resourceUnlinked` atom.

**Re-linking** después de unlink crea **nueva row** (partial unique index `(from, to, kind) WHERE unlinked_at IS NULL`). Historia preservada.

**Hard delete** NUNCA. Si compliance requiere wipe, sigue el GDPR delete path (mig 00260) que stamps tombstone + clears PII, no que destruye links.

---

## §8 — RPC discipline

### Hoy (mig 00202)

| RPC | Behavior |
|---|---|
| `link_resource_to_event(p_event_id, p_resource_id)` | source hardcoded 'event'; target whitelist {space, asset, fund, right}; kind hardcoded 'uses'. Idempotent. Emits atom. |
| `unlink_resource_from_event(p_link_id)` | stamps unlinked_at; emits atom. Idempotent. |

### Post-P1

| RPC | Behavior |
|---|---|
| `link_resources(p_from_id, p_to_id, p_kind, p_metadata jsonb)` | polymorphic source/target; kind from catalog; per-kind validators; idempotent (returns existing active link if present); emits `resourceLinked` |
| `unlink_resources(p_link_id, p_reason text)` | stamps unlinked_at + reason; emits `resourceUnlinked`; idempotent |

`link_resource_to_event` y `unlink_resource_from_event` quedan como aliases backward-compat que llaman a las nuevas.

---

## §9 — Atom Guard (P2)

`resource_links` necesita atom guard partial — actualmente carece (F12).

**Partial guard contract:**
- INSERT: solo via RPCs SECURITY DEFINER (RLS revoke a authenticated).
- UPDATE: solo permitido si cambio es `unlinked_at: null → ts` + `unlinked_by: null → uuid` + `unlink_reason: null → text`. Cualquier otra mutación rejected.
- DELETE: siempre rejected.

Pattern lift de `system_events_processed_at_only_guard` (mig 00162).

---

## §10 — Projection canónica (post-P2)

`resource_links_active_view`:

```sql
CREATE VIEW resource_links_active_view AS
SELECT
  rl.id AS link_id,
  rl.group_id,
  rl.from_resource_id,
  rl.to_resource_id,
  rl.link_kind,
  rl.linked_at,
  rl.linked_by
FROM resource_links rl
WHERE rl.unlinked_at IS NULL;
```

Plus `resource_links_history_view` para audit/admin:

```sql
CREATE VIEW resource_links_history_view AS
SELECT * FROM resource_links ORDER BY linked_at DESC;
```

Atoms remain source of truth via `system_events`. View is fast-path.

---

## §11 — Lo que NUNCA se hace con links

- Hard delete de link rows.
- Link kind no-cataloged sin migration.
- Auto-create links from rules (rules pueden disparar `link_resources` RPC vía consequence, pero el link es explícito, no implícito).
- Treat link como permission grant (Right Doctrine §1).
- Link de resource a algo que no es resource (no link a member, no link a vote).
- Mutar `link_kind` post-create (kind es immutable; un cambio de relación = unlink old + link new).
- Confiar en `resource_links` table como única fuente sin atom backing.

---

## §12 — Atom payload schema

**`resourceLinked`:**
```json
{
  "link_id": "uuid",
  "from_resource_id": "uuid",
  "from_resource_type": "event|asset|fund|...",
  "to_resource_id": "uuid",
  "to_resource_type": "...",
  "link_kind": "uses|owns|funds|scheduled_in|grants_access_to",
  "linked_by": "uuid (user_id)",
  "linked_at": "iso8601",
  "metadata": { ... optional kind-specific knobs ... }
}
```

**`resourceUnlinked`:**
```json
{
  "link_id": "uuid",
  "from_resource_id": "uuid",
  "to_resource_id": "uuid",
  "link_kind": "...",
  "unlinked_by": "uuid",
  "unlinked_at": "iso8601",
  "reason": "string | null"
}
```

Schemas registrados en `public.system_event_payload_schemas` (mig 00243).

---

## §13 — Test contracts

- `test_link_resources_emits_atom_before_insert` — verify ordering.
- `test_link_resources_idempotent` — second call returns same link_id.
- `test_unlink_does_not_hard_delete` — row remains with unlinked_at set.
- `test_relink_after_unlink_creates_new_row` — partial unique index works.
- `test_link_kind_grants_access_to_requires_right_source` — POST-P1.
- `test_link_resources_polymorphic_source` — POST-P1.
- `test_resource_links_atom_guard_blocks_update_to_link_kind` — POST-P2.
- `test_resource_links_atom_guard_allows_unlinked_at_null_to_ts` — POST-P2.
- `test_resource_links_recomputes_from_link_atoms` — POST-P2 — drop table; rebuild from system_events.

---

## §14 — Founding cases

**Caso 1: event uses palco**
- `link_resources(event_id, palco_id, 'uses')` — registers usage.
- `event.usedResourcesView` lists palco.
- NO automatic access grants to RSVPs. If desired: rule "WHEN rsvp.created on this event THEN grant_space_access to actor on palco" (palco rule, scope=resource).

**Caso 2: fund funds event**
- `link_resources(fund_id, event_id, 'funds')`.
- `fund.expensesView` may filter by `funds` link to show "expenses related to this event".
- NO automatic withdrawal — `fund_record_expense` is explicit.

**Caso 3: right grants access to space**
- `link_resources(right_id, palco_id, 'grants_access_to')`.
- `right_state_view + grants_access_to link` lets the engine answer "can holder access palco?" via projection.
- The actual access still requires `book_space` or `grant_space_access` — link is the entitlement, not the act.

**Caso 4: group owns asset**
- `link_resources(group_id, asset_id, 'owns')` — usually implicit (asset.group_id), but `owns` link models shared/co-ownership.

---

## §15 — Future extensions

- **Weighted links** — `metadata.weight` for funding share calculations (e.g., fund finances 60% of event). Out of scope for P1.
- **Temporal links** — `valid_from`/`valid_until` for links that activate/deactivate. Out of scope.
- **Inverse projections** — `resource_inbound_links_view` (todo lo que apunta a este resource). Post-P1.
