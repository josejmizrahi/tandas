# R.5A — Context Detail & Resource Detail Architecture

**Fecha:** 2026-06-05
**Founder-signed lock:** ver `doctrine_ruul_foundation_actor_context_resource.md` (memoria) y CLAUDE.md MVP 2.0 doctrine.
**Status:** Contrato congelado — pendiente ejecución por slices.
**Branch base:** `main` (último commit `96e58d4f` D.0 drift fix).

Documento autoritativo para R.5A. Antes de tocar SQL o iOS, todo cambio debe alinearse a este contrato.

---

## 0. Principios rectores

1. **Additive only.** No se renombra ni se reemplaza tabla viva. `resource_type`/`resource_type_catalog`/`resource_type_capabilities` permanecen como **legacy compat** hasta que B.6/F.1 estén en producción y founder firme deprecación.
2. **Triada inmutable.** Actor / Context / Resource. No crear `entity/entities`. No fusionar actors+resources. **No** se agrega `actor_resource_links` en R.5A (discusión de Ruul 3.0).
3. **Lógica vive en capabilities + rights + relations.** Subtypes clasifican, no determinan comportamiento.
4. **iOS no depende de `resource_type`.** Render se hace desde `class`, `subtype`, `effective_capabilities`, `rights`, `permissions`, `state`, `sections`, `widgets`, `actions`.
5. **`available_actions[]` mantiene shape canónico F.2X.** Cualquier extensión es additive (campos nuevos opcionales).
6. **`execute_resource_action` es dispatcher, NO reemplazo.** Delega por `action_key` a RPCs vivos (`record_expense`, `grant_right`, `request_resource_reservation`, etc.). Solo añade idempotencia + emisión uniforme de activity_event + gate de governance.
7. **Cero impacto runtime hasta B.6/B.7.** Las slices B.0–B.5 sólo agregan tablas/catálogos/columnas; los RPCs vivos no cambian comportamiento. iOS sigue funcionando con `resource_detail`/`context_summary`.
8. **Smoke test por slice.** Cada migration entra con `_smoke_r5a_b_<N>` siguiendo el patrón de R.4A–R.4D (verde 100% antes de avanzar).
9. **Context Detail es ciudadano de primera clase.** Mismo patrón descriptor-driven que Resource: `context_section_catalog` + `context_subtype_sections` + `context_dashboard_widgets` + `context_subtype_widgets`. El subtype = `actors.actor_subtype` (`family`, `company`, `trip`, `project`, `community`, `trust`, `generic`).

---

## 1. Modelo conceptual (recap del lock)

```
Actor       → entidad participante  (person | collective | legal_entity | system)
Context     → Actor con is_context=true (familia, empresa, viaje, proyecto, comunidad)
Resource    → objeto administrable (casa, fondo, contrato, vehículo, obligación, …)
```

**Regla de oro:**
- ¿necesita miembros / roles / decisiones / gobernanza? → **Context**.
- ¿necesita propiedad / uso / reservas / documentación / valuación? → **Resource**.

**Resource evoluciona a:**

```
Resource → Class → Subtype → Effective Capabilities → Rights → Relations → Sections → Widgets → Actions → Forms → State
```

---

## 2. Estado actual del backend (qué existe ya)

| Pieza | Tabla / RPC | Estado | Origen |
|---|---|---|---|
| Tipos de recurso | `resource_type_catalog` (15 seed) | ✅ vivo | R.2M (`20260603100000`) |
| Capabilities | `resource_capabilities_catalog` (15 keys) | ✅ vivo | R.2M / R.2M-3 |
| Type→Capability | `resource_type_capabilities` | ✅ vivo | R.2M-3 |
| Catálogo de acciones | `resource_action_catalog` | ✅ vivo (~22 acciones) | R.2M-3 |
| Rights universales | `resource_rights` | ✅ vivo | MVP2 004 |
| Available actions | `resource_available_actions(resource_id, actor_id)` + `*_event/_context/_decision/_reservation/_obligation` | ✅ vivo | F.2X.0 |
| Detail RPCs | `resource_detail`, `event_detail`, `decision_detail`, `reservation_detail`, `obligation_detail` | ✅ vivo | R.2S/F.2X |
| Marker actor=context | `actors.is_context` + trigger | ✅ vivo | R.4A |
| Hierarchy contexts | `actor_relationships.contains` | ✅ vivo | R.2U |
| Governance policies | `governance_policies` + `policy_proposals` | ✅ vivo | R.5 (D.1–D.3) |
| Vote delegations | `vote_delegations` | ✅ vivo | R.5 (D.3) |

**Conclusión:** R.5A no parte de cero. Extiende lo vivo.

---

## 3. Modelo target (qué se agrega)

### 3.1 Tablas nuevas

| Tabla | Propósito | Slice |
|---|---|---|
| `resource_classes` | Catálogo de clases (real_estate, financial, vehicle, …) | B.0 |
| `resource_subtypes` | Subtipos por clase (vacation_home, money_pool, …) | B.0 |
| `resource_subtype_capabilities` | Defaults por subtype (subtype → capability) | B.2 |
| `resource_capability_overrides` | Per-instance overrides (resource → capability → enabled) | B.2 |
| `resource_relations` | Relaciones resource↔resource (contains, secures, …) | B.3 |
| `resource_section_catalog` | Catálogo universal de secciones UI de Resource | B.4R |
| `resource_subtype_sections` | Mapping resource_subtype → sección visible (con required_capability/rights/status) | B.4R |
| `resource_dashboard_widgets` | Catálogo universal de widgets de Resource | B.4R |
| `resource_subtype_widgets` | Mapping resource_subtype → widget | B.4R |
| `context_section_catalog` | Catálogo universal de secciones UI de Context | B.4C |
| `context_subtype_sections` | Mapping actor_subtype (context) → sección visible (con required_permission/status) | B.4C |
| `context_dashboard_widgets` | Catálogo universal de widgets de Context | B.4C |
| `context_subtype_widgets` | Mapping actor_subtype (context) → widget | B.4C |
| `resource_action_forms` | Esquema JSON de cada formulario de acción | B.5b |

### 3.2 Tablas alteradas (additive)

| Tabla | Cambio | Slice |
|---|---|---|
| `resources` | + `resource_class_key text` (FK), + `resource_subtype_key text` (FK), + backfill desde `resource_type` | B.1 |
| `resource_capabilities_catalog` | + ~20 capabilities nuevas (ver §4.3) | B.2 |
| `resource_action_catalog` | + ~60 acciones nuevas (ver §4.5) | B.5a |

### 3.3 RPCs nuevos

| RPC | Slice | Tipo |
|---|---|---|
| `effective_resource_capabilities(p_resource_id)` | B.2 | STABLE |
| `list_resource_relations(p_resource_id)` | B.3 | STABLE |
| `set_resource_relation` / `remove_resource_relation` | B.3 | SECURITY DEFINER |
| `set_resource_capability_override(p_resource_id, p_capability_key, p_enabled, p_reason?)` | B.2 | SECURITY DEFINER |
| `resource_detail_descriptor(p_resource_id)` | B.6 | STABLE |
| `context_detail_descriptor(p_context_actor_id)` | B.7 | STABLE |
| `list_resource_actions(p_resource_id)` | B.8 | STABLE |
| `execute_resource_action(p_resource_id, p_action_key, p_payload, p_client_id?)` | B.8 | SECURITY DEFINER |

`resource_detail` (existente) **se mantiene** durante toda la transición. `resource_detail_descriptor` es la superficie nueva. F.1 hace el switch en iOS.

---

## 4. Seeds canónicos

### 4.1 `resource_classes` (17 keys)

```
real_estate · financial · vehicle · equipment · document · event · obligation ·
right · inventory · project · trip · space · digital_asset · service ·
membership · agreement · generic
```

### 4.2 `resource_subtypes` (seed mínimo R.5A.B.0, agrupados por class)

| class_key | subtype_keys |
|---|---|
| real_estate | primary_residence, vacation_home, apartment, office, warehouse, land, rental_property, industrial_property |
| financial | money_pool, bank_account, investment_account, crypto_wallet, trust_fund |
| vehicle | car, truck, machine, tool |
| document | contract, receipt, statement, certificate, policy |
| event | recurring_event, meeting, dinner, community_event |
| obligation | iou, fine, loan, contribution, dues |
| inventory | inventory_item |
| project | internal_project |
| trip | group_trip |
| equipment | generic_equipment |
| space | generic_space |
| right | generic_right |
| digital_asset | generic_digital_asset |
| service | generic_service |
| membership | generic_membership |
| agreement | generic_agreement |
| generic | generic_resource |

**Backfill resource_type → (class_key, subtype_key)** (B.1):

| resource_type legacy | class_key | subtype_key |
|---|---|---|
| `house` | real_estate | primary_residence |
| `property` | real_estate | land |
| `vehicle` | vehicle | car |
| `bank_account` | financial | bank_account |
| `cash_pool` | financial | money_pool |
| `security` | financial | investment_account |
| `contract` | document | contract |
| `document` | document | certificate |
| `equipment` | equipment | generic_equipment |
| `digital_asset` | digital_asset | generic_digital_asset |
| `trust_asset` | financial | trust_fund |
| `trip_booking` | trip | group_trip |
| `game` | event | recurring_event |
| `membership_asset` | membership | generic_membership |
| `reservation` | space | generic_space |
| `other` | generic | generic_resource |

### 4.3 `resource_capabilities_catalog` — keys adicionales (B.2)

Catálogo final = 15 vivas ∪ ~20 nuevas → ~35 total. Vivas: reservable, monetary, transferable, shareable, governable, beneficiary_supported, approval_required, expirable, depreciable, documentable, sellable, rentable, auditable, ownership_trackable, maintainable.

**Nuevas:** ownable, usable, payable, chargeable, settleable, splittable, assignable, custodiable, condition_trackable, location_bound, schedulable, recurring, closeable, rule_bound, votable, signable, versionable, disputable, notifiable, income_generating, leasable, insurable, taxable, inventory_tracked, quantity_tracked, access_controlled.

Mapeo legacy ↔ nuevo (mantener ambas, NO renombrar):
- `monetary` ≈ payable+chargeable+settleable (se mantiene como agregado para back-compat).
- `rentable` ≈ leasable (alias en metadata, ambas vivas).
- `sellable` ≈ transferable+disputable (independientes).

### 4.4 `resource_section_catalog` (45 keys)

```
overview · details · balance · movements · member_balances · expenses · contributions ·
fines · ious · settlements · attendees · rsvp · host · recurrence · availability ·
reservations · calendar · access · rights · rules · decisions · obligations ·
documents · versions · approvals · signatures · maintenance · condition ·
usage_history · custody · payments · disputes · itinerary · tasks · budget ·
checklist · stock · inventory_movements · location · insurance · taxes ·
valuation · income · leases · relations · activity · settings
```

### 4.5 `resource_action_catalog` — keys adicionales (B.5a)

Catálogo final = ~22 vivas ∪ ~70 nuevas. Lista completa en spec del founder §15. Se agregan agrupadas por `ui_section`:

- **resource ops:** edit_resource, archive_resource, restore_resource, view_activity, transfer_resource, link_document, upload_document, link_existing_resource, unlink_resource, request_transfer, approve_transfer, transfer_ownership, transfer_custody, return_resource, report_issue, record_maintenance, update_condition, update_valuation, record_damage.
- **rights:** grant_right (alias del vivo), revoke_right (alias del vivo).
- **reservations:** view_availability, create_reservation, approve_reservation, reject_reservation, cancel_reservation, complete_reservation, join_waitlist, resolve_reservation_conflict, block_time, unblock_time.
- **money:** record_payment, record_contribution, record_iou, record_charge, record_payout, finalize_settlement_batch, void_transaction, export_statement.
- **events:** rsvp_event, invite_participant, mark_no_show, change_host, preview_next_host, set_next_host, cancel_event, reopen_event, record_event_expense.
- **documents:** upload_new_version, request_approval, approve_document, reject_document, sign_document, archive_document.
- **obligations:** accept_obligation, complete_obligation, dispute_obligation, forgive_obligation, extend_due_date, convert_to_settlement, cancel_obligation.
- **real estate:** record_property_expense, record_insurance, record_tax_payment, record_lease_income, create_lease, terminate_lease.
- **inventory:** adjust_stock, transfer_stock, consume_item, record_purchase.

Cada nueva acción se inserta con: `required_capability` (FK), `required_rights text[]`, `ui_section`, `sort_order`. Las acciones que requieren governance template (transfer_ownership, archive_resource, …) se marcan en `metadata.execution_mode = 'request_decision'` + `metadata.decision_template_key`.

### 4.6 `resource_dashboard_widgets` (17 seed)

```
balance_summary · open_obligations · upcoming_reservations · next_event ·
recent_activity · resource_value · insurance_status · tax_status ·
maintenance_status · document_status · reservation_status ·
member_balance_summary · settlement_status · condition_status ·
custody_status · income_summary · lease_status
```

### 4.7 `context_section_catalog` (10 seed)

```
overview · people · resources · money · calendar · governance ·
documents · obligations · activity · settings
```

Cada sección tiene: `section_key`, `display_name`, `description`, `icon`, `default_sort_order`, `metadata`. Las secciones se ordenan por `default_sort_order` y se filtran por permisos en `context_detail_descriptor`.

### 4.8 `context_dashboard_widgets` (≥12 seed)

```
next_event · open_decisions · open_obligations · cash_balance ·
member_count_summary · active_projects · recent_activity ·
critical_resources · pending_invitations · upcoming_reservations ·
budget_progress · settlement_status
```

### 4.9 `context_subtype_sections` y `context_subtype_widgets` — defaults por subtype

`actors.actor_subtype` (where `is_context=true`) es plain text whitelist. Subtypes seed para R.5A.B.4C (no FK rígido — mapping flexible):

| actor_subtype | sections visibles (default) | widgets default |
|---|---|---|
| `family` | overview, people, resources, money, calendar, governance, documents, obligations, activity, settings | next_event, cash_balance, open_obligations, recent_activity |
| `company` | overview, people, resources, money, governance, documents, activity, settings | cash_balance, open_decisions, active_projects, critical_resources |
| `trip` | overview, people, resources, money, calendar, documents, obligations, activity, settings | budget_progress, upcoming_reservations, member_count_summary, recent_activity |
| `project` | overview, people, resources, calendar, governance, documents, activity, settings | active_projects, open_decisions, critical_resources, recent_activity |
| `community` | overview, people, resources, money, calendar, governance, documents, activity, settings | next_event, member_count_summary, pending_invitations, recent_activity |
| `trust` | overview, people, resources, money, governance, documents, obligations, activity, settings | cash_balance, critical_resources, open_decisions, recent_activity |
| `friend_group` (legacy) | overview, people, money, calendar, activity, settings | next_event, cash_balance, open_obligations, recent_activity |
| `generic` (fallback) | overview, people, resources, activity, settings | recent_activity |

**Fallback rule:** si un context tiene `actor_subtype` no mapeado, se usa `generic`. iOS nunca debe quedar sin secciones que mostrar.

---

## 5. Contratos JSON canónicos

### 5.1 `effective_resource_capabilities(p_resource_id uuid)`

```json
{
  "resource_id": "uuid",
  "class_key": "real_estate",
  "subtype_key": "vacation_home",
  "defaults": ["ownable", "maintainable", "documentable", "payable", "auditable",
               "location_bound", "insurable", "taxable", "reservable",
               "chargeable", "shareable"],
  "overrides": [
    { "capability_key": "reservable", "enabled": true,  "reason": "Founder enabled" },
    { "capability_key": "leasable",   "enabled": false, "reason": "Familia decidió no rentar" }
  ],
  "effective": ["ownable", "maintainable", "documentable", "payable", "auditable",
                "location_bound", "insurable", "taxable", "reservable",
                "chargeable", "shareable"]
}
```

Fórmula: `effective = (defaults ∪ overrides_enabled) ∖ overrides_disabled`.

### 5.2 `resource_detail_descriptor(p_resource_id uuid)`

```json
{
  "resource":   { /* fila resources + canonical_owner_actor_id + status */ },
  "class":      { "class_key": "...", "display_name": "...", "icon": "...", "description": "...", "metadata": {} },
  "subtype":    { "subtype_key": "...", "class_key": "...", "display_name": "...", "icon": "...", "metadata": {} },
  "effective_capabilities": ["ownable", "reservable", "..."],
  "rights": [
    { "right_id": "uuid", "holder_actor_id": "uuid", "holder_display_name": "...",
      "right_kind": "OWN", "percent": "100.0", "scope": null,
      "starts_at": "...", "ends_at": null }
  ],
  "sections": [
    { "section_key": "overview", "display_name": "Resumen", "icon": "...",
      "sort_order": 1, "visible": true, "required_capability": null,
      "required_rights": [], "visible_when_status": [] },
    { "section_key": "reservations", "display_name": "Reservaciones", "icon": "...",
      "sort_order": 20, "visible": true, "required_capability": "reservable",
      "required_rights": ["VIEW","USE","MANAGE","OWN","GOVERN"],
      "visible_when_status": ["active"] }
  ],
  "widgets": [
    { "widget_key": "next_event", "display_name": "Próxima reserva", "icon": "...",
      "data_source_key": "resource.next_reservation", "sort_order": 1 }
  ],
  "actions": [
    { "action_key": "reserve_resource", "label": "Reservar", "section": "reservations",
      "enabled": true, "reason": null,
      "required_rights": ["USE","MANAGE","OWN"],
      "required_capability": "reservable",
      "mode": "execute",
      "decision_template_key": null,
      "form_schema_present": true,
      "dangerous": false,
      "confirmation_required": false }
  ],
  "action_forms": {
    "reserve_resource": {
      "form_schema": { /* JSON Schema simplificado: fields, types, required, helpText */ },
      "default_payload": { "starts_at": null, "ends_at": null, "purpose": null },
      "confirmation_required": false,
      "dangerous": false
    }
  },
  "state": {
    "status": "active",
    "archived": false,
    "locked_for_governance": false,
    "open_decision_id": null
  },
  "metrics": {
    "estimated_value": "1500000.00",
    "currency": "MXN",
    "balance": null,
    "last_movement_at": null
  },
  "relations": [
    { "relation_id": "uuid", "direction": "outbound",
      "relation_type": "documents",
      "other_resource_id": "uuid",
      "other": { "id": "uuid", "display_name": "Escritura Casa Acapulco",
                 "class_key": "document", "subtype_key": "contract" } }
  ],
  "linked_events":      [ /* preview ≤5: id, title, starts_at, status */ ],
  "linked_documents":   [ /* preview ≤5: id, title, kind, uploaded_at */ ],
  "linked_obligations": [ /* preview ≤5: id, kind, amount, currency, status */ ],
  "linked_decisions":   [ /* preview ≤5: id, title, status, closes_at */ ],
  "activity_preview":   [ /* últimos ≤10 activity_events del resource */ ]
}
```

**Filtros aplicados internamente:**
- `sections` se filtran por `required_capability ∈ effective_capabilities`, `required_rights ∩ rights_del_actor`, y `status ∈ visible_when_status` (vacío = sin filtro).
- `actions` se construyen reusando `resource_available_actions(resource_id, current_actor_id())` + merge con `metadata.execution_mode` y `decision_template_key` desde `resource_action_catalog` + check de `resource_action_forms`.
- `widgets` se filtran por `required_capability`.

### 5.3 `context_detail_descriptor(p_context_actor_id uuid)`

```json
{
  "context": { /* fila actors con is_context=true + actor_kind + actor_subtype + visibility + metadata */ },
  "membership": {
    "membership_id": "uuid",
    "membership_type": "founder",
    "joined_at": "...",
    "my_permissions": ["context.invite", "members.manage", "resources.create", "..."]
  },
  "roles": [
    { "role_key": "founder", "display_name": "Founder", "member_count": 1 },
    { "role_key": "member",  "display_name": "Miembro", "member_count": 4 }
  ],
  "permissions": ["context.invite", "members.manage", "..."],
  "sections": [
    /* Resueltas desde context_subtype_sections filtradas por my_permissions y status del context.
       Cada item: section_key, display_name, icon, sort_order, visible, required_permission, visible_when_status. */
    { "section_key": "overview", "display_name": "Resumen",      "icon": "...", "sort_order": 1,  "visible": true,
      "required_permission": null, "visible_when_status": [] },
    { "section_key": "people",   "display_name": "Personas",     "icon": "...", "sort_order": 2,  "visible": true,
      "required_permission": null, "visible_when_status": [] },
    { "section_key": "resources","display_name": "Recursos",     "icon": "...", "sort_order": 3,  "visible": true,
      "required_permission": null, "visible_when_status": [] },
    { "section_key": "money",    "display_name": "Dinero",       "icon": "...", "sort_order": 4,  "visible": true,
      "required_permission": null, "visible_when_status": [] },
    { "section_key": "calendar", "display_name": "Calendario",   "icon": "...", "sort_order": 10, "visible": true,
      "required_permission": null, "visible_when_status": [] },
    { "section_key": "governance","display_name":"Gobernanza",   "icon": "...", "sort_order": 11, "visible": true,
      "required_permission": "decisions.view", "visible_when_status": [] },
    { "section_key": "documents","display_name": "Documentos",   "icon": "...", "sort_order": 12, "visible": true,
      "required_permission": null, "visible_when_status": [] },
    { "section_key": "obligations","display_name":"Obligaciones","icon": "...", "sort_order": 13, "visible": true,
      "required_permission": null, "visible_when_status": [] },
    { "section_key": "activity", "display_name": "Actividad",    "icon": "...", "sort_order": 14, "visible": true,
      "required_permission": null, "visible_when_status": [] },
    { "section_key": "settings", "display_name": "Configuración","icon": "...", "sort_order": 15, "visible": true,
      "required_permission": "context.manage", "visible_when_status": [] }
  ],
  "widgets": [
    /* Resueltas desde context_subtype_widgets filtradas por permisos. Mismo shape que resource widgets. */
    { "widget_key": "next_event",     "display_name": "Próximo evento",     "icon": "...",
      "data_source_key": "context.next_event",     "sort_order": 1 },
    { "widget_key": "cash_balance",   "display_name": "Balance",            "icon": "...",
      "data_source_key": "context.cash_balance",   "sort_order": 2 },
    { "widget_key": "open_obligations","display_name":"Obligaciones",       "icon": "...",
      "data_source_key": "context.open_obligations","sort_order": 3 },
    { "widget_key": "recent_activity","display_name": "Actividad reciente", "icon": "...",
      "data_source_key": "context.recent_activity","sort_order": 4 }
  ],
  "actions": [ /* available_actions canónicos para el context (de context_available_actions) */ ],
  "metrics": {
    "member_count": 5,
    "resource_count_by_class": { "real_estate": 2, "financial": 1, "document": 4 },
    "pending_decisions": 1,
    "open_obligations": 3,
    "balance_by_currency": { "MXN": "12345.67" }
  },
  "members_preview":     [ /* ≤8 con display_name, avatar, role */ ],
  "resources_preview":   [ /* ≤8 agrupados por class_key */ ],
  "events_preview":      [ /* próximos ≤5 */ ],
  "money_preview":       { "my_balance": "...", "open_settlements": 1 },
  "obligations_preview": [ /* ≤5 */ ],
  "decisions_preview":   [ /* ≤5 abiertas */ ],
  "documents_preview":   [ /* ≤5 recientes */ ],
  "activity_preview":    [ /* últimos ≤10 */ ]
}
```

### 5.4 `list_resource_actions(p_resource_id uuid)`

Es **subconjunto** del campo `actions` de `resource_detail_descriptor`, expuesto como RPC standalone para refresh barato post-execute:

```json
[
  { "action_key": "...", "label": "...", "section": "...",
    "enabled": true, "reason": null,
    "required_rights": ["..."], "required_capability": "...",
    "mode": "execute",                    // "execute" | "request_decision"
    "decision_template_key": null,        // sólo si mode=request_decision
    "form_schema_present": true,
    "dangerous": false,
    "confirmation_required": false }
]
```

### 5.5 `execute_resource_action(p_resource_id, p_action_key, p_payload jsonb, p_client_id uuid default null)`

**Dispatcher.** Validaciones:

1. `auth.uid()` y `current_actor_id()` no nulos.
2. Membership activo en context del recurso.
3. `action_key ∈ resource_action_catalog`.
4. `required_capability ∈ effective_resource_capabilities(p_resource_id)`.
5. `required_rights ∩ rights_efectivos_del_actor ≠ ∅`.
6. Estado del recurso compatible (`status ∈ visible_when_status`).
7. Governance gate: si existe `governance_policy` que cubre el action_key, validar.
8. Idempotencia por `(actor_id, resource_id, action_key, client_id)`.

**Dispatch:**

| `metadata.execution_mode` | Comportamiento |
|---|---|
| `execute` (default) | Llama al RPC mapeado (ver §5.6), pasa `p_payload`, captura resultado. |
| `request_decision` | Llama `create_decision(template_key=metadata.decision_template_key, payload=p_payload, ...)`. NO ejecuta la acción todavía — `execute_decision` la disparará al cerrar. |

**Return:**

```json
{
  "action_key": "...",
  "mode": "execute",                 // o "request_decision"
  "delegated_to_rpc": "record_expense",
  "result": { /* shape del RPC delegado, opaco al dispatcher */ },
  "decision_id": null,               // uuid si mode=request_decision
  "activity_event_id": "uuid",       // siempre emitido
  "idempotent_hit": false
}
```

### 5.6 Dispatcher mapping `action_key → RPC vivo` (B.8)

Mapping completo se mantiene en tabla `resource_action_dispatch` (creada en B.8). Snapshot inicial:

| action_key | RPC delegado | Notas |
|---|---|---|
| `reserve_resource` | `request_resource_reservation` | payload: starts_at, ends_at, purpose |
| `approve_reservation` | `approve_reservation` | |
| `cancel_reservation` | `cancel_reservation` | |
| `resolve_reservation_conflict` | `resolve_reservation_conflict` | |
| `record_expense` | `record_expense` | scope: resource_id opcional |
| `record_fine` | `record_fine` | |
| `record_game_result` | `record_game_result` | |
| `generate_settlement` | `generate_settlement_batch` | |
| `mark_settlement_paid` | `mark_settlement_paid` | |
| `grant_right` | `grant_right` | |
| `revoke_right` | `revoke_right` | |
| `archive_resource` | `archive_resource` | mode=request_decision si policy lo exige |
| `transfer_ownership` | `create_decision` (template `resource_transfer`) | siempre request_decision |
| `rsvp_event` | `rsvp_event` | resource_id=event |
| `check_in_participant` | `check_in_participant` | |
| `close_event` | `close_event` | |
| `cancel_participation` | `cancel_participation` | |
| `create_decision` | `create_decision` | |
| `vote_decision` | `vote_decision` | |
| `upload_document` | `register_document` (R.2P) | |
| (acciones sin RPC vivo) | nuevo RPC minor o `raise '0A000' not_implemented` | B.5a marca cada acción con `available=false, reason='not_implemented'` hasta tener RPC |

---

## 6. Slicing

### Backend

| Slice | Contenido | Migrations | Smoke | Depende |
|---|---|---|---|---|
| **B.0** | `resource_classes` + `resource_subtypes` + seeds (17+30) | 1 mig | `_smoke_r5a_b0_class_subtype_catalogs` | — |
| **B.1** | ALTER `resources` add class_key+subtype_key + FK + backfill desde `resource_type` | 1 mig | `_smoke_r5a_b1_resources_backfill` | B.0 |
| **B.2** | Expand `resource_capabilities_catalog` (~20 nuevas) + `resource_subtype_capabilities` + `resource_capability_overrides` + RPC `effective_resource_capabilities` + RPC `set_resource_capability_override` | 1 mig | `_smoke_r5a_b2_effective_capabilities` | B.1 |
| **B.3** | `resource_relations` + RPCs `list_resource_relations`/`set_resource_relation`/`remove_resource_relation` | 1 mig | `_smoke_r5a_b3_resource_relations` | B.0 |
| **B.4R** | `resource_section_catalog` + `resource_subtype_sections` + `resource_dashboard_widgets` + `resource_subtype_widgets` + seeds | 1 mig | `_smoke_r5a_b4r_resource_sections_widgets` | B.2 |
| **B.4C** | `context_section_catalog` + `context_subtype_sections` + `context_dashboard_widgets` + `context_subtype_widgets` + seeds (7 subtypes: family, company, trip, project, community, trust, generic + friend_group legacy) | 1 mig | `_smoke_r5a_b4c_context_sections_widgets` | — (independiente de la rama Resource) |
| **B.5a** | Expand `resource_action_catalog` (~60 nuevas) + `metadata.execution_mode` + `metadata.decision_template_key` | 1 mig | `_smoke_r5a_b5a_actions_expanded` | B.2 |
| **B.5b** | `resource_action_forms` + seeds JSON Schema para las acciones existentes (~80 rows) | 1 mig | `_smoke_r5a_b5b_action_forms` | B.5a |
| **B.6** | RPC `resource_detail_descriptor(p_resource_id)` consolidado | 1 mig | `_smoke_r5a_b6_resource_descriptor` | B.0–B.4R, B.5b |
| **B.7** | RPC `context_detail_descriptor(p_context_actor_id)` consolidado | 1 mig | `_smoke_r5a_b7_context_descriptor` | B.4C |
| **B.8** | `resource_action_dispatch` (mapping) + RPC `list_resource_actions` + RPC `execute_resource_action` (dispatcher) | 1 mig | `_smoke_r5a_b8_action_dispatcher` | B.5b |

**Checklist por slice (aplica a B.0–B.8):**

- [ ] Migration con header doctrinal (qué, por qué, dependencias).
- [ ] DDL aditivo (sin DROP de tablas/columnas vivas).
- [ ] Seed determinista (idempotente con `ON CONFLICT DO NOTHING` o `DO UPDATE SET`).
- [ ] RLS apropiada (read context-members; write SECURITY DEFINER con `REVOKE FROM anon` + `GRANT EXECUTE TO authenticated, service_role`).
- [ ] Smoke test verde (≥5 asserts cubriendo happy path + 1 negativo).
- [ ] Cero cambio de comportamiento en RPCs vivos (B.0–B.5b).
- [ ] Documentado en este archivo (sección "Status").

### Frontend (arranca SOLO con B.6 + B.7 en main)

| Slice | Contenido | Depende |
|---|---|---|
| **F.0** | Domain models `ResourceDetailDescriptor`, `ContextDetailDescriptor`, `ResourceRelation`, `ResourceSection`, `ResourceWidget`, `ResourceActionForm` + wire RPC en `RuulRPCClient` protocol + `MockRuulRPCClient.demo()` + `SupabaseRuulRPCClient` | B.6, B.7 |
| **F.1** | `ResourceDetailView` v2 descriptor-driven: header dinámico, sections renderer, widgets renderer. **Mantener v1** hasta paridad funcional con 7 subtypes seed founder. | F.0 |
| **F.2** | `ResourceActionFormView` runtime que consume `form_schema` jsonb. Soporta tipos: text, number, date, currency, picker, boolean, reference (actor/resource). Confirmation sheet si `confirmation_required=true`. | F.1, B.8 |
| **F.3** | `ContextDetailView` con tabs Overview / People / Resources / Money / More. Reemplaza `ContextHomeView` actual cuando esté listo (F.NAV lo respeta — sigue siendo el contenido del tab Contextos). | F.0 |
| **F.4** | Sub-tabs: Calendar, Governance, Documents, Activity, Settings (uno por commit). | F.3 |

**Checklist por slice iOS:**
- [ ] Domain decoding tests verdes.
- [ ] Mock con dato del demo world founder.
- [ ] Preview funcional contra Mock.
- [ ] Strict concurrency limpio.
- [ ] Install OK iPhone JJ (smoke manual).
- [ ] `if resource_type == ...` → cero en código nuevo.

---

## 7. Compatibilidad y legacy

| Pieza vieja | Tratamiento durante R.5A | Tratamiento post R.5A |
|---|---|---|
| `resource_type` (col) | Se mantiene poblada. Backfill bidireccional: al crear/editar via path nuevo, set ambos. | Deprecation candidate (founder decide) |
| `resource_type_catalog` | Vivo, consultable | Vivo, alias de mapping con `resource_subtypes` |
| `resource_type_capabilities` | Vivo (lo usa `resource_can`) | Continúa como "defaults legacy" — `effective_resource_capabilities` lo absorbe |
| `resource_detail` RPC | Vivo, sin cambios | Reemplazado por `resource_detail_descriptor` cuando F.1 ship; deprecation post-F.4 |
| `resource_available_actions` | Vivo, sin cambios | Reusado internamente por `list_resource_actions` y `resource_detail_descriptor.actions` |
| `context_summary` RPC | Vivo, sin cambios | Reemplazado por `context_detail_descriptor` cuando F.3 ship |
| `available_actions[]` shape | Inmutable (campos nuevos opcionales: `mode`, `decision_template_key`, `form_schema_present`, `dangerous`, `confirmation_required`) | Igual |
| iOS `ResourceDetailView` v1 | Vive en paralelo durante F.1 | Borrado al hacer cutover |

**Regla irrenunciable:** ninguna slice puede dejar build rojo en iOS ni romper los RPCs vivos.

### 7.1 Explícitamente fuera de R.5A (discusión Ruul 3.0)

- `actor_resource_links` (tabla puente actor↔resource más allá de `resource_rights`).
- `entity` / `entities` (fusión actors+resources).
- Renombrar `resource_type` o eliminarlo.
- Cambiar el comportamiento de `resource_can` para que lea de `effective_resource_capabilities`.

Cualquiera de estos se retoma como R3.x post founder sign-off independiente. Si una slice de R.5A empieza a coquetear con alguno, **se detiene y se eleva**.

---

## 8. Riesgos y gates

| Riesgo | Mitigación | Gate |
|---|---|---|
| Slicing B.5b explota (80 form_schemas) | Partir en B.5b.1 (acciones vivas) y B.5b.2 (acciones nuevas) si supera 600 líneas SQL | Pre-B.5b |
| `execute_resource_action` regresa shape inconsistente entre RPCs delegados | `result` es jsonb opaco; el dispatcher solo envuelve. iOS decodifica por `action_key` | Pre-B.8 |
| Governance gate de `transfer_ownership` rompe casos existentes | B.8 inicia con `metadata.execution_mode='execute'` para TODAS las acciones vivas; `request_decision` se activa acción por acción con founder sign-off | Pre-B.8 |
| iOS v2 se cae con resources sin class/subtype (datos viejos) | B.1 hace backfill 100% en una sola transacción; CHECK constraint NOT NULL en B.6 una vez verificado | Pre-B.6 |
| `effective_capabilities` cambia comportamiento de `resource_can` | B.2 NO toca `resource_can` — lo deja en `resource_type_capabilities`. Nuevo RPC paralelo. F.1 hace switch | Pre-F.1 |
| Drift name-based de migrations | Aplicar SIEMPRE vía MCP `apply_migration` + escribir a disco inmediato. Founder doctrine `feedback_migration_drift_doctrine` aplica | Cada slice |
| GRANT EXECUTE olvidado | Auditar al cierre de cada slice via query estándar | Cada slice |

---

## 9. Rollback strategy

Cada slice debe ser rollback-safe vía migration descendiente. Política:

- **B.0–B.4:** rollback = `DROP TABLE … CASCADE` + restore vía mig posterior. Sin pérdida de datos (catálogos seedeables).
- **B.1 (ALTER resources):** las cols nuevas son nullable hasta B.6. Rollback = `ALTER TABLE resources DROP COLUMN`. Los datos en `resource_type` están intactos.
- **B.5a–B.5b:** rollback = DELETE rows del catalog/forms. RPCs vivos no dependen de las nuevas filas.
- **B.6–B.8:** rollback = `DROP FUNCTION`. iOS sigue en v1 (con `resource_detail`/`context_summary`).
- **F.0–F.4:** rollback = revert commit + reinstalar. v1 sigue compilable.

**No rollback automático para data drift** (overrides creados por usuarios). Si B.2 se revierte, los overrides quedan en su tabla — recreables al re-aplicar B.2.

---

## 10. Doctrinas y plans alineados

- `Plans/Doctrine/F2X_IntentFirst_ContextualActions.md` — `available_actions[]` permanece canónico.
- `Plans/Doctrine/FNAV_AppShellNavigation.md` — `ContextDetailView` vive dentro de tab Contextos; F.NAV intacto.
- `Plans/Active/doctrine_actor_context.md` — Actor/Context separation respetada.
- `Plans/Active/MVP2_iOS_Contract.md` — actualizar al cerrar B.6/B.7/B.8 con las firmas nuevas.
- Memoria `doctrine_ruul_foundation_actor_context_resource.md` — lock conceptual fuente.

---

## 11. Status

| Slice | Estado | Commit | Fecha |
|---|---|---|---|
| R.5A.PLAN | ✅ doc escrito | — | 2026-06-05 |
| B.0 | ✅ aplicado + smoke verde | `20260605203939` + `20260605204123` | 2026-06-05 |
| B.1 | ✅ aplicado + smoke verde (15 rows backfilled 100%) | `20260605204611` + `20260605204738` | 2026-06-05 |
| B.2 | ✅ aplicado + smoke verde (42 caps + 279 defaults + 2 RPCs) | `20260605205441` + fix `20260605205800` + smoke `20260605205902` | 2026-06-05 |
| B.3 | ✅ aplicado + smoke verde (15 types + table + 3 RPCs) | `20260605211051` + smoke `20260605211237` | 2026-06-05 |
| B.4R | ✅ aplicado + smoke verde (47 sections + 428 mappings + 17 widgets + 137 mappings) | `20260605211838` + smoke `20260605212156` | 2026-06-05 |
| B.4C | ✅ aplicado + smoke verde (10 sections + 64 mappings + 12 widgets + 29 mappings + 8 subtypes) | `20260605212522` + smoke `20260605212747` | 2026-06-05 |
| B.5a | ✅ aplicado + smoke verde (catálogo 20→90 + execution_mode + dangerous + 2 request_decision) | `20260605213141` + smoke `20260605213322` | 2026-06-05 |
| B.5b | ✅ aplicado + smoke verde (90/90 forms con form_schema dialect simple, single slice) | `20260605213754` + smoke `20260605214014` | 2026-06-05 |
| B.6 | ✅ aplicado + smoke verde (17 keys top-level + sections filtradas dinámicas + subtype switch) | `20260605214459` + smoke `20260605214628` + fix `20260605214727` | 2026-06-05 |
| B.7 | ✅ aplicado + smoke verde (16 keys + project vs family canon + my_permissions + previews) | `20260605215315` + smoke `20260605215440` | 2026-06-05 |
| B.8 | ✅ aplicado + smoke verde (dispatcher con 11 RPCs vivos cableados + 2 request_decision + activity emit) | `20260605215950` + smoke `20260605220120` + fix `20260605220225` | 2026-06-05 |
| **B.H** (post review) | ✅ founder review hardening (items 4/5/6 — 1/2/3/7 already in spec) + B.5b smoke updated | `20260605221742` + smoke fix `20260605221841` | 2026-06-05 |
| F.0 | ✅ Domain models (ResourceDetailDescriptor + ContextDetailDescriptor + 4 RPCs wire) + build verde 28s | iOS only (no migrations) | 2026-06-05 |
| F.1 | ✅ ResourceDescriptorStore + ResourceDetailViewV2 (read-only descriptor render) + beta toggle en v1 Menu | iOS only — build verde 18s | 2026-06-05 |
| F.2 | ✅ ResourceActionFormSchema + ResourceActionFormView runtime (11 field types + confirmation + execute_resource_action wire) | iOS only — build verde 21s | 2026-06-05 |
| F.1 | ⬜ pendiente | — | — |
| F.2 | ⬜ pendiente | — | — |
| F.3 | ⬜ pendiente | — | — |
| F.4 | ⬜ pendiente | — | — |
