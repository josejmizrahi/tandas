-- ============================================================================
-- AUDIT.7 — Normalizar policies `{public}` → TO authenticated (2026-06-11)
-- ============================================================================
-- Fase 2 ítem 3 del SupabaseCleanupMigrationPlan. Seis policies declaraban el
-- rol implícito `public` en vez de `authenticated`. No es fuga (anon no tiene
-- grants de tabla y los quals exigen actor/membresía), pero la intención debe
-- ser explícita: defensa en profundidad si algún día se otorga un grant de
-- tabla a anon por error. Quals idénticos a los vigentes (pg_policies, live).
-- No-op funcional.
-- ============================================================================

-- actor_context_preferences
drop policy if exists "acp own read" on public.actor_context_preferences;
create policy "acp own read" on public.actor_context_preferences
  for select to authenticated
  using (actor_id = current_actor_id());

-- decision_options
drop policy if exists decision_options_select on public.decision_options;
create policy decision_options_select on public.decision_options
  for select to authenticated
  using (exists (
    select 1 from public.decisions d
    where d.id = decision_options.decision_id
      and is_context_member(d.context_actor_id)));

-- event_guests
drop policy if exists event_guests_read on public.event_guests;
create policy event_guests_read on public.event_guests
  for select to authenticated
  using (exists (
    select 1 from public.calendar_events ce
    where ce.id = event_guests.event_id
      and is_context_member(ce.context_actor_id)));

-- pool_accounts
drop policy if exists pool_accounts_select on public.pool_accounts;
create policy pool_accounts_select on public.pool_accounts
  for select to authenticated
  using (
    is_context_member(parent_context_actor_id)
    or exists (
      select 1 from public.pool_basis_entries pbe
      where pbe.pool_account_id = pool_accounts.id
        and pbe.contributor_actor_id = current_actor_id()));

-- pool_basis_entries
drop policy if exists pool_basis_entries_select on public.pool_basis_entries;
create policy pool_basis_entries_select on public.pool_basis_entries
  for select to authenticated
  using (
    contributor_actor_id = current_actor_id()
    or exists (
      select 1 from public.pool_accounts pa
      where pa.id = pool_basis_entries.pool_account_id
        and is_context_member(pa.parent_context_actor_id)));

-- rule_attention_items
drop policy if exists rule_attention_items_select_subject on public.rule_attention_items;
create policy rule_attention_items_select_subject on public.rule_attention_items
  for select to authenticated
  using (subject_actor_id = current_actor_id());
