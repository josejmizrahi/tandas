create or replace function public.next_host_for_series(
  p_series_id uuid,
  p_cycle     integer
) returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_series       public.resource_series;
  v_cfg          jsonb;
  v_participants jsonb;
  v_order        text;
  v_replacement  text;
  v_cycle_offset int;
  v_count        int;
  v_idx          int;
  v_candidate    uuid;
  v_attempts     int := 0;
  v_max_attempts int;
begin
  if p_series_id is null or p_cycle is null or p_cycle < 1 then
    return null;
  end if;

  select * into v_series from public.resource_series where id = p_series_id;
  if not found then
    return null;
  end if;

  v_cfg := coalesce(
    v_series.metadata->'capability_configs'->'rotation',
    '{}'::jsonb
  );

  v_participants := v_cfg->'participants';
  if v_participants is null or jsonb_typeof(v_participants) <> 'array'
     or jsonb_array_length(v_participants) = 0 then
    return null;
  end if;

  v_count := jsonb_array_length(v_participants);
  v_order := coalesce(v_cfg->>'order', 'sequential');
  v_replacement := coalesce(v_cfg->>'replacementPolicy', 'skip_to_next');
  v_cycle_offset := coalesce((v_cfg->>'cycle_offset')::int, 0);
  v_max_attempts := case when v_replacement = 'skip_to_next' then v_count else 1 end;

  if v_order = 'random' then
    v_idx := (
      abs(hashtextextended(p_series_id::text || ':' || p_cycle::text, 0))
      % v_count
    )::int;
  else
    v_idx := ((p_cycle - 1 - v_cycle_offset) % v_count + v_count) % v_count;
  end if;

  loop
    begin
      v_candidate := (v_participants->>v_idx)::uuid;
    exception when others then
      v_candidate := null;
    end;

    if v_candidate is not null then
      if v_replacement = 'skip_to_next' then
        if exists (
          select 1 from public.group_members
           where group_id = v_series.group_id
             and user_id  = v_candidate
             and active   = true
        ) then
          return v_candidate;
        end if;
      else
        return v_candidate;
      end if;
    end if;

    v_attempts := v_attempts + 1;
    if v_attempts >= v_max_attempts then
      return null;
    end if;

    if v_order = 'random' then
      v_idx := (
        abs(hashtextextended(p_series_id::text || ':' || p_cycle::text || ':' || v_attempts::text, 0))
        % v_count
      )::int;
    else
      v_idx := (v_idx + 1) % v_count;
    end if;
  end loop;
end;
$$;

comment on function public.next_host_for_series(uuid, integer) is
  'mig 00336: honors optional cycle_offset in rotation config so reorder restarts the cursor. Sequential: index = ((cycle-1-offset) mod count + count) mod count. Random: ignores offset. Missing offset defaults to 0.';;
