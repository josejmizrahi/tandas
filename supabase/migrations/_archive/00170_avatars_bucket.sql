-- Mig 00170: Avatars storage bucket
--
-- Constitution: Layer 0 Identity. `profiles.avatar_url` existed since 00001
-- but no bucket nor RLS allowed clients to actually upload. This migration
-- creates a public `avatars` bucket scoped per-user:
--   - Objects live under `{auth.uid}/...` (folder-prefix-as-owner pattern).
--   - Only the owner can INSERT/UPDATE/DELETE objects under their prefix.
--   - SELECT is public so plain `getPublicURL` works without signing.
--
-- Bucket-level limits: 2 MB, images only (jpeg/png/webp/heic/heif). Heavier
-- formats are rejected at the storage layer before any DB write.

-- 1) Bucket (idempotent)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars',
  'avatars',
  true,
  2 * 1024 * 1024,
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']
)
on conflict (id) do update
   set public = excluded.public,
       file_size_limit = excluded.file_size_limit,
       allowed_mime_types = excluded.allowed_mime_types;

-- 2) RLS: only owner can write under their own prefix
drop policy if exists "avatars_owner_insert" on storage.objects;
create policy "avatars_owner_insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars_owner_update" on storage.objects;
create policy "avatars_owner_update"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars_owner_delete" on storage.objects;
create policy "avatars_owner_delete"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 3) Public read: bucket is public, but explicit policy makes intent clear.
drop policy if exists "avatars_public_select" on storage.objects;
create policy "avatars_public_select"
  on storage.objects for select to public
  using (bucket_id = 'avatars');
