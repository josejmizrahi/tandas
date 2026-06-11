-- ────────────────────────────────────────────────────────────────────────────
-- FE.1c — cierre de drift repo↔prod: `_resource_type_for_subtype(text)` se usa
-- en create_resource (20260608110000) y en el smoke de audit_14, pero su
-- definición vivía SOLO en prod (hotfix aplicado directo, nunca exportado a la
-- cadena). El replay fresco de edge-tests fallaba con 42883 al ejecutar
-- _smoke_mvp2_audit_subtype_creatable. Timestamp 141500 deliberado: corre
-- antes de audit_14 (142000) en el replay; en prod es create-or-replace
-- idéntico a lo ya desplegado (no-op semántico).
--
-- Definición extraída de prod con pg_get_functiondef (2026-06-11).
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public._resource_type_for_subtype(p_subtype_key text)
returns text
language sql
stable
set search_path to 'public'
as $function$
  with class_lookup as (
    select rs.class_key from public.resource_subtypes rs where rs.subtype_key = p_subtype_key
  )
  select case (select class_key from class_lookup)
    when 'real_estate'   then case p_subtype_key
      when 'primary_residence' then 'house'
      when 'vacation_home'     then 'house'
      when 'apartment'         then 'house'
      else 'property'
    end
    when 'vehicle'       then 'vehicle'
    when 'equipment'     then 'equipment'
    when 'financial'     then case p_subtype_key
      when 'money_pool'       then 'cash_pool'
      when 'bank_account'     then 'bank_account'
      when 'trust_fund'       then 'trust_asset'
      when 'crypto_wallet'    then 'digital_asset'
      when 'investment_account' then 'security'
      else 'cash_pool'
    end
    when 'document'      then case p_subtype_key
      when 'contract' then 'contract'
      else 'document'
    end
    when 'event'         then 'reservation'
    when 'trip'          then 'trip_booking'
    when 'membership'    then 'membership_asset'
    when 'digital_asset' then 'digital_asset'
    when 'inventory'     then 'equipment'
    -- agreement, obligation, project, right, service, space, generic
    else 'other'
  end;
$function$;

comment on function public._resource_type_for_subtype(text) is
  'Mapea subtype_key → resource_type legacy. Backfilled del prod a la cadena (FE.1c, era drift).';
