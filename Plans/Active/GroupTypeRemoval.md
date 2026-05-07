# GroupType Removal — follow-up to Audit § 5.3 #7c

> Status: scaffolding shipped 2026-05-07 (Template.config.presentation +
> defaultCategory + migration 00037). Removal of `GroupType` Swift enum
> + `groups.group_type` column deferred until consumers migrate.

## Why this is split out

The audit (`Plans/Active/Audit-2026-05-06.md` §5.3 item 7c) calls for full
removal of the legacy `GroupType` enum + the `groups.group_type` column,
folding their data into `templates.config.presentation` /
`templates.config.defaultCategory`.

Doing the full removal in one pass requires wiring **TemplateRegistry**
into the app bootstrap so consumers can read Template data instead of
GroupType. That plumbing is significant and overlaps with concurrent
design-system work that touches AppState. To avoid conflicts and keep
the changes mergeable in small pieces, the work is split:

- **Done**: Template gains `presentation` + `defaultCategory`.
  Accessors `Template.effective*` give the canonical values. Migration
  00037 populates the four template rows. GroupType is marked
  DEPRECATED in code.
- **Pending** (this doc): wire the registry, migrate consumers, drop
  the enum, drop the column.

## Pending tasks

1. **Wire TemplateRegistry into AppState**.
   - Instantiate `TemplateRegistry(repository: liveTemplateRepository)`
     during AppState bootstrap.
   - Call `await registry.refresh()` once after auth + groups load.
   - Expose `templateRegistry` on AppState so views/coordinators can
     `await app.templateRegistry.template(id: groupBaseTemplate)`.
   - Cache invalidation: refresh on `applicationDidBecomeActive` if
     more than N hours stale (defer; not critical).

2. **Migrate `GroupInfoSheet`** (the only non-test, non-repo consumer
   of `Group.groupType.displayName`).
   - Inject `Template?` from coordinator/parent, or `await` the
     registry inside the view's `task {}`.
   - Render `template?.effectiveDisplayName ?? group.category.displayName`.
   - Header subtitle becomes "Cena recurrente · 5 miembros" or, if the
     template hasn't loaded yet, falls back to category copy gracefully.

3. **Migrate `CreateGroupParams`** to drop `groupType: GroupType`.
   - Replace with `baseTemplate: String` (template id).
   - Update `MockGroupsRepository.create` and
     `LiveGroupsRepository.create` to forward `baseTemplate` instead.
   - The RPC `create_group_with_admin` signature change: replace
     `p_group_type text` with `p_base_template text`. Cohabitation
     pattern — keep both parameters for one release with the old
     param ignored, then drop.

4. **Migrate Onboarding flow**.
   - `FounderOnboardingCoordinator.createInitial(...)` currently
     hardcodes `GroupType.recurringDinner.rawValue`. Replace with
     `draft.template ?? TemplateRegistry.dinnerRecurringId`.

5. **Migrate tests**.
   - Drop the `GroupType decodes snake_case from Supabase` test
     (currently failing on main since 2eda57e — already broken by the
     parallel Group struct expansion).
   - Drop `groupType:` parameter passing in `MockGroupsRepositoryTests`.

6. **Drop `Group.groupType`**.
   - Remove the property + CodingKey + decoder line + init parameter.
   - Remove from `CreateGroupParams`.
   - Update all repository call sites (Mock + Live) to stop forwarding.

7. **Delete `ios/Tandas/Models/GroupType.swift`**.
   - Last step — verify zero references in the codebase first.

8. **Backend: deprecate then drop `groups.group_type` column**.
   - Migration N: alter column NULLABLE + COMMENT DEPRECATED, update
     `create_group_with_admin` to no longer require it.
   - Migration N+1 (after 2 weeks cohabitation): drop the column. Drop
     RPC parameter.

## DoD

- [ ] `grep -rn "GroupType\b" --include="*.swift" ios/` returns zero
      results.
- [ ] `groups.group_type` column dropped in prod.
- [ ] `Plans/Active/Audit-2026-05-06.md` §5.3 item 7c crossed off.
- [ ] Founder can still create a group from the Cena recurrente
      template; subtitle reads "Cena recurrente · X miembros".

## Estimated effort

1–1.5 days focused work once AppState is stable and not being touched
by parallel sessions.
