-- §1. profiles
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

-- §2. groups
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

-- §3. group_purposes
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

-- §4. group_memberships
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

-- §5. group_membership_events
create policy group_membership_events_select_members
  on public.group_membership_events for select to authenticated
  using (
    public.is_group_member(group_id)
    or exists (
      select 1 from public.group_memberships m
      where m.id = membership_id and m.user_id = (select auth.uid())
    )
  );

-- §6. permissions
create policy permissions_select_anyone
  on public.permissions for select to authenticated using (true);

-- §7. group_roles
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
  using (public.has_group_permission(group_id, 'roles.manage') and is_system = false)
  with check (public.has_group_permission(group_id, 'roles.manage') and is_system = false);
create policy group_roles_delete_permission
  on public.group_roles for delete to authenticated
  using (public.has_group_permission(group_id, 'roles.manage') and is_system = false);

-- §8. group_role_permissions
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

-- §9. group_member_roles
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

-- §10. group_mandates
create policy group_mandates_select_members
  on public.group_mandates for select to authenticated
  using (public.is_group_member(group_id));

-- §11. rule_shapes_catalog
create policy rule_shapes_catalog_select_anyone
  on public.rule_shapes_catalog for select to authenticated using (true);

-- §12. group_rules
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

-- §13. group_rule_versions
create policy group_rule_versions_select_members
  on public.group_rule_versions for select to authenticated
  using (
    exists (
      select 1 from public.group_rules r
      where r.id = rule_id and public.is_group_member(r.group_id)
    )
  );

-- §14. group_rule_evaluations
create policy group_rule_evaluations_select_admin
  on public.group_rule_evaluations for select to authenticated
  using (public.has_group_permission(group_id, 'records.read'));

-- §15. group_resources
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
