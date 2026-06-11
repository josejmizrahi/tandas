-- ────────────────────────────────────────────────────────────────────────────
-- FE.5 (P1.2) — bucket `avatars` para fotos de perfil. Público para lectura
-- (AsyncImage directo entre miembros); escritura restringida a la carpeta del
-- propio actor: `{actor_id}/...`. Límite 2MB, solo imágenes.
-- ────────────────────────────────────────────────────────────────────────────

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do nothing;

drop policy if exists "avatars_insert_own_folder" on storage.objects;
create policy "avatars_insert_own_folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = public.current_actor_id()::text
  );

drop policy if exists "avatars_update_own_folder" on storage.objects;
create policy "avatars_update_own_folder"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = public.current_actor_id()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = public.current_actor_id()::text
  );
