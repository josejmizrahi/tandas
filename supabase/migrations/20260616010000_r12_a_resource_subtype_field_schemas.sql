-- ────────────────────────────────────────────────────────────────────────────
-- R.12.A — Schema declarativo de campos por subtype (slice 1 de B firmado).
-- Doctrina: la tabla resource_subtypes.metadata es el catálogo. El iOS lee
-- el array `metadata.fields` (shape canónico FormFieldSpec ya en uso por
-- ResourceActionFormView) y renderea form dinámico. Cero cambio de RPC:
-- create_resource/update_resource ya aceptan p_metadata jsonb libre.
--
-- Shape canónico (FormFieldSpec en RuulCore/Domain/ResourceActionFormSchema.swift):
--   { "key": "make", "label": "Marca", "type": "text", "required": true,
--     "options": [], "multiple": false, "placeholder": "Honda", "help_text": null }
-- types: text · multiline · number · currency · date · datetime · boolean ·
--        picker · actor_ref · resource_ref · file_url
-- ────────────────────────────────────────────────────────────────────────────

-- ── VEHICLE ─────────────────────────────────────────────────────────────────
update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','make','label','Marca','type','text','required',true,'placeholder','Honda'),
  jsonb_build_object('key','model','label','Modelo','type','text','required',true,'placeholder','Civic'),
  jsonb_build_object('key','year','label','Año','type','number','required',false,'placeholder','2024'),
  jsonb_build_object('key','license_plate','label','Placa','type','text','required',false,'placeholder','ABC-123'),
  jsonb_build_object('key','vin','label','VIN','type','text','required',false,'placeholder','17 caracteres'),
  jsonb_build_object('key','color','label','Color','type','text','required',false),
  jsonb_build_object('key','fuel_type','label','Combustible','type','picker','required',false,
    'options', jsonb_build_array('Gasolina','Diesel','Híbrido','Eléctrico','GNC')),
  jsonb_build_object('key','mileage','label','Kilometraje','type','number','required',false,'placeholder','45000')
)) where subtype_key in ('car','motorcycle','truck');

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','make','label','Marca','type','text','required',true),
  jsonb_build_object('key','model','label','Modelo','type','text','required',true),
  jsonb_build_object('key','year','label','Año','type','number'),
  jsonb_build_object('key','registration_number','label','Registro','type','text','placeholder','Matrícula'),
  jsonb_build_object('key','hin','label','HIN','type','text','help_text','Hull Identification Number'),
  jsonb_build_object('key','color','label','Color','type','text'),
  jsonb_build_object('key','length_m','label','Eslora (m)','type','number')
)) where subtype_key = 'boat';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','make','label','Fabricante','type','text','required',true),
  jsonb_build_object('key','model','label','Modelo','type','text','required',true),
  jsonb_build_object('key','year','label','Año','type','number'),
  jsonb_build_object('key','tail_number','label','Matrícula','type','text','placeholder','XA-ABC'),
  jsonb_build_object('key','serial_number','label','Serie','type','text')
)) where subtype_key = 'aircraft';

-- ── REAL ESTATE ─────────────────────────────────────────────────────────────
update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','address','label','Dirección','type','text','required',true),
  jsonb_build_object('key','area_sqm','label','Superficie (m²)','type','number'),
  jsonb_build_object('key','bedrooms','label','Recámaras','type','number'),
  jsonb_build_object('key','bathrooms','label','Baños','type','number'),
  jsonb_build_object('key','year_built','label','Año construcción','type','number'),
  jsonb_build_object('key','floor','label','Piso','type','number')
)) where subtype_key = 'apartment';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','address','label','Dirección','type','text','required',true),
  jsonb_build_object('key','area_sqm','label','Superficie (m²)','type','number'),
  jsonb_build_object('key','bedrooms','label','Recámaras','type','number'),
  jsonb_build_object('key','bathrooms','label','Baños','type','number'),
  jsonb_build_object('key','year_built','label','Año construcción','type','number')
)) where subtype_key in ('primary_residence','vacation_home','rental_property');

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','address','label','Dirección','type','text','required',true),
  jsonb_build_object('key','area_sqm','label','Superficie (m²)','type','number'),
  jsonb_build_object('key','year_built','label','Año construcción','type','number')
)) where subtype_key in ('office','warehouse','industrial_property');

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','address','label','Dirección','type','text','required',true),
  jsonb_build_object('key','area_sqm','label','Superficie (m²)','type','number'),
  jsonb_build_object('key','zoning','label','Uso de suelo','type','text','placeholder','Habitacional')
)) where subtype_key = 'land';

-- ── FINANCIAL ───────────────────────────────────────────────────────────────
update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','institution','label','Banco','type','text','required',true,'placeholder','BBVA'),
  jsonb_build_object('key','account_type','label','Tipo','type','picker',
    'options', jsonb_build_array('Cheques','Ahorros','Nómina','Empresa')),
  jsonb_build_object('key','account_number','label','Cuenta','type','text','help_text','Últimos 4 dígitos sugerido')
)) where subtype_key = 'bank_account';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','blockchain','label','Red','type','picker','required',true,
    'options', jsonb_build_array('Bitcoin','Ethereum','Solana','Polygon','Arbitrum','Base','Otra')),
  jsonb_build_object('key','wallet_address','label','Dirección','type','text','required',true),
  jsonb_build_object('key','wallet_label','label','Etiqueta','type','text','placeholder','Cold storage')
)) where subtype_key = 'crypto_wallet';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','institution','label','Casa de bolsa','type','text','required',true),
  jsonb_build_object('key','account_type','label','Tipo','type','picker',
    'options', jsonb_build_array('Acciones','Fondos','Mixto','Retiro')),
  jsonb_build_object('key','account_number','label','Cuenta','type','text')
)) where subtype_key = 'investment_account';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','trustee_name','label','Trustee','type','text','required',true),
  jsonb_build_object('key','account_number','label','Cuenta','type','text'),
  jsonb_build_object('key','jurisdiction','label','Jurisdicción','type','text','placeholder','Delaware')
)) where subtype_key = 'trust_fund';

-- ── DOCUMENT (subtypes para documents que ALSO son resources) ───────────────
update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','policy_number','label','Número de póliza','type','text','required',true),
  jsonb_build_object('key','provider','label','Aseguradora','type','text','required',true,'placeholder','GNP, AXA, etc.'),
  jsonb_build_object('key','premium_amount','label','Prima','type','currency'),
  jsonb_build_object('key','currency','label','Moneda','type','picker','options', jsonb_build_array('MXN','USD','EUR')),
  jsonb_build_object('key','starts_at','label','Vigencia desde','type','date','required',true),
  jsonb_build_object('key','expires_at','label','Vigencia hasta','type','date','required',true),
  jsonb_build_object('key','coverage_summary','label','Cobertura','type','multiline','placeholder','Resumen de coberturas y deducibles')
)) where subtype_key = 'policy';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','party_a','label','Parte A','type','text','required',true),
  jsonb_build_object('key','party_b','label','Parte B','type','text','required',true),
  jsonb_build_object('key','effective_date','label','Fecha efectiva','type','date'),
  jsonb_build_object('key','expiration_date','label','Vencimiento','type','date'),
  jsonb_build_object('key','summary','label','Resumen','type','multiline')
)) where subtype_key = 'contract';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','issuer','label','Emisor','type','text','required',true),
  jsonb_build_object('key','issued_to','label','Emitido a','type','text'),
  jsonb_build_object('key','issue_date','label','Fecha emisión','type','date'),
  jsonb_build_object('key','expires_at','label','Vence','type','date'),
  jsonb_build_object('key','certificate_number','label','Número','type','text')
)) where subtype_key = 'certificate';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','vendor','label','Proveedor','type','text','required',true),
  jsonb_build_object('key','receipt_number','label','Folio','type','text'),
  jsonb_build_object('key','issue_date','label','Fecha','type','date','required',true),
  jsonb_build_object('key','total_amount','label','Total','type','currency'),
  jsonb_build_object('key','currency','label','Moneda','type','picker','options', jsonb_build_array('MXN','USD','EUR'))
)) where subtype_key = 'receipt';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','institution','label','Institución','type','text','required',true),
  jsonb_build_object('key','period_start','label','Periodo desde','type','date'),
  jsonb_build_object('key','period_end','label','Periodo hasta','type','date'),
  jsonb_build_object('key','statement_number','label','Número','type','text')
)) where subtype_key = 'statement';

-- ── EQUIPMENT ───────────────────────────────────────────────────────────────
update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','make','label','Marca','type','text','required',true),
  jsonb_build_object('key','model','label','Modelo','type','text','required',true),
  jsonb_build_object('key','serial_number','label','Serie','type','text'),
  jsonb_build_object('key','purchase_date','label','Fecha de compra','type','date'),
  jsonb_build_object('key','warranty_expires','label','Garantía hasta','type','date')
)) where subtype_key = 'machine';

update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','make','label','Marca','type','text'),
  jsonb_build_object('key','model','label','Modelo','type','text'),
  jsonb_build_object('key','serial_number','label','Serie','type','text')
)) where subtype_key in ('tool','generic_equipment');

-- ── DIGITAL ASSET ───────────────────────────────────────────────────────────
update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','platform','label','Plataforma','type','text','required',true,'placeholder','Instagram, Notion, Stripe…'),
  jsonb_build_object('key','url','label','URL','type','file_url'),
  jsonb_build_object('key','account_handle','label','Usuario / Handle','type','text','placeholder','@miempresa')
)) where subtype_key = 'generic_digital_asset';

-- ── TRIP ────────────────────────────────────────────────────────────────────
update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','destination','label','Destino','type','text','required',true,'placeholder','Cancún'),
  jsonb_build_object('key','start_date','label','Salida','type','date','required',true),
  jsonb_build_object('key','end_date','label','Regreso','type','date','required',true),
  jsonb_build_object('key','accommodation','label','Hospedaje','type','text'),
  jsonb_build_object('key','transportation','label','Transporte','type','text')
)) where subtype_key = 'group_trip';

-- ── SPACE ───────────────────────────────────────────────────────────────────
update public.resource_subtypes set metadata = jsonb_build_object('fields', jsonb_build_array(
  jsonb_build_object('key','capacity','label','Capacidad','type','number','placeholder','12'),
  jsonb_build_object('key','hourly_rate','label','Tarifa por hora','type','currency'),
  jsonb_build_object('key','currency','label','Moneda','type','picker','options', jsonb_build_array('MXN','USD','EUR'))
)) where subtype_key = 'generic_space';

-- ── Smoke: schema parseable + invariantes ───────────────────────────────────
create or replace function public._smoke_mvp2_r12_a_subtype_field_schemas()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row record;
  v_field jsonb;
  v_seeded_count int := 0;
  v_bad_count int := 0;
  v_allowed_types text[] := array['text','multiline','number','currency','date','datetime','boolean','picker','actor_ref','resource_ref','file_url'];
begin
  for v_row in
    select subtype_key, metadata->'fields' as fields
      from public.resource_subtypes
     where metadata ? 'fields'
  loop
    v_seeded_count := v_seeded_count + 1;
    if jsonb_typeof(v_row.fields) <> 'array' then
      raise exception 'r12_a smoke: subtype % metadata.fields no es array', v_row.subtype_key;
    end if;
    for v_field in select * from jsonb_array_elements(v_row.fields) loop
      if not v_field ? 'key' or not v_field ? 'label' or not v_field ? 'type' then
        v_bad_count := v_bad_count + 1;
        raise exception 'r12_a smoke: subtype % field sin key/label/type: %', v_row.subtype_key, v_field;
      end if;
      if not (v_field->>'type') = any(v_allowed_types) then
        raise exception 'r12_a smoke: subtype % field type % no permitido', v_row.subtype_key, v_field->>'type';
      end if;
    end loop;
  end loop;

  if v_seeded_count < 20 then
    raise exception 'r12_a smoke: esperaba al menos 20 subtypes seeded, got %', v_seeded_count;
  end if;

  raise notice 'r12_a smoke OK: % subtypes con field schema', v_seeded_count;
end; $$;

revoke all on function public._smoke_mvp2_r12_a_subtype_field_schemas() from public, anon, authenticated;

comment on function public._smoke_mvp2_r12_a_subtype_field_schemas() is
  'R.12.A smoke: cada subtype seeded con metadata.fields es FormFieldSpec-compatible (key/label/type required, type ∈ allowed set, fields es array). 28 subtypes seeded.';
