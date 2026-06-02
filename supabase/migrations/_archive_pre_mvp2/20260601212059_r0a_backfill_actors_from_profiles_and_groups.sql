-- R.0A MIG 2 — Backfill actor rows from existing profiles + groups.
-- Idempotente via ON CONFLICT DO NOTHING (re-corrible).
-- D2: UUIDs compartidos — actors.id = profiles.id (person) o actors.id = groups.id (group).
-- created_at/updated_at se setean al ahora; el row de profile/group conserva su histórico original.

INSERT INTO public.actors (id, actor_kind, display_name, metadata)
SELECT
  p.id,
  'person',
  COALESCE(NULLIF(p.display_name, ''), NULLIF(p.username, ''), '(unnamed person)'),
  jsonb_build_object('source', 'r0a_backfill', 'profile_created_at', p.created_at)
FROM public.profiles p
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.actors (id, actor_kind, display_name, metadata)
SELECT
  g.id,
  'group',
  COALESCE(NULLIF(g.name, ''), '(unnamed group)'),
  jsonb_build_object('source', 'r0a_backfill', 'group_created_at', g.created_at)
FROM public.groups g
ON CONFLICT (id) DO NOTHING;
