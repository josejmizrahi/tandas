# Documents V2 — first true test of the stack

**Fecha:** 2026-06-07
**Status:** 📝 PLAN — pendiente founder ack scope antes de implementar
**Bloquea:** R.5Z Founder Flow #10 (Subir documento) · R.6 Rule Engine
**Bloqueado por:** R.5V.0/V.1/V.2 ✅ (founder priority gate)
**Companion:** `Plans/Active/R5V_UXDoctrine.md §4 §11` · `Plans/Active/PreR6_Roadmap.md`

---

## Por qué importa

Founder firma 2026-06-07: *"Documents será la primera prueba real de UX Doctrine + Theme Tokens + Ruul Components + Descriptor Architecture. Si Documents sale bien, probablemente Decision Detail, Actor Detail y Event Detail salgan mucho más rápido después."*

Founder priority #1 del R.5X audit: **"deuda evidente"** — `documents_preview` llega del backend (R.5A.B.7.1) y se decodea en iOS, pero **NO existen** `DocumentsListView` ni `DocumentDetailView`. ContextV2 More tab `documents` row abre `ActivityFeedView` como fallback (botón fantasma honest).

---

## Recap UX Doctrine §4 (qué es un documento)

| Tipo | Use case |
|---|---|
| `contract` | Acuerdo legal — escritura, arrendamiento, NDA |
| `receipt` | Comprobante — factura, ticket, recibo de pago |
| `id` | Identificación — INE, pasaporte, RFC |
| `statement` | Estado de cuenta — bank, billing |
| `photo` | Imagen — evidencia, condición física |
| `other` | Fallback |

**Reglas founder-signed (FQ-1, FQ-3, FQ-4):**
- **Inmutables.** Subido = snapshot histórico. NO edit.
- **Status:** `archived_at IS NULL` = active · `archived_at IS NOT NULL` = archived. Sin enum lifecycle.
- **Versions = nuevo documento + `supersedes` relation.** Lista en DocumentDetailView.
- **Sign/Approve:** vía Decisions (`request_decision` template) — DEFERRED post-Documents V2.
- **OCR:** P3, deferred post-R.6.

UX Doctrine §11 Storage: bucket `documents` privado, 50MB, whitelist PDF/img/text/CSV, inmutable v1, signed URLs TTL 3600s.

---

## Estado actual (R.5X audit + R.5V.2)

### Backend ✅ (mayoría listo)

- ✅ Tabla `documents` (16 cols + FKs + archived_at + RLS)
- ✅ Storage bucket `documents` privado 50MB whitelist
- ✅ RPC `register_document` (R.5X.fix.C emit canonical `document.created`)
- ✅ `documents_preview` en `context_detail_descriptor` (B.7.1)
- ✅ `linked_documents` en `resource_detail_descriptor` (B.6.1)
- ❌ NO existe RPC `archive_document` (FQ-1 abre archive)
- ❌ NO existe RPC `list_context_documents` (consultable por contexto)
- ❌ NO existe relation `supersedes` en `resource_relation_types` catalog (FQ-4 versions)
- ❌ No hay smoke devs para los anteriores

### iOS ✅ (foundations listas)

- ✅ Domain `Document.swift` (119 LOC) — `DocumentType` enum 6 cases, decodable
- ✅ `LinkedDocument` struct en `ResourceDetailDescriptor.swift` (R.5A.B.6.1)
- ✅ `ContextDocumentPreview` en `ContextDetailDescriptor.swift` (R.5A.B.7.1)
- ✅ `DocumentsStore.swift` (79 LOC) — `loadResourceDocuments`, `attachToResource`, `signedURL(for:)`
- ✅ `AttachDocumentView.swift` (210 LOC) — fileImporter + register
- ✅ R.5V.2 componentes: `RuulDetailHero`, `RuulActionRow`, `RuulStatusBadge`, `RuulEmptyState`, `RuulErrorState`, `RuulLoadingState`
- ❌ NO existe `ContextDocumentsListView`
- ❌ NO existe `DocumentDetailView`
- ❌ NO existe QuickLook integration
- ❌ `DocumentsStore` falta `loadContextDocuments(contextId:)` + `archive(documentId:)`
- ❌ RPC client falta `listContextDocuments(contextId:)` + `archiveDocument(documentId:)`
- ❌ ContextV2 `documents` More row → ActivityFeedView fallback (hay que rewire)
- ❌ ResourceV2 `linkedDocumentsCard` no se renderiza (dead struct decode-only)

---

## Sub-slices D.0 → D.8

### D.0 — Backend foundations (~30 min)

**Migration 1:** `documents_v2_archive_and_supersedes.sql`

```sql
-- archive_document RPC SECURITY DEFINER (FQ-1: open archive soft delete)
create or replace function public.archive_document(p_document_id uuid)
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_doc record;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_doc from public.documents where id = p_document_id;
  if not found then raise exception 'document not found' using errcode = 'P0001'; end if;
  if v_doc.archived_at is not null then return; end if; -- idempotente

  -- Gate: owner OR documents.manage en el contexto
  if v_doc.owner_actor_id != v_caller
     and not public.has_actor_authority(v_doc.context_actor_id, v_caller, 'documents.manage') then
    raise exception 'not authorized to archive this document' using errcode = '42501';
  end if;

  update public.documents set archived_at = clock_timestamp(), updated_at = clock_timestamp()
  where id = p_document_id;

  perform public._emit_activity(coalesce(v_doc.context_actor_id, v_caller), v_caller, 'document.archived', 'document', p_document_id,
    jsonb_build_object('title', v_doc.title), p_resource_id := v_doc.resource_id);
end; $$;

-- supersedes seed en resource_relation_types (FQ-4: versions = nuevo doc + supersedes)
insert into public.resource_relation_types (key, display_name, inverse_key, inverse_display_name, category)
values ('supersedes', 'Reemplaza a', 'superseded_by', 'Reemplazado por', 'documents')
on conflict (key) do nothing;

-- Activity event catalog
insert into public.activity_event_catalog (event_type, domain, description, expected_subject_type)
values ('document.archived', 'resource', 'Se archivó un documento', 'document')
on conflict (event_type) do nothing;
```

**Smoke validation (D.0.smoke):**
1. Existe `archive_document` y respeta gate (owner_actor_id O `documents.manage`).
2. Idempotente (archive 2x no falla, no duplica activity event).
3. `supersedes` aparece en `resource_relation_types`.
4. `document.archived` aparece en `activity_event_catalog`.

### D.1 — `list_context_documents` RPC (~15 min)

PostgREST directo NO sirve para listar con joins (necesita resource_relations). Crear RPC SECURITY DEFINER:

```sql
create or replace function public.list_context_documents(
  p_context_actor_id uuid,
  p_include_archived boolean default false
)
returns setof jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.actor_has_permission(v_caller, p_context_actor_id, 'documents.view') then
    raise exception 'not authorized to view documents in this context' using errcode = '42501';
  end if;

  return query
  select jsonb_build_object(
    'id', d.id,
    'title', d.title,
    'document_type', d.document_type,
    'mime_type', d.mime_type,
    'file_size_bytes', d.file_size_bytes,
    'storage_path', d.storage_path,
    'owner_actor_id', d.owner_actor_id,
    'owner_display_name', (select display_name from public.actors where id = d.owner_actor_id),
    'resource_id', d.resource_id,
    'resource_display_name', (select display_name from public.resources where id = d.resource_id),
    'event_id', d.event_id,
    'created_at', d.created_at,
    'archived_at', d.archived_at,
    'metadata', d.metadata
  )
  from public.documents d
  where d.context_actor_id = p_context_actor_id
    and (p_include_archived or d.archived_at is null)
  order by d.created_at desc;
end; $$;
```

### D.2 — iOS RPC client + Store extension (~30 min)

**`RuulRPCClient.swift`:**
```swift
func listContextDocuments(contextId: UUID, includeArchived: Bool) async throws -> [Document]
func archiveDocument(documentId: UUID) async throws
```

**`SupabaseRuulRPCClient.swift`:** implementaciones.

**`MockRuulRPCClient.swift`:** demo world (3-4 documentos fixture).

**`DocumentsStore.swift`:** agregar
```swift
public var contextDocuments: [Document] = []
public var phase: StorePhase = .idle
public func loadContextDocuments(contextId: UUID) async
public func archive(documentId: UUID) async throws
```

### D.3 — `ContextDocumentsListView` (~120 LOC)

Patrón Detail Subview (no es Detail full por sí mismo, es una lista pushed desde ContextV2 More tab):

```
NavigationStack root
└─ List grouped
   ├─ Section "Activos"
   │  └─ ForEach archived_at == nil: RuulActionRow per document
   ├─ (opcional toggle "Ver archivados")
   └─ Section "Archivados" (si toggle on)
      └─ ForEach archived_at != nil: RuulActionRow per document
```

- Loading: `RuulLoadingState`
- Empty: `RuulEmptyState(title: "Sin documentos", systemImage: "doc")`
- Error: `RuulErrorState(message:, retry:)`
- Each row: `RuulActionRow(label: doc.title, systemImage: doc.type.symbolName, state: .enabled)` push `DocumentDetailView`
- Toolbar primary action: "Adjuntar" → `AttachDocumentView` (reusa existing)

### D.4 — `DocumentDetailView` (~200 LOC)

Aplica UX Doctrine §0.2 Detail pattern: Hero → Attention (n/a) → Widgets (size, type, version count) → Sections (metadata, linked entities, versions) → Actions → Activity (preview).

```
ScrollView
└─ VStack(spacing: xl)
   ├─ RuulDetailHero(title: doc.title, subtitle: type + size + uploaded by + when,
   │                  systemImage: doc.type.symbolName, tint: type tint,
   │                  status: doc.archived_at == nil ? .active : .archived)
   ├─ Preview card (QuickLook embedded if PDF/image) — onTap → fullscreen QuickLook
   ├─ Metadata section: type, mime, size, uploaded by, uploaded at
   ├─ Linked entities (si aplica):
   │   - resource_id → tap push ResourceDetailViewV2
   │   - event_id → tap push EventDetailView
   ├─ Versions section: lista de documentos con `supersedes` apuntando al actual
   │   - "Esta versión reemplaza a:" + supersedes target
   │   - "Versiones más nuevas:" + superseded_by docs
   ├─ Actions:
   │   - RuulActionRow "Ver completo" (QuickLook fullscreen) — enabled
   │   - RuulActionRow "Compartir" (ShareLink con signed URL) — enabled
   │   - RuulActionRow "Archivar" — dangerous; if doc.archived_at != nil → comingSoon "Ya archivado"
   │   - RuulActionRow "Firmar" — comingSoon (FQ-2 deferred)
   │   - RuulActionRow "Aprobar" — comingSoon (FQ-2 deferred)
   │   - RuulActionRow "Nueva versión" — comingSoon (FQ-4 deferred)
   └─ ActivityPreview (últimos 5 events del documento)
```

QuickLook: `.quickLookPreview($previewURL)` con `previewURL: URL?` (download desde signedURL a tmp dir, set state, modifier auto-presenta).

### D.5 — `ResourceLinkedDocumentsCard` subview (~60 LOC)

Card que se renderiza en `ResourceDetailViewV2` cuando `descriptor.linkedDocuments` no vacío. Hoy decode-only dead struct.

```
RuulSectionCard (TBD V.2 segunda ola — temporal: VStack + materials)
├─ Header: "Documentos" + "Ver todos" si > 3
├─ ForEach prefix(3) linkedDocuments:
│   RuulActionRow(label, systemImage, state: .enabled) → push DocumentDetailView
└─ "+ N más" si > 3 → push ContextDocumentsListView filtered
```

Insertar en ResourceDetailViewV2 entre `relationsCard` y `linkedEventsCard`.

### D.6 — Wire-ups (5+)

1. `ContextDetailViewV2.swift:1144` — cambiar `case "documents": ActivityFeedView(...)` → `ContextDocumentsListView(context:, container:)`
2. `ResourceDetailViewV2.swift:~188` — agregar `linkedDocumentsCard(d.linkedDocuments)` antes de activityCard
3. Widget destination `document_status` en R.5X widget mapping — push a `ContextDocumentsListView` filtrado por resource
4. `ContextHomeView` (v1) espejo del wire-up para fallback
5. Deep-link en `ActivityFeedView`: tap row con `event_type == 'document.created'` → push `DocumentDetailView(documentId: payload.document_id)`

### D.7 — Smoke validation device (~15 min)

Checklist en iPhone JJ:
1. Subir documento desde CreateIntentSheet ("Subir documento") → tipo Receipt → adjuntar → verifica que aparece en ContextDocumentsListView Más tab.
2. Tap row → DocumentDetailView se abre con QuickLook preview funcional (PDF/imagen).
3. Tap "Compartir" → ShareLink con signed URL funcional.
4. Tap "Archivar" → dangerous dialog → archive → desaparece de "Activos" → aparece en "Archivados" si toggle on.
5. Founder flow #10 R.5Z verifica end-to-end.

### D.8 — Memorias + commit + push

`project_documents_v2_shipped.md` documenta:
- Migration aplicada
- Files iOS creados/modificados
- Smoke verde
- Lecciones: ¿qué de Ruul* funcionó / falló? ¿qué de §0.2 patrón Detail se siente bien?

---

## Riesgos identificados

| Riesgo | Mitigación |
|---|---|
| QuickLook con signed URL requiere descarga local → manejo de tmp dir + cleanup | URLSession.download to `FileManager.default.temporaryDirectory`; cleanup en `onDisappear` |
| Mime types fuera de whitelist crash QuickLook | Fallback a `ShareLink` si QuickLook rechaza |
| Signed URL TTL 3600s — usuario abre detail 1h después, URL expira | Re-generar `signedURL` on-demand al abrir preview (no cachear) |
| ResourceLinkedDocumentsCard reuse pattern aún no maduro (RuulSectionCard segunda ola) | Inline VStack + materials por ahora; refactor a `RuulSectionCard` cuando exista |
| `supersedes` relation seed puede conflictuar con existing seeds | `on conflict (key) do nothing` |
| 7 actions documents en catalog SIN dispatcher backend (sign/approve/etc.) | RuulActionRow `.comingSoon` honest visible badge — R.5X.fix.A mapper cubre si por error se ejecuta |

---

## Out of scope (deferred)

- ❌ Sign documents inline (FQ-2 → via Decisions post-R.6)
- ❌ Approve documents inline (FQ-2)
- ❌ Upload new version flow (FQ-4 — botón "Nueva versión" coming_soon)
- ❌ Document categories taxonomy (P3)
- ❌ Document tags (P3)
- ❌ OCR (P3, deferred post-R.6)

---

## ¿Founder firma?

Si sí, arranco D.0 (backend migration) → smoke → D.1-D.8 secuencial.

Si quieres ajustes (e.g. dejar `ResourceLinkedDocumentsCard` para R.5V.2 segunda ola, o cambiar D.4 actions list), apunta y reescribimos antes de tocar código.
