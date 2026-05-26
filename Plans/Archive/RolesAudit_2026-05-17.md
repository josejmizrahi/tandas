# Roles / Permisos / Membresía — Auditoría 2026-05-17

> **Status:** Canon. Producto del audit cross-layer (DB · Edge · Swift · doctrina). Acompaña a `Plans/Active/RolesRemediation_2026-05-17.md` (plan ejecutable).

## TL;DR

Cuatro hallazgos estructurales gobiernan todo lo demás:

1. **`has_permission` existe pero NO se invoca** desde edge functions (0 calls) ni desde Swift (la implementación cliente es local — re-implementa lógica server-side). El comentario en `Permission.swift:5-7` que dice "calls server's has_permission()" es aspiracional, no real.
2. **RLS y RPC están en gates distintos para la misma acción** (fines/votes/rules/events). Funciona hoy porque las RPCs corren `SECURITY DEFINER` y bypassan RLS. Pero la asimetría es deuda doctrinal — un Phase-5 que quiera servir vía PostgREST directo se split-brainea.
3. **`members_update_admin` RLS (mig 00002:42)** permite a cualquier admin hacer `UPDATE group_members SET roles = ...` directo desde PostgREST, sin atom. Es el agujero más grande: bypassea `assign_role`/`unassign_role` y deja history vacía.
4. **`groups.roles` (catálogo) muta sin emitir atom** (mig 00230 explícito). Un founder puede borrar el rol `treasurer` y los 20 miembros lo pierden sin un solo `roleUnassigned` en `system_events`. Único rastro: `updated_at`.

Mig 00262 ("separate founder from admin") aterrizó al nivel de catálogo y seed pero **no cascadeó** a `is_group_admin`, RLS, ni Swift. Esa es la deuda subyacente que hace que todos los `is_group_admin` callsites sigan conflateando founder (identidad) y admin (capacidad).

---

## A. Mapa actual de roles/permisos

### Almacenes de roles (4 paralelos)

| Almacén | Tipo | Contenido | Mutación canónica | Atom |
|---|---|---|---|---|
| `groups.roles` jsonb | Catálogo | role_id → {label, permissions[], maxHolders, system} | `upsert_group_role` / `delete_group_role` RPCs (mig 00230) + RLS direct allowed | **NO** (deliberado) |
| `group_members.roles` jsonb[] | Asignación | array de role_ids del miembro | `assign_role` / `unassign_role` RPCs (mig 00229) + RLS direct allowed | sí en RPC, **NO** vía RLS |
| `group_members.role` text | Legacy proyección | `'admin' \| 'member'` | trigger `sync_group_members_role_text` (mig 00263) | nunca |
| `groups.governance` jsonb | Meta-policy | `whoCanCloseEvents → 'host'`, etc. | guarded por `guard_groups_governance_update` (mig 00124) — gate canónico `has_permission(modifyGovernance)` | no específico |
| `group_policies` table | Action-level policy | (group, action, scope) → required | RLS `has_permission(modifyGovernance)` (mig 00087) | no — config table |

### Resolvers de autorización (3 paralelos, no reconciliados)

| Resolver | Pregunta que responde | Source | Cobertura |
|---|---|---|---|
| `has_permission(group, user, perm)` | "¿este miembro tiene esta permission?" | `groups.roles` union semantics + alias `admin→founder` | 27 permissions; falta cobertura para 8+ RPCs (ver §H) |
| `is_group_admin(group, user)` | "¿es admin/founder?" | `group_members.role='admin'` text | usado por casi todo RLS y por 8+ RPCs |
| `resolve_governance(group, actor, action, payload)` | "¿esta acción requiere voto / admin_only / denied?" | `group_policies` → `groups.governance` fallback → `has_permission` | sólo 5 acciones implementadas: `rule.%`, `member.invite`, `member.remove`, `expense.create`, `capability.enable`. Todo lo demás cae en `denied(no_policy)` |

### Catálogo de permissions (en código, 27 enums)

`modifyGovernance, modifyRules, modifyMembers, assignRoles, removeMember, issueFine, voidFine, markFinePaid, closeAppeal, createVotes, castVote, manageEvents, manageModules, assignSlot, bookSlot, approveSlotSwap, fundContribute, fundWithdraw, fundAudit, expenseSubmit, expenseApprove, transferRight, delegateRight, revokeRight, suspendRight, exerciseRight` + `unknown(String)`

**No existe tabla canónica de permissions** — el catálogo vive como column defaults repetidos en mig 00063, 00233, 00236, 00237, 00255, 00262.

### Defaults por rol (post-mig 00262)

- **founder**: 16 permissions (todas las de admin + transfer/delegate/revoke/suspend/exerciseRight + manageEvents + manageModules + issueFine/markFinePaid)
- **admin**: 8 permissions (modifyGovernance, modifyRules, modifyMembers, assignRoles, removeMember, voidFine, closeAppeal, createVotes) — **NO recibió los backfills de 00233/00236/00237/00255**
- **member**: 2 permissions (createVotes, castVote)
- **treasurer / captain / arbiter / observer**: aparecen en `MemberRole` enum iOS pero **no en server defaults** — sólo se materializan si el usuario los crea vía `upsert_group_role`

---

## B. Fuentes de verdad encontradas

| Pregunta | Fuente canónica deseada | Fuente real hoy |
|---|---|---|
| ¿Quién es esta persona? | `auth.users` + `profiles` | ✅ idem |
| ¿Es miembro de este grupo? | `group_members` activo | ✅ idem (`is_group_member`) |
| ¿Qué roles tiene? | `group_members.roles` jsonb | ⚠️ duplicado en `.role` text + sync trigger |
| ¿Qué permissions tiene este rol? | `groups.roles[role_id].permissions` | ✅ pero sin atom on change |
| ¿Puede ejecutar acción X? | `has_permission(group, user, perm)` | ❌ disponible pero invocado en ~30% de los sitios; resto usa `is_group_admin` o lee roles directo |
| ¿La acción X requiere voto? | `resolve_governance(group, actor, action, payload)` | ⚠️ sólo 5 acciones cubiertas |
| ¿Es founder (identidad)? | `groups.created_by` (immutable) | ✅ pero usado inconsistentemente — `ResourceDetailSheet.isFounder` (Swift) lo mezcla con rol |
| ¿Es host de este evento? | `event.host_id` / `metadata.host_id` (contextual) | ✅ correcto |
| ¿Tiene custody de este asset? | atoms `custodyAssigned`/`custodyReleased` + projection | ✅ correcto (NO es rol) |
| ¿Tiene un right sobre X? | `resources(type=right)` con holder | ✅ correcto (NO es rol) |

---

## C. Violaciones doctrinales (cross-layer)

| # | Capa | Ubicación | Qué hace | Severidad |
|---|---|---|---|---|
| V1 | DB · RLS | `00002_rls.sql:42` `members_update_admin` | Permite UPDATE directo de `group_members.roles` sin atom | **DOCTRINAL VIOLATION** |
| V2 | DB · RLS | `00002_rls.sql:35` `groups_update_admin` | Permite UPDATE directo de `groups.roles` (catálogo) sin atom; trigger sólo guarda `governance` | **DOCTRINAL VIOLATION** |
| V3 | DB · RPC | `00252:85,161` `transfer_right` / `delegate_right` | Gate por `gm.role in ('founder','admin')` text, **a pesar de que `transferRight`/`delegateRight` están en el catálogo de permissions desde 00255** | **HERESY** |
| V4 | Edge · ALL | (ausente) | `has_permission` invocado **0 veces** en 16 edge functions | **DOCTRINAL VIOLATION** |
| V5 | Edge · HTTP | `send-event-notification/index.ts:38-119` | Service-role HTTP function sin auth check; cualquiera puede triggear pushes a miembros arbitrarios | **HERESY** |
| V6 | Edge · process-system-events | `:358-373` `createUserAction` | Hardcodea `'founder'` como pool de approvers V1 | TRANSITIONAL DEBT (confesado) |
| V7 | Edge · rule engine | `_shared/ruleEngineConditions.ts:186-192` `actorHasRole` | Engine evalúa "actor tiene este label" en vez de "actor tiene esta permission" — by design pero sortea la separación role≠permission | DOCTRINAL VIOLATION (arquitectural) |
| V8 | DB · trigger gap | (todos los emit-* crons) | Insertan a `system_events` directo en vez de via `record_system_event` RPC; `process-system-events` sí usa la RPC — inconsistente | DOCTRINAL VIOLATION |
| V9 | DB · RPC | `00027:37` `can_modify_rules` | Lee `gm.roles ? 'founder'` directo; usado por RLS `rules_update_governance` | DOCTRINAL VIOLATION |
| V10 | DB · RPC | `00203:375,446` `fund_lock` / `fund_unlock` | `is_group_admin` en vez de permission | DOCTRINAL VIOLATION |
| V11 | DB · RPC | `00266:548,737,805,864` space admin RPCs (`promote_from_waitlist`, `grant_access`, `revoke_access`, `update_metadata`, `archive_space`) | `is_group_admin` | DOCTRINAL VIOLATION |
| V12 | DB · RPC | `00177:64` `archive_group`, `00184` `archive_resource` | `is_group_admin` | DOCTRINAL VIOLATION |
| V13 | DB · RPC | `00148:636`, `00150:862` finalize_vote founder lookup | `gm.roles ?\| array['founder']` para encontrar quien aplica un cambio | DOCTRINAL VIOLATION |
| V14 | DB · RPC cascade | `delete_group_role` (mig 00230) | Strip de role de N miembros emite **0 atoms** | DOCTRINAL VIOLATION |
| V15 | Swift · resolver | `CapabilityResolver+SecondaryActions.swift` (14 sites) | Toma `viewerRole: MemberRole` y compara `== .founder` / `== .host` para gating de UI | DOCTRINAL VIOLATION |
| V16 | Swift · adapter | `UniversalResourceDetailView.swift:733` `viewerRole()` | Proyecta N rawRoles → 1 de 4 enum cases; custom roles colapsan a `.member` | DOCTRINAL VIOLATION |
| V17 | Swift · service | `GovernanceService.swift` `hasPermission` | Implementación local pura — no llama a la RPC `has_permission` server | DOCTRINAL VIOLATION |
| V18 | Swift · UI | `ResourceDetailSheet.swift:269` `isFounder` | Gate de "crear regla" por `group.createdBy == userId` (identidad) en vez de `.modifyRules` | DOCTRINAL VIOLATION |
| V19 | Swift · UI | `MoneySectionView.swift:285` `viewerIsAdmin` | `roles.contains(.founder)` para fund lock — comment admite "es admin-only server-side" | DOCTRINAL VIOLATION |
| V20 | Swift · service | `MembersCoordinator.swift:66,103` | Short-circuit `me.isAdmin` antes de consultar el catálogo — admin role bypassea el chequeo per-permission | TRANSITIONAL DEBT |
| V21 | Swift · model | `Member.swift:104,148,155`, `Group.swift:207`, `GovernanceService.swift:55`, `GroupHomeCoordinator.swift:41` | Alias hardcoded `'admin' ↔ 'founder'` en 5 archivos | TRANSITIONAL DEBT |
| V22 | Swift · model | `MemberRole` enum (iOS) | Falta el caso `admin` — `roles: [MemberRole]` typed dropea `admin` silenciosamente | TRANSITIONAL DEBT |
| V23 | DB · RLS | `00002_rls.sql:108-112,55-80,86-88,115-121,146-153,165` | Todo RLS write de fines/events/votes/pots/expenses/payments en `is_group_admin` (no `has_permission`) | TRANSITIONAL DEBT (RPCs DEFINER bypassan) |
| V24 | DB · sync | `00263_sync_role_text_includes_admin` | Mapea `roles ? 'admin' OR 'founder' → text='admin'` — re-conflata lo que 00262 separó | TRANSITIONAL DEBT (puente intencional) |
| V25 | Edge · `verify-otp` | `:147-150` | Promueve `auth.users` sin emitir atom `identityPromoted` | TRANSITIONAL DEBT |
| V26 | Swift · repo | `LiveGroupsRepository.swift:704-712` `leave` | Direct PostgREST `update(active=false)` en vez de la RPC `leave_group` | TRANSITIONAL DEBT (datos equivalentes vía trigger) |
| V27 | Doctrina interna | `groups.created_by` vs `groups.roles['founder']` | Founder es a la vez identidad immutable Y rol asignable — dos conceptos que comparten nombre | DOCTRINAL AMBIGUITY |

---

## D. Roles que deben **quedarse**

| Rol | Por qué | Acción |
|---|---|---|
| **member** | Default participant. Permission bundle mínimo (createVotes, castVote). Estable group-wide. | Mantener. Es el caso CLEAN del modelo role=bundle. |
| **admin** | Capacidad operativa del grupo, separada de identidad (post-00262). Bundle estable: modifyGovernance, modifyRules, modifyMembers, etc. | Mantener. **Cascadear 00262 a iOS y RLS** (ver §J). |
| **treasurer** | Bundle de money permissions (fundContribute/Withdraw/Audit, expenseApprove, issueFine). Persistente grupo-wide. | Mantener pero **definir como default seed**, hoy es ad-hoc en `MemberRole` enum sin server seed. |
| **captain** | Roster-rule scope per Governance.md §14. Persistente. | Mantener como **template-conditional role** (no default global; activable por templates de equipos). |
| **observer / arbiter** | Definidos en `MemberRole` enum iOS pero sin server seed ni uso real. | **Decisión pendiente**: o se promueven a defaults seedeados con permissions claras, o se borran del enum. Hoy son cargo cult. |

---

## E. Roles que deben convertirse en **rights**

Per RightRules §1.1 + Right.md §5: si tiene identidad, lifecycle, transferable, exclusive, expira, o sobrevive a su target → es right, no rol.

| Concepto | Por qué NO es rol | Modelado correcto |
|---|---|---|
| "Tesorero **del fondo X**" (vs treasurer del grupo) | Scoped a un resource específico, posiblemente transferible | `right` con target=fund, permission cluster=money_ops |
| "Owner" de cualquier asset/fund/space valioso | Implica ownership económico/social, transferible | `right(type=ownership)` con holder + target |
| "Custodian" de un asset (cuando hay ownership claim) | Si es solo "quien lo tiene físicamente" → atom `custodyAssigned`. Si implica derecho de uso → `right` | Ya correcto en código (no es rol). |
| "Voting power" diferenciado (1 socio = 3 votos) | Transferible, divisible | `right(type=voting_share)` con `divisible=true` |
| "Veto sobre transfers > $X" | Scoped, exclusive, prioritario | `right(type=veto)` con scope=action_class |
| "Membresía Gold" del club | Expira, transferible | `right` con `expires_at` |
| "Equity / vesting cliff" | Transferible, divisible, vesting | `right` con metadata |

**Heresía nombrada hoy:** mig 00255 introdujo permissions `transferRight`/`delegateRight`/`revokeRight`/`suspendRight`/`exerciseRight`. Esos **son permissions del sistema** (flags que gatean RPCs), no rights. El naming engaña pero la implementación es doctrinal — los rights de verdad viven en `resources(type=right)`.

**Heresía sin nombrar hoy:** founder. `groups.created_by` es identidad immutable; `groups.roles['founder']` es bundle de permisos. El campo `created_by` tiene comportamiento de right (sobrevive, da prioridad permanente, da control jurídico — RLS `groups_select_archived_founder`). Pero NO está modelado como `right`. **Recomendación doctrinal pendiente:** ¿debería existir un right autogenerado `right(type=founder_share, holder=created_by, target=group)`? Esto desbloquearía transferencia de fundación, que hoy es imposible.

---

## F. Roles que deben convertirse en **contextual assignments**

| Concepto | Modelado correcto | Estado hoy |
|---|---|---|
| **host de un evento** | `event.host_id` + atom `hostAssigned` + `participant_role` scoped al resource | ✅ correcto en DB; ❌ Swift `viewerRole == .host` confunde "host de este evento" con rol persistente |
| **starter / bench** de un partido | `participant_role` scoped al resource | n/a hoy (post-Beta) |
| **slot holder** (turno de rotación) | atoms `slotAssigned` + `current_host_view` projection | ✅ correcto |
| **booking holder** (reserva de space) | `bookings` + atom | ✅ correcto |
| **custodian de un asset** | atom `custodyAssigned` / `custodyReleased` | ✅ correcto (NO modelado como rol) |
| **organizer** | NO existe como rol. Si aparece, es "host" o "admin". | ✅ no presente |
| **guest** | No es rol completo. Relación limitada visible-only. | ⚠️ no modelada — sólo aparece en `RolePreset` enum como UI label |

---

## G. Roles que deben convertirse en **capability overrides**

Per HierarchyReference §7 + memoria `project_hierarchy_gaps`:

| Patrón | Modelado correcto | Estado |
|---|---|---|
| "David no entra a la rotativa" | `member_capability_overrides` con `eligibility_override` | tabla existe (mig 00181) |
| "Guest puede reservar excepcionalmente" | `capability_allow=true` override | idem |
| "Contador externo ve ledger" | `visibility_override` o policy scoped | idem |
| "Nuevo miembro exento de multa 30 días" | scoped rule con `obligation_exemption` | rules engine soporta |
| "Jose puede invitar 6 guests" | `quota_override` | idem |
| Per-member rule (sólo aplica a Isaac) | `membership_id` axis ortogonal (mig 00250) | ✅ correcto |

**Hallazgo F16 en ConsistencyAudit** sigue abierto: `member_capability_overrides.effective_until` muta sin atom. P7 post-Beta.

---

## H. RPCs / RLS / UI que leen roles incorrectamente

### RPCs que deben migrar a `has_permission`

| RPC | Mig | Gate actual | Gate correcto |
|---|---|---|---|
| `transfer_right` | 00252:85 | `gm.role in ('founder','admin')` | `has_permission(transferRight)` |
| `delegate_right` | 00252:161 | idem | `has_permission(delegateRight)` |
| `fund_lock` | 00203:375 | `is_group_admin` | `has_permission(modifyGovernance)` o nueva `lockFund` |
| `fund_unlock` | 00203:446 | idem | idem |
| `grant_space_access` | 00266:737 | `is_group_admin` | `has_permission(manageBookings)` (a definir) |
| `revoke_space_access` | 00266:805 | idem | idem |
| `update_space_metadata` | 00266:864 | idem | `has_permission(manageEvents)` o equivalente |
| `archive_space` | 00266:* | idem | `has_permission(modifyGovernance)` |
| `archive_group` | 00177:64 | idem | `has_permission(modifyGovernance)` |
| `archive_resource` | 00184 | idem | `has_permission(modifyGovernance)` |
| `promote_space_from_waitlist` | 00266:548 | idem | `has_permission(manageBookings)` |
| `can_modify_rules` | 00027:37 | `gm.roles ? 'founder'` | `has_permission(modifyRules)` |
| `finalize_vote` recipient lookup | 00148:636, 00150:862 | `gm.roles ?\| array['founder']` | `has_permission(modifyRules)` |

### RLS que deben migrar a `has_permission`

Toda mig 00002 (`groups`, `group_members`, `rules`, `fines`, `events`, `votes`, `pots`, `expenses`, `payments`, `invites`) usa `is_group_admin`. Mig 00078 (`resource_series`, `resource_capabilities`, `ledger_entries`) idem. Mig 00181 (`rule_evaluations`, `rule_conflicts`, `member_capability_overrides`) idem. → **Phase 5 RLS rewire** (declarado deferred en Primitives.md §11).

**Crítico (no es deferred):** `members_update_admin` RLS debe **además** prohibir UPDATE de `roles` column (patrón mig 00124 con BEFORE trigger raising on `roles IS DISTINCT FROM` cuando no es SECURITY DEFINER).

### Edge functions que deben llamar `has_permission`

- `process-system-events` debe reemplazar `'founder'` hardcoded por selector `$role.<perm-holder>` o llamar `has_permission`.
- `send-event-notification` debe verificar membresía + permission del caller (HERESY hoy).
- TODOS los crons que insertan a `system_events` directo deben routar via `record_system_event` RPC (consistencia con `process-system-events`).

### Swift que debe migrar

| Sitio | Cambio |
|---|---|
| `CapabilityResolver+SecondaryActions.swift` (14 sites) | Parametrizar en `Set<Permission>` o closure `(Permission) -> Bool` en vez de `viewerRole: MemberRole` |
| `UniversalResourceDetailView.swift:733` `viewerRole()` | Borrar. Reemplazar callsites por la cierre de permissions |
| `GovernanceService.swift` `hasPermission` | Reemplazar implementación local por llamada a RPC `has_permission` con cache |
| `GroupHomeCoordinator.swift:30,41,45` | `isCurrentUserAdmin` → `hasPermission(.modifyGovernance)` async |
| `VoteDetailCoordinator.swift:35-46` | `myRole == "founder" \|\| "admin"` → `hasPermission(.modifyGovernance)` (o nueva `.finalizeVote`) |
| `MoneySectionView.swift:285` | `roles.contains(.founder)` → `hasPermission(.modifyGovernance)` |
| `ResourceDetailSheet.swift:269` | `group.createdBy == userId` → `hasPermission(.modifyRules)` |
| `EventDetailHost.swift:261-268` | `isAdmin \|\| isHost` → `hasPermission(.modifyRules) \|\| viewer == host` |
| `MembersCoordinator.swift:66,103` | Borrar short-circuit `me.isAdmin`; consultar catálogo siempre |
| `Member.isAdmin` (line 147) | Reemplazar callers; deprecar el getter |
| `MemberRole` enum | Añadir caso `.admin`; auditar todos los `.contains(.founder)` que deberían ser `.contains(.admin)` |
| `LeaveGroupConfirmationSheet.swift:25` | `isSoleAdmin` cuenta "role name admin" — debe contar "miembros con `.modifyGovernance`" |

---

## I. Modelo canónico propuesto

```
─── Identity ────────────────────────────────────────
   auth.users            ← principal
   profiles              ← datos personales
   groups.created_by     ← founder identity (immutable)
                           [pendiente: ¿right autogenerado?]

─── Membership ──────────────────────────────────────
   group_members         ← relación User↔Group (Atom-ish)
                           active, joined_at, joined_via, left_at

─── Roles (permission bundles) ──────────────────────
   groups.roles jsonb    ← catálogo {role_id → permissions[]}
   group_members.roles[] ← asignación al miembro
   Sólo escritos via assign_role/unassign_role/upsert_role/delete_role
   Toda mutación emite atom (incl. cascade de delete_role)
   members_update_admin RLS NO permite roles column write
   groups_update_admin RLS NO permite roles column write
   group_members.role text column: ELIMINAR (post-cascade 00262)

─── Permissions (system flags) ──────────────────────
   public.permissions enum (formalizar como tabla catálogo)
   Resueltas exclusivamente via:
       has_permission(actor, group, perm)            -- yes/no
       resolve_governance(actor, group, action, payload) -- yes/vote/no
   NADIE lee roles[] directo.

─── Rights (claims) ─────────────────────────────────
   resources(type='right') con holder, target, scope,
   priority, exclusive, transferable, delegable, expires_at
   Mutados via atoms transfer/delegate/revoke/suspend/exercise
   [Phase 3: integrar rights en authorization helpers]

─── Capabilities (behavioral primitives) ────────────
   public.capabilities catalog (28 entries)
   resource_capabilities (per-resource enable/disable)
   member_capability_overrides (per-member exceptions)
   Capability dice "qué se puede"; permission dice "quién puede"

─── Policies (meta-rules) ───────────────────────────
   group_policies (action → required: admin_only|vote|denied)
   groups.governance jsonb (legacy fallback)
   Wrapped por resolve_governance

─── Contextual assignments ──────────────────────────
   event.host_id, slot atoms, custody atoms, bookings,
   participant_role (per-resource, scoped)
   NUNCA tocan group_members.roles
```

### Regla de oro

Toda autorización en código pasa por **una sola pregunta**:

```
has_permission(actor, action, scope)
   o
resolve_governance(actor, group, action, payload) → {allowed | vote_required | denied}
```

Prohibido:
- Leer `group_members.roles` fuera de los resolvers
- Leer `group_members.role` text en código nuevo (deprecated)
- Comparar strings de rol (`== 'admin'`, `.contains('founder')`) excepto en:
  - UI labels (icon, color, "Fundador" pill)
  - Sort order (founder primero)
  - System-role guards (`role.system && role.id == 'founder'`)

---

## J. Plan de migración (resumen — detalle en `RolesRemediation_2026-05-17.md`)

> Restricción cardinal: el freeze 2026-05-17 prohíbe nuevos primitives/types/capabilities. Todo lo siguiente es **fix de deuda doctrinal sobre lo existente** — encaja como Sprint 5 del freeze.

- **Sprint B (start aquí):** cerrar agujero RLS de mutación directa + emit atoms en mutación del catálogo. Server-only.
- **Sprint A:** cerrar el split founder/admin en iOS (`MemberRole.admin`, eliminar alias `'admin' ↔ 'founder'` en 5 archivos).
- **Sprint C:** eliminar `is_group_admin` callsites (RPC) — fix HERESY V3 + V10/V11/V12/V9/V13.
- **Sprint D:** atom-correctness en edge functions — fix HERESY V5 + V8 (crons → record_system_event).
- **Sprint E:** Swift `GovernanceService.hasPermission` llama RPC server + cache; refactor `CapabilityResolver+SecondaryActions`.
- **Sprint F:** cleanup tail (eliminar `group_members.role` text, RLS Phase 5 rewire, formalizar `public.permissions`).

---

## K. Clasificación role-por-role (audit §6)

| Rol | ¿Persistente? | ¿Contextual? | ¿Right? | ¿Permiso? | ¿Relación temporal? | Estado actual |
|---|---|---|---|---|---|---|
| **admin** | SÍ persistente del grupo | no | no | bundle de permissions | no | TRANSITIONAL DEBT — split de 00262 incompleto. Falta `MemberRole.admin` iOS + cascade RLS. |
| **owner** | NO existe como rol en Ruul | no | **SÍ debería ser right** | no | no | n/a — no implementado como rol. Si surge "owner de X" → modelar como `right`. |
| **founder** | SÍ pero **identidad + bundle simultáneo** | no | **AMBIGUO** — `created_by` tiene shape de right | bundle | no | DOCTRINAL AMBIGUITY — V27. Discusión pendiente. |
| **captain** | SÍ (roster scope) | "captain de este match" SÍ es contextual | no | bundle | no | ACCEPTABLE — definido en Governance.md; no en defaults seed actuales; iOS lo conoce como MemberRole case sin server backing. |
| **treasurer** | SÍ (money scope) | no | "treasurer del fondo X" SÍ es right | bundle | no | TRANSITIONAL DEBT — en MemberRole enum iOS sin server default seed. |
| **host** | **NO** debe ser persistente | **SÍ** contextual del evento | no | no | sí (lifecycle del evento) | CLEAN en DB (`event.host_id`); DOCTRINAL VIOLATION en Swift (`viewerRole == .host` y MemberRole case `.host` lo trata como persistente). |
| **custodian** | NO | **SÍ** atom-driven sobre asset | A veces SÍ es right | no | sí | CLEAN — no modelado como rol. |
| **organizer** | NO existe | n/a | n/a | n/a | n/a | CLEAN por ausencia. |
| **member** | SÍ default | no | no | bundle mínimo | no | CLEAN. |
| **guest** | NO debe ser rol | **SÍ** relación limitada | no | no | sí | ACCEPTABLE — no modelado como rol completo. Sólo aparece como UI preset. |
| **arbiter / observer** | dudoso | dudoso | n/a | bundle (sin definir) | dudoso | TRANSITIONAL DEBT — en `MemberRole` enum iOS sin uso real ni server seed. Cargo cult. **Decisión necesaria**: formalizar o borrar. |

---

## L. Severity summary

| Bucket | Count |
|---|---|
| HERESY (must fix urgent) | 3 (V3 transfer_right, V5 send-event-notification, parcialmente V4) |
| DOCTRINAL VIOLATION | 14 |
| TRANSITIONAL DEBT | 8 |
| DOCTRINAL AMBIGUITY | 1 (founder identity vs role — necesita decisión) |
| ACCEPTABLE | 4 |
| CLEAN | ~6 sitios |

**3 heresías deben caer dentro del freeze** (no son features, son agujeros de auth):
- V3 `transfer_right` / `delegate_right` text-column gate
- V5 `send-event-notification` sin auth
- V1+V2 `members_update_admin` / `groups_update_admin` permiten role writes directos sin atom

## M. Decisiones doctrinales pendientes

1. **Founder identity vs founder role** (V27): ¿materializar `groups.created_by` como `right(type=founder_share)` para habilitar transferencia? O declarar founder como caso especial inmutable.
2. **`actorHasRole` rule condition** (V7): ¿el engine puede seguir evaluando "actor tiene este label" o debe migrar a `actorHasPermission`? Hoy permite a un rule author "promover" un role a tener poderes sin pasar por permission catalog.
3. **arbiter / observer**: formalizar como server-seeded roles con permission bundle claro, o borrar del `MemberRole` enum iOS.

---

**Fin del audit.** Implementación: `Plans/Active/RolesRemediation_2026-05-17.md`.
