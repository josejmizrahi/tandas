# R.5 · Governance Engine

Estado: **backend aplicado en dev (`wyvkqveienzixinonhum`) + smoke verde**. Primera
fase del roadmap R.5→R.13. Todo additive y backward-compatible.

## Objetivo

Convertir las decisiones en el mecanismo oficial de autoridad: políticas de
gobernanza por contexto, delegación de voto, voto ponderado, voto por consenso,
auditoría y gobernanza obligatoria para acciones críticas — sin romper iOS ni
renombrar RPCs.

## Principio rector: opt-in

Un contexto **sin** filas en `governance_policies` se comporta **exactamente**
igual que antes:
- peso de voto = 1 (el trigger devuelve 1 cuando no hay `vote_weight_source` ni
  delegaciones),
- `close_decision` usa la lógica histórica (approve > reject),
- `remove_member` remueve directo (con `members.manage`).

El engine sólo "despierta" cuando el contexto define políticas.

## Migraciones

| Archivo | Contenido |
|---|---|
| `20260604150000_r5_governance_engine.sql` | tablas + helpers + trigger + RPCs + `close_decision`/`remove_member` policy-aware + catálogo de actividad |
| `20260604150001_r5_smoke_governance.sql` | smoke (1ª iteración) |
| `20260604150002_r5_smoke_fix_cleanup.sql` | smoke canónico (fix: `activity_events` es append-only) |

## Tablas nuevas

- **`governance_policies`** `(context_actor_id, policy_key, policy_value jsonb)`
  unique`(context, key)`. RLS: miembros leen.
- **`vote_delegations`** `(context, delegator, delegate, starts_at, ends_at, revoked_at)`.
  Índice único parcial: una delegación activa por `(context, delegator)`.
- **`governance_actions`** auditoría + enlace acción crítica ↔ decisión que la
  gobierna `(action_key, target, decision_id, status, proposed_by, executed_by)`.
  La verdad sobre "aprobada" la da `decisions.status` (no se duplica estado).

## Mapeo de los 6 sub-objetivos

| Sub | Cómo se implementó |
|---|---|
| 5.1 Governance Policies | tabla `governance_policies` + `create/update/list_governance_policies` + reader `governance_policy(ctx,key)` |
| 5.2 Delegación de voto | `vote_delegations` + `delegate_vote` / `revoke_vote_delegation`; el peso delegado se suma al delegate mientras el delegador no vote |
| 5.3 Weighted voting | `actor_vote_weight(ctx, actor, policy)` (equal/shares/ownership/participation) + `_effective_vote_weight` + **trigger** `trg_decision_votes_weight` (BEFORE INSERT/UPDATE). `vote_decision` **no se toca** |
| 5.4 Consent voting | rama en `close_decision`: con `consent_voting=true`, aprobado salvo objeción (`reject>0`). También quórum (`quorum`) y umbral (`approval_threshold`) |
| 5.5 Governance Audit | tabla `governance_actions` (propuso/aprobó/ejecutó). `close_decision` refleja approved/rejected; `remove_member` marca `executed` |
| 5.6 Mandatory Governance | `request_governed_action(ctx, action_key, …)` abre decisión `governance` si la política lo exige; `remove_member` gate por `member_ban_requires_vote` |

## Decisiones de diseño (por qué así)

- **No se modifica `vote_decision`** (la RPC más compleja, ya con multiple_choice
  y `decision_options`). El peso entra por trigger → cero riesgo para iOS.
- **Quórum/umbral/consent viven en `close_decision`** (cierre manual), no en el
  auto-finalize, para no alterar el camino de voto en caliente.
- **`governance_actions` no duplica estado**: el gate (`_governance_action_approved`)
  consulta `decisions.status`. Backend = autoridad.
- **`decision_type='governance'`** (ya permitido desde R.4B) para las decisiones
  que gobiernan acciones críticas; el detalle va en `payload.governed_action`.

## Acciones críticas cubiertas (policy keys)

`member_ban_requires_vote`, `resource_transfer_requires_vote`,
`rule_change_requires_vote`, `ownership_change_requires_vote`,
`large_expense_requires_vote`. Hoy el gate está cableado en `remove_member`
(prueba canónica); el resto se cablea cuando cada dominio lo necesite vía el
mismo patrón `request_governed_action` + `_governance_action_approved`.

## Smoke (`_smoke_r5_governance`) — verde en dev

C1 tablas+RLS · C2 policies upsert/list/reader · C3 weighted (shares→peso 3) ·
C4 delegación (peso 2) + revoke · C5 consent (aprueba sin objeción / rechaza con
objeción) · C6 quórum insuficiente → rejected · C7 mandatory governance
(remove_member bloqueado → request → aprobar → remover + auditoría executed) ·
C8 member sin autoridad no fija políticas.

## Backward-compat verificada

Smokes que ejercen los caminos tocados, verdes tras R.5: `mvp2_m2_participation`
(remove_member), `mvp2_m7_decisions`, `r2q_yes_no_abstain`, `r2q_single_choice`,
`r2q_backward_compatibility`, `r2q_execution_payload`, `r4b_decision_templates`,
`f_decision_5_update_decision`.

(Pre-existentes y ajenos a R.5: `r2q_*_voting_model_not_implemented` esperan que
`multiple_choice` falle, pero R.2Q.6 lo implementó; `r2t_*` falla por la regla
F.EVENT.5 de location requerido. Ninguno toca gobernanza.)

## Pendiente para iOS (siguiente, no bloquea sign-off backend)

- Modelos `RuulCore/Domain`: `GovernancePolicy`, `VoteDelegation`, `GovernanceAction`.
- `RuulRPCClient`: `createGovernancePolicy`, `delegateVote`, `requestGovernedAction`, …
- Mock world + previews. UI de políticas dentro del ContextHome de admin.

## Siguiente fase

R.6 · Rule Engine completo — **requiere sign-off de R.5**.
