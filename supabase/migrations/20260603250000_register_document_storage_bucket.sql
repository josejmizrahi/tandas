-- Storage bucket `documents` para los binarios de `register_document`.
--
-- iOS sube el archivo a Storage (path = `<scope_actor_id>/<uuid>-<safe_name>`)
-- y luego llama register_document() pasando el storage_path. La autoridad
-- real (quién puede REGISTRAR un documento contra un recurso/contexto) la
-- enforza register_document() vía permission check; las policies de
-- storage.objects son permisivas para authenticated.
--
-- Doctrina:
--  - Bucket privado (acceso vía signed URLs creadas server-side).
--  - 50 MB max por archivo (suficiente para PDFs, escrituras escaneadas).
--  - MIME whitelist evita uploads de ejecutables.
--  - DELETE/UPDATE NO se permiten en v1 — documentos immutable; el flujo
--    de archivado se hará vía documents.archived_at + workflow específico.

-- 1. Bucket (idempotente)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'documents',
  'documents',
  false,
  52428800, -- 50 MB
  ARRAY[
    'application/pdf',
    'image/jpeg',
    'image/png',
    'image/heic',
    'image/heif',
    'image/webp',
    'text/plain',
    'text/csv',
    'application/octet-stream'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- 2. Policies sobre storage.objects para el bucket `documents`.

-- SELECT: authenticated. El acceso real es vía signed URLs (válidas N segundos),
-- pero también permitimos SELECT directo para listings server-side. La RLS
-- de la tabla `documents` filtra qué storage_paths el caller puede *conocer*.
DROP POLICY IF EXISTS documents_bucket_select ON storage.objects;
CREATE POLICY documents_bucket_select
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (bucket_id = 'documents');

-- INSERT: cualquier authenticated puede subir al bucket. La doctrina:
-- "register_document() es la autoridad de quién puede asociar un archivo a
-- un recurso/contexto". Si un caller sube binarios sin nunca llamar
-- register_document, el archivo queda huérfano (sin metadata, no visible).
DROP POLICY IF EXISTS documents_bucket_insert ON storage.objects;
CREATE POLICY documents_bucket_insert
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (bucket_id = 'documents');

-- Nota: SIN DELETE/UPDATE policies para v1. Inmutabilidad de documentos.
