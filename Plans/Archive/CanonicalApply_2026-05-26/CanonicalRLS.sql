-- ============================================================================
-- CanonicalRLS.sql — Row Level Security policies para canonical schema
-- ============================================================================
--
-- Se aplica DESPUÉS de `CanonicalSchema.sql`. Define todas las policies del
-- schema canónico siguiendo los 5 patrones documentados en
-- `Plans/Active/CanonicalSchema_RLS.md`.
--
-- Tablas append-only no aceptan INSERT desde `authenticated` — toda escritura
-- pasa por RPCs SECURITY DEFINER (catalogadas en CanonicalSchema_RPCs.md).
--
-- Decisiones lock (CanonicalSchema_RLS.md §40):
--   * NO policies `to anon` en V1.
--   * `group_events` insert = RPC-only.
--   * `dispute_events.body` = involved + records.read.
--   * `force row level security` = NO en V1 (re-evaluar pre-launch).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- §1. profiles
-- ----------------------------------------------------------------------------

create policy profiles_select_authenticated
  on public.profiles for select to authenticated using (true);

create policy profiles_insert_self
  on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));

create policy profiles_update_self
  on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy profiles_delete_self
  on public.profiles for delete to authenticated
  using (id = (select auth.uid()));

-- ----------------------------------------------------------------------------
-- §2. groups
-- ----------------------------------------------------------------------------

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

-- DELETE intencionalmente sin policy — archivar / disolver, nunca borrar.

-- ----------------------------------------------------------------------------
-- §3. group_purposes
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §4. group_memberships
-- ----------------------------------------------------------------------------

create policy group_memberships_select_members
  on public.group_memberships for select to authenticated
  using (public.is_group_member(group_id) or user_id = (select auth.uid()));

create policy group_memberships_insert_invite_accept
  on public.group_memberships for insert to authenticated
  with check (
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

-- ----------------------------------------------------------------------------
-- §5. group_membership_events (append-only, server-side only)
-- ----------------------------------------------------------------------------

create policy group_membership_events_select_members
  on public.group_membership_events for select to authenticated
  using (
    public.is_group_member(group_id)
    or exists (
      select 1 from public.group_memberships m
      where m.id = membership_id and m.user_id = (select auth.uid())
    )
  );
-- INSERT/UPDATE/DELETE = sin policies. Triggers atom_no_* bloquean update/delete.
-- INSERT solo via SECURITY DEFINER RPCs.

-- ----------------------------------------------------------------------------
-- §6. permissions (catalog público)
-- ----------------------------------------------------------------------------

create policy permissions_select_anyone
  on public.permissions for select to authenticated using (true);

-- ----------------------------------------------------------------------------
-- §7. group_roles
-- ----------------------------------------------------------------------------

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
    public.has_group_permission(group_id, 'roles.manage') and is_system = false
  )
  with check (
    public.has_group_permission(group_id, 'roles.manage') and is_system = false
  );

create policy group_roles_delete_permission
  on public.group_roles for delete to authenticated
  using (
    public.has_group_permission(group_id, 'roles.manage') and is_system = false
  );

-- ----------------------------------------------------------------------------
-- §8. group_role_permissions
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §9. group_member_roles
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §10. group_mandates (RPC-only write)
-- ----------------------------------------------------------------------------

create policy group_mandates_select_members
  on public.group_mandates for select to authenticated
  using (public.is_group_member(group_id));

-- ----------------------------------------------------------------------------
-- §11. rule_shapes_catalog
-- ----------------------------------------------------------------------------

create policy rule_shapes_catalog_select_anyone
  on public.rule_shapes_catalog for select to authenticated using (true);

-- ----------------------------------------------------------------------------
-- §12. group_rules
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §13. group_rule_versions (RPC-only write)
-- ----------------------------------------------------------------------------

create policy group_rule_versions_select_members
  on public.group_rule_versions for select to authenticated
  using (
    exists (
      select 1 from public.group_rules r
      where r.id = rule_id and public.is_group_member(r.group_id)
    )
  );

-- ----------------------------------------------------------------------------
-- §14. group_rule_evaluations (engine internal)
-- ----------------------------------------------------------------------------

create policy group_rule_evaluations_select_admin
  on public.group_rule_evaluations for select to authenticated
  using (public.has_group_permission(group_id, 'records.read'));

-- ----------------------------------------------------------------------------
-- §15. group_resources
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §16. Resource subtypes — events/funds/slots/spaces/assets/rights
--      Uniform pattern: gated by parent resource.
-- ----------------------------------------------------------------------------

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

create policy group_resource_funds_select_via_parent
  on public.group_resource_funds for select to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id)))
    )
  );
create policy group_resource_funds_write_via_parent
  on public.group_resource_funds for insert to authenticated
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );
create policy group_resource_funds_update_via_parent
  on public.group_resource_funds for update to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  )
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );

create policy group_resource_slots_select_via_parent
  on public.group_resource_slots for select to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id)))
    )
  );
create policy group_resource_slots_write_via_parent
  on public.group_resource_slots for insert to authenticated
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );
create policy group_resource_slots_update_via_parent
  on public.group_resource_slots for update to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  )
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );

create policy group_resource_spaces_select_via_parent
  on public.group_resource_spaces for select to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id)))
    )
  );
create policy group_resource_spaces_write_via_parent
  on public.group_resource_spaces for insert to authenticated
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );
create policy group_resource_spaces_update_via_parent
  on public.group_resource_spaces for update to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  )
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );

create policy group_resource_assets_select_via_parent
  on public.group_resource_assets for select to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id)))
    )
  );
create policy group_resource_assets_write_via_parent
  on public.group_resource_assets for insert to authenticated
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );
create policy group_resource_assets_update_via_parent
  on public.group_resource_assets for update to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  )
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );

create policy group_resource_rights_select_via_parent
  on public.group_resource_rights for select to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id)))
    )
  );
create policy group_resource_rights_write_via_parent
  on public.group_resource_rights for insert to authenticated
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );
create policy group_resource_rights_update_via_parent
  on public.group_resource_rights for update to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  )
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );

-- ----------------------------------------------------------------------------
-- §17. group_resource_asset_valuations (append-only via RPC)
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §18. group_resource_capabilities
-- ----------------------------------------------------------------------------

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
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );

create policy group_resource_capabilities_update_via_parent
  on public.group_resource_capabilities for update to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  )
  with check (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')
    )
  );

-- ----------------------------------------------------------------------------
-- §19. group_resource_series
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §20. group_resource_bookings, rsvp_actions, check_in_actions (RPC-only write)
-- ----------------------------------------------------------------------------

create policy group_resource_bookings_select_members
  on public.group_resource_bookings for select to authenticated
  using (public.is_group_member(group_id));

create policy group_rsvp_actions_select_members
  on public.group_rsvp_actions for select to authenticated
  using (public.is_group_member(group_id));

create policy group_check_in_actions_select_members
  on public.group_check_in_actions for select to authenticated
  using (public.is_group_member(group_id));

-- ----------------------------------------------------------------------------
-- §21. group_resource_transactions (Money 2.0 — RPC only)
-- ----------------------------------------------------------------------------

create policy group_resource_transactions_select_members
  on public.group_resource_transactions for select to authenticated
  using (public.is_group_member(group_id));

-- ----------------------------------------------------------------------------
-- §22. group_obligations / settlements / settlement_obligations (RPC only)
-- ----------------------------------------------------------------------------

create policy group_obligations_select_members
  on public.group_obligations for select to authenticated
  using (public.is_group_member(group_id));

create policy group_settlements_select_members
  on public.group_settlements for select to authenticated
  using (public.is_group_member(group_id));

create policy group_settlement_obligations_select_via_settlement
  on public.group_settlement_obligations for select to authenticated
  using (
    exists (
      select 1 from public.group_settlements s
      where s.id = settlement_id and public.is_group_member(s.group_id)
    )
  );

-- ----------------------------------------------------------------------------
-- §23. group_contributions
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §24. group_decisions
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §25. group_decision_options
-- ----------------------------------------------------------------------------

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
      where d.id = decision_id and public.has_group_permission(d.group_id, 'decisions.create')
    )
  );

-- ----------------------------------------------------------------------------
-- §26. group_votes (RPC-only write)
-- ----------------------------------------------------------------------------

create policy group_votes_select_members
  on public.group_votes for select to authenticated
  using (public.is_group_member(group_id));

-- ----------------------------------------------------------------------------
-- §27. group_sanctions (RPC-only write)
-- ----------------------------------------------------------------------------

create policy group_sanctions_select_visible
  on public.group_sanctions for select to authenticated
  using (
    public.is_group_member(group_id)
    or exists (
      select 1 from public.group_memberships m
      where m.id = target_membership_id and m.user_id = (select auth.uid())
    )
  );

-- ----------------------------------------------------------------------------
-- §28. group_disputes
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §29. group_dispute_events (RPC-only write)
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §30. group_reputation_events (RPC-only write)
-- ----------------------------------------------------------------------------

create policy group_reputation_events_select_visible
  on public.group_reputation_events for select to authenticated
  using (
    case visibility
      when 'public'  then true
      when 'members' then public.is_group_member(group_id)
      when 'private' then public.has_group_permission(group_id, 'records.read')
    end
  );

-- ----------------------------------------------------------------------------
-- §31. group_cultural_norms
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §32. group_dissolutions (RPC-only write)
-- ----------------------------------------------------------------------------

create policy group_dissolutions_select_members
  on public.group_dissolutions for select to authenticated
  using (public.is_group_member(group_id));

-- ----------------------------------------------------------------------------
-- §33. group_events (universal log — RPC-only)
-- ----------------------------------------------------------------------------

create policy group_events_select_members
  on public.group_events for select to authenticated
  using (public.is_group_member(group_id));

-- NO INSERT policy for authenticated — all writes via SECURITY DEFINER.

-- ----------------------------------------------------------------------------
-- §34. group_invites
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §35. notification_tokens (self)
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §36. notification_preferences (self)
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- §37. notifications_outbox (service-role only insert)
-- ----------------------------------------------------------------------------

create policy notifications_outbox_select_self
  on public.notifications_outbox for select to authenticated
  using (recipient_user_id = (select auth.uid()));

-- ============================================================================
-- §38. Realtime publication for multi-device sync
-- ============================================================================

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

-- ============================================================================
-- End — CanonicalRLS.sql
-- ============================================================================
