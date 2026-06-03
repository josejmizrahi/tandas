-- R.2Q.1 — Auto-seed decision_options + create_decision con voting_model
-- Trigger AFTER INSERT en decisions:
--   - yes_no_abstain → 3 default options (approve/reject/abstain)
--   - single_choice con payload.options → mapea esos (incluye action para reservation_dispute)
--   - single_choice con decision_type='reservation_dispute' + conflict_id → 4 dispute options

CREATE OR REPLACE FUNCTION public._auto_seed_decision_options()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  opt jsonb;
  opt_idx int;
  opt_label text;
  v_award_payload jsonb;
  v_conflict public.reservation_conflicts%rowtype;
  v_res_a public.resource_reservations%rowtype;
  v_res_b public.resource_reservations%rowtype;
  v_name_a text;
  v_name_b text;
  v_conflict_id uuid;
BEGIN
  IF NEW.voting_model = 'yes_no_abstain' THEN
    INSERT INTO public.decision_options (decision_id, option_key, title, sort_order)
    VALUES
      (NEW.id, 'approve', 'A favor', 0),
      (NEW.id, 'reject', 'En contra', 1),
      (NEW.id, 'abstain', 'Abstención', 2)
    ON CONFLICT (decision_id, option_key) DO NOTHING;

  ELSIF NEW.voting_model = 'single_choice' THEN
    -- caso A: caller pasó payload.options (legacy path)
    IF NEW.payload ? 'options' AND jsonb_typeof(NEW.payload->'options') = 'array' THEN
      opt_idx := 0;
      FOR opt IN SELECT jsonb_array_elements(NEW.payload->'options') LOOP
        IF jsonb_typeof(opt) = 'string' THEN
          opt_label := opt #>> '{}';
        ELSE
          opt_label := opt::text;
        END IF;

        v_award_payload := '{}'::jsonb;
        IF NEW.decision_type = 'reservation_dispute'
           AND NEW.payload ? 'option_reservations'
           AND NEW.payload->'option_reservations' ? opt_label THEN
          v_award_payload := jsonb_build_object(
            'action', 'reservation_award',
            'winner_reservation_id', NEW.payload->'option_reservations'->>opt_label,
            'conflict_id', COALESCE(
              NEW.payload->>'reservation_conflict_id',
              NEW.payload->>'conflict_id'
            )
          );
        END IF;

        INSERT INTO public.decision_options (decision_id, option_key, title, payload, sort_order)
        VALUES (NEW.id, opt_label, opt_label, v_award_payload, opt_idx)
        ON CONFLICT (decision_id, option_key) DO NOTHING;

        opt_idx := opt_idx + 1;
      END LOOP;

    -- caso B: reservation_dispute con conflict_id → 4 dispute options
    ELSIF NEW.decision_type = 'reservation_dispute'
          AND (NEW.payload ? 'conflict_id' OR NEW.payload ? 'reservation_conflict_id') THEN
      v_conflict_id := COALESCE(
        (NEW.payload->>'reservation_conflict_id')::uuid,
        (NEW.payload->>'conflict_id')::uuid
      );
      SELECT * INTO v_conflict FROM public.reservation_conflicts WHERE id = v_conflict_id;
      IF v_conflict.id IS NOT NULL THEN
        SELECT * INTO v_res_a FROM public.resource_reservations WHERE id = v_conflict.reservation_a_id;
        SELECT * INTO v_res_b FROM public.resource_reservations WHERE id = v_conflict.reservation_b_id;
        v_name_a := COALESCE(
          (SELECT display_name FROM public.actors WHERE id = v_res_a.reserved_for_actor_id),
          (SELECT display_name FROM public.actors WHERE id = v_res_a.requested_by_actor_id),
          'Solicitud A'
        );
        v_name_b := COALESCE(
          (SELECT display_name FROM public.actors WHERE id = v_res_b.reserved_for_actor_id),
          (SELECT display_name FROM public.actors WHERE id = v_res_b.requested_by_actor_id),
          'Solicitud B'
        );

        INSERT INTO public.decision_options (decision_id, option_key, title, payload, sort_order)
        VALUES
          (NEW.id, 'award_a', 'Asignar a ' || v_name_a,
           jsonb_build_object(
             'action','reservation_award',
             'winner_reservation_id', v_conflict.reservation_a_id,
             'conflict_id', v_conflict.id), 0),
          (NEW.id, 'award_b', 'Asignar a ' || v_name_b,
           jsonb_build_object(
             'action','reservation_award',
             'winner_reservation_id', v_conflict.reservation_b_id,
             'conflict_id', v_conflict.id), 1),
          (NEW.id, 'split', 'Dividir fechas',
           jsonb_build_object('action','split_reservation','conflict_id', v_conflict.id), 2),
          (NEW.id, 'cancel', 'Cancelar ambas',
           jsonb_build_object('action','cancel_reservations','conflict_id', v_conflict.id), 3)
        ON CONFLICT (decision_id, option_key) DO NOTHING;
      END IF;
    END IF;
  END IF;

  -- otros voting_models (multiple_choice, ranked_choice, ...): caller debe crear options manualmente

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_auto_seed_decision_options ON public.decisions;
CREATE TRIGGER trg_auto_seed_decision_options
AFTER INSERT ON public.decisions
FOR EACH ROW EXECUTE FUNCTION public._auto_seed_decision_options();

-- create_decision: agrega p_voting_model (opcional). Si NULL, se autodetecta.
CREATE OR REPLACE FUNCTION public.create_decision(
  p_context_actor_id uuid,
  p_decision_type text,
  p_title text,
  p_description text DEFAULT NULL,
  p_closes_at timestamptz DEFAULT NULL,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_client_id text DEFAULT NULL,
  p_voting_model text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
  v_existing uuid;
  v_voting_model text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'decisions.create') then
    raise exception 'not authorized to create decisions in context %', p_context_actor_id using errcode = '42501';
  end if;

  if p_client_id is not null then
    select id into v_existing from public.decisions
     where context_actor_id = p_context_actor_id and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('decision_id', v_existing,
        'decision', (select to_jsonb(d) from public.decisions d where d.id = v_existing));
    end if;
  end if;

  -- Auto-detect voting_model si no se pasa
  v_voting_model := p_voting_model;
  if v_voting_model is null then
    if coalesce(p_payload, '{}'::jsonb) ? 'options'
       and jsonb_typeof(coalesce(p_payload, '{}'::jsonb)->'options') = 'array' then
      v_voting_model := 'single_choice';
    elsif p_decision_type = 'reservation_dispute'
          and (coalesce(p_payload, '{}'::jsonb) ? 'conflict_id'
               or coalesce(p_payload, '{}'::jsonb) ? 'reservation_conflict_id') then
      v_voting_model := 'single_choice';
    else
      v_voting_model := 'yes_no_abstain';
    end if;
  end if;

  insert into public.decisions
    (context_actor_id, decision_type, title, description, created_by_actor_id, closes_at, payload, client_id, voting_model)
  values
    (p_context_actor_id, p_decision_type, btrim(p_title), p_description, v_caller, p_closes_at,
     coalesce(p_payload, '{}'::jsonb), p_client_id, v_voting_model)
  returning id into v_id;

  perform public._emit_activity(p_context_actor_id, v_caller, 'decision.created', 'decision', v_id,
    jsonb_build_object('decision_type', p_decision_type, 'title', btrim(p_title), 'voting_model', v_voting_model),
    p_decision_id := v_id);

  return jsonb_build_object('decision_id', v_id,
    'decision', (select to_jsonb(d) from public.decisions d where d.id = v_id));
end; $$;
