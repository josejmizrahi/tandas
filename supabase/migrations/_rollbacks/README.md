# Rollback migrations

Each `<NNNNN>_rollback.sql` here is the inverse of the forward migration
`supabase/migrations/<NNNNN>_<name>.sql`. They live in a sibling
directory (this one) because the Supabase CLI scans `migrations/*.sql`
non-recursively, and rollbacks share a `version` prefix with their
forward counterpart — keeping both in the root caused
`schema_migrations_pkey` PK conflicts during `supabase start` in CI.

## When to use

- `supabase db reset` runs forward migrations only. Rollbacks are not
  automatically reverted.
- To revert one forward migration in dev/staging: run the matching
  `_rollbacks/<NNNNN>_rollback.sql` against the target DB via `psql` or
  the SQL editor.
- In prod, prefer fix-forward over rollback. Use these only when a
  forward migration is unrecoverable.

## Naming

Always `<NNNNN>_rollback.sql` where `<NNNNN>` matches the forward
migration. The pairing is by prefix; tooling and humans both rely on
it.

## Why subdir (not extension rename)

A subdirectory keeps the rollback files visible next to their forward
counterpart conceptually (`ls supabase/migrations/_rollbacks/`) without
breaking the supabase CLI's flat-scan model. An alternative
`.rollback.sql` double-extension would still end in `.sql` and
potentially be picked up by some tooling.
