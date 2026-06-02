-- §24. group_decisions
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

-- §25. group_decision_options
create policy group_decision_options_select_via_decision
  on public.group_decision_options for select to authenticated
  using (
    exists (select 1 from public.group_decisions d where d.id = decision_id and public.is_group_member(d.group_id))
  );
create policy group_decision_options_insert_via_decision
  on public.group_decision_options for insert to authenticated
  with check (
    exists (select 1 from public.group_decisions d where d.id = decision_id and public.has_group_permission(d.group_id, 'decisions.create'))
  );

-- §26. group_votes
create policy group_votes_select_members
  on public.group_votes for select to authenticated
  using (public.is_group_member(group_id));

-- §27. group_sanctions
create policy group_sanctions_select_visible
  on public.group_sanctions for select to authenticated
  using (
    public.is_group_member(group_id)
    or exists (
      select 1 from public.group_memberships m
      where m.id = target_membership_id and m.user_id = (select auth.uid())
    )
  );

-- §28. group_disputes
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

-- §29. group_dispute_events
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

-- §30. group_reputation_events
create policy group_reputation_events_select_visible
  on public.group_reputation_events for select to authenticated
  using (
    case visibility
      when 'public'  then true
      when 'members' then public.is_group_member(group_id)
      when 'private' then public.has_group_permission(group_id, 'records.read')
    end
  );

-- §31. group_cultural_norms
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

-- §32. group_dissolutions
create policy group_dissolutions_select_members
  on public.group_dissolutions for select to authenticated
  using (public.is_group_member(group_id));

-- §33. group_events
create policy group_events_select_members
  on public.group_events for select to authenticated
  using (public.is_group_member(group_id));

-- §34. group_invites
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

-- §35. notification_tokens
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

-- §36. notification_preferences
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

-- §37. notifications_outbox
create policy notifications_outbox_select_self
  on public.notifications_outbox for select to authenticated
  using (recipient_user_id = (select auth.uid()));

-- §38. Realtime publication
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
