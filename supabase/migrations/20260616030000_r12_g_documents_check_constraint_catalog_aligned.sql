-- R.12.G — extender CHECK constraint de documents.document_type para que
-- soporte los subtypes del catálogo resource_subtypes class_key='document'
-- (certificate + policy nuevos). Mantiene back-compat con valores ya en
-- uso (contract/receipt/id/statement/photo/other).
--
-- Doctrina: el catálogo es single source. Cuando un subtype nuevo se
-- agrega a resource_subtypes class='document', solo se agrega una row
-- al catalog + extender este CHECK si requiere persistirse en documents.
-- El CHECK existe por safety: previene typos al setear el text libre.

alter table public.documents
  drop constraint if exists documents_document_type_check;

alter table public.documents
  add constraint documents_document_type_check check (
    document_type = any (array[
      -- Legacy / general purpose
      'contract', 'receipt', 'id', 'statement', 'photo', 'other',
      -- R.12.G catalog-aligned (resource_subtypes class='document')
      'policy', 'certificate'
    ])
  );

comment on constraint documents_document_type_check on public.documents is
  'R.12.G: text values aligned con resource_subtypes class_key=document seed (cert/contract/policy/receipt/statement) + legacy (id/photo/other).';
