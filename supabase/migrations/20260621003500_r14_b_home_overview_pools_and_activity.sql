-- R.14.B — Extiende home_overview con agregados de botes (P0 #3) y última
-- actividad (P0 #4).
--
-- Friend Groups Launch: el card "Tus grupos" hoy responde sólo a
-- "próximo evento / saldo / pendientes". Falta:
--   • "¿cuánto hay en mis botes?" — chip 💰 con suma de pools abiertos
--   • "¿qué pasó recientemente?" — timestamp del último activity event
--
-- Esta mig agrega 4 campos al jsonb retornado, todos opcionales (backwards
-- compat con clientes iOS que aún no decodifican).
--
-- Campos nuevos:
--   pools_total       numeric — SUM(basis_amount) pools abiertos, moneda dominante
--   pools_currency    text    — moneda con mayor total (o NULL si 0 pools)
--   pools_count       int     — count de pools abiertos por contexto
--   last_activity_at  timestamptz — max(created_at) de activity_events del contexto

CREATE OR REPLACE FUNCTION public.home_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_caller uuid := public.current_actor_id();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '28000';
  END IF;

  RETURN COALESCE((
    WITH my_contexts AS (
      SELECT a.id AS context_id, a.display_name, a.actor_kind, a.actor_subtype
      FROM public.actors a
      WHERE a.id = v_caller
        AND a.actor_kind = 'person'
        AND a.archived_at IS NULL
      UNION
      SELECT a.id, a.display_name, a.actor_kind, a.actor_subtype
      FROM public.actor_memberships m
      JOIN public.actors a ON a.id = m.context_actor_id
      WHERE m.member_actor_id = v_caller
        AND m.membership_status = 'active'
        AND a.archived_at IS NULL
    ),
    member_counts AS (
      SELECT context_actor_id, COUNT(*)::int AS n
      FROM public.actor_memberships
      WHERE membership_status = 'active'
      GROUP BY context_actor_id
    ),
    next_events AS (
      SELECT DISTINCT ON (e.context_actor_id)
        e.context_actor_id, e.starts_at, e.title
      FROM public.calendar_events e
      WHERE e.starts_at > now()
        AND (e.status IS NULL OR e.status NOT IN ('cancelled','closed'))
        AND e.cancelled_at IS NULL
      ORDER BY e.context_actor_id, e.starts_at ASC
    ),
    pending_obligations AS (
      SELECT context_actor_id, COUNT(*)::int AS n
      FROM public.obligations
      WHERE debtor_actor_id = v_caller AND status = 'open'
      GROUP BY context_actor_id
    ),
    pending_decisions AS (
      SELECT d.context_actor_id, COUNT(*)::int AS n
      FROM public.decisions d
      WHERE d.status = 'open'
        AND NOT EXISTS (
          SELECT 1 FROM public.decision_votes v
          WHERE v.decision_id = d.id AND v.voter_actor_id = v_caller
        )
      GROUP BY d.context_actor_id
    ),
    balance_by_currency AS (
      SELECT
        context_actor_id,
        currency,
        SUM(CASE WHEN creditor_actor_id = v_caller THEN amount
                 WHEN debtor_actor_id = v_caller THEN -amount
                 ELSE 0 END) AS net
      FROM public.obligations
      WHERE status = 'open'
        AND (debtor_actor_id = v_caller OR creditor_actor_id = v_caller)
      GROUP BY context_actor_id, currency
    ),
    balance_pick AS (
      SELECT DISTINCT ON (context_actor_id)
        context_actor_id, currency, net
      FROM balance_by_currency
      ORDER BY context_actor_id, abs(net) DESC, currency ASC
    ),
    -- R.14.B — pools agregados por contexto
    pools_by_currency AS (
      SELECT
        pa.parent_context_actor_id AS context_actor_id,
        be.currency,
        SUM(be.basis_amount) AS total,
        COUNT(DISTINCT pa.id)::int AS pool_count
      FROM public.pool_accounts pa
      JOIN public.pool_basis_entries be ON be.pool_account_id = pa.id
      WHERE pa.status = 'open' AND be.resolved_at IS NULL
      GROUP BY pa.parent_context_actor_id, be.currency
    ),
    pools_pick AS (
      SELECT DISTINCT ON (context_actor_id)
        context_actor_id, currency, total
      FROM pools_by_currency
      ORDER BY context_actor_id, total DESC, currency ASC
    ),
    pools_count_per_context AS (
      SELECT parent_context_actor_id AS context_actor_id, COUNT(*)::int AS n
      FROM public.pool_accounts
      WHERE status = 'open'
      GROUP BY parent_context_actor_id
    ),
    -- R.14.B — última actividad del contexto (any event type)
    last_activity AS (
      SELECT context_actor_id, MAX(created_at) AS last_at
      FROM public.activity_events
      GROUP BY context_actor_id
    ),
    preferences AS (
      SELECT context_actor_id, is_favorite, last_visited_at
      FROM public.actor_context_preferences
      WHERE actor_id = v_caller
    )
    SELECT jsonb_agg(jsonb_build_object(
      'context_actor_id', c.context_id,
      'display_name',     c.display_name,
      'actor_kind',       c.actor_kind,
      'actor_subtype',    c.actor_subtype,
      'is_favorite',      COALESCE(p.is_favorite, false),
      'last_visited_at',  p.last_visited_at,
      'member_count',     COALESCE(mc.n, CASE WHEN c.actor_kind = 'person' THEN 1 ELSE 0 END),
      'pending_count',    COALESCE(po.n, 0) + COALESCE(pd.n, 0),
      'next_event_at',    ne.starts_at,
      'next_event_title', ne.title,
      'my_balance',       bp.net,
      'balance_currency', bp.currency,
      'pools_total',      pp.total,
      'pools_currency',   pp.currency,
      'pools_count',      COALESCE(pc.n, 0),
      'last_activity_at', la.last_at
    ) ORDER BY p.last_visited_at DESC NULLS LAST, c.display_name)
    FROM my_contexts c
    LEFT JOIN member_counts mc          ON mc.context_actor_id = c.context_id
    LEFT JOIN next_events ne            ON ne.context_actor_id = c.context_id
    LEFT JOIN pending_obligations po    ON po.context_actor_id = c.context_id
    LEFT JOIN pending_decisions pd      ON pd.context_actor_id = c.context_id
    LEFT JOIN balance_pick bp           ON bp.context_actor_id = c.context_id
    LEFT JOIN pools_pick pp             ON pp.context_actor_id = c.context_id
    LEFT JOIN pools_count_per_context pc ON pc.context_actor_id = c.context_id
    LEFT JOIN last_activity la          ON la.context_actor_id = c.context_id
    LEFT JOIN preferences p             ON p.context_actor_id = c.context_id
  ), '[]'::jsonb);
END;
$function$;
