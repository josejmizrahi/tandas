# D.22 FASE B — `action_catalog` Shape Proposal

**Status:** pending founder approval ANTES de mig.
**Depende de:** doctrinal lock-ins en `Plans/Active/D22_ActionGovernance_AuditA.md` §5.
**Output:** 1 migración + ≈ 90 filas seed.

---

## 1. Shape SQL propuesto

```sql
CREATE TABLE action_catalog (
  action_key text PRIMARY KEY,
  domain text NOT NULL CHECK (domain IN (
    'identity','group','membership','resource','money','rule',
    'decision','sanction','dispute','mandate','role','norm',
    'reputation','dissolution','engine','inbox','notification'
  )),
  display_name text NOT NULL,
  description text NOT NULL,

  -- Risk tier
  risk_level text NOT NULL CHECK (risk_level IN (
    'low','medium','high','critical','constitutional'
  )),
  is_constitutional boolean NOT NULL DEFAULT false,

  -- Authority
  default_required_permission text REFERENCES permissions(key),
  default_requires_decision boolean NOT NULL DEFAULT false,
  default_decision_template_key text REFERENCES decision_templates_catalog(template_key),

  -- Founder override (sólo si NO es constitutional)
  founder_can_override boolean NOT NULL DEFAULT false,

  -- Threshold gating (sólo money/value actions)
  has_threshold boolean NOT NULL DEFAULT false,
  default_threshold_amount numeric,
  default_threshold_unit text,

  -- Dispatch
  executable_rpc text,  -- nombre del RPC que ejecuta el side effect
  target_kind text,     -- kind del target (membership, resource, rule, sanction, ...)

  metadata jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),

  -- Invariantes
  CONSTRAINT action_catalog_founder_no_constitutional
    CHECK (NOT (is_constitutional AND founder_can_override)),
  CONSTRAINT action_catalog_threshold_consistent
    CHECK (NOT has_threshold OR (default_threshold_amount IS NOT NULL AND default_threshold_unit IS NOT NULL)),
  CONSTRAINT action_catalog_decision_consistent
    CHECK (NOT default_requires_decision OR default_decision_template_key IS NOT NULL)
);

CREATE INDEX idx_action_catalog_domain ON action_catalog (domain);
CREATE INDEX idx_action_catalog_risk ON action_catalog (risk_level);
```

**Group-level overrides** (extender `groups.governance`):
```jsonb
{
  "action_thresholds": {
    "money.expense.record": {"amount": 10000, "unit": "MXN"},
    "money.pool_charge.create": {"amount": 5000, "unit": "MXN"},
    "resource.value.update": {"amount": 50000, "unit": "MXN"}
  },
  "action_overrides": {
    "membership.suspend": "requires_decision",
    "resource.archive": "direct"
  },
  "founder_emergency_enabled": true
}
```

Sólo permite **elevar** (default direct → require decision). NO permite bajar (default decision → direct) salvo `founder_emergency_enabled=true` para acciones con `founder_can_override=true`.

---

## 2. Seed payload (90 filas) — preview por dominio

### 2.1 Identity (4 acciones · todas low/self-only)

| action_key | risk | constitutional | requires_decision | founder_override | threshold |
|---|---|---|---|---|---|
| `identity.profile.read` | low | false | false | false | — |
| `identity.profile.update` | low | false | false | false | — |
| `identity.gdpr.delete_export` | medium | false | false | false | — |
| `identity.token.register` | low | false | false | false | — |

### 2.2 Group (5)

| action_key | risk | constitutional | decision | founder_override | template |
|---|---|---|---|---|---|
| `group.create` | low | false | false | false | — |
| `group.purpose.set` | low | false | false | true | — |
| `group.purpose.archive` | low | false | false | true | — |
| `group.visibility.set` | high | **true** | **true** | **false** | `decision.group_visibility` (nuevo) |
| `group.boundary.set` | high | **true** | **true** | **false** | `decision.group_boundary` (nuevo) |

### 2.3 Group meta — governance & engine (5)

| action_key | risk | constitutional | decision | founder_override |
|---|---|---|---|---|
| `group.decision_rules.set` | **constitutional** | **true** | **true** | **false** |
| `engine.toggle` | high | **true** | **true** | **false** |
| `group.dissolve.start` | high | false | false | true (admin propose) |
| `group.dissolve.finalize` | **constitutional** | **true** | **true** | **false** |
| `group.dissolve.record_step` | medium | false | false | true |

### 2.4 Membership (10 + transitions)

| action_key | risk | decision | founder_override |
|---|---|---|---|
| `membership.invite` | low | false | true |
| `membership.invite.revoke` | low | false | true |
| `membership.invite.accept` | low | false | false (self) |
| `membership.request` | low | false | false (self) |
| `membership.request.approve` | medium | false (o group-elevated) | true |
| `membership.leave` | low | false | false (self) |
| `membership.pause` | low | false | true |
| `membership.suspend` | medium | **false** (admin-direct per founder) | true |
| `membership.ban` | high | **true** | **true** (founder emergency) |
| `membership.remove` | high | **true** | **true** (founder emergency) |
| `membership.reinstate.from_banned` | high | **true** (catalog enforced) | false |
| `membership.confirm_provisional` | low | false | true |

**`membership_state_transitions_catalog` fix (FASE D):**
- `active→banned` → `requires_decision=true`
- `active→removed` → `requires_decision=true`
- `suspended→banned` → `requires_decision=true`
- `active→suspended` → `requires_decision=false` (admin-direct)
- `active→paused` → `requires_decision=false` (self/admin)

### 2.5 Resource (26)

| action_key | risk | decision | threshold |
|---|---|---|---|
| `resource.create` | low | false | — |
| `resource.update` | low | false | — |
| `resource.archive` | high | **true** | — |
| `resource.unarchive` | medium | **true** (nuevo template) | — |
| `resource.transfer` | high | **true** | — |
| `resource.value.update` | medium | **threshold** | sí (default `default_threshold_amount=10000 MXN`) |
| `resource.valuation.record` | low | false | — |
| `resource.event.lifecycle` | low | false | — |
| `resource.custodian.assign` | low | false | — |
| `resource.custodian.release` | low | false | — |
| `resource.condition.mark` | low | false | — |
| `resource.book` | low | false | — |
| `resource.book.cancel` | low | false | — |
| `resource.right.grant` | medium | false | — |
| `resource.right.transfer` | medium | false | — |
| `resource.right.revoke` | medium | false | — |
| `resource.slot.assign` | low | false | — |
| `resource.slot.release` | low | false | — |
| `resource.fund.lock` | medium | false (admin) | — |
| `resource.fund.unlock` | medium | false (admin) | — |
| `resource.fund.set_threshold` | low | false | — |
| `resource.capability.enable` | low | false | — |
| `resource.capability.disable` | low | false | — |
| `resource.rsvp.submit` | low | false (self) | — |
| `resource.checkin.submit` | low | false (self) | — |
| `resource.series.create` | low | false | — |
| `resource.series.update` | low | false | — |

### 2.6 Money (15)

| action_key | risk | decision | threshold | founder_override |
|---|---|---|---|---|
| `money.expense.record` | medium | **threshold** | sí (default `10000 MXN`) | true |
| `money.settlement.record` | low | false | — | true |
| `money.contribution.record` | low | false | — | true |
| `money.contribution.log` | low | false | — | true |
| `money.contribution.verify` | low | false | — | true |
| `money.contribution.non_monetary` | low | false | — | true |
| `money.pool_charge.create` | medium | **threshold** | sí (default `5000 MXN`) | true |
| `money.pool_charge.batch` | medium | **threshold** | sí (default `5000 MXN`) | true |
| `money.payout` | **high** | **true** (nuevo `decision.payout`) | sí (default `0`) | **true** |
| `money.peer_obligation.record` | low | false | — | true |
| `money.transaction.reverse` | **high** | **true** (nuevo `decision.transaction_reverse`) | — | **true** |
| `money.sanction.issue` | medium | false | — | true |
| `money.sanction.pay` | low | false (self) | — | false |
| `money.sanction.update_status` | medium | false | — | true |
| `money.payment_plan.propose` | low | false | — | true |
| `money.payment_plan.cancel` | low | false | — | true |

### 2.7 Rule (6)

| action_key | risk | decision | founder_override |
|---|---|---|---|
| `rule.propose` | low | false | true |
| `rule.create_text` | low | false | true |
| `rule.create_engine` | medium | false | true |
| `rule.publish` | high | **true** (extender `decision.rule_change`) | true |
| `rule.archive` | medium | **true** | true |
| `rule.activate` | medium | decision-only | true |

### 2.8 Decision (7) — todas meta, todas direct

`decision.create / vote / vote.ranked / finalize / execute / cancel / template.apply` → todas direct, no_override (es el sistema mismo).

### 2.9 Dispute (5) — todas direct

`dispute.open / event.append / mediator.assign / resolve / escalate_to_vote`.

### 2.10 Mandate (3)

| action_key | risk | decision | founder_override |
|---|---|---|---|
| `mandate.grant` | high | **true** (nuevo `decision.mandate_grant`) | true |
| `mandate.revoke` | medium | dual (template existe) | true |
| `mandate.report` | low | false | true |

### 2.11 Role (4)

| action_key | risk | constitutional | decision |
|---|---|---|---|
| `role.create` | **constitutional** | **true** | **true** (nuevo `decision.role_create`) |
| `role.update_permissions` | **constitutional** | **true** | **true** (nuevo `decision.role_update`) |
| `role.assign` | medium (tiered) | false | varies (decision if rol founder/admin) |
| `role.revoke` | medium (tiered) | false | varies |

> `role.assign` tier-aware: si `target_role IN ('founder','admin')` → decision. Si `member`/`observer`/custom → direct. Lógica en `resolve_action_governance`.

### 2.12 Norm (4)

| action_key | risk | decision |
|---|---|---|
| `norm.propose` | low | false |
| `norm.endorse` | low | false |
| `norm.retire` | low | false |
| `norm.promote_to_rule` | medium | **true** (acoplada a `rule.publish`) |

### 2.13 Reputation (2)

`reputation.event.record / .retract` → direct.

### 2.14 Inbox / Notifications (4) — self-only direct

`inbox.mark_read / mark_all_read / notification.preference.set / notification.token.register`.

---

## 3. Templates faltantes (FASE D)

9 templates a crear en `decision_templates_catalog`:

| template_key | display_name | decision_type | reference_kind | execution_mode | metadata |
|---|---|---|---|---|---|
| `decision.payout` | "Aprobar payout" | proposal | money_movement | manual | `{action_key:'money.payout'}` |
| `decision.transaction_reverse` | "Revertir transacción" | proposal | money_movement | secondary_approval | `{action_key:'money.transaction.reverse'}` |
| `decision.engine_toggle` | "Activar/desactivar motor" | governance | group | manual | `{action_key:'engine.toggle'}` |
| `decision.governance_change` | "Cambio constitucional" | governance | group | secondary_approval | `{action_key:'group.decision_rules.set', constitutional:true}` |
| `decision.group_boundary` | "Cambiar política de entrada" | governance | group | manual | `{action_key:'group.boundary.set'}` |
| `decision.group_visibility` | "Cambiar visibilidad del grupo" | governance | group | manual | `{action_key:'group.visibility.set'}` |
| `decision.role_create` | "Crear rol nuevo" | governance | role | secondary_approval | `{action_key:'role.create', constitutional:true}` |
| `decision.role_update` | "Cambiar permisos de rol" | governance | role | secondary_approval | `{action_key:'role.update_permissions', constitutional:true}` |
| `decision.mandate_grant` | "Otorgar mandato" | proposal | mandate | manual | `{action_key:'mandate.grant'}` |

Y extender `decision.rule_change` para soportar `action='publish'` (no solo archive).

---

## 4. Preguntas residuales para el founder

A. **`group.dissolve.start` puede ser direct (admin propose) o requiere decisión grupal incluso para abrir el proceso?** Default: direct con perm `group.dissolve`, founder_override=true.

B. **`mandate.revoke` decision-required o dual?** Hoy es dual. Default propuesto: dual (admin direct + decision opcional vía `mandate_revoke` reference_kind).

C. **`role.assign(custom_role)` direct siempre, o si el custom_role tiene perm `members.remove`/`engine.toggle`/etc. lo elevamos?** Default propuesto: direct para custom. Decision sólo para founder/admin built-in.

D. **`founder_emergency_enabled` default por grupo:** ¿`true` o `false` al crear grupo? Default propuesto: `true` (founder puede actuar emergency desde día 1; grupo puede desactivar vía decision).

E. **`record_payout` threshold default `0`:** ¿todo payout requiere decisión, o sólo > X? Default propuesto: `0` (todo payout abre decisión — alto riesgo).

---

## 5. Próximo paso

Pendiente:
1. Founder revisa §2-4.
2. Founder responde A-E (5 residuales, todos pueden ir con default propuesto si OK).
3. Aplicar mig FASE B (1 archivo SQL ≈ 200 líneas: CREATE TABLE + seed 90 filas).
4. Smoke `_smoke_action_catalog_seed` verifica que las 90 action_keys están + invariantes OK.

Después de FASE B, **FASE C (resolve_action_governance)** puede arrancar self-contained sin más preguntas.

**Tamaño estimado FASE B:** 1 mig + 1 smoke. ≈ 1 hora.
