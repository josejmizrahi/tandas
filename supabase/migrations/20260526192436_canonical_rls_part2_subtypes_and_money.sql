-- §16. Resource subtypes (events/funds/slots/spaces/assets/rights)
create policy group_resource_events_select_via_parent
  on public.group_resource_events for select to authenticated
  using (
    exists (
      select 1 from public.group_resources r
      where r.id = resource_id
        and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id)))
    )
  );
create policy group_resource_events_write_via_parent
  on public.group_resource_events for insert to authenticated
  with check (
    exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update'))
  );
create policy group_resource_events_update_via_parent
  on public.group_resource_events for update to authenticated
  using (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')))
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));

create policy group_resource_funds_select_via_parent
  on public.group_resource_funds for select to authenticated
  using (
    exists (select 1 from public.group_resources r where r.id = resource_id
      and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id))))
  );
create policy group_resource_funds_write_via_parent
  on public.group_resource_funds for insert to authenticated
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));
create policy group_resource_funds_update_via_parent
  on public.group_resource_funds for update to authenticated
  using (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')))
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));

create policy group_resource_slots_select_via_parent
  on public.group_resource_slots for select to authenticated
  using (
    exists (select 1 from public.group_resources r where r.id = resource_id
      and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id))))
  );
create policy group_resource_slots_write_via_parent
  on public.group_resource_slots for insert to authenticated
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));
create policy group_resource_slots_update_via_parent
  on public.group_resource_slots for update to authenticated
  using (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')))
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));

create policy group_resource_spaces_select_via_parent
  on public.group_resource_spaces for select to authenticated
  using (
    exists (select 1 from public.group_resources r where r.id = resource_id
      and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id))))
  );
create policy group_resource_spaces_write_via_parent
  on public.group_resource_spaces for insert to authenticated
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));
create policy group_resource_spaces_update_via_parent
  on public.group_resource_spaces for update to authenticated
  using (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')))
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));

create policy group_resource_assets_select_via_parent
  on public.group_resource_assets for select to authenticated
  using (
    exists (select 1 from public.group_resources r where r.id = resource_id
      and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id))))
  );
create policy group_resource_assets_write_via_parent
  on public.group_resource_assets for insert to authenticated
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));
create policy group_resource_assets_update_via_parent
  on public.group_resource_assets for update to authenticated
  using (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')))
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));

create policy group_resource_rights_select_via_parent
  on public.group_resource_rights for select to authenticated
  using (
    exists (select 1 from public.group_resources r where r.id = resource_id
      and (r.visibility = 'public' or (r.visibility = 'members' and public.is_group_member(r.group_id))))
  );
create policy group_resource_rights_write_via_parent
  on public.group_resource_rights for insert to authenticated
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));
create policy group_resource_rights_update_via_parent
  on public.group_resource_rights for update to authenticated
  using (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')))
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));

-- §17. group_resource_asset_valuations
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

-- §18. group_resource_capabilities
create policy group_resource_capabilities_select_via_parent
  on public.group_resource_capabilities for select to authenticated
  using (exists (select 1 from public.group_resources r where r.id = resource_id and public.is_group_member(r.group_id)));
create policy group_resource_capabilities_write_via_parent
  on public.group_resource_capabilities for insert to authenticated
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));
create policy group_resource_capabilities_update_via_parent
  on public.group_resource_capabilities for update to authenticated
  using (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')))
  with check (exists (select 1 from public.group_resources r where r.id = resource_id and public.has_group_permission(r.group_id, 'resources.update')));

-- §19. group_resource_series
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

-- §20. bookings / rsvp_actions / check_in_actions (read-only, write via RPC)
create policy group_resource_bookings_select_members
  on public.group_resource_bookings for select to authenticated
  using (public.is_group_member(group_id));
create policy group_rsvp_actions_select_members
  on public.group_rsvp_actions for select to authenticated
  using (public.is_group_member(group_id));
create policy group_check_in_actions_select_members
  on public.group_check_in_actions for select to authenticated
  using (public.is_group_member(group_id));

-- §21. group_resource_transactions
create policy group_resource_transactions_select_members
  on public.group_resource_transactions for select to authenticated
  using (public.is_group_member(group_id));

-- §22. obligations / settlements
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

-- §23. group_contributions
create policy group_contributions_select_members
  on public.group_contributions for select to authenticated
  using (public.is_group_member(group_id));
create policy group_contributions_insert_anymember
  on public.group_contributions for insert to authenticated
  with check (
    public.has_group_permission(group_id, 'contribution.record')
    and exists (select 1 from public.group_memberships m where m.id = membership_id and m.user_id = (select auth.uid()))
  );
create policy group_contributions_update_self_or_verifier
  on public.group_contributions for update to authenticated
  using (
    (status = 'claimed' and exists (select 1 from public.group_memberships m where m.id = membership_id and m.user_id = (select auth.uid())))
    or public.has_group_permission(group_id, 'records.read')
  )
  with check (
    public.has_group_permission(group_id, 'contribution.record')
    or public.has_group_permission(group_id, 'records.read')
  );
