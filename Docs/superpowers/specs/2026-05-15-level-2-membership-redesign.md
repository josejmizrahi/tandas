# Nivel 2 — Membership / Relación: gaps + rediseño

**Fecha:** 2026-05-15
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Jerarquía:** `Plans/Active/HierarchyReference.md` §1 — Layer 2 (Membership/Relation)
**Migraciones base:** `00001` (`group_members`), `00004` (turn_order), `00019` (`roles` jsonb), `00035` (vote→remove trigger), `00088`/`00111` (policy resolver), `00106` (multi-role), `00115` (`leave_group`/`remove_member`), `00180` (`left_at`+`joined_via` audit)
**Spec hermanos:** Nivel 0 (Identity) y Nivel 1 (Group) — ambos shipped.

## Problema

Nivel 2 vive en `group_members`. El BE soporta lifecycle completo (join/leave/remove con audit), multi-role jsonb, turn_order, on_committee, invite system (`Invite` + `InviteRepository.createInvite/markUsed/listPending`), governance-gated mutations. El FE expone una rebanada estrecha y privilegia al admin:

1. **`EditMembersSheet` (578 L)** es la **única** entrada para ver miembros desde el grupo. Es admin-only en su affordance principal (kick, reorder). Member regular abre la misma sheet — UI confusa, mezcla "ver" con "administrar".

2. **`group_members.roles: jsonb`** es multi-role (founder, member, host, treasurer, arbiter, observer) mutable post-mig 00106. FE lo **lee** y muestra badges, pero **no permite cambiarlo**. No existe RPC `set_member_role`; cambios deben ir vía governance (`vote_required` policy). Como no hay RPC ni propose-flow, los roles son efectivamente inmutables tras la creación del grupo.

3. **`group_members.on_committee` boolean** controla elegibilidad para apelaciones. Sin UI para asignar. Apelaciones quedan rotas si nadie tiene el flag.

4. **`group_members.joined_via` + `joined_via_invite_code`** (mig 00180) registran cómo entró cada miembro (`founder_seed`/`invite_code`/`admin_add`). No visible en `MemberDetailView` — útil para soporte y trust.

5. **`group_members.left_at`** trackea ex-miembros. FE filtra `active=true` siempre — los ex-miembros son invisibles. Sin papelera ni historial.

6. **`InviteRepository.createInvite(groupId, phoneE164?)` y `listPending(groupId)`** existen. UI solo expone esto en **onboarding founder** (`InviteMembersView`). Post-creación, invitar más gente requiere usar el invite code manual o re-armar el flow. Sin "Invitar miembros" desde `GroupHomeView`.

7. **`Invite` model** con `markUsed`, `usedByUserId`, `expiresAt`, lifecycle completo en BE. Cero UI para ver "invites pendientes" del grupo (admin) o "mis invites enviados" (founder).

8. **`group_members.display_name_override: text`** permite a admin sobreescribir el display_name del perfil dentro del grupo. Cero UI. Useful para corregir nombre tras invite-by-phone donde el usuario aún no completó profile.

9. **Self-leave row** existe en `GroupHomeView.AVANZADO` (post-Nivel 1) pero el callback `onLeaveGroup` es no-op visual — no presenta confirmación, no muestra error si el usuario es único admin.

10. **`MemberDetailView` (182 L)** existe y muestra hero + roles + joined date. Pero el único entry point es `RSVPAvatarStrip` en event detail — no se llega desde `GroupHomeView → Miembros`. La sheet de members es lista plana sin tap-to-detail.

11. **Turn order drag** funciona en `EditMembersSheet` pero sin undo ni error recovery — si `setTurnOrder` falla, la app refresca silenciosamente.

12. **No hay `MembersCoordinator` dedicado.** `EditMembersSheet` usa `app.groupsRepo` directamente. Patrón inconsistente con Nivel 0/1.

13. **Privacy ungrouping:** member regular ve la lista completa con misma chrome que admin (botones de kick deshabilitados). Hubiera más limpio darle una vista "View only" simple.

## Objetivo

Que Nivel 2 tenga:

- **Dos surfaces separadas** desde `GroupHomeView → Miembros`:
  - **`MembersListView`** (read-only, todos): lista clara con avatares + roles + "joined hace N días". Tap → `MemberDetailView`.
  - **`MembersAdminView`** (admin-only): superset de la anterior con kick, reorder, role-change-propose, invite-more, view-pending-invites, view-ex-members.
- **Role change propose flow** (BE nuevo: `propose_member_role_change` RPC + FE picker). Si governance es `direct` → cambio inmediato; si `vote_required` → opens vote.
- **Bulk invite desde GroupHome** sin onboarding founder.
- **`MemberDetailView` mejorado** con joined_via, on_committee toggle (admin), pending invites del usuario.
- **Self-leave confirmable** desde GroupHome con guard "eres único admin".
- **`MembersCoordinator`** dedicated.

## Approach — 5 pasadas

### Pass 1 · Separar list (todos) de admin (admin), entry desde GroupHome

| Archivo | Acción |
|---|---|
| `Features/Members/MembersCoordinator.swift` | **NUEVO** (~90 L). Loads `[MemberWithProfile]` + active group + `app.session.user.id` para autodetect. |
| `Features/Members/Views/MembersListView.swift` | **NUEVO** (~180 L). Read-only para todos: avatar + display_name + roles badges + joined date. Tap → `MemberDetailView`. |
| `Features/Members/Views/MembersAdminView.swift` | **NUEVO** (~300 L). Refactor de `EditMembersSheet` con turn-reorder + kick + invite-more button. Hereda el coordinator + agrega admin gating. |
| `Features/Groups/Members/EditMembersSheet.swift` | **DELETE** (578 L). Su lógica se reparte entre las 2 nuevas. |
| `Features/Shell/RootShellState.swift` | **Modify**. Renombrar `case members` → `case membersAdmin`; agregar `case membersList`. |
| `Features/Shell/RootShellSheets.swift` | **Modify**. Dos handlers fullScreenCover (list + admin). |
| `Features/Shell/RootRouter.swift` | **Modify**. Renombrar `openMembers()` → `openMembersAdmin()`; agregar `openMembersList()`. |
| `Features/Group/Views/GroupHomeView.swift` | **Modify**. "Miembros" nav row check si actor es admin → admin view, sino list view. |

### Pass 2 · Bulk invite desde GroupHome + self-leave guard

| Archivo | Acción |
|---|---|
| `Features/Members/Views/InviteMembersFromGroupView.swift` | **NUEVO** (~220 L). Wrapper around existing `PhonePickerSheet` + manual entry + share link. Llamna `InviteRepository.createInvite` en batch. |
| `Features/Members/Views/LeaveGroupConfirmationSheet.swift` | **NUEVO** (~140 L). Confirmation con guard "eres único admin → transferir admin primero". |
| `Features/Group/Views/GroupHomeView.swift` | **Modify**. Wire `onLeaveGroup` → presenta sheet. Agregar "Invitar miembros" row admin-only en COMUNIDAD. |
| `Features/Members/Views/MembersAdminView.swift` | **Modify**. Botón "+" en navbar → `InviteMembersFromGroupView`. |

### Pass 3 · Role change propose flow (requiere migración BE)

| Archivo | Acción |
|---|---|
| `supabase/migrations/NEXT_propose_member_role_change.sql` | **NUEVO** (~100 L SQL). RPC `propose_member_role_change(p_group_id, p_user_id, p_new_roles[], p_reason?)`. Resuelve policy: si direct → applies + emite `memberRoleChanged` system_event; si vote_required → opens vote via existing infrastructure. |
| `Repositories/MembersRepository.swift` | **NUEVO** (~120 L). Methods: `proposeRoleChange(groupId:userId:newRoles:reason:)`, `toggleCommittee(groupId:userId:on:)`, `setDisplayNameOverride(groupId:userId:override:)`. |
| `Features/Members/Views/RoleChangePickerSheet.swift` | **NUEVO** (~200 L). Multi-select 6 roles del enum + reason input + "Proponer" button. Muestra si el cambio será directo o irá a voto. |
| `Features/Members/Views/MemberDetailView.swift` | **Modify**. Agrega: joined_via subtitle, on_committee toggle (admin), "Cambiar rol" button (admin). |

### Pass 4 · Ex-members + pending invites visibility

| Archivo | Acción |
|---|---|
| `Features/Members/Views/ExMembersView.swift` | **NUEVO**. Lista de `left_at IS NOT NULL` con avatar + nombre + "Salió hace X" + reason. Admin-only. |
| `Features/Members/Views/PendingInvitesView.swift` | **NUEVO**. `InviteRepository.listPending(groupId)` rendered con avatar (si tiene profile) + phone + sent date + share/revoke. |
| `Features/Members/Views/MembersAdminView.swift` | **Modify**. Tabs o secciones: Activos / Pendientes / Salieron. |

### Pass 5 · Polish: display_name_override editor + turn order error recovery

| Archivo | Acción |
|---|---|
| `Features/Members/Views/EditDisplayNameOverrideSheet.swift` | **NUEVO**. Admin abre desde `MemberDetailView` → guardar `display_name_override`. |
| `Features/Members/Views/MembersAdminView.swift` | **Modify**. Turn order drag con explicit "Guardar orden" button + error toast + undo. |

## Wireframe `MembersListView` (Pass 1)

```
┌─────────────────────────────────────────┐
│  ⟵                                       │
│  Miembros (8)                            │
│  ─────────────────────────────────────  │
│  ╭───╮                                   │
│  │ J │ José Mizrahi              FUNDADOR│
│  ╰───╯ Te                                 │
│  ─────────────────────────────────────  │
│  ╭───╮                                   │
│  │ A │ Ana López                ADMIN  →│
│  ╰───╯ Hace 3 meses                       │
│  ─────────────────────────────────────  │
│  ╭───╮                                   │
│  │ C │ Carla R.                         →│
│  ╰───╯ Hace 5 días                        │
│  ...                                      │
└─────────────────────────────────────────┘
```

## Wireframe `MembersAdminView` (Pass 1 + 4)

```
┌─────────────────────────────────────────┐
│  ⟵       Activos | Pendientes | Salieron│
│                                       +  │  ← invite from group
│  ┌──────────────────────────────────┐   │
│  │ José Mizrahi  FUNDADOR           │   │
│  │ Hace 6 meses · founder_seed       │   │
│  │ [Cambiar rol] [Tirar voto]       │   │  ← admin actions inline
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │ Ana López  ADMIN                 │   │
│  │ Hace 3 meses · invite_code        │   │
│  │ [Cambiar rol] [Echar]            │   │
│  └──────────────────────────────────┘   │
│  ...                                      │
│  ──────────────────────────────────     │
│  Drag para cambiar el turno  [Guardar]  │
└─────────────────────────────────────────┘
```

## Decisiones explícitas

1. **`EditMembersSheet` muere.** Su contenido se reparte en dos vistas según rol.
2. **`MembersAdminView` no es modal sino full-screen** (consistent con la política `.fullScreenCover`).
3. **Role change requires BE migration** — Pass 3 introduce `propose_member_role_change` RPC. No hay shortcut directo (governance debe gobernarlo).
4. **Self-leave** vive en GroupHome.AVANZADO con confirmation guard.
5. **Bulk invite** desde GroupHome reusa primitives del onboarding (`PhonePickerSheet`).
6. **`MemberDetailView`** es read-only para no-admin; admin ve toggles + actions inline.
7. **Ex-members** son visibles en una sección/tab separada — no "papelera" tipo Nivel 1, sino "Salieron" como tab dentro de admin view. Found member list shouldn't include them by default.
8. **Capability overrides** (mig propuesto pero no implementado) quedan fuera de scope — viven como rules según constitución.

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `MembersListViewSnapshot`: admin vs member ven la misma lista. `MembersAdminViewSnapshot`: el botón "Echar" sólo aparece para admin. |
| 2 | `LeaveGroupConfirmationSheet`: bloquea si único admin. `InviteMembersFromGroupView`: batch insert N invites. |
| 3 | `MembersRepositoryTests.proposeRoleChange`: direct vs vote_required paths. `RoleChangePickerSheet`: multi-select preserva selección al swap. |
| 4 | `ExMembersView`: solo `left_at IS NOT NULL`. `PendingInvitesView`: hide expired. |
| 5 | `EditDisplayNameOverrideSheet`: empty string → null. |

## Out of scope

- **Member-level capability overrides** (`member_capability_overrides` table — no implementado en BE; viven como rule exceptions per constitution)
- **Transfer admin** UI específico (deferred — usuarios pueden combinar role change + leave hoy)
- **Member-to-member chat** (Layer 16/futuro)
- **Member analytics** (asistencia, balance personal — vive en Profile/Activity)

## Cobertura del plan inicial

**Pass 1 + Pass 2 en el primer commit.** Es la separación estructural (list vs admin) + el wire-up de bulk invite y self-leave que post-Nivel 1 quedó pendiente. Pass 3 requiere migración BE — su propio plan después.

## Done When

- 5 pasadas mergeadas (los planes se hacen incrementalmente).
- `EditMembersSheet` no existe.
- Miembros tienen dos surfaces: list y admin.
- Bulk invite reachable desde GroupHome.
- Self-leave funcional con guard.
- Role change vía RPC nuevo + UI propose.
- Ex-members y pending invites visibles para admin.
- Build clean + smoke en simulador.
