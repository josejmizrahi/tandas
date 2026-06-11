-- ────────────────────────────────────────────────────────────────────────────
-- FE.2 (P0.4) — UI honesta: el descriptor de obligaciones dejaba de anunciar
-- pay / dispute / cancel, acciones SIN RPC de dispatch (iOS las filtraba a
-- "Próximamente" con una whitelist defensiva — R.5Z.fix.CC.1). Doctrina UX
-- §0.4: ninguna acción visible sin dispatcher.
--
-- Decisión de producto (founder delegó 2026-06-11): el pago de obligaciones
-- money fluye por el settlement canónico (neteo por novación) — un
-- pay_obligation directo duplicaría esa vía. dispute/cancel volverán cuando
-- existan sus RPCs.
--
-- Quedan: mark_completed (non-money) · forgive · edit_obligation — exactamente
-- las 3 que iOS tiene cableadas (wiredActionKeys en ObligationDetailView).
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public.obligation_available_actions(p_obligation_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to public
as $$
declare
  v_ob public.obligations%rowtype;
  v_active boolean;
  v_is_debtor boolean;
  v_is_creditor boolean;
  v_is_manager boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  select * into v_ob from public.obligations where id = p_obligation_id;
  if v_ob.id is null then return '[]'::jsonb; end if;

  v_active := v_ob.status in ('open', 'accepted', 'in_progress');
  v_is_debtor := p_actor_id = v_ob.debtor_actor_id;
  v_is_creditor := p_actor_id = v_ob.creditor_actor_id;
  v_is_manager := v_ob.context_actor_id is not null
              and public.has_actor_authority(v_ob.context_actor_id, p_actor_id, 'money.settle');

  -- FE.2: 'pay' removida — el pago de obligaciones money vive en el flujo de
  -- settlement (generate_settlement_batch + mark_settlement_paid).

  if v_ob.obligation_kind <> 'money' and v_active then
    v_actions := v_actions || public._aa('mark_completed', 'Marcar como cumplida', 'obligations',
      v_is_debtor or v_is_creditor or v_is_manager,
      case when v_is_debtor or v_is_creditor or v_is_manager then 'Participas en esta obligación'
           else 'Solo deudor, acreedor o un administrador pueden marcarla' end);
  end if;

  -- FE.2: 'dispute' y 'cancel' removidas hasta que existan sus RPCs.

  if v_active then
    v_actions := v_actions || public._aa('forgive', 'Condonar', 'obligations',
      v_is_creditor, case when v_is_creditor then 'Eres el acreedor y puedes condonar'
                          else 'Solo el acreedor puede condonar' end);
  end if;

  if v_active then
    v_actions := v_actions || public._aa('edit_obligation', 'Editar obligación', 'obligations',
      v_is_creditor or v_is_manager,
      case when v_is_creditor then 'Eres el acreedor y puedes editar'
           when v_is_manager then 'Tienes permiso para administrar dinero'
           else 'Solo el acreedor o un administrador pueden editar la obligación' end);
  end if;

  if v_ob.context_actor_id is not null then
    return public._aa_apply_governance_mode(v_actions, v_ob.context_actor_id);
  end if;
  return v_actions;
end; $$;
