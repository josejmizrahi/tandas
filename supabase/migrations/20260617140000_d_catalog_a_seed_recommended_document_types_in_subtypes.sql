-- D.CATALOG.A — seed recommended_document_types en resource_subtypes.metadata
--
-- Founder Flow #10.c (2026-06-09): "catalog de tipos tipado por
-- resource/event type. Casa → escritura/factura predial/póliza/contrato/
-- recibos. Vehículo → tarjeta circulación/póliza/factura compra/
-- mantenimientos."
--
-- Approach: agregar `recommended_document_types` array al
-- resource_subtypes.metadata. iOS AttachDocumentView prioritiza estos types
-- en Section "Recomendados" cuando attach a un resource específico.
-- Doctrina founder R.12.G: catalog single source. Valores deben estar en
-- `document_type` CHECK constraint (cert/contract/policy/receipt/statement/
-- legacy id/photo/other).

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'recommended_document_types', jsonb_build_array(
       'certificate', 'contract', 'policy', 'receipt', 'statement'
     )
   )
 where class_key = 'real_estate'
   and subtype_key in (
     'primary_residence', 'vacation_home', 'apartment',
     'rental_property', 'warehouse', 'office', 'industrial_property'
   );

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'recommended_document_types', jsonb_build_array(
       'certificate', 'contract', 'receipt'
     )
   )
 where class_key = 'real_estate'
   and subtype_key = 'land';

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'recommended_document_types', jsonb_build_array(
       'certificate', 'policy', 'receipt', 'statement'
     )
   )
 where class_key = 'vehicle'
   and subtype_key in ('car', 'truck', 'motorcycle', 'boat', 'aircraft');

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'recommended_document_types', jsonb_build_array(
       'contract', 'receipt'
     )
   )
 where class_key = 'space'
   and subtype_key = 'generic_space';

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'recommended_document_types', jsonb_build_array(
       'certificate', 'receipt'
     )
   )
 where class_key = 'equipment'
   and subtype_key in ('machine', 'tool', 'generic_equipment');

update public.resource_subtypes
   set metadata = metadata || jsonb_build_object(
     'recommended_document_types', jsonb_build_array(
       'statement', 'contract', 'receipt'
     )
   )
 where class_key = 'financial';
