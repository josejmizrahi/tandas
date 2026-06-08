# R.5X — Audit Matrix

**Fecha:** 2026-06-07
**Status:** 🟡 BATCH 1 + 2 CERRADOS — Audits 4/7/11/12 con data real. Batch 3 (founder flows) en curso. Esta matriz es la fuente única para R.6.

**Companion doc:** `Plans/Active/R5X_ProductCompletenessAudit.md` (metodología, decisiones, backlog).

---

## Legenda

| Status | |
|---|---|
| 🟢 COMPLETE | End-to-end funciona, incluyendo loading/empty/error |
| 🟡 PARTIAL | Camino dorado OK, edge case visible falla |
| ⚠️ INERT | UI existe, no carga/no navega/no ejecuta |
| ⬛ MISSING | Backend existe, UI no |
| 🔴 ORPHANED | UI existe, backend no |
| 💥 BROKEN | Regresión |
| ⚪ NO_EFFECT | Catálogo existe pero no afecta render |
| ❓ UNKNOWN | Batch correspondiente aún no corrió |

| Prio | |
|---|---|
| **P0** | Roto end-to-end; demo-blocker |
| **P1** | Incompleto pero no roto |
| **P2** | UX |
| **P3** | Optimización / cleanup |
| **—** | Sin assign (auditoría aún no priorizó) |

---

## Discrepancias spec ↔ backend real (Batch 1)

| Item | Spec prompt | Real | Acción |
|---|---|---|---|
| Resource actions | "~90" / "90" | **88** | Ajustar comms |
| Resource sections | "47" | **48** | Ajustar comms |
| Context sections | "10" | **11** | Ajustar comms; agent vio 10 porque `conflicts` no es tab |
| Resource widgets | "17" | **18** | Ajustar comms |
| Context widgets | "12" | **13** | Ajustar comms |
| `vehicle` subtype | esperado | **NO EXISTE** | Backend usa `car`; founder canon real |
| Action dispatch wired | "16 mappings" | **16 / 88** | 72 actions raise `0A000 not_implemented` si se ejecutan |
| Catalog cols `requires_*` | varias | sólo `required_capability` + `required_rights[]` | El gating no tiene `requires_subtype`/`class`/`permission` a nivel catalog; vive en matrices subtype×* |
| Capabilities seedeadas pero nunca default_enabled | n/a | **6**: `approval_required`, `depreciable`, `monetary`, `rentable`, `sellable`, `usable` | NO_EFFECT |

---

## Master Matrix (sintetizada Batch 1)

| # | Domain | Feature | Backend | Descriptor | UI | Navigation | Actions | Permissions | Status | Prio | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | Resource | Detail V2 hero + state | ✅ | ✅ (`resource`, `class`, `subtype`, `state`, `metrics`, `effective_capabilities`) | ✅ | ✅ | n/a | n/a | 🟢 | — | 100% data-driven |
| 02 | Resource | conflictsCard + 3-kind | ✅ R.5B | ✅ `conflicts` | ✅ | ✅ inline alert | ✅ resolve 3 kinds | n/a | 🟢 | — | R.5B.5b shipped |
| 03 | Resource | Widget cards (18) | ✅ catalog | ✅ `widgets[]` | ✅ render todos | 🟡 10/18 destino, 7 INERT, 1 (conflicts_summary) absorbido por conflictsCard | n/a | n/a | 🟡 PARTIAL | **P1** | Inerts: `condition_status`, `custody_status`, `document_status`, `insurance_status`, `maintenance_status`, `tax_status`, `resource_value` |
| 04 | Resource | Section rows (48) | ✅ catalog | ✅ `sections[]` | ✅ render todos | 🟡 4 tappables (`reservations`, `availability`, `activity`, `settings`), resto row plana | n/a | n/a | 🟡 PARTIAL | **P1** | 44/48 sections sin destino dedicado (overview/details ok como fallback) |
| 05 | Resource | handleActionTap dispatch | ✅ B.8 16/88 wired | ✅ `actions[]` con form_schema_present | ✅ runtime form + 4 sheets nativos | 🟢 | 16 RPC vivas + 72 `not_implemented` | ✅ enabled flag honrado | 🟡 PARTIAL | **P0** | 72 actions caen al runtime form → backend raise → user ve error genérico |
| 06 | Resource | revoke_right native sheet | ✅ RPC vivo | ✅ action | ⚠️ NO interceptado (cae a runtime form) | n/a | runtime form OK | ok | 🟡 PARTIAL | **P2** | grant_right SÍ tiene sheet propio; revoke_right no |
| 07 | Resource | ResourceActionFormView runtime | ✅ B.5b 88 forms | ✅ `actionForms[key]` | ✅ 11 tipos field + pickers nativos | ✅ confirmación diferenciada (dangerous/decision/default) | ok | ok | 🟢 | — | |
| 08 | Resource | linked_events/obligations/decisions cards | ✅ B.6.1 | ✅ 3 keys | ✅ | ✅ push legacy detail | n/a | n/a | 🟢 | — | |
| 09 | Resource | Relations card | ✅ B.3 | ✅ `relations.outbound/inbound` | ✅ | 🟡 sin push a `ResourceDetailViewV2` desde row (cae a legacy?) | n/a | n/a | 🟡 PARTIAL | **P3** | Confirmar destino exacto en Batch 2 |
| 10 | Resource | Activity preview | ✅ | ✅ `activityPreview` | ✅ | ✅ "Ver todo" → ActivityFeedView | n/a | n/a | 🟢 | — | |
| 11 | Resource | Empty/loading/error | n/a | n/a | ✅ StateViews helpers | n/a | n/a | n/a | 🟢 | — | |
| 12 | Context | Detail V2 tabs (5) | n/a | ✅ `sections[].visible` filtra tabs | ✅ dinámico | ✅ | n/a | n/a | 🟢 | — | |
| 13 | Context | Overview attentionCard | ✅ R.5A V2 P1.2 | ✅ contextual filter | ✅ | 🟡 categorías `settlement`, `rule_*` sin dispatch | 5 categorías wired | n/a | 🟡 PARTIAL | **P1** | invitation/decision_vote/obligation_pay/obligation_complete OK; reservation_conflict → lista, no detail |
| 14 | Context | Overview conflictsCard + list | ✅ R.5B | ✅ `conflicts` | ✅ R.5B.5c | ✅ ContextConflictsListView + 3-kind dialog | ✅ | n/a | 🟢 | — | |
| 15 | Context | Overview metricsCard | ✅ B.7 metrics | ✅ `metrics` | ✅ memberCount + pendingDecisions + openObligations + resourceCountByClass | n/a | n/a | n/a | 🟢 | — | |
| 16 | Context | Overview widgetsRow (13) | ✅ catalog | ✅ `widgets[]` | ✅ todos render | 🟡 10/13 destino, 3 inerts (`active_projects`, `pending_invitations`, `conflicts_summary` absorbido) | n/a | n/a | 🟡 PARTIAL | **P1** | `active_projects`: NO_EFFECT; `pending_invitations` se ve en More via card propia, no como widget |
| 17 | Context | Overview childContexts carousel | ✅ B.7.1 | ✅ `childContextsPreview` | ✅ | 🟡 cards outsider `.opacity(0.5)` sin error/CTA (DEAD-END HIGH) | n/a | n/a | 🟡 PARTIAL | **P1** | User no sabe que puede pedir acceso |
| 18 | Context | Overview activity card | ✅ | ✅ `activityPreview` | ✅ | ✅ "Ver todo" | n/a | n/a | 🟢 | — | |
| 19 | Context | People tab | ✅ | ✅ `membersPreview` + `roles` | ✅ avatar + role rows | 🟡 role rows en V2 NO push (V1 sí) | sin crear inline (via quick action OK) | n/a | 🟡 PARTIAL | **P2** | Confirmar role row push en Batch 2 |
| 20 | Context | Resources tab | ✅ | ✅ `resourcesPreview` agrupado por class | ✅ | ✅ push ResourceDetailViewV2 | sin crear inline (via quick action) | n/a | 🟢 | — | |
| 21 | Context | Money tab | ✅ B.7.1 | ✅ `moneyPreview.myBalanceByCurrency` + `openSettlements` + `obligationsPreview` | ✅ | ✅ SettlementView + ObligationDetailView | sin crear inline (via quick action) | n/a | 🟢 | — | |
| 22 | Context | More tab — documents section | ✅ catalog | ✅ `documents_preview` | ⚠️ row tappable → ActivityFeedView fallback | ❌ NO existe DocumentsListView | n/a | n/a | ⚠️ INERT | **P1** | UX deshonesto: row promete documentos, abre actividad |
| 23 | Context | More tab — governance/calendar/activity/settings | ✅ | ✅ sections | ✅ | ✅ DecisionsListView / EventsListView / ActivityFeedView / ContextSettingsView | n/a | n/a | 🟢 | — | |
| 24 | Context | More tab — pendingInvitations card | ✅ B.7.1 | ✅ `pendingInvitationsPreview` | ✅ info card | ⚠️ sin tap (info-only) | n/a | n/a | 🟡 PARTIAL | **P2** | Sin manage/revoke inline (sólo desde PendingInvitationsView) |
| 25 | Context | More tab — permissions chips | ✅ B.7 | ✅ `permissions` | ✅ scrollable badges | n/a | n/a | n/a | 🟢 | — | |
| 26 | Context | Quick actions toolbar (V2) | ✅ `context_available_actions` | ✅ `actions[]` | ✅ Menu | 🟡 7 wired (`create_resource`, `create_event`, `create_decision`, `record_expense`, `invite_member`, `create_rule`, `create_child_context`); resto `default: break` no-op | 7 dispatched | ok | 🟡 PARTIAL | **P1** | Si backend devuelve action no listada → silencio sin handler |
| 27 | Home | attention_inbox cross-context | ✅ F.NAV.10 | n/a | ✅ | 🟡 5 categorías OK; `settlement`, `rule_*`, `conflict` directo NO dispatched | 5 / 7+ wired | n/a | 🟡 PARTIAL | **P1** | Settlement abierto a paciente HOY no aparece como atención |
| 28 | Home | jumpToContext (`reservation_conflict`) | ✅ | n/a | ✅ | 🟡 push al home contexto, no a conflict detail | n/a | n/a | 🟡 PARTIAL | **P2** | UX: usuario debe re-buscar el conflict desde overview |
| 29 | Navigation | Tab Shell (5 tabs F.NAV) | n/a | n/a | ✅ Home/Contextos/Crear/Actividad/Yo | ✅ | n/a | n/a | 🟢 | — | |
| 30 | Navigation | CreateIntentSheet (7 intents) | n/a | n/a | ✅ | ✅ 7 destinos sheet | n/a | n/a | 🟢 | — | |
| 31 | Navigation | Document detail / QuickLook | ⬛ NO existe | n/a | ❌ NO existe | ❌ | n/a | n/a | ⬛ MISSING | **P1** | Necesario para audit 9 founder flow casa+documento |
| 32 | Navigation | Conflict individual detail | ⬛ NO existe | n/a | ❌ NO existe (inline dialog only) | ❌ | resolve OK desde dialog | n/a | ⚠️ INERT | **P2** | Dialog hace el trabajo, pero "Ver detalle" no existe |
| 33 | Navigation | Reservation conflict push directo | ⬛ legacy `ReservationConflictView` existe | n/a | ✅ archivo presente | ⚠️ no llega desde attention | n/a | n/a | ⚠️ INERT | **P1** | View existe pero ningún row puente la abre desde attention |
| 34 | Navigation | StateViews helpers | n/a | n/a | ✅ Loading/Error/Empty/ActionRunner | n/a | n/a | n/a | 🟢 | — | |
| 35 | Auth | SignedOut + person actor gate | ✅ | n/a | ✅ SignedOutView + SessionLoadingView | ✅ 3 gates | n/a | n/a | 🟢 | — | |

**Cobertura sintetizada Batch 1:** 35 filas. Batch 2 agregará ~40 (descriptor fields, capabilities, permissions, states).

---

## Audit 1 · Context Detail (5 tabs)

### Inventario `context_section_catalog` (11 sections — corregido vs spec)

| section_key | Tab que la usa | UI render | Datos | CRUD | Loading | Empty | Error | Status | Prio | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| overview | Overview | ✅ | ✅ | ➖ read-only | ✅ store.phase | ⬜ all-cards-fallback (no VStack vacío) | ✅ ErrorStateView | 🟢 | — | |
| people | People | ✅ | ✅ | ➖ create via quick action | ✅ | ✅ EmptyCard | ➖ heredado | 🟢 | — | |
| resources | Resources | ✅ | ✅ agrupado por class | ➖ create via quick action | ✅ | ✅ EmptyCard | ➖ heredado | 🟢 | — | |
| calendar | More → EventsListView | ✅ row | ✅ | ➖ create via quick action | ✅ | ✅ en EventsListView | ✅ | 🟢 | — | |
| governance | More → DecisionsListView | ✅ row | ✅ | ➖ create via quick action | ✅ | ✅ | ✅ | 🟢 | — | |
| obligations | Money | ✅ | ✅ | ➖ via quick action | ✅ | ✅ EmptyCard | ➖ heredado | 🟢 | — | |
| activity | More → ActivityFeedView | ✅ | ✅ | n/a | ✅ | ✅ | ✅ | 🟢 | — | |
| documents | More → ActivityFeedView (FALLBACK) | 🟡 row | ❌ no carga documents reales — abre activity | ⬛ no upload inline (via CreateIntentSheet) | ✅ | ❌ deshonesto | ❌ | ⚠️ INERT | **P1** | DocumentsListView NO existe |
| money | Money | ✅ | ✅ B.7.1 my_balance + settlements | ➖ via quick action | ✅ | 🟡 sólo en obligaciones | ➖ heredado | 🟢 | — | |
| conflicts | Overview conflictsCard + ContextConflictsListView | ✅ R.5B.5c | ✅ | ✅ resolve 3-kind | ✅ | ✅ implícito (card no aparece) | ✅ alert | 🟢 | — | |
| settings | More → ContextSettingsView | ✅ row | ✅ | ✅ | ✅ | n/a | ✅ | 🟢 | — | |

**Sumario:** 10 🟢 · 1 ⚠️ (`documents`).

---

## Audit 2 · Resource Detail (subtypes founder)

ResourceDetailV2 es 100% data-driven. La cobertura por subtype depende del backend (sections/widgets/capabilities seedeadas) + iOS widgets-with-destination (10/18) + actions-with-RPC (16/88).

| subtype | UI ve (catalog) | UI puede ejecutar end-to-end | Widgets inert hoy | Actions sin RPC backend | Status | Prio |
|---|---|---|---|---|---|---|
| primary_residence | 13 sections + 7 widgets + 8 caps | grant/revoke right, attach doc, edit, archive, restore, view_*, record_expense, ↓ rest = error | `document_status`, `insurance_status`, `maintenance_status`, `tax_status`, `resource_value` (5/7) | record_property_expense, record_insurance, record_maintenance, record_tax_payment, update_valuation, log_maintenance, link_document, … | 🟡 PARTIAL | **P0** |
| vacation_home | 16 sections + 7 widgets + 11 caps | grant/revoke, attach doc, edit, reserve_resource, cancel_reservation, approve_reservation, ↓ rest = error | `insurance_status`, `maintenance_status`, `resource_value` (3/7, lease/income wired via money) | block_time, unblock_time, manage_reservations, record_lease_income, … | 🟡 PARTIAL | **P0** |
| warehouse | 17 sections + 7 widgets + 10 caps | grant/revoke, attach doc, edit, ↓ rest = error | `insurance_status`, `maintenance_status`, `resource_value` (3/7) | create_lease, terminate_lease, record_lease_income, transfer_custody, return_resource, … | 🟡 PARTIAL | **P0** |
| money_pool | 16 sections + 6 widgets + 7 caps | grant/revoke, attach doc, edit, record_expense (vía dispatch), ↓ rest = error | sólo widgets covered → 🟢 (todos wired a money/activity/settlement) | record_contribution, generate_settlement, finalize_settlement_batch, convert_to_settlement, dispute_obligation, … | 🟡 PARTIAL | **P0** |
| ~~vehicle~~ → `car` | — | — | — | — | ❓ | re-auditar |
| contract | 10 sections + 3 widgets + 6 caps | grant/revoke, attach doc, edit, ↓ rest = error | `document_status` (1/3) | approve_document, sign_document, request_approval, review_document, upload_new_version, … | 🟡 PARTIAL | **P0** |
| iou | 9 sections + 3 widgets + 5 caps | grant/revoke, attach doc, edit, record_expense vía dispatch, ↓ rest = error | sólo widgets covered → 🟢 | dispute_obligation, accept_obligation, record_payment, complete_obligation, … | 🟡 PARTIAL | **P0** |
| group_trip | 12 sections + 4 widgets + 7 caps | grant/revoke, attach doc, edit, reserve, ↓ rest = error | sólo widgets covered → 🟢 | record_event_expense, cancel_event, invite_participant, change_host, … | 🟡 PARTIAL | **P0** |
| internal_project | 12 sections + 4 widgets + 5 caps | grant/revoke, attach doc, edit, ↓ rest = error | sólo widgets covered → 🟢 | close_event, reopen_event, … | 🟡 PARTIAL | **P0** |

**Sumario:** 8/8 founder canon en PARTIAL. La razón compartida es **Audit 3** (72 actions sin RPC vivo). Sin resolverlo, ningún subtype puede salir a 🟢.

---

## Audit 3 · Action Coverage (resource_action_catalog · 88)

**Cobertura backend:** 16 RPC vivos · 72 sin dispatch (raise `0A000 not_implemented` si se ejecutan).

| status | conteo | criterio |
|---|---|---|
| 🟢 COMPLETE (visible + form + RPC + result + activity) | **16** | `accept_obligation`*, `archive_resource`, `attach_document`, `cancel_reservation`, `check_in_participant`, `close_event`, `create_reservation`, `edit_resource`, `grant_right`, `record_expense`, `request_transfer`, `reserve_resource`, `revoke_right`, `rsvp_event`, `transfer_ownership`, `update_resource`, `approve_reservation` (=17 si contamos approve_reservation, agent dijo 16) |
| 🟡 PARTIAL (visible + form + sin RPC) | **72** | Catalog dump completo en backend agent's output |
| ⬛ MISSING | 0 | n/a |
| 🔴 ORPHANED | 0 | n/a |

**Hallazgo P0:** la promesa intent-first (cualquier action visible es ejecutable) se rompe a partir del 16% real. iOS debe **(a)** ocultar acciones sin dispatch, **(b)** marcar UI con "no implementado", o **(c)** backend B.8 debe ampliar dispatch. Decisión founder pendiente.

**Tabla detallada (88 filas):** ver dump backend en `R5X_ProductCompletenessAudit.md` § Apéndice A o queryear `resource_action_catalog` + `resource_action_dispatch` directo.

---

## Audit 4 · Capability Coverage (42)

**Batch 2 cierre:** Las 42 caps son consumidas por `descriptor.effective_capabilities` (B.2 RPC) y se renderizan como chips en heroCard Resource V2 (`ResourceDetailViewV2:213-249`). El gate de visibilidad de sections/widgets/actions vive en el descriptor B.6 (filtrado por capability). iOS no tiene switch hardcoded por capability — todo el comportamiento es backend-driven.

| capability_key | descriptor inyecta | UI cambia | acciones asociadas (gate) | comportamiento real | Status |
|---|---|---|---|---|---|
| `access_controlled` | ✅ via B.6 | section `access` filtrado | `block_time`, `unblock_time` (parcial) | 🟡 hay caps + section, sin destino dedicado | 🟡 PARTIAL |
| `approvable` | ✅ | section `approvals` filtrado | `approve_document`, `request_approval`, `review_document` | 🟡 section row inert | 🟡 PARTIAL |
| `approval_required` | n/a | n/a | typo — `approve_document` lo usa pero `approvable` es el real | ⚪ NO_EFFECT (no subtype enable) | ⚪ NO_EFFECT cleanup |
| `assignable` | ✅ | section `custody` filtrado | `transfer_custody`, `return_resource` | 🟡 section inert | 🟡 PARTIAL |
| `auditable` | ✅ (42 subtypes default) | section `activity` ubicua | `view_activity`, `view_audit`, `export_statement`, `void_transaction` | 🟢 activity siempre presente | 🟢 |
| `beneficiary_supported` | ✅ (2 subtypes) | section `beneficiaries` (no en catalog!) | `grant_beneficiary`, `view_beneficiaries` | ⚪ NO_EFFECT — section no existe en catalog | ⚪ NO_EFFECT cleanup |
| `chargeable` | ✅ | section `movements` filtrado | `record_charge` | 🟡 section inert | 🟡 PARTIAL |
| `closeable` | ✅ | section `settings` (todos) | `close_event`, `reopen_event` | 🟢 close OK via dispatch | 🟢 |
| `condition_trackable` | ✅ | section `condition` filtrado | `record_damage`, `update_condition`, `report_issue` | ⚠️ section inert founder-priority | ⚠️ INERT P1 |
| `custodiable` | ✅ | section `custody` filtrado | `transfer_custody`, `return_resource` | ⚠️ section inert founder-priority | ⚠️ INERT P1 |
| `depreciable` | n/a | n/a | ninguna action | ⚪ NO_EFFECT | ⚪ NO_EFFECT cleanup |
| `disputable` | ✅ | section `disputes` filtrado | `dispute_obligation` | ⚠️ section inert | ⚠️ INERT P2 |
| `documentable` | ✅ (31 subtypes default) | section `documents` filtrado | 11 actions documents subset | ⚠️ **section inert (founder ⬛)**; widget `document_status` también inert | ⚠️ INERT P1 |
| `expirable` | ✅ | section `obligations` indirecto | `extend_due_date` | 🟡 sin UI dedicada | 🟡 PARTIAL |
| `governable` | ✅ | section `decisions` filtrado | `request_transfer`, `transfer_ownership` (request_decision mode) | 🟢 via Decisions | 🟢 |
| `income_generating` | ✅ | section `income` filtrado | `record_lease_income` | ⚠️ section inert founder-priority | ⚠️ INERT P1 |
| `insurable` | ✅ (12 subtypes default) | section `insurance` + widget `insurance_status` | `record_insurance` | ⚠️ **section inert + widget inert founder-priority** | ⚠️ INERT P1 |
| `inventory_tracked` | ✅ (1 subtype) | section `inventory_movements` + `stock` | `adjust_stock`, `consume_item`, `record_purchase`, `transfer_stock` | ⚠️ section inert | ⚠️ INERT P2 |
| `leasable` | ✅ (5 subtypes) | section `leases` + widget `lease_status` (wired→money) | `create_lease`, `terminate_lease` | ⚠️ section inert; widget OK | 🟡 PARTIAL P1 |
| `location_bound` | ✅ (9 subtypes) | section `location` filtrado | n/a (display only) | ⚠️ section inert | ⚠️ INERT P2 |
| `maintainable` | ✅ (12 subtypes default) | section `maintenance` + widget `maintenance_status` | `log_maintenance`, `record_maintenance`, `view_maintenance` | ⚠️ **section + widget inert founder-priority** | ⚠️ INERT P1 |
| `monetary` | ❌ NO subtype default (gap?) | section `money` general | `record_expense`, `record_contribution`, `view_transactions`, `generate_settlement` | ⚠️ Money flow funciona vía money_pool sin la cap → audit semántico backend | ⚪ NO_EFFECT ⚠️ |
| `notifiable` | ✅ (3 subtypes) | n/a | n/a | ⚪ no surface UI hoy | ⚪ NO_EFFECT P3 |
| `ownable` | ✅ (14 subtypes) | section `rights` | `grant_right`, `revoke_right` | 🟢 via heroCard + rights row | 🟢 |
| `ownership_trackable` | ✅ | section `ownership` (no en catalog?) | `view_ownership`, `transfer_ownership` | 🟡 section sin destino | 🟡 PARTIAL |
| `payable` | ✅ (23 subtypes default) | sections `payments`/`obligations`/`expenses`/`ious`/`fines` | `accept_obligation`, `record_payment`, `record_payout`, `complete_obligation`, `forgive_obligation`, `record_property_expense`, etc | ⚠️ sections inert founder-priority | ⚠️ INERT P1 |
| `quantity_tracked` | ✅ (1 subtype) | section `stock` | n/a | ⚠️ section inert | ⚠️ INERT P3 |
| `recurring` | ✅ (3 subtypes) | section `recurrence` + section `host` | `change_host`, `preview_next_host`, `set_next_host` | ⚠️ section inert (HostRotationOrderSheet existe pero no conectada) | ⚠️ INERT P2 |
| `rentable` | n/a | n/a | ninguna | ⚪ alias antiguo de `leasable` | ⚪ NO_EFFECT cleanup |
| `reservable` | ✅ (12 subtypes default) | sections `reservations`+`availability`+`calendar` + widgets `reservation_status`/`upcoming_reservations` | 8+ actions reservations | 🟢 fully wired | 🟢 |
| `rule_bound` | ✅ (1 subtype) | section `rules` | n/a | ⚠️ inert hasta R.6 | ⚠️ INERT R.6 |
| `schedulable` | ✅ (8 subtypes) | section `attendees` + `calendar` | `cancel_event`, `check_in_participant`, `invite_participant`, `mark_no_show`, `rsvp_event` | 🟢 wired | 🟢 |
| `sellable` | n/a | n/a | ninguna | ⚪ NO_EFFECT cleanup |
| `settleable` | ✅ (10 subtypes default) | section `settlements` + widget `settlement_status` | `convert_to_settlement`, `finalize_settlement_batch` | 🟢 SettlementView wired | 🟢 |
| `shareable` | ✅ (7 subtypes) | section `rights` | `grant_right`, `revoke_right` | 🟢 | 🟢 |
| `signable` | ✅ (2 subtypes) | section `signatures` | `sign_document` | ⚠️ section inert | ⚠️ INERT P2 |
| `splittable` | ✅ (4 subtypes) | section `member_balances` | record_expense.split_method param | 🟢 via runtime form | 🟢 |
| `taxable` | ✅ (8 subtypes) | section `taxes` | `record_tax_payment` | ⚠️ **section inert founder-priority** | ⚠️ INERT P1 |
| `transferable` | ✅ (10 subtypes default) | sections `ownership`/`settings` | `request_transfer`, `transfer_ownership`, `transfer_interest`, `transfer_resource`, `approve_transfer` | 🟢 via request_decision pattern | 🟢 |
| `usable` | n/a | n/a | ninguna | ⚪ NO_EFFECT cleanup (right USE cubre) |
| `versionable` | ✅ (4 subtypes) | section `versions` | `upload_new_version` | ⚠️ section inert | ⚠️ INERT P2 |
| `votable` | ✅ (1 subtype) | section `decisions` | vote_decision (no en catalog actions, propia de decision) | 🟢 DecisionDetailView | 🟢 |

**Sumario capabilities:** 12 🟢 · 4 🟡 PARTIAL · 18 ⚠️ INERT (sections behind cap inert) · 8 ⚪ NO_EFFECT (cleanup). **Hallazgo: la capability es la que activa el render del section/widget, no la causa raíz. La causa raíz es Audit 5 — los sections inert.**

---

## Audit 5 · Section Coverage

### Resource (48)

| section_key | subtypes founder usando | UI render | Tap destino | Status | Prio | Notes |
|---|---|---|---|---|---|---|
| `overview` | 42 (all) | ✅ via hero | n/a | 🟢 | — | |
| `details` | 37 | ✅ via hero | n/a | 🟢 | — | |
| `activity` | 42 | ✅ via activityCard + section row | ✅ ActivityFeedView | 🟢 | — | |
| `settings` | 42 | ✅ section row | ✅ ResourceSettingsView | 🟢 | — | |
| `conflicts` | 42 | ✅ conflictsCard | ✅ inline | 🟢 | — | |
| `relations` | 42 | ✅ relationsCard | 🟡 sin push verificado | 🟡 | **P3** | |
| `reservations` | 12 | ✅ section row | ✅ ReservationsListView (scoped) | 🟢 | — | |
| `availability` | 2 | ✅ section row | ✅ ReservationsListView | 🟢 | — | |
| `documents` | 31 | ✅ section row (sin tap) | ⚠️ row plana, sin push | ⚠️ INERT | **P1** | Spec founder lo nombró atención prioritaria |
| `insurance` | 12 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P1** | Spec founder lo nombró |
| `maintenance` | 12 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P1** | Spec founder lo nombró |
| `taxes` | 8 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P1** | Spec founder lo nombró |
| `valuation` | 9 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P1** | Spec founder lo nombró |
| `leases` | 5 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P1** | Spec founder lo nombró |
| `condition` | 5 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P1** | Spec founder lo nombró |
| `inventory_movements` | 1 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | 1 subtype: stock-tracked |
| `custody` | 7 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P1** | Spec founder lo nombró |
| `income` | 5 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P1** | Spec founder lo nombró |
| `payments` | 9 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P1** | Spec founder lo nombró |
| `rights` | 20 | ✅ row | ⚠️ row plana (rights mostradas en hero ya) | 🟡 PARTIAL | **P2** | |
| `decisions` | 4 | ✅ row | 🟡 via linked_decisions card OK | 🟡 PARTIAL | **P2** | Duplicate render path |
| `expenses` | 5 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P1** | |
| `ious` | 1 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | 1 subtype |
| `member_balances` | 1 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | 1 subtype |
| `movements` | 5 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `contributions` | 1 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `balance` | 5 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `settlements` | 6 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `attendees` | 5 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `host` | 3 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `rsvp` | 3 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `approvals` | 2 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `signatures` | 2 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `versions` | 5 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `budget` | 2 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `itinerary` | 1 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `tasks` | 1 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `checklist` | 1 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `disputes` | 3 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `fines` | 1 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `usage_history` | 3 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `location` | 12 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `access` | 5 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | |
| `stock` | 1 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `recurrence` | 3 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `calendar` | 2 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P3** | |
| `rules` | 2 | ✅ row | ⚠️ row plana | ⚠️ INERT | **P2** | Bloquea R.6 si rules sin push |

**Sumario resource sections:** 7 🟢 · 4 🟡 · 37 ⚠️ INERT. **`P1` count: 11** secciones founder-priority sin destino.

### Context (11)

| section_key | UI render | Tap destino | Status |
|---|---|---|---|
| overview | ✅ | n/a | 🟢 |
| people | ✅ tab | MembersListView via NavigationLink (header) + row plana | 🟢 |
| resources | ✅ tab | ResourceDetailViewV2 | 🟢 |
| money | ✅ tab | SettlementView + ObligationDetailView | 🟢 |
| obligations | ✅ tab money | ObligationDetailView | 🟢 |
| calendar | ✅ More row | EventsListView | 🟢 |
| governance | ✅ More row | DecisionsListView | 🟢 |
| documents | ✅ More row | ⚠️ ActivityFeedView fallback | ⚠️ INERT |
| activity | ✅ More row | ActivityFeedView | 🟢 |
| conflicts | ✅ Overview card + list | inline + ContextConflictsListView | 🟢 |
| settings | ✅ More row | ContextSettingsView | 🟢 |

**Sumario context sections:** 10 🟢 · 1 ⚠️.

---

## Audit 6 · Widget Coverage

### Resource (18)

| widget_key | backend datos | UI render | Tap destino | Status | Prio |
|---|---|---|---|---|---|
| `balance_summary` | ✅ | ✅ | MoneyHomeView | 🟢 | — |
| `member_balance_summary` | ✅ | ✅ | MoneyHomeView | 🟢 | — |
| `income_summary` | ✅ | ✅ | MoneyHomeView | 🟢 | — |
| `lease_status` | ✅ | ✅ | MoneyHomeView | 🟢 | — |
| `open_obligations` | ✅ | ✅ | MoneyHomeView | 🟢 | — |
| `next_event` | ✅ | ✅ | EventsListView | 🟢 | — |
| `recent_activity` | ✅ | ✅ | ActivityFeedView | 🟢 | — |
| `reservation_status` | ✅ | ✅ | ReservationsListView | 🟢 | — |
| `upcoming_reservations` | ✅ | ✅ | ReservationsListView | 🟢 | — |
| `settlement_status` | ✅ | ✅ | SettlementView | 🟢 | — |
| `conflicts_summary` | ✅ | ⚠️ absorbido por conflictsCard (no se renderiza como widget) | inline alert | 🟡 PARTIAL | **P3** | duplicación intencional |
| `condition_status` | ✅ | ✅ | ⚠️ sin destino | ⚠️ INERT | **P1** |
| `custody_status` | ✅ | ✅ | ⚠️ sin destino | ⚠️ INERT | **P1** |
| `document_status` | ✅ | ✅ | ⚠️ sin destino | ⚠️ INERT | **P1** |
| `insurance_status` | ✅ | ✅ | ⚠️ sin destino | ⚠️ INERT | **P1** |
| `maintenance_status` | ✅ | ✅ | ⚠️ sin destino | ⚠️ INERT | **P1** |
| `tax_status` | ✅ | ✅ | ⚠️ sin destino | ⚠️ INERT | **P1** |
| `resource_value` | ✅ | ✅ | ⚠️ sin destino | ⚠️ INERT | **P2** |

**Sumario:** 10 🟢 · 1 🟡 · 7 ⚠️ INERT.

### Context (13)

| widget_key | backend datos | UI render | Tap destino | Status | Prio |
|---|---|---|---|---|---|
| `cash_balance` | ✅ | ✅ | MoneyHomeView | 🟢 | — |
| `budget_progress` | ✅ | ✅ | MoneyHomeView | 🟢 | — |
| `open_obligations` | ✅ | ✅ | MoneyHomeView | 🟢 | — |
| `critical_resources` | ✅ | ✅ | ResourcesListView | 🟢 | — |
| `member_count_summary` | ✅ | ✅ | MembersListView | 🟢 | — |
| `next_event` | ✅ | ✅ | EventsListView | 🟢 | — |
| `open_decisions` | ✅ | ✅ | DecisionsListView | 🟢 | — |
| `recent_activity` | ✅ | ✅ | ActivityFeedView | 🟢 | — |
| `settlement_status` | ✅ | ✅ | SettlementView | 🟢 | — |
| `upcoming_reservations` | ✅ | ✅ | ContextReservationsView | 🟢 | — |
| `active_projects` | ✅ | ✅ render genérico | ⚠️ sin destino | ⚠️ INERT | **P2** |
| `pending_invitations` | ✅ | 🟡 surface en More card propia (no como widget) | n/a | 🟡 PARTIAL | **P3** |
| `conflicts_summary` | ✅ | ⚠️ absorbido por conflictsCard | inline | 🟡 PARTIAL | **P3** |

**Sumario:** 10 🟢 · 2 🟡 · 1 ⚠️ INERT.

---

## Audit 7 · Descriptor Coverage (leaf-level, Batch 2)

### resource_detail_descriptor — dead/dormant leaf fields

| field path | decoded | rendered | status | notes |
|---|---|---|---|---|
| `linkedDocuments[]` | ✅ | ❌ | **⬛ DEAD** | Struct existe, 0 calls UI. Coincide con documents gap. **Slice docs lo cubre** (linkedDocumentsCard) |
| `state.archivedAt` | ✅ | ❌ | ⚠️ DORMANT | UX value: "Archivado el X" subtext |
| `state.lockedForGovernance` | ✅ | ❌ | ⚠️ DORMANT | UX value: badge "Bloqueado" |
| `state.openDecisionId` | ✅ | ❌ | ⚠️ DORMANT | UX value: link a decisión bloqueante |
| `metrics.balance` | ✅ | ❌ | ⚠️ DORMANT | UX value: hero subtext |
| `metrics.lastMovementAt` | ✅ | ❌ | ⚠️ DORMANT | UX value: "Última actividad hace X" |
| `relations.resourceId` | ✅ | ❌ | ⚪ NO_EFFECT | self-ref, cleanup |
| `rights[]` | ✅ | ❌ V2 (v1 only) | 🟡 LEGACY | Eliminar de V2 path o usar en heroCard rights chips |

### resource_detail_descriptor (18 top-level keys reales)

| key | en RPC output | en iOS Domain | consumido (UI) | Status |
|---|---|---|---|---|
| `resource` | ✅ | ✅ | ✅ hero | 🟢 |
| `class` | ✅ | ✅ | ✅ hero | 🟢 |
| `subtype` | ✅ | ✅ | ✅ hero | 🟢 |
| `effective_capabilities` | ✅ | ✅ | ✅ hero chips | 🟢 |
| `rights` | ✅ | ✅ | ✅ implícito | 🟢 |
| `state` | ✅ | ✅ | ✅ hero | 🟢 |
| `metrics` | ✅ | ✅ | ✅ hero | 🟢 |
| `sections` | ✅ | ✅ | ✅ sectionsCard | 🟢 |
| `widgets` | ✅ | ✅ | ✅ widgetsRow | 🟢 |
| `actions` | ✅ | ✅ | ✅ actionsCard | 🟢 |
| `action_forms` | ✅ | ✅ | ✅ runtime form | 🟢 |
| `relations` | ✅ | ✅ | ✅ relationsCard | 🟢 |
| `linked_events` | ✅ | ✅ | ✅ B.6.1 | 🟢 |
| `linked_obligations` | ✅ | ✅ | ✅ B.6.1 | 🟢 |
| `linked_decisions` | ✅ | ✅ | ✅ B.6.1 | 🟢 |
| `linked_documents` | ✅ | ❓ | ❓ Batch 2 — confirmar | ❓ |
| `activity_preview` | ✅ | ✅ | ✅ | 🟢 |
| `conflicts` | ✅ | ✅ | ✅ R.5B | 🟢 |

**Sumario preliminar:** 17 🟢 + 1 ❓ (`linked_documents`). Si confirmamos no usado → ⬛/⚪.

### context_detail_descriptor (19 top-level keys reales)

| key | en RPC | en iOS | consumido | Status |
|---|---|---|---|---|
| `context` | ✅ | ✅ JSONValue | ✅ | 🟢 |
| `membership` | ✅ | ✅ JSONValue | ✅ | 🟢 |
| `sections` | ✅ | ✅ | ✅ tabs | 🟢 |
| `widgets` | ✅ | ✅ | ✅ widgetsRow | 🟢 |
| `actions` | ✅ | ✅ | 🟡 7/N wired | 🟡 |
| `permissions` | ✅ | ✅ | ✅ chips More | 🟢 |
| `roles` | ✅ | ✅ | 🟡 row sin push V2 | 🟡 |
| `metrics` | ✅ | ✅ | ✅ metricsCard | 🟢 |
| `members_preview` | ✅ | ✅ | ✅ People tab | 🟢 |
| `resources_preview` | ✅ | ✅ | ✅ Resources tab | 🟢 |
| `events_preview` | ✅ | ❓ | ❓ Batch 2 (tab calendar usa preview?) | ❓ |
| `obligations_preview` | ✅ | ✅ | ✅ Money tab | 🟢 |
| `decisions_preview` | ✅ | ❓ | ❓ Batch 2 (tab governance usa?) | ❓ |
| `documents_preview` | ✅ | ❓ | ❌ no surface (More row → activity fallback) | ⬛ MISSING |
| `money_preview` | ✅ | ✅ B.7.1 | ✅ Money tab | 🟢 |
| `activity_preview` | ✅ | ✅ | ✅ Overview | 🟢 |
| `conflicts` | ✅ | ✅ | ✅ R.5B | 🟢 |
| `child_contexts_preview` | ✅ B.7.1 | ✅ | ✅ Overview carousel | 🟢 |
| `pending_invitations_preview` | ✅ B.7.1 | ✅ | ✅ More card | 🟢 |

**Sumario preliminar:** 14 🟢 + 2 🟡 + 1 ⬛ (`documents_preview` MISSING en surface) + 3 ❓.

---

## Audit 8 · Navigation Audit — dead-ends

| Source | Destination esperada | Estado actual | Status | Prio |
|---|---|---|---|---|
| `documents_preview` rows (cualquier surface) | DocumentDetailView / QuickLook | No existe; fallback ActivityFeedView | ⬛ MISSING | **P1** |
| `conflict` individual (catalog R.5B) — atención del usuario | ConflictDetailView | No existe; inline dialog cubre resolve pero no detail | ⚠️ INERT | **P2** |
| `child_contexts_preview` card outsider | Membership request / disclaimer | `.opacity(0.5)` sin error/CTA | 🟡 PARTIAL | **P1** |
| `attention.reservation_conflict` | ReservationConflictView (existe en /Features/Reservations/) | Salta a context home, no a conflict | ⚠️ INERT | **P1** |
| `attention.settlement` / `attention.rule_*` | Settlement/RuleDetail | No dispatched (cae a EmptyView) | ⬛ MISSING | **P1** |
| Resource widget tap (`document_status`/`insurance_status`/...) (7 widgets) | Section dedicado o sheet | `tappable: false` cascade | ⚠️ INERT | **P1** |
| Resource section row (44/48) | Section dedicada | Row plana sin chevron | ⚠️ INERT | **P1** |
| `roles[]` row Context People tab V2 | MembersListView filtered | NO push (V1 sí) | 🟡 PARTIAL | **P2** |
| Context widget `active_projects` | Lista proyectos del contexto | sin destino | ⚠️ INERT | **P2** |
| Resource `revoke_right` action | Sheet propio | Cae a runtime form | 🟡 PARTIAL | **P2** |
| Context quick action no-listed | dispatch handler | `default: break` | ⚠️ INERT | **P1** |

---

## Audit 9 · Founder Flows

_Pendiente Batch 3. Pre-cierre: cada flow ya inicia con clic-counter inferido del shell._

| Flow | Pasos | Clics inferidos | Pantallas vacías sospechadas | Errores sospechados | Acciones ocultas | Nav rota |
|---|---|---|---|---|---|---|
| Familia · crear + invitar + gasto + settlement | 4 | ~12 | None (todos los pasos están en V2 + dispatch) | record_expense OK · settlement OK · invite OK | n/a | n/a |
| Casa · crear + documento + reservar + resolver conflicto | 4 | ~14 | Document detail ❌, Resource detail SI | attach_document OK · request_resource_reservation OK · resolve_resource_conflict OK | none | Document tap (P1) |
| Viaje · crear + participantes + fondo + gastos + liquidar | 5 | ~18 | Money pool resource section ⚠️ inert rows | record_contribution `not_implemented` (no en B.8 dispatch) · generate_settlement OK · convert_to_settlement `not_implemented` | many | record_contribution rota |
| Empresa · crear + recurso + obligación + decisión | 4 | ~12 | Obligation flow visible · create_decision OK | All OK | none | n/a |

**Sumario preliminar:** Familia 🟢 · Empresa 🟢 · Casa 🟡 (documento) · Viaje 🔴 (`record_contribution`/`convert_to_settlement` sin RPC).

---

## Audit 10 · Attention System

| Categoría | HomeView (cross) | ContextDetailV2 | ContextHome v1 | Status |
|---|---|---|---|---|
| Invitations | ✅ PendingInvitationsView | ✅ | ✅ | 🟢 |
| Decisions (vote) | ✅ DecisionDetailView | ✅ | ✅ | 🟢 |
| Obligations (pay/complete) | ✅ ObligationDetailView | ✅ | ✅ | 🟢 |
| Reservation conflicts | 🟡 salta a contexto home | 🟡 abre lista (no detail) | 🟡 abre lista | 🟡 PARTIAL |
| Resource conflicts (R.5B direct) | ⬛ NO surface en attention | ✅ via conflictsCard local | ✅ via conflictsCard local | 🟡 PARTIAL |
| Settlements | ⬛ NO dispatched | ⬛ NO surface | ⬛ NO surface | ⬛ MISSING |
| Rules / Rule violations | ⬛ NO dispatched | ⬛ NO surface | ⬛ NO surface | ⬛ MISSING |

**Sumario:** 3 🟢 · 2 🟡 · 2 ⬛. **P1: Settlements + Rules deben aparecer en attention.**

---

## Audit 11 · State Coverage (Batch 2 cierre)

| Entidad | backend states | iOS visible | Match | Hallazgo P0/P1 |
|---|---|---|---|---|
| Context | active · inactive · archived | 0 badge UI (usa `is_context_archived` bool) | 🟡 | P2: badge en ContextsListView |
| Resource | active · inactive · archived | 2/3 (active green, archived orange); **`inactive` ORPHANED** | 🔴 | **P1**: render badge inactive en hero |
| Decision | open · approved · rejected · executed · cancelled | 5/5 ✅ via StatusBadge + Theme.Status.decision | 🟢 | — |
| Reservation | requested · approved · confirmed · rejected · cancelled · completed · waitlisted | 7/7 ✅ + swipeActions condicionales (isPending/isActive) | 🟢 | — |
| Obligation | open · accepted · in_progress · completed · expired · settled · cancelled · forgiven · disputed | 9/9 ✅ via StatusBadge | 🟢 | — |
| Conflict | open · acknowledged · resolved · dismissed | 2/4 visible + 2 historical (R.5B `includeResolved=false`, by design) | 🟢 | — |
| Document | ❌ NO status field | n/a | ❓ | **founder Q**: ¿lifecycle draft/shared/archived? |
| Event | scheduled · in_progress · completed · cancelled | 4/4 badge ✅ pero **EventDetailView SIN actions** (`close_event`/`edit_event` MISSING UI) | 🟡 | **P1**: añadir actions a EventDetailView |

**One-way transitions sin undo:**
| Entity | Forward | Reverse |
|---|---|---|
| Resource archived | `archive_resource` action | `restore_resource` (catalog OK, dispatch wired — verificar en UI) |
| Obligation completed | `mark_completed` | ❌ no `reopen_obligation` |
| Reservation cancelled | `cancel_reservation` | ❌ no reverse |
| Conflict resolved/dismissed | `resolve_resource_conflict` | ❌ R.5B intencional |
| Event cancelled | `cancel_event` | ❓ no `reopen_event`? (catalog tiene `reopen_event` — verificar dispatch) |

**Sumario state coverage:** 3 🟢 · 3 🟡 · 1 🔴 · 1 ❓. Resource `inactive` ORPHAN + Event actions MISSING son P1.

---

## Audit 12 · Permission Audit (Batch 2 cierre) — 🟢 SOLID

| Surface | descriptor.actions[].enabled | UI gate | RPC enforcement | Match |
|---|---|---|---|---|
| `grant_right` button | ✅ | `ResourceV2:471 .disabled(!action.enabled)` | `grant_right` SECURITY DEFINER `actor_has_right(OWN/MANAGE)` + `has_actor_authority` | 🟢 |
| `revoke_right` button | ✅ | ídem | `revoke_right` multi-gate (holder/OWN/MANAGE/authority) | 🟢 |
| `archive_resource` | ✅ via dispatcher B.8 | ídem | `archive_resource` has_actor_authority | 🟢 |
| `record_expense` quick action Context | ✅ | `ContextV2:1112 .disabled(!action.enabled)` | `record_expense` has_actor_authority `money.create` | 🟢 |
| `create_decision` | ✅ | ídem | `create_decision` has_actor_authority `governance.create` | 🟢 |
| `invite_member` | ✅ | ídem + `MembersListView.swift:44 store.canInvite()` | `create_invite` / `invite_member` validated | 🟢 |
| `request_resource_reservation` (reserve_resource) | ✅ via dispatch | iOS form runtime | `request_resource_reservation` `_can_manage_reservations()` + self USE | 🟢 |
| `approve_reservation` | ✅ | `ResourceV2:471` | `approve_reservation` `_can_manage_reservations` | 🟢 |
| `cancel_reservation` | ✅ | ídem | `cancel_reservation` (gate self+manage) | 🟢 (presumido) |
| `vote_decision` | ✅ via `actor_has_permission` | DecisionDetailView | `vote_decision` SECURITY DEFINER | 🟢 |
| `resolve_resource_conflict` (3-kind dialog) | ✅ | ConflictsModifier | `resolve_resource_conflict` `_can_manage_reservations` o `has_actor_authority('resources.manage')` | 🟢 |
| `assign_role` | ❓ | MemberDetailView (no leído full) | `assign_role` (presumido has_actor_authority) | 🟡 sin confirmar pero patrón estándar |

**Hallazgos clave:**

- ✅ `descriptor.actions[].enabled` honrado consistentemente (`.disabled()`).
- ✅ `action.reason` se muestra en disabled state (`ResourceV2:525-528`).
- ✅ Sheets nativos abren sólo vía `handleActionTap` que validó.
- ✅ RPCs SECURITY DEFINER tienen gate explícito en 100% de los auditados.
- ✅ `descriptor.permissions[]` es info-only (chips More tab), NO gate. Correcto.
- ✅ **0 botones fantasma detectados** en cualquier surface.

**Sumario:** 11 🟢 + 1 🟡 (assign_role, presumido OK). Cadena descriptor → UI → RPC **SOLID**. R.6 puede asumir esta cadena para Rule Engine.

---

## Audit 9 · Founder Flows (Batch 3 cierre)

### Flow 1 · Familia (crear + invitar + gasto + settlement) — 🟡

| Métrica | Valor |
|---|---|
| Clics totales | 13 |
| Pantallas vacías | 1 (post-adjunto doc) |
| Errores user-visible | 0 |
| Acciones ocultas | 1 (invitar requiere nav secundaria) |
| Nav rota | 1 (DocumentsListView missing) |

Status: 🟡 viable con fricción. Bloqueador: documentos invisibles post-attach.

### Flow 2 · Casa (crear + documento + reservar + resolver conflicto) — 🟡

| Métrica | Valor |
|---|---|
| Clics totales | 9 |
| Pantallas vacías | 1 (post-adjunto doc) |
| Errores user-visible | 0 (pero UX confusa) |
| Acciones ocultas | 1 (Resource subtype `primary_residence`/`vacation_home` NO mapeado al form) |
| Nav rota | 1 (no DocumentsListView) |

Status: 🟡 viable con fricción. Bloqueador: documentos invisibles + UX subtype confusa.

**Sub-hallazgo nuevo:** `ReservationIntentLanding:446-450` filtra resource types HARDCODED `["house", "property", "vehicle", "equipment", "reservation", "trip_booking"]` — viola Foundation Lock (debería leer `capability.reservable` del descriptor).

### Flow 3 · Viaje (crear + participantes + fondo + gastos + liquidar) — 🟡

| Métrica | Valor |
|---|---|
| Clics totales | 8 |
| Pantallas vacías | 0 |
| Errores user-visible | 0 (UX dislocado) |
| Acciones ocultas | 2 (participantes manual; money_pool catalog drift fallback enum) |
| Nav rota | 1 (EventScope NO populated → "gasto del evento" feature incompleto) |

Status: 🟡 viable con fricción. money_pool no está en enum fallback de CreateResourceView (líneas 5-53) — si backend `resourceTypeCatalog()` falla, money_pool desaparece.

### Flow 4 · Empresa (crear + recurso + obligación + decisión) — 🔴 BLOQUEADO

| Métrica | Valor |
|---|---|
| Clics totales | 11 |
| Pantallas vacías | 0 |
| Errores user-visible | **1 — `intent.obligation` NO EXISTE en CreateIntentSheet** |
| Acciones ocultas | 2 (obligaciones inaccesibles main flow; resource actions sólo en detail) |
| Nav rota | 1 (Obligaciones no en intent picker) |

Status: 🔴 BLOQUEADO. CreateObligationView existe (línea 6-159) pero inaccesible desde el wizard "Crear". User abandona flow.

### Hallazgos transversales

| Hallazgo | Impacto |
|---|---|
| `intent.obligation` MISSING en CreateIntentSheet | **P0** founder flow 4 blocker |
| `loadKnownActors` falla silenciosa en InviteMembersView (try/catch silencio) | P2 UX |
| EventScope nunca populated por CreateIntentSheet/FormDestination | P1 feature incompleto |
| Resource subtype picker NO existe en CreateResourceView | P1 UX confuso |
| Reservable filter HARDCODED en ReservationIntentLanding (no usa capability.reservable) | P1 viola Foundation Lock |
| 30 vistas con state handling robusto (Loading/Empty/Error) | ✅ |
| Creation guards graceful (silencio si RPC falla) | ✅ |

**Sumario founder flows:** 0 🟢 · 3 🟡 · 1 🔴. Flow 4 blocker es trivial de cerrar (slice agregar enum case + handler).

---

## Sumario por audit (cierre Batch 1 + 2 + 3)

| # | Audit | 🟢 | 🟡 | ⚠️ | ⬛ | 🔴 | ⚪ |
|---|---|---|---|---|---|---|---|
| 1 | Context Detail | 10 | 0 | 1 | 0 | 0 | 0 |
| 2 | Resource Detail (subtypes) | 0 | 8 | 0 | 0 | 0 | 0 |
| 3 | Action Coverage | 16 | 72 | 0 | 0 | 0 | 0 |
| 4 | Capability Coverage | 12 | 4 | 18 | 0 | 0 | 8 |
| 5 | Section Coverage Resource | 7 | 4 | 37 | 0 | 0 | 0 |
| 5 | Section Coverage Context | 10 | 0 | 1 | 0 | 0 | 0 |
| 6 | Widget Coverage Resource | 10 | 1 | 7 | 0 | 0 | 0 |
| 6 | Widget Coverage Context | 10 | 2 | 1 | 0 | 0 | 0 |
| 7 | Descriptor Coverage Resource | 17 | 1 | 0 | 1 | 0 | 1 |
| 7 | Descriptor Coverage Context | 13 | 1 | 0 | 4 | 0 | 1 |
| 8 | Navigation | 0 | 4 | 5 | 2 | 0 | 0 |
| 9 | Founder Flows | 0 | 3 | 0 | 0 | 1 | 0 |
| 10 | Attention System | 3 | 2 | 0 | 2 | 0 | 0 |
| 11 | State Coverage | 3 | 3 | 0 | 0 | 1 | 0 (1 ❓ Document) |
| 12 | Permission Audit | 11 | 1 | 0 | 0 | 0 | 0 |

---

## Sumario por prio (cierre final tras Batch 3)

### P0 — Roto end-to-end, demo-blocker (3 items)

| ID | Audit | Finding | Slice | Status founder |
|---|---|---|---|---|
| P0-01 | 3 | 72/88 actions sin RPC dispatch raise `0A000` al ejecutar | R.5X.fix.A: mapper iOS `not_implemented → "Próximamente"` | ✅ firmado D+C |
| P0-02 | 9 | Flow 4 Empresa BLOQUEADO: `intent.obligation` NO existe en CreateIntentSheet → user no puede crear obligaciones desde wizard | R.5X.fix.B: agregar enum case `.obligation` + FormDestination switch + CreateObligationView entry | ⏳ |
| P0-03 | Batch 2 docs | Activity catalog/emit DRIFT: catalog tiene `document.created` pero `register_document` emite `document.registered` → Activity feed render roto | R.5X.fix.C: 1-line migration backend | ⏳ |

### P1 — Incompleto (≈30 items)

| ID | Audit | Finding | Slice |
|---|---|---|---|
| P1-01 | 1, 7, batch 2 docs | `DocumentsListView` + `DocumentDetailView` NO existen; `descriptor.linkedDocuments`/`documentsPreview` dead; QuickLook no integrado | **R.5X.fix.docs** (3 views nuevas + `listContextDocuments` RPC client + DocumentsStore extension + 5 wire-ups) |
| P1-02 | 5 | 11 sections Resource founder-priority INERT (`documents/insurance/maintenance/taxes/valuation/leases/condition/custody/income/payments/expenses`) | R.5X.fix.sections — placeholder views con "Próximamente" honesto o subview embebido en V2 |
| P1-03 | 6 | 7 widgets Resource INERT (`condition_status/custody_status/document_status/insurance_status/maintenance_status/tax_status/resource_value`) | R.5X.fix.widgets — mapping widget→section destination + placeholder |
| P1-04 | 10 | `settlement_attention` + `rule_*` MISSING en attention_inbox | **R.5Y.A1** (Attention Center backend + iOS dispatch) |
| P1-05 | 10 | `reservation_conflict` attention abre lista (no detail); `ReservationConflictView` existe pero ningún row la abre | R.5Y.A2 wire row → ReservationConflictView |
| P1-06 | 1 | Context V2 quick actions `default: break` para 8°+ action | R.5X.fix.quickactions — audit `context_available_actions` output + ampliar switch |
| P1-07 | 8 | Child contexts card outsider `.opacity(0.5)` sin error/CTA | R.5X.fix.childContexts — disclaimer + "Solicitar acceso" CTA |
| P1-08 | 11 | Resource `inactive` ORPHAN — backend state nunca rendered iOS | R.5X.fix.inactive — badge en heroCard |
| P1-09 | 11 | Event EventDetailView SIN actions (`close_event`/`edit_event` MISSING UI) | R.5X.fix.eventActions — espejo de Obligation actions |
| P1-10 | 1 | Context `documents` More tab → fallback ActivityFeedView | cierra con P1-01 |
| P1-11 | 9 Flow 2 | Resource subtype picker NO existe en CreateResourceView | R.5X.fix.subtypePicker |
| P1-12 | 9 Flow 2 | `ReservationIntentLanding:446-450` filtra resource types HARDCODED → viola Foundation Lock | R.5X.fix.reservableFilter — leer `capability.reservable` del descriptor |
| P1-13 | 9 Flow 3 | EventScope NO populated por CreateIntentSheet/FormDestination | R.5X.fix.eventScope — wire scope desde context |
| P1-14 | batch 2 docs | 6 RPCs documents missing (`list_context_documents`, `archive_document`, `sign_document`, `approve_document`, `request_approval`, `upload_new_version`) | cierra parcial con P1-01 (mínimo `list_context_documents`); resto deferred a `request_decision` pattern |

### P2 — UX (≈15 items)

| ID | Audit | Finding |
|---|---|---|
| P2-01 | 2 | `revoke_right` sin sheet propio (cae a runtime form) — slice espejo de `GrantRightSheet` |
| P2-02 | 1 | `roles[]` row Context People tab V2 NO push (V1 sí) |
| P2-03 | 8 | Conflict individual "Ver detalle" no existe — decidir nueva view o dialog inline suficiente |
| P2-04 | 1 | `pending_invitations_preview` More card sin manage inline |
| P2-05 | 6 | Context widget `active_projects` sin destino |
| P2-06 | 11 | Context badge archived en lista (`is_context_archived` bool no renderizado) |
| P2-07 | 9 | `loadKnownActors` falla silenciosa en InviteMembersView |
| P2-08 | 7 | `metrics.balance`+`metrics.lastMovementAt` dormant (UX value); `state.archivedAt/lockedForGovernance/openDecisionId` dormant |
| P2-09 | 5 | Resource sections 2nd-tier (`access/location/budget/disputes/expenses` x N subtypes) sin destino |
| P2-10 | 7 | JSONValue holdouts HIGH RISK: `linkedEvents/linkedObligations/linkedDecisions` parsed inline, `membership`/`context` opaque |

### P3 — Optimización / cleanup (≈12 items)

| ID | Audit | Finding |
|---|---|---|
| P3-01 | 4 | 6 capabilities catalog ⚪ NO_EFFECT (`approval_required/depreciable/monetary/rentable/sellable/usable`) — cleanup |
| P3-02 | 6 | `conflicts_summary` widget Resource+Context absorbido por conflictsCard (duplicate render) |
| P3-03 | 5 | Resource sections residuales (`approvals/signatures/versions/tasks/checklist/itinerary/fines/usage_history/stock/recurrence/calendar`) sin destino — defer-when-needed |
| P3-04 | 7 | Helper API sin uso: `.has()`, `.section()`, `.action()` — eliminar o adoptar |
| P3-05 | 1 | Overview ContextV2 sin EmptyState propio |
| P3-06 | 7 | `roles[].description`, `metrics.balanceByCurrency` (vs `moneyPreview.myBalanceByCurrency`) dormant |
| P3-07 | 2 | Resource `rights[]` v1 legacy only en descriptor (v2 ya muestra via hero) |

### Founder Q (decisión bloqueante)

| Q | Tema | Recomendación temporal |
|---|---|---|
| FQ-1 | Documents `immutable v1` se queda o abrimos archive/delete? | **Open archive** vía nuevo RPC `archive_document` SECURITY DEFINER (soft delete). Blobs Storage permanecen. |
| FQ-2 | Sign/approve documents inline o via Decisions? | **Vía Decisions** (`request_decision` template `document_approval`/`document_signing`) — consistente con `transfer_ownership` |
| FQ-3 | Document `status` lifecycle = `draft/shared/archived`? | Iniciar simple: `archived_at IS NULL` = active, ≠ NULL = archived. Sin enum por ahora. |
| FQ-4 | Versions = `parent_document_id` o tabla aparte? | **Deferred** post-R.6. `upload_new_version` queda "Próximamente" hasta firma. |

---

**R.5X cierre listo**: ver `Plans/Active/R5X_ProductCompletenessAudit.md` § Backlog priorizado para slice IDs y handoff a R.5Y + R.6.
