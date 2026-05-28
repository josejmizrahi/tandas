# CanonicalSchema_RLS.md — Policy set completo (DRAFT)

> Anexo de `Plans/Active/CanonicalSchema.sql`. Define toda la RLS del schema
> canónico. Cuando esté aprobado, su SQL se concatena al `00001_canonical_schema.sql`
> antes de aplicarlo en el branch (A4 del Plan).

## 0. Preámbulo

### Roles

- `authenticated` — usuarios logueados (auth.users).
- `service_role` — clave de servicio (edge functions, jobs, RPCs marcados security definer).
- `anon` — sin login. Por defecto **no tiene policies** (deniega todo).

### Helpers (definidos en `CanonicalSchema.sql §16`)

```sql
public.is_group_member(p_group_id uuid)               -- caller is active member
public.has_group_permission(p_group_id uuid, p_key text)  -- caller's roles grant key
public.assert_same_group(uuid, uuid)                  -- raises on mismatch
```

### Patrones canónicos

| Patrón | Quién lee | Quién escribe |
|---|---|---|
| **A — grupo + permiso** | miembros activos | quien tenga el permission key |
| **B — append-only vía RPC** | miembros activos | solo `service_role` (RPCs SECURITY DEFINER); UPDATE/DELETE bloqueado por triggers |
| **C — catálogo público** | cualquier authenticated | nadie desde app (DDL only) |
| **D — visibility-aware** | `public` o `members` o `private` segun campo | dueño + permisos |
| **E — self only** | dueño del row | dueño del row |

### Invariante (locked en doctrine)

> **Universal events server-side only.** `group_events`, `group_resource_transactions`,
> `group_obligations`, `group_settlements`, `group_settlement_obligations`,
> `group_votes`, `group_rule_versions`, `group_rule_evaluations`,
> `group_rsvp_actions`, `group_check_in_actions`, `group_dispute_events`,
> `group_membership_events`, `group_reputation_events`,
> `group_resource_asset_valuations`, `group_resource_bookings`,
> `notifications_outbox`
> **NO aceptan INSERT desde `authenticated`.** Solo via RPCs SECURITY DEFINER
> que validan permiso + lockean rows + emiten side-effects en transacción.

---

## 1. Identity — `profiles` (Patrón E)

```sql
create policy profiles_select_authenticated
  on public.profiles for select to authenticated
  using (true);

create policy profiles_insert_self
  on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));

create policy profiles_update_self
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy profiles_delete_self
  on public.profiles for delete to authenticated
  using (id = (select auth.uid()));
```

> Nota: `auth.users` row se elimina por cascada; `deleted_at` se setea via
> RPC `delete_and_export_my_data` (GDPR).

---

## 2. Groups — `groups` (Patrón D)

```sql
create policy groups_select_visible_or_member
  on public.groups for select to authenticated
  using (visibility = 'public' or public.is_group_member(id));

create policy groups_insert_authenticated
  on public.groups for insert to authenticated
  with check (created_by = (select auth.uid()));

create policy groups_update_with_permission
  on public.groups for update to authenticated
  using (public.has_group_permission(id, 'group.update'))
  with check (public.has_group_permission(id, 'group.update'));

-- DELETE deshabilitado: archivar / disolver, nunca borrar.
```

---

## 3. Purposes — `group_purposes` (Patrón A + visibility)

```sql
create policy group_purposes_select_visible
  on public.group_purposes for select to authenticated
  using (
    visibility = 'public'
    or (visibility = 'members' and public.is_group_member(group_id))
    or (visibility = 'private' and public.has_group_permission(group_id, 'purpose.set'))
  );

create policy group_purposes_insert_permission
  on public.group_purposes for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'purpose.set')
    and created_by = (select auth.uid())
  );

create policy group_purposes_update_permission
  on public.group_purposes for update to authenticated
  using (public.has_group_permission(group_id, 'purpose.set'))
  with check (public.has_group_permission(group_id, 'purpose.set'));
```

---

## 4. Memberships — `group_memberships` (Patrón A)

```sql
create policy group_memberships_select_members
  on public.group_memberships for select to authenticated
  using (public.is_group_member(group_id) or user_id = (select auth.uid()));

create policy group_memberships_insert_invite_accept
  on public.group_memberships for insert to authenticated
  with check (
    -- Permitido solo: el caller se agrega a sí mismo aceptando invitación, O
    --                 alguien con members.invite agrega placeholder.
    user_id = (select auth.uid())
    or public.has_group_permission(group_id, 'members.invite')
  );

create policy group_memberships_update_permission_or_self_leave
  on public.group_memberships for update to authenticated
  using (
    public.has_group_permission(group_id, 'members.update')
    or (user_id = (select auth.uid()) and status in ('active','provisional'))
  )
  with check (
    public.has_group_permission(group_id, 'members.update')
    or (user_id = (select auth.uid()) and status = 'left')
  );

-- DELETE deshabilitado: se desactiva con status, nunca se borra.
```

---

## 5. Membership events — `group_membership_events` (Patrón B)

```sql
create policy group_membership_events_select_members
  on public.group_membership_events for select to authenticated
  using (
    public.is_group_member(group_id)
    or exists (
      select 1 from public.group_memberships m
      where m.id = membership_id and m.user_id = (select auth.uid())
    )
  );

-- INSERT/UPDATE/DELETE = sin policies para authenticated.
-- Solo via SECURITY DEFINER RPC (record_membership_event).
```

---

## 6. Permissions catalog — `permissions` (Patrón C)

```sql
create policy permissions_select_anyone
  on public.permissions for select to authenticated using (true);

-- INSERT/UPDATE/DELETE = sin policies. Solo DDL (migraciones).
```

---

## 7. Group roles — `group_roles` (Patrón A)

```sql
create policy group_roles_select_members
  on public.group_roles for select to authenticated
  using (public.is_group_member(group_id));

create policy group_roles_insert_permission
  on public.group_roles for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'roles.manage')
    and is_system = false
  );

create policy group_roles_update_permission
  on public.group_roles for update to authenticated
  using (
    public.has_group_permission(group_id, 'roles.manage')
    and is_system = false
  )
  with check (
    public.has_group_permission(group_id, 'roles.manage')
    and is_system = false
  );

create policy group_roles_delete_permission
  on public.group_roles for delete to authenticated
  using (
    public.has_group_permission(group_id, 'roles.manage')
    and is_system = false
  );
```

> System roles (founder/admin/member) creados por `create_group` solo se
> modifican via DDL o RPCs internas.

---

## 8. Role permissions — `group_role_permissions` (Patrón A via role)

```sql
create policy group_role_permissions_select_members
  on public.group_role_permissions for select to authenticated
  using (
    exists (
      select 1 from public.group_roles r
      where r.id = role_id and public.is_group_member(r.group_id)
    )
  );

create policy group_role_permissions_insert_permission
  on public.group_role_permissions for insert to authenticated
  with check (
    exists (
      select 1 from public.group_roles r
      where r.id = role_id
        and public.has_group_permission(r.group_id, 'roles.manage')
        and r.is_system = false
    )
  );

create policy group_role_permissions_delete_permission
  on public.group_role_permissions for delete to authenticated
  using (
    exists (
      select 1 from public.group_roles r
      where r.id = role_id
        and public.has_group_permission(r.group_id, 'roles.manage')
        and r.is_system = false
    )
  );
```

---

## 9. Member roles — `group_member_roles` (Patrón A via membership)

```sql
create policy group_member_roles_select_members
  on public.group_member_roles for select to authenticated
  using (
    exists (
      select 1 from public.group_memberships m
      where m.id = membership_id and public.is_group_member(m.group_id)
    )
  );

create policy group_member_roles_insert_permission
  on public.group_member_roles for insert to authenticated
  with check (
    exists (
      select 1 from public.group_memberships m
      where m.id = membership_id
        and public.has_group_permission(m.group_id, 'roles.manage')
    )
  );

create policy group_member_roles_delete_permission
  on public.group_member_roles for delete to authenticated
  using (
    exists (
      select 1 from public.group_memberships m
      where m.id = membership_id
        and public.has_group_permission(m.group_id, 'roles.manage')
    )
  );
```

---

## 10. Mandates — `group_mandates` (Patrón A)

```sql
create policy group_mandates_select_members
  on public.group_mandates for select to authenticated
  using (public.is_group_member(group_id));

-- INSERT/UPDATE/DELETE solo via RPC grant_mandate / revoke_mandate
-- (creación libre podría burlar audit + same-group asserts).
```

---

## 11. Rule shapes catalog — `rule_shapes_catalog` (Patrón C)

```sql
create policy rule_shapes_catalog_select_anyone
  on public.rule_shapes_catalog for select to authenticated using (true);

-- DDL only.
```

---

## 12. Rules — `group_rules` (Patrón A)

```sql
create policy group_rules_select_members
  on public.group_rules for select to authenticated
  using (public.is_group_member(group_id));

create policy group_rules_insert_permission
  on public.group_rules for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'rules.create')
    and created_by = (select auth.uid())
  );

create policy group_rules_update_permission
  on public.group_rules for update to authenticated
  using (public.has_group_permission(group_id, 'rules.update'))
  with check (public.has_group_permission(group_id, 'rules.update'));

-- DELETE deshabilitado: archivar via status.
```

---

## 13. Rule versions — `group_rule_versions` (Patrón B)

```sql
create policy group_rule_versions_select_members
  on public.group_rule_versions for select to authenticated
  using (
    exists (
      select 1 from public.group_rules r
      where r.id = rule_id and public.is_group_member(r.group_id)
    )
  );

-- INSERT solo via RPC publish_rule_version (SECURITY DEFINER).
-- UPDATE bloqueado por atom_no_mutation_guard salvo effective_until.
-- DELETE bloqueado por atom_no_delete_guard.
```

---

## 14. Rule evaluations — `group_rule_evaluations` (Patrón B)

```sql
create policy group_rule_evaluations_select_admin
  on public.group_rule_evaluations for select to authenticated
  using (public.has_group_permission(group_id, 'records.read'));

-- INSERT solo via edge function (rule engine), corre con service_role.
```

> Las evaluaciones son ruido para miembros normales. Solo se exponen vía
> RuleDetailView → Activity bajo permiso `records.read`.

---

## 15. Resources — `group_resources` (Patrón A)

```sql
create policy group_resources_select_visible
  on public.group_resources for select to authenticated
  using (
    visibility = 'public'
    or (visibility = 'members' and public.is_group_member(group_id))
    or (visibility = 'private' and public.has_group_permission(group_id, 'records.read'))
  );

create policy group_resources_insert_permission
  on public.group_resources for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'resources.create')
    and created_by = (select auth.uid())
  );

create policy group_resources_update_permission
  on public.group_resources for update to authenticated
  using (public.has_group_permission(group_id, 'resources.update'))
  with check (public.has_group_permission(group_id, 'resources.update'));

-- DELETE deshabilitado: archivar.
```

---

## 16. Resource subtypes (events/funds/slots/spaces/assets/rights)

Pattern uniforme — SELECT/INSERT/UPDATE chequean acceso al parent resource.
Ejemplo para `group_resource_events`:

```sql
create policy group_resource_events_select_via_parent
  on public.group_resource_events for select to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and (
          r.visibility = 'public'
          or (r.visibility = 'members' and public.is_group_member(r.group_id))
        )
    )
  );

create policy group_resource_events_write_via_parent
  on public.group_resource_events for insert to authenticated
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and public.has_group_permission(r.group_id, 'resources.update')
    )
  );

create policy group_resource_events_update_via_parent
  on public.group_resource_events for update to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and public.has_group_permission(r.group_id, 'resources.update')
    )
  )
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and public.has_group_permission(r.group_id, 'resources.update')
    )
  );
```

Replica idéntico cambiando `group_resource_events` por:
- `group_resource_funds`
- `group_resource_slots`
- `group_resource_spaces`
- `group_resource_assets`
- `group_resource_rights`

---

## 17. Asset valuations — `group_resource_asset_valuations` (Patrón B)

```sql
create policy group_resource_asset_valuations_select_via_parent
  on public.group_resource_asset_valuations for select to authenticated
  using (
    exists (
      select 1 from public.group_resource_assets a
      join public.group_resources r on r.id = a.resource_id
      where a.resource_id = group_resource_asset_valuations.resource_id
        and public.is_group_member(r.group_id)
    )
  );

-- INSERT solo via RPC record_asset_valuation.
```

---

## 18. Resource capabilities — `group_resource_capabilities` (Patrón A via resource)

```sql
create policy group_resource_capabilities_select_via_parent
  on public.group_resource_capabilities for select to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.is_group_member(r.group_id)
    )
  );

create policy group_resource_capabilities_write_via_parent
  on public.group_resource_capabilities for insert to authenticated
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and public.has_group_permission(r.group_id, 'resources.update')
    )
  );

create policy group_resource_capabilities_update_via_parent
  on public.group_resource_capabilities for update to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and public.has_group_permission(r.group_id, 'resources.update')
    )
  )
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and public.has_group_permission(r.group_id, 'resources.update')
    )
  );
```

---

## 19. Resource series — `group_resource_series` (Patrón A)

```sql
create policy group_resource_series_select_members
  on public.group_resource_series for select to authenticated
  using (public.is_group_member(group_id));

create policy group_resource_series_insert_permission
  on public.group_resource_series for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'resources.create')
    and created_by = (select auth.uid())
  );

create policy group_resource_series_update_permission
  on public.group_resource_series for update to authenticated
  using (public.has_group_permission(group_id, 'resources.update'))
  with check (public.has_group_permission(group_id, 'resources.update'));
```

---

## 20. Bookings / RSVP / Check-in (Patrón B — append-only via RPC)

```sql
-- bookings
create policy group_resource_bookings_select_members
  on public.group_resource_bookings for select to authenticated
  using (public.is_group_member(group_id));

-- INSERT solo via RPC book_resource (chequea bookings.create + atom guard).

-- rsvp
create policy group_rsvp_actions_select_members
  on public.group_rsvp_actions for select to authenticated
  using (public.is_group_member(group_id));

-- INSERT solo via RPC submit_rsvp.

-- check-in
create policy group_check_in_actions_select_members
  on public.group_check_in_actions for select to authenticated
  using (public.is_group_member(group_id));

-- INSERT solo via RPC submit_check_in.
```

---

## 21. Transactions — `group_resource_transactions` (Patrón B, Money 2.0)

```sql
create policy group_resource_transactions_select_members
  on public.group_resource_transactions for select to authenticated
  using (public.is_group_member(group_id));

-- INSERT solo via RPCs Money 2.0 (record_expense, record_contribution,
-- record_settlement_v2, record_pool_charge, record_payout, reverse_ledger_entry).
-- Estas RPCs:
--   * SECURITY DEFINER + set search_path = public
--   * verifican has_group_permission(group_id, '<key>')
--   * lockean obligations.FOR UPDATE para FIFO
--   * escriben en transacción: transaction + (obligation|settlement|...) + group_events
```

---

## 22. Money 2.0 entities — obligations, settlements, settlement_obligations (Patrón B)

```sql
-- obligations
create policy group_obligations_select_members
  on public.group_obligations for select to authenticated
  using (public.is_group_member(group_id));
-- INSERT/UPDATE solo via RPCs Money 2.0.

-- settlements
create policy group_settlements_select_members
  on public.group_settlements for select to authenticated
  using (public.is_group_member(group_id));
-- INSERT/UPDATE solo via RPC record_settlement_v2.

-- settlement_obligations
create policy group_settlement_obligations_select_via_settlement
  on public.group_settlement_obligations for select to authenticated
  using (
    exists (
      select 1 from public.group_settlements s
      where s.id = settlement_id and public.is_group_member(s.group_id)
    )
  );
-- INSERT solo via record_settlement_v2 (calculo FIFO).
```

---

## 23. Contributions — `group_contributions` (Patrón A)

```sql
create policy group_contributions_select_members
  on public.group_contributions for select to authenticated
  using (public.is_group_member(group_id));

create policy group_contributions_insert_anymember
  on public.group_contributions for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'contribution.record')
    and exists (
      select 1 from public.group_memberships m
      where m.id = membership_id and m.user_id = (select auth.uid())
    )
  );

create policy group_contributions_update_self_or_verifier
  on public.group_contributions for update to authenticated
  using (
    -- self can edit description/title while still 'claimed'
    (status = 'claimed'
      and exists (
        select 1 from public.group_memberships m
        where m.id = membership_id and m.user_id = (select auth.uid())
      ))
    or public.has_group_permission(group_id, 'records.read')
  )
  with check (
    public.has_group_permission(group_id, 'contribution.record')
    or public.has_group_permission(group_id, 'records.read')
  );
```

> Doctrina "registrar ≠ aprobar": cualquier miembro registra; verificar/rechazar
> requiere permiso aparte (vía RPC `verify_contribution`).

---

## 24. Decisions — `group_decisions` (Patrón A)

```sql
create policy group_decisions_select_members
  on public.group_decisions for select to authenticated
  using (public.is_group_member(group_id));

create policy group_decisions_insert_permission
  on public.group_decisions for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'decisions.create')
    and created_by = (select auth.uid())
  );

create policy group_decisions_update_permission
  on public.group_decisions for update to authenticated
  using (public.has_group_permission(group_id, 'decisions.resolve'))
  with check (public.has_group_permission(group_id, 'decisions.resolve'));
```

> Open → closed → passed/rejected transitions corren via RPC `start_vote` /
> `finalize_vote`; UPDATE policy permite cancel/edit pre-open.

---

## 25. Decision options — `group_decision_options` (Patrón A via decision)

```sql
create policy group_decision_options_select_via_decision
  on public.group_decision_options for select to authenticated
  using (
    exists (
      select 1 from public.group_decisions d
      where d.id = decision_id and public.is_group_member(d.group_id)
    )
  );

create policy group_decision_options_insert_via_decision
  on public.group_decision_options for insert to authenticated
  with check (
    exists (
      select 1 from public.group_decisions d
      where d.id = decision_id
        and public.has_group_permission(d.group_id, 'decisions.create')
    )
  );
```

---

## 26. Votes — `group_votes` (Patrón B, append vía RPC `cast_vote`)

```sql
create policy group_votes_select_members
  on public.group_votes for select to authenticated
  using (public.is_group_member(group_id));

-- INSERT solo via RPC cast_vote. Esta verifica:
--   * decision.status = 'open'
--   * has_group_permission(group_id, 'decisions.vote')
--   * voter_membership corresponde al caller
--   * decision.committee_only ⇒ voter is on committee
```

---

## 27. Sanctions — `group_sanctions` (Patrón A + RPC para issue)

```sql
create policy group_sanctions_select_visible
  on public.group_sanctions for select to authenticated
  using (
    public.is_group_member(group_id)
    or exists (
      select 1 from public.group_memberships m
      where m.id = target_membership_id and m.user_id = (select auth.uid())
    )
  );

-- INSERT solo via RPC issue_sanction (verifica sanctions.create + atom).
-- UPDATE permitido para resolución / dispute outcome via RPC.
```

---

## 28. Disputes — `group_disputes` (Patrón A)

```sql
create policy group_disputes_select_involved_or_records
  on public.group_disputes for select to authenticated
  using (
    public.is_group_member(group_id)
    and (
      public.has_group_permission(group_id, 'records.read')
      or exists (
        select 1 from public.group_memberships m
        where m.user_id = (select auth.uid())
          and m.id in (opened_by_membership_id, respondent_membership_id, mediator_membership_id)
      )
    )
  );

create policy group_disputes_insert_permission
  on public.group_disputes for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'disputes.open')
    and exists (
      select 1 from public.group_memberships m
      where m.id = opened_by_membership_id and m.user_id = (select auth.uid())
    )
  );

create policy group_disputes_update_mediator
  on public.group_disputes for update to authenticated
  using (
    public.has_group_permission(group_id, 'disputes.mediate')
    or public.has_group_permission(group_id, 'disputes.resolve')
  )
  with check (
    public.has_group_permission(group_id, 'disputes.mediate')
    or public.has_group_permission(group_id, 'disputes.resolve')
  );
```

> SELECT es estricta: solo involucrados o quien tenga `records.read`. Una
> disputa NO es público entre miembros del grupo por default.

---

## 29. Dispute events — `group_dispute_events` (Patrón B via dispute)

```sql
create policy group_dispute_events_select_via_dispute
  on public.group_dispute_events for select to authenticated
  using (
    exists (
      select 1 from public.group_disputes d
      where d.id = dispute_id
        and public.is_group_member(d.group_id)
        and (
          public.has_group_permission(d.group_id, 'records.read')
          or exists (
            select 1 from public.group_memberships m
            where m.user_id = (select auth.uid())
              and m.id in (d.opened_by_membership_id, d.respondent_membership_id, d.mediator_membership_id)
          )
        )
    )
  );

-- INSERT solo via RPC append_dispute_event.
```

---

## 30. Reputation — `group_reputation_events` (Patrón B)

```sql
create policy group_reputation_events_select_visible
  on public.group_reputation_events for select to authenticated
  using (
    case visibility
      when 'public'  then true
      when 'members' then public.is_group_member(group_id)
      when 'private' then public.has_group_permission(group_id, 'records.read')
    end
  );

-- INSERT solo via RPC record_reputation_event (triggers atom guards).
-- Actores con reputation.record pueden añadir manualmente; el resto se
-- emite automáticamente desde RPC de obligation_settled / sanction_issued / etc.
```

---

## 31. Cultural norms — `group_cultural_norms` (Patrón A + visibility)

```sql
create policy group_cultural_norms_select_visible
  on public.group_cultural_norms for select to authenticated
  using (
    visibility = 'public'
    or (visibility = 'members' and public.is_group_member(group_id))
  );

create policy group_cultural_norms_insert_permission
  on public.group_cultural_norms for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'culture.propose')
    and proposed_by = (select auth.uid())
  );

create policy group_cultural_norms_update_endorse
  on public.group_cultural_norms for update to authenticated
  using (
    public.has_group_permission(group_id, 'culture.endorse')
    or proposed_by = (select auth.uid())
  )
  with check (
    public.has_group_permission(group_id, 'culture.endorse')
    or proposed_by = (select auth.uid())
  );
```

---

## 32. Dissolutions — `group_dissolutions` (Patrón A, gate alto)

```sql
create policy group_dissolutions_select_members
  on public.group_dissolutions for select to authenticated
  using (public.is_group_member(group_id));

-- INSERT/UPDATE solo via RPCs propose_dissolution / approve_dissolution /
-- record_liquidation_step / finalize_dissolution. Cada una valida group.dissolve
-- + estado anterior.
```

---

## 33. Universal events — `group_events` (Patrón B — server-side ONLY)

```sql
create policy group_events_select_members
  on public.group_events for select to authenticated
  using (public.is_group_member(group_id));

-- INSERT/UPDATE/DELETE = sin policies para authenticated.
-- Toda escritura proviene de SECURITY DEFINER RPCs / triggers internos.
-- Esta es la barrera más estricta del schema.
```

---

## 34. Invites — `group_invites` (Patrón A + self lookup)

```sql
create policy group_invites_select_visible
  on public.group_invites for select to authenticated
  using (
    public.has_group_permission(group_id, 'members.invite')
    or invited_user_id = (select auth.uid())
    or (email is not null and email = (select email from auth.users where id = (select auth.uid())))
  );

create policy group_invites_insert_permission
  on public.group_invites for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'members.invite')
    and invited_by = (select auth.uid())
  );

create policy group_invites_update_invitee_or_inviter
  on public.group_invites for update to authenticated
  using (
    invited_user_id = (select auth.uid())
    or public.has_group_permission(group_id, 'members.invite')
  )
  with check (
    invited_user_id = (select auth.uid())
    or public.has_group_permission(group_id, 'members.invite')
  );
```

---

## 35. Notification tokens — `notification_tokens` (Patrón E)

```sql
create policy notification_tokens_select_self
  on public.notification_tokens for select to authenticated
  using (user_id = (select auth.uid()));

create policy notification_tokens_insert_self
  on public.notification_tokens for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy notification_tokens_update_self
  on public.notification_tokens for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy notification_tokens_delete_self
  on public.notification_tokens for delete to authenticated
  using (user_id = (select auth.uid()));
```

---

## 36. Notification preferences — `notification_preferences` (Patrón E)

```sql
create policy notification_preferences_select_self
  on public.notification_preferences for select to authenticated
  using (user_id = (select auth.uid()));

create policy notification_preferences_upsert_self
  on public.notification_preferences for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and public.is_group_member(group_id)
  );

create policy notification_preferences_update_self
  on public.notification_preferences for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy notification_preferences_delete_self
  on public.notification_preferences for delete to authenticated
  using (user_id = (select auth.uid()));
```

---

## 37. Notifications outbox — `notifications_outbox` (Patrón B)

```sql
create policy notifications_outbox_select_self
  on public.notifications_outbox for select to authenticated
  using (recipient_user_id = (select auth.uid()));

-- INSERT/UPDATE solo desde edge functions (service_role).
-- Dispatcher actualiza dispatch_status.
```

---

## 38. Bucket policies (storage)

Buckets que existirán en `storage.buckets`:

- `avatars` — públicos por user_id prefix.
- `group_avatars` — públicos por group_id prefix.
- `dispute_evidence` — privados, leíbles solo por involucrados (via signed URL emitida por RPC).

Las policies de storage van en una migración separada (`00002_storage_buckets.sql`)
porque dependen de `storage.objects` y `storage.buckets`.

---

## 39. Realtime publication

Tablas que se publican via `supabase_realtime` (para multi-device):

```sql
alter publication supabase_realtime add table public.group_memberships;
alter publication supabase_realtime add table public.group_resources;
alter publication supabase_realtime add table public.group_resource_events;
alter publication supabase_realtime add table public.group_decisions;
alter publication supabase_realtime add table public.group_votes;
alter publication supabase_realtime add table public.group_sanctions;
alter publication supabase_realtime add table public.group_obligations;
alter publication supabase_realtime add table public.group_settlements;
alter publication supabase_realtime add table public.group_disputes;
alter publication supabase_realtime add table public.group_events;
alter publication supabase_realtime add table public.notifications_outbox;
alter publication supabase_realtime add table public.group_rsvp_actions;
alter publication supabase_realtime add table public.group_check_in_actions;
alter publication supabase_realtime add table public.group_resource_transactions;
```

---

## 40. Decisiones cerradas (locked 2026-05-26)

1. **`anon` role: NO en V1.** Ruul es private-first; no hay discovery público de grupos. La landing de invite funciona con el token en URL (sin DB pre-login) y dispara signup; después se llama `accept_invite` autenticado. Si V2 agrega grupos públicos descubribles, se agregan policies `to anon` SELECT específicas entonces, no antes.

2. **`group_events.insert` = RPC-only.** Costo aceptado: toda acción iOS que dispare memoria pasa por una RPC SECURITY DEFINER. Beneficio: memoria es inmutable y consistente con el resto del estado (transacción única). Side-effects cross-cutting (notifications, rule engine triggers, reputation events) viven server-side, no en el cliente.

3. **`dispute_events.body`: involucrados + `records.read`.** Confirmado. Privacy fuerte por default, escalable cuando el admin necesita auditar abuso.

4. **`force row level security`: NO en V1, sí en V1.1 post security-review.** `service_role` bypassa RLS por default (norma Supabase). El rule engine cron + dispatcher cross-tenant operan con service_role. Forzar RLS exige refactor a session-context (`SET LOCAL ruul.group_id`) que es un trabajo aparte. Decisión revertible: si el security review pre-launch detecta un riesgo concreto, se aplica `force row level security` a las tablas más sensibles (`group_resource_transactions`, `group_obligations`, `group_settlements`, `group_sanctions`, `group_disputes`, `group_dissolutions`, `group_reputation_events`).

Estas decisiones son input directo para `CanonicalSchema_RPCs.md` — las RPCs cubren la totalidad de los flujos write que iOS necesita.
