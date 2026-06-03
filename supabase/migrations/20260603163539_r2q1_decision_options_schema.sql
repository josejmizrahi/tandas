-- R.2Q.1 — Decision Options & Voting Models
-- Schema + backfill. Additivo. No rompe R.2G ni iOS.

-- 1. voting_model en decisions
ALTER TABLE public.decisions
  ADD COLUMN IF NOT EXISTS voting_model text;
UPDATE public.decisions SET voting_model = 'yes_no_abstain' WHERE voting_model IS NULL;
ALTER TABLE public.decisions
  ALTER COLUMN voting_model SET NOT NULL,
  ALTER COLUMN voting_model SET DEFAULT 'yes_no_abstain';

ALTER TABLE public.decisions
  DROP CONSTRAINT IF EXISTS decisions_voting_model_check;
ALTER TABLE public.decisions
  ADD CONSTRAINT decisions_voting_model_check
  CHECK (voting_model IN (
    'yes_no_abstain',
    'single_choice',
    'multiple_choice',
    'ranked_choice',
    'approval_vote',
    'numeric_allocation',
    'consent'
  ));

-- 2. decision_options
CREATE TABLE IF NOT EXISTS public.decision_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_id uuid NOT NULL REFERENCES public.decisions(id) ON DELETE CASCADE,
  option_key text NOT NULL,
  title text NOT NULL,
  description text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  sort_order integer NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (decision_id, option_key)
);
CREATE INDEX IF NOT EXISTS idx_decision_options_decision_id ON public.decision_options(decision_id);

ALTER TABLE public.decision_options ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS decision_options_select ON public.decision_options;
CREATE POLICY decision_options_select ON public.decision_options
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.decisions d
      WHERE d.id = decision_options.decision_id
        AND public.is_context_member(d.context_actor_id)
    )
  );

-- 3. option_id en decision_votes (nullable para backward compat)
ALTER TABLE public.decision_votes
  ADD COLUMN IF NOT EXISTS option_id uuid REFERENCES public.decision_options(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_decision_votes_option_id ON public.decision_votes(option_id);

-- 4. Backfill: existing decisions
DO $$
DECLARE
  d_row record;
  opt jsonb;
  opt_idx int;
  opt_label text;
  v_opt_id uuid;
  v_award_payload jsonb;
BEGIN
  FOR d_row IN SELECT * FROM public.decisions LOOP
    IF d_row.payload ? 'options' AND jsonb_typeof(d_row.payload->'options') = 'array' THEN
      UPDATE public.decisions SET voting_model = 'single_choice' WHERE id = d_row.id;
      opt_idx := 0;
      FOR opt IN SELECT jsonb_array_elements(d_row.payload->'options') LOOP
        IF jsonb_typeof(opt) = 'string' THEN
          opt_label := opt #>> '{}';
        ELSE
          opt_label := opt::text;
        END IF;

        v_award_payload := '{}'::jsonb;
        IF d_row.decision_type = 'reservation_dispute'
           AND d_row.payload ? 'option_reservations'
           AND d_row.payload->'option_reservations' ? opt_label THEN
          v_award_payload := jsonb_build_object(
            'action', 'reservation_award',
            'winner_reservation_id', d_row.payload->'option_reservations'->>opt_label,
            'conflict_id', COALESCE(
              d_row.payload->>'reservation_conflict_id',
              d_row.payload->>'conflict_id'
            )
          );
        END IF;

        INSERT INTO public.decision_options (decision_id, option_key, title, payload, sort_order)
        VALUES (d_row.id, opt_label, opt_label, v_award_payload, opt_idx)
        ON CONFLICT (decision_id, option_key) DO NOTHING
        RETURNING id INTO v_opt_id;

        IF v_opt_id IS NULL THEN
          SELECT id INTO v_opt_id FROM public.decision_options
            WHERE decision_id = d_row.id AND option_key = opt_label;
        END IF;

        UPDATE public.decision_votes
           SET option_id = v_opt_id
         WHERE decision_id = d_row.id
           AND metadata->>'option' = opt_label
           AND option_id IS NULL;

        opt_idx := opt_idx + 1;
      END LOOP;
    ELSE
      INSERT INTO public.decision_options (decision_id, option_key, title, sort_order)
      VALUES
        (d_row.id, 'approve', 'A favor', 0),
        (d_row.id, 'reject', 'En contra', 1),
        (d_row.id, 'abstain', 'Abstención', 2)
      ON CONFLICT (decision_id, option_key) DO NOTHING;

      UPDATE public.decision_votes dv
         SET option_id = do2.id
        FROM public.decision_options do2
       WHERE dv.decision_id = d_row.id
         AND do2.decision_id = d_row.id
         AND do2.option_key = dv.vote
         AND dv.option_id IS NULL;
    END IF;
  END LOOP;
END $$;
