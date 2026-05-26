# Ruul — Right Rules (Doctrina companion)

**Status:** Canónico desde 2026-05-17. Founder directive.
**Companion of:** `Plans/Active/Right.md` (spec del resource type), `Plans/Active/Constitution.md` (Artículo 2 — enum congelado), `Plans/Active/TalmudicGovernance.md` (claim vs permission), `Plans/Active/ConsistencyAudit_2026-05-17.md` (findings F2, F10, F20 — right tiene atoms pero no projection real).

> Un **`right`** es un **claim**: el reconocimiento explícito de que un holder puede ejercer una capability sobre un target, con scope/prioridad/exclusividad/transferabilidad/delegabilidad/divisibilidad/expiración configurables. **NO es un permiso. NO es una capability. NO es ownership-by-itself. NO es role.**

> El error doctrinal en Ruul al 2026-05-17: rights se implementaron con holder en `resources.metadata` mutado por `transfer_right`, y atoms emitidos como decoración. Este doc fija la separación entre las 7 distinciones que evitan colapsar right con sus vecinos.

---

## §1 — Las 7 distinciones cardinales

### 1. Right ≠ Permission

**Right** = claim posesivo, transferible, exhibible al sistema. Vive en `resources(type=right)`. Cualquier holder lo puede ejercer.

**Permission** = flag de role. Vive en `groups.roles[].permissions`. Cualquier miembro con ese role puede ejercer la acción asociada.

**Diferencia operativa:**
- Quitar permission a un miembro = cambiar su role. Quitar a varios = un solo update de role.
- Quitar right a un miembro = transfer/revoke atomico, individual, auditable, posiblemente votado.

**Naming hazard:** mig 00255 introduce permissions con nombres `transferRight`, `delegateRight`, etc. Son **flags que gatean RPCs**, no rights. Mantener la distinción mental.

### 2. Right ≠ Capability

**Capability** = comportamiento posible declarado en `capabilities` table. Aplica al resource. Ejemplo: `booking` capability sobre un space significa que se puede reservar.

**Right** = quien tiene el derecho de ejercer una capability con prioridad/exclusividad. Ejemplo: "Jose tiene right de booking sobre el palco con prioridad 1".

**Capability dice "qué se puede hacer". Right dice "quién, con qué cláusulas, lo puede hacer."**

### 3. Right ≠ Resource Ownership by Itself

**Ownership de un resource** = registrado en atoms (`assetTransferred`) + projection. Es propiedad del resource.

**Right** = puede sobrevivir al cambio de owner del target resource. Si la propiedad del palco se transfiere, los rights de socios viejos pueden persistir.

**Ejemplo:** Familia A vende palco a familia B. Los socios fundadores tienen `right` de uso 1 partido por mes por 10 años — el right sobrevive la transferencia de ownership del asset.

### 4. Right is a Claim Over a Resource/Capability/Benefit

**Estructura del right:**
- `holder` (member or external entity)
- `target` (resource id, capability, or generic "benefit")
- `scope` (qué incluye exactamente)
- `priority` (orden en colas/asignaciones)
- `exclusive` (si bloquea otros rights del mismo tipo)
- `divisible` (si se puede fraccionar)
- `transferable` (si se puede ceder)
- `delegable` (si se puede prestar temporalmente)
- `expires_at` (cuándo deja de tener efecto)

Sin `holder + target` un right no existe — no es un permiso flotante.

### 5. Rights Can Be Held, Transferred, Delegated, Revoked, Exercised

5 verbos distintos, 5 atoms distintos:

- **Held** (`rightCreated`) — el right se crea con un holder inicial.
- **Transferred** (`rightTransferred`) — holder cambia. Permanente (hasta otro transfer).
- **Delegated** (`rightDelegated`) — holder cede ejercicio temporal a otro sin cambiar holder. Tiene `until`.
- **Revoked** (`rightRevoked`) — admin/governance retira el right. Permanente. Diferente de transfer.
- **Exercised** (`rightExercised`) — holder usa el right. NO cambia holder. Solo registra el acto.

Plus 4 estados:
- **Suspended** (`rightSuspended`) — temporal pause. Reversible vía `rightRestored`.
- **Restored** (`rightRestored`) — unsuspend.
- **Expired** (`rightExpired`) — cron-driven en `expires_at`.
- **ExpiringSoon** (`rightExpiringSoon`) — cron warning ~7 días antes.

### 6. Possession ≠ Exercise

**Possession** = holder reconocido por el sistema. Holder puede no haber usado el right nunca.

**Exercise** = acto concreto de invocar el right. Tiene timestamp, contexto, posiblemente target específico (qué partido, qué fecha).

Atom `rightExercised` NO muta holder. Solo registra el uso. Esto es **CLEAN doctrinal en mig 00198** — `exercise_right` solo escribe `last_exercised_at` cache + emite atom.

Implicación: una projection de `right_use_count_view` puede contar exercises sin tocar possession.

### 7. Right Assignment Must Be Atom-Backed

**Cada asignación de right (create, transfer, delegate, revoke, suspend, restore, expire) DEBE emitir su atom canónico ANTES de cualquier mutación.**

Hoy (2026-05-17): los atoms se emiten, pero la mutación de `resources.metadata.holder_member_id` es la verdad operativa, y `right_holders_view` lee de metadata.

**Post-R2:** atoms son la verdad. `right_state_view` rebuilds holder/delegate/status from `system_events`. `right_holders_view` consume `right_state_view`. Mutación de metadata se elimina o se marca explícitamente como cache (con OperationalCacheDoctrine §5 entry).

---

## §8 — Right State Must Be Projection-Derived

Ver Axiom 12 (Projection ≠ Truth) en `ConsistencyAudit_2026-05-17.md` §2.

Hoy `right_holders_view` reads `resources.metadata.holder_member_id` directly — **violación F20**.

**Contract post-R2:**

```sql
CREATE VIEW right_state_view AS
WITH events AS (
  SELECT
    resource_id,
    occurred_at,
    event_type,
    payload
  FROM system_events
  WHERE event_type IN (
    'rightCreated', 'rightTransferred', 'rightDelegated',
    'rightRevoked', 'rightSuspended', 'rightRestored',
    'rightExpired', 'rightExercised'
  )
),
holder_chain AS (
  SELECT DISTINCT ON (resource_id)
    resource_id,
    CASE
      WHEN event_type = 'rightCreated' THEN payload->>'holder_member_id'
      WHEN event_type = 'rightTransferred' THEN payload->>'to_member_id'
      ELSE NULL
    END AS holder_member_id,
    occurred_at AS holder_since
  FROM events
  WHERE event_type IN ('rightCreated', 'rightTransferred')
  ORDER BY resource_id, occurred_at DESC
),
status_chain AS (
  SELECT DISTINCT ON (resource_id)
    resource_id,
    CASE
      WHEN event_type = 'rightRevoked' THEN 'revoked'
      WHEN event_type = 'rightExpired' THEN 'expired'
      WHEN event_type = 'rightSuspended' THEN 'suspended'
      WHEN event_type = 'rightRestored' THEN 'active'
      WHEN event_type = 'rightCreated' THEN 'active'
      WHEN event_type = 'rightTransferred' THEN 'active'
    END AS status
  FROM events
  ORDER BY resource_id, occurred_at DESC
),
delegate_chain AS (
  SELECT DISTINCT ON (resource_id)
    resource_id,
    CASE
      WHEN event_type = 'rightDelegated' AND (payload->>'until')::timestamptz > now()
        THEN payload->>'delegate_member_id'
      ELSE NULL
    END AS delegate_member_id,
    (payload->>'until')::timestamptz AS delegate_until
  FROM events
  WHERE event_type = 'rightDelegated'
  ORDER BY resource_id, occurred_at DESC
)
SELECT
  r.id AS right_id,
  r.group_id,
  r.metadata->>'target_resource_id' AS target_resource_id,
  h.holder_member_id,
  h.holder_since,
  d.delegate_member_id,
  d.delegate_until,
  s.status,
  (r.metadata->>'expires_at')::timestamptz AS expires_at
FROM resources r
LEFT JOIN holder_chain h USING (resource_id)
LEFT JOIN status_chain s USING (resource_id)
LEFT JOIN delegate_chain d USING (resource_id)
WHERE r.resource_type = 'right'
  AND r.archived_at IS NULL;
```

**Contract:** `right_holders_view` is rewritten as a wrapper over `right_state_view` for backward compatibility.

---

## §9 — RPC discipline post-R2

| RPC | Pre-R2 | Post-R2 |
|---|---|---|
| `create_right` | INSERT resources + INSERT atom | INSERT resources (config only) + emit `rightCreated` atom (carries holder); right_state_view derives holder |
| `transfer_right` | UPDATE metadata + emit atom | emit `rightTransferred` only; right_state_view picks up new holder |
| `delegate_right` | UPDATE metadata + emit atom | emit `rightDelegated` only |
| `revoke_right` | UPDATE status + emit atom | emit `rightRevoked` only |
| `suspend_right` | UPDATE metadata + emit atom | emit `rightSuspended` only |
| `restore_right` | UPDATE metadata + emit atom | emit `rightRestored` only |
| `exercise_right` | UPDATE last_exercised_at + emit atom | unchanged (UPDATE is OperationalCache acceptable) |
| `expire_due_rights` (cron) | UPDATE status + emit atom | emit `rightExpired` only; cron condition reads `expires_at` from `resources.metadata` (config, not state) |
| `update_right_metadata` | UPDATE metadata silently | **R8** — emit `rightMetadataUpdated(diff_jsonb)` atom; or split into per-knob RPCs each with own atom |

---

## §10 — Test contracts

- `test_right_state_view_derives_holder_from_atoms` — INSERT atoms with synthetic holder chain; verify view returns latest.
- `test_right_state_view_handles_revoke_then_restore` — sequence of revoke→restore should resolve status='active'.
- `test_right_transfer_does_not_mutate_metadata` — POST-R2.
- `test_right_exercise_does_not_change_holder` — already true; preserve.
- `test_update_right_metadata_emits_diff_atom` — POST-R8.
- `test_right_expiration_atom_emitted_for_each_due_right` — cron loop test.
- `test_right_delegation_expires_when_until_passes` — view should return NULL delegate_member_id when until < now.

---

## §11 — Lo que NUNCA se hace con rights

- Mutar `holder_member_id` directamente sin atom.
- Tratar right como ACL row.
- Crear `right_permissions` table separada de `groups.roles[].permissions`.
- Modelar capability como right (capability es declarativa, right es claim).
- Asumir que possession implica exercise.
- Borrar atoms de transfer chain.
- Permitir que la RPC mute metadata después de emitir atom (atom-first siempre).

---

## §12 — AI propose, no execute

AI puede:
- Sugerir transfer de right ("Jose no usa su right desde 6 meses; ¿transferir a Maria?") → genera draft proposal.
- Sugerir creación de nuevo right ("El grupo necesita un right de tesorería") → draft.
- Resumir histórico de holders.

AI NO puede:
- Emitir atoms de right.
- Mutar metadata de right.
- Auto-transfer / auto-revoke / auto-expire (la cron sí, AI no).

---

## §13 — Future extensions

- **Fractional rights** (`divisible=true`): un right puede tener N shares; transfer_right_share emite atom per share.
- **Conditional rights**: right efectivo solo si condición externa cumple (ej. "right activo si pagaste cuota anual"). Modelado como rule sobre el right resource.
- **External rights**: holder no es member sino persona externa (delegado, contractor). Requiere flagging para excluir de proyecciones internas.

Cada extension debe pasar el filtro ontológico §13 de Constitution.md antes de entrar.
