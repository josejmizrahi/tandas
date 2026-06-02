-- Aterriza la doctrina mandate_id en money tables.
-- doctrine_mandate_in_money_rpcs.md: persistencia obligatoria para audit trail.

alter table public.group_resource_transactions
  add column if not exists mandate_id uuid
  references public.group_mandates(id) on delete set null;

alter table public.group_settlements
  add column if not exists mandate_id uuid
  references public.group_mandates(id) on delete set null;

alter table public.group_obligations
  add column if not exists source_mandate_id uuid
  references public.group_mandates(id) on delete set null;

create index if not exists group_resource_transactions_mandate_idx
  on public.group_resource_transactions(mandate_id)
  where mandate_id is not null;

create index if not exists group_settlements_mandate_idx
  on public.group_settlements(mandate_id)
  where mandate_id is not null;

create index if not exists group_obligations_source_mandate_idx
  on public.group_obligations(source_mandate_id)
  where source_mandate_id is not null;

-- Same-group enforcement: mandate y la fila deben vivir en el mismo grupo.
-- Trigger porque mandate_id es opcional y no se incluye en composite FK.

create or replace function public.assert_mandate_same_group()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_mandate_group uuid; v_row_group uuid;
begin
  if NEW.mandate_id is null then return NEW; end if;
  select group_id into v_mandate_group from public.group_mandates where id = NEW.mandate_id;
  v_row_group := NEW.group_id;
  perform public.assert_same_group(v_mandate_group, v_row_group);
  return NEW;
end;
$$;

create trigger group_resource_transactions_mandate_same_group
  before insert or update of mandate_id on public.group_resource_transactions
  for each row execute function public.assert_mandate_same_group();

create trigger group_settlements_mandate_same_group
  before insert or update of mandate_id on public.group_settlements
  for each row execute function public.assert_mandate_same_group();

create or replace function public.assert_source_mandate_same_group()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_mandate_group uuid;
begin
  if NEW.source_mandate_id is null then return NEW; end if;
  select group_id into v_mandate_group from public.group_mandates where id = NEW.source_mandate_id;
  perform public.assert_same_group(v_mandate_group, NEW.group_id);
  return NEW;
end;
$$;

create trigger group_obligations_source_mandate_same_group
  before insert or update of source_mandate_id on public.group_obligations
  for each row execute function public.assert_source_mandate_same_group();

comment on column public.group_resource_transactions.mandate_id is
  'When the actor recorded this transaction acting by delegated authority, the granting mandate. NULL = direct_permission or self_party.';
comment on column public.group_settlements.mandate_id is
  'When the actor recorded this settlement acting by delegated authority. NULL = direct_permission or self_party.';
comment on column public.group_obligations.source_mandate_id is
  'When this obligation was materialized by an action taken under a mandate, the originating mandate. Lets audit trace which mandate caused which debt.';
