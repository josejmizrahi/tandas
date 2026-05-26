# CanonicalSchema_Migration.md — Export / import desde schema legacy

> Anexo de `Plans/Active/CanonicalSchema.sql`.
> Define cómo mover los ~115 rows vivos de prod (snapshot 2026-05-26 en
> `CanonicalSchema_DataInventory.md`) al schema canónico recién aplicado
> en el branch. Se ejecuta en A6 del Plan (después de aplicar 00001 + RLS
> + RPCs + reescribir edge functions).

---

## 0. Estrategia

Data viva: 13 tablas con contenido, máximo 27 rows por tabla. Total ~115 rows.

Por el volumen, el camino más limpio es:

1. **Dump JSON por tabla** del schema viejo (en branch source o desde prod
   read-only).
2. **Script Node/Deno** que lee el JSON, transforma columna por columna,
   y hace `INSERT ... ON CONFLICT DO NOTHING` contra el branch canónico vía
   `supabase-js` con `service_role` key.
3. **Verificación** de conteos esperados + spot-check de un grupo conocido.

No usamos `pg_dump --data-only` directo porque varios columnas cambian de
nombre/forma y el resultado no encajaría sin transformaciones intermedias.

---

## 1. Pre-condiciones

- [x] A4 aplicó `00001_canonical_schema.sql` (con bloques RLS + RPCs concat) en branch nuevo `canonical-schema`.
- [ ] Edge functions canónicas desplegadas al branch (A5).
- [ ] Backup completo de producción (`pg_dump fpfvlrwcskhgsjuhrjpz > backup_pre_canonical.sql`) guardado fuera del project.

---

## 2. Export (lectura desde prod)

Script `scripts/canonical_migration/export.ts` que ejecuta SELECTs y emite un único JSON.

```typescript
const TABLES = [
  'profiles',
  'groups',
  'group_members',
  'invites',
  'identity_atoms',
  'resources',
  'system_events',
  'group_policies',
  'rsvp_actions',
  'user_actions',
  'ledger_entries',
  'notification_tokens',
  'notifications_outbox',
] as const;

for (const t of TABLES) {
  const { data } = await prodClient.from(t).select('*');
  fs.writeFileSync(`./dump/${t}.json`, JSON.stringify(data, null, 2));
}
```

Resultado esperado por table (filas):

```
profiles               11
groups                  3
group_members          13
invites                10
identity_atoms         12
resources               7
system_events          27
group_policies         24   (seeds; ver §4)
rsvp_actions            3
user_actions            2   (skip — ver §4)
ledger_entries          1
notification_tokens     1
notifications_outbox    1
```

---

## 3. Transform + import

Script `scripts/canonical_migration/import.ts`. Orden CRÍTICO (FK dependencies):

```
1. profiles
2. groups
3. group_purposes               (derivado de groups.description)
4. group_memberships            (de group_members)
5. group_membership_events      (sintético para los joins históricos)
6. (system roles + role_permissions + member_roles via create_group seed... ver §4)
7. resources                    (envelope desde resources)
8. group_resource_<subtype>     (split de resources.metadata)
9. group_resource_series        (skip — no rows en prod)
10. group_invites               (de invites)
11. ledger_entries → group_resource_transactions
12. rsvp_actions → group_rsvp_actions
13. system_events → group_events
14. notification_tokens, notifications_outbox
```

Cada step llama `supabase-js insert(..., { onConflict: 'id' })` contra el branch.

### 3.1 profiles → profiles

Mapping directo. Columnas:

| Prod | Canonical |
|---|---|
| `id` | `id` |
| `username` | `username` |
| `display_name` | `display_name` |
| `avatar_url` | `avatar_url` |
| `bio` | `bio` |
| `phone` | `phone` |
| `timezone` | `timezone` (default 'UTC' si null) |
| `locale` | `locale` (default 'es' si null) |
| `deleted_at` | `deleted_at` |
| `created_at` | `created_at` |
| `updated_at` | `updated_at` |

Si prod tiene `placeholder_*` columns (mig 00310): se pierden. Los placeholder
flows en canónico se manejan via `group_invites` + `group_memberships.status='invited'`.

### 3.2 groups → groups

| Prod | Canonical | Transform |
|---|---|---|
| `id` | `id` | passthrough |
| `name` | `name` | passthrough |
| `description` | `purpose_summary` | passthrough (queda como denormalized 1-liner) |
| `category` | `category` | passthrough |
| `governance` (jsonb) | `decision_rules` (jsonb) | rename only, mismo shape |
| `archived_at` | `archived_at` | passthrough |
| `roles` (jsonb) | `roles_catalog` (jsonb) | rename |
| `base_template` | — | **drop** (template scaffolding ya no aplica) |
| `invite_code` | — | drop (lo cubre group_invites.code) |
| `created_by` | `created_by` | passthrough |
| `settings` | `settings` | passthrough |
| — | `visibility` | default `'private'` |
| — | `status` | derive: `archived_at IS NOT NULL ? 'archived' : 'active'` |
| — | `dissolved_at` | NULL |

**Derived: `group_purposes`.** Para cada grupo, si `description` no es vacío,
insertar un row en `group_purposes`:

```ts
{
  group_id: g.id,
  kind: 'declared',
  body: g.description,
  visibility: 'members',
  status: 'active',
  created_by: g.created_by,
  created_at: g.created_at,
}
```

### 3.3 group_members → group_memberships

| Prod | Canonical | Transform |
|---|---|---|
| `id` | `id` | passthrough |
| `group_id` | `group_id` | passthrough |
| `user_id` | `user_id` | passthrough |
| `active` (bool) + `leftAt` | `status` | true → 'active'; false + leftAt → 'left'; otherwise → 'removed' |
| — | `membership_type` | default 'member' |
| `role` (text, deprecated) | — | **drop**; los roles vienen de `roles` jsonb |
| `roles` (jsonb) | — | leído para crear `group_member_roles` (ver §3.5) |
| `joined_at` | `joined_at` | passthrough |
| `leftAt` | `left_at` | passthrough |
| `joinedVia` | `joined_via` | rename |
| `turn_order` | `turn_order` | passthrough |
| `invited_by` | `invited_by` | passthrough |
| `metadata` | `metadata` | passthrough |
| `created_at`, `updated_at` | iguales | passthrough |

### 3.4 group_membership_events (sintético)

Prod no tiene esta tabla; se sintetiza para preservar historia mínima:

```ts
for (const m of memberships) {
  inserts.push({
    group_id: m.group_id,
    membership_id: m.id,
    actor_user_id: m.user_id,
    event_type: 'joined',
    reason: m.joined_via ?? 'migration',
    created_at: m.joined_at ?? m.created_at,
  });
  if (m.status === 'left' || m.status === 'removed') {
    inserts.push({
      group_id: m.group_id,
      membership_id: m.id,
      actor_user_id: m.user_id,
      event_type: m.status,
      reason: 'migration',
      created_at: m.left_at ?? m.updated_at,
    });
  }
}
```

### 3.5 Roles + role permissions + member_roles

Prod guarda los roles en dos lugares: `groups.roles` (catalog jsonb) y
`group_members.roles` (jsonb array de keys). Canonical normaliza a 3 tablas.

Para cada `group`:

1. Para cada role en `g.roles_catalog` (post-rename) o sus 3 defaults
   (`founder`, `admin`, `member`):
   - INSERT `group_roles` con `is_system=true` si key en {`founder`,`admin`,`member`}.
2. Para cada role: INSERT `group_role_permissions` con su permission_keys
   computados (founder = todos los keys; admin = subset operativo; member =
   keys baseline). Re-usa la lógica del RPC `create_group` (CanonicalSchema.sql §19).

Para cada `group_member`:

3. Por cada role_key en `m.roles[]`: lookup role_id en el grupo, INSERT
   `group_member_roles`.

Edge case: si `m.roles` está vacío (legacy founders sin migrar), asignar al menos
`member`.

### 3.6 invites → group_invites

| Prod | Canonical | Transform |
|---|---|---|
| `id` | `id` | passthrough |
| `group_id` | `group_id` | passthrough |
| `email` | `email` | passthrough |
| `phone` | `phone` | passthrough |
| `invited_user_id` | `invited_user_id` | passthrough |
| `placeholder_membership_id` | `placeholder_membership_id` | passthrough |
| `invited_by` | `invited_by` | passthrough |
| `used_at` IS NOT NULL | `status='accepted'` | derive |
| (otros) | `status='pending'\|'expired'\|'revoked'` | según expires_at vs now() y revoked_at |
| `code` | `code` | passthrough |
| `token` (raw) | `token_hash` | rehash con sha256 si era plaintext |
| `expires_at`, `accepted_at`, `metadata`, `created_at` | iguales | passthrough |

### 3.7 resources → group_resources + subtypes

Para cada `r in resources`:

1. INSERT envelope:

```ts
{
  id: r.id,
  group_id: r.group_id,
  resource_type: r.resource_type,
  name: r.metadata?.name ?? r.metadata?.title ?? 'Recurso',
  description: r.metadata?.description,
  status: r.archived_at ? 'archived' : 'active',
  visibility: 'members',
  ownership_kind: 'group',                  // default; founder puede ajustar luego
  metadata: r.metadata ?? {},
  created_by: r.created_by,
  archived_at: r.archived_at,
  series_id: r.series_id,
  created_at: r.created_at,
  updated_at: r.updated_at,
}
```

2. INSERT subtype según `r.resource_type`:

- **`event`** → `group_resource_events`:
  ```ts
  {
    resource_id: r.id,
    starts_at: r.metadata.starts_at,
    ends_at: r.metadata.ends_at,
    location: r.metadata.location,
    capacity: r.metadata.capacity,
    host_membership_id: r.metadata.host_membership_id,
    rsvp_deadline: r.metadata.rsvp_deadline,
  }
  ```

- **`fund`** → `group_resource_funds`:
  ```ts
  {
    resource_id: r.id,
    fund_kind: r.metadata.is_shared_pool ? 'shared_pool' : (r.metadata.is_protected ? 'protected' : 'pool'),
    currency: r.metadata.currency ?? 'MXN',
    is_shared_pool: r.metadata.is_shared_pool ?? false,
    is_in_kind: r.metadata.is_in_kind ?? false,
    threshold_target: r.metadata.threshold_target,
    locked_at: r.metadata.locked_at,
  }
  ```

- **`asset`** → `group_resource_assets`:
  ```ts
  {
    resource_id: r.id,
    asset_kind: r.metadata.kind,
    serial_number: r.metadata.serial_number,
    current_value: r.metadata.current_value,
    current_value_unit: r.metadata.current_value_unit,
    condition: r.metadata.condition,
    custodian_membership_id: r.metadata.custodian_membership_id,
  }
  ```

- **`space`** → `group_resource_spaces`:
  ```ts
  {
    resource_id: r.id,
    address: r.metadata.address,
    geo: r.metadata.geo,
    capacity: r.metadata.capacity,
    rules: r.metadata.rules,
  }
  ```

- **`slot` / `right`** → análogo a sus tablas con los campos correspondientes.

### 3.8 ledger_entries → group_resource_transactions

| Prod | Canonical | Transform |
|---|---|---|
| `id` | `id` | passthrough |
| `group_id` | `group_id` | passthrough |
| `source_resource_id` | `resource_id` | passthrough (prod usa source_resource para el recurso destino del entry) |
| `type` | `transaction_type` | mapping: `expense`→`expense`, `contribution`→`contribution`, `payout`→`payout`, `settlement`→`settlement_payment`, `fine_paid`→`fine_payment`, `pool_charge`→`pool_charge`. **Si `type='fine_issued'`: SKIP, no se migra al ledger** (no fue movimiento de valor; ver §4). |
| `from_member_id` | `from_membership_id` | passthrough |
| `to_member_id` | `to_membership_id` | passthrough |
| `paid_by_member_id` (metadata) | `paid_by_membership_id` | passthrough |
| `amount` | `amount` | passthrough (check > 0; si era 0 o negativo, log y skip) |
| `currency` | `unit` | rename |
| `reversed_entry_id` | `reversed_entry_id` | passthrough |
| `split_breakdown`, `split_mode` | iguales | passthrough |
| `in_kind` | `in_kind` | passthrough |
| `note`, `metadata` | `description`, `metadata` | rename note→description |
| `client_id` | `client_id` | passthrough |
| `created_by` | `recorded_by` | rename |
| `occurred_at`, `created_at` | iguales | passthrough |
| — | `source_entity_kind` | derive: si type era `settlement`→'settlement'; si `fine_paid`→'sanction'; etc. |
| — | `source_entity_id` | derive del metadata si presente |

### 3.9 rsvp_actions → group_rsvp_actions

Mapping directo. Renames mínimos: `action_status → rsvp_status` si aplica.

### 3.10 system_events → group_events

| Prod | Canonical | Transform |
|---|---|---|
| `id` | — | drop (canonical genera bigint cursor) |
| `id` (uuid) | `uuid_id` | passthrough |
| `group_id` | `group_id` | passthrough |
| `actor_user_id` | `actor_user_id` | passthrough |
| `event_type` | `event_type` | passthrough (keys ya casan: groupCreated, rsvpSubmitted, member.placeholder_created, etc.) |
| `entity_type` | `entity_kind` | rename |
| `entity_id` | `entity_id` | passthrough |
| `summary` | `summary` | passthrough |
| `payload` | `payload` | passthrough |
| `occurred_at` | `occurred_at` | passthrough |
| `created_at` | `created_at` | passthrough |

**Importante:** insertar con `service_role` para sortear la policy de RLS que
prohíbe INSERT de `authenticated` en `group_events`.

### 3.11 notification_tokens, notifications_outbox

Mapping directo. Verificar `platform in ('apns','fcm','web')`.

---

## 4. Tablas que NO se migran

| Tabla prod | Razón |
|---|---|
| `identity_atoms` | Sistema de placeholder linking obsoleto. Canonical lo cubre con `group_invites` + `group_memberships.status='invited'`. Los 12 rows ya están reflejados en `group_members.joined_via='placeholder_*'` y `invites`. |
| `group_policies` (24 rows) | Eran seeds per-grupo (8 policies × 3 grupos). Canonical re-seedea automáticamente via permissions catalog + role_permissions. |
| `user_actions` (2 rows) | Inbox state efímero; no es memoria. Si hay items aún pendientes, se re-emiten desde edge function al primer login post-migración. |
| `system_events` con `event_type` no reconocido | Log + skip; revisar manualmente. Snapshot actual no tiene event_types huérfanos. |
| `ledger_entries` con `type='fine_issued'` | No es movimiento de valor; iría en `group_sanctions` que en prod no tiene tabla equivalente migrable. Snapshot actual no tiene rows de este tipo (0 fines). |
| Tablas vacías en prod | Skip; estructura ya está en canonical. |

---

## 5. Verificación post-import

Script `scripts/canonical_migration/verify.ts`:

1. **Conteos esperados** (asserts):
   - `profiles` = 11
   - `groups` = 3
   - `group_purposes` = N donde N = grupos con description ≠ ∅ (esperado: ~2-3)
   - `group_memberships` = 13
   - `group_membership_events` ≥ 13 (al menos uno 'joined' por miembro)
   - `group_roles` = 9 (3 system × 3 grupos) + custom si aplican
   - `group_member_roles` ≥ 13 (al menos uno por miembro)
   - `group_invites` = 10
   - `group_resources` = 7
   - `group_resource_funds` = 3
   - `group_resource_assets` = 2
   - `group_resource_events` = 1
   - `group_resource_spaces` = 1
   - `group_resource_transactions` = 1
   - `group_rsvp_actions` = 3
   - `group_events` = 27
   - `notification_tokens` = 1
   - `notifications_outbox` = 1

2. **Same-group invariants** (debería pasar; si falla, hay bug en mapping):
   ```sql
   -- 0 rows expected:
   select * from group_member_roles gmr
     join group_memberships m on m.id = gmr.membership_id
     join group_roles r on r.id = gmr.role_id
    where m.group_id is distinct from r.group_id;
   ```

3. **Spot-check de un grupo conocido** (founder pick):
   - Sus miembros se ven en la lista.
   - Su evento conocido tiene RSVPs migrados.
   - Su fund tiene el transaction migrado.
   - `group_events` muestra el `groupCreated` original.

4. **Sanity Money 2.0:**
   - `group_resource_transactions.amount > 0` para todos.
   - No hay `transaction_type='fine_issued'`.

---

## 6. Rollback

Si la verificación falla:

1. NO se mergea el branch a main.
2. Branch se elimina: `mcp__supabase__delete_branch`.
3. Producción queda intacta.
4. Se identifica el bug en el script de migración, se corrige, se re-aplica
   en un branch nuevo, se re-verifica.

---

## 7. Cutover (A8 del Plan)

Solo cuando todas las verificaciones pasan:

1. Backup final: `pg_dump fpfvlrwcskhgsjuhrjpz > backup_pre_cutover.sql`.
2. `mcp__supabase__merge_branch` aplica el branch canónico a producción.
3. Las 343 migraciones legacy se mueven a `supabase/migrations/_archive/`.
4. `00001_canonical_schema.sql` (con bloques RLS + RPCs concat) queda como única migración viva.
5. Codegen Swift↔TS (A9): regenera tipos del nuevo schema.
6. iOS quedará temporalmente roto — esperado. Se restaura compilación en B1.

---

## 8. Pendientes

1. **Implementar `scripts/canonical_migration/{export,import,verify}.ts`.** Se hace en A3 del Plan, después de aprobar este spec.
2. **Decidir si las edge functions también migran logs o se reinician.** Snapshot actual indica `notifications_outbox` con 1 row pending — se migra para no perder el push.
3. **Confirmar política de `roles_catalog` seed.** Si los 3 grupos de prod ya tienen custom roles ahí, la lógica de §3.5 debe respetarlos. Verificar antes de export.
